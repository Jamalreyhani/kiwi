! $Id: minimizer_engine.f90 703 2008-04-03 15:51:31Z sebastian $ 
! ------------------------------------------------------------------------------
! 
!    Copyright 2007 Sebastian Heimann
! 
!    Licensed under the Apache License, Version 2.0 (the "License");
!    you may not use this file except in compliance with the License.
!    You may obtain a copy of the License at
! 
!        http://www.apache.org/licenses/LICENSE-2.0
! 
!    Unless required by applicable law or agreed to in writing, software
!    distributed under the License is distributed on an "AS IS" BASIS,
!    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
!    See the License for the specific language governing permissions and
!    limitations under the License.
!

module minimizer_engine

  ! this thing represents a source - greensfunction - receiver - seismogram - misfit setup
  
    use constants
    use util
    use unit
    use orthodrome
    use gfdb
    use source
    use seismogram
    use seismogram_io
    use sparse_trace
    use receiver
    use better_varying_string
    use read_table
    use comparator
    use piecewise_linear_function
    
    implicit none

    private
    public set_database
    public set_local_interpolation
    public set_ref_seismograms
    public set_source_location
    public set_source_crustal_thickness_limit
    public set_source_params
    public set_source_params_mask
    public set_source_subparams
    public set_effective_dt
    public set_receivers
    public set_misfit_method
    public set_misfit_filter
    public set_misfit_taper
    public minimize_lm
    public output_seismograms
    public output_seismogram_spectra
    public output_source_model
    public cleanup_minimizer
    public get_source_subparams
    public get_distances
    public get_global_misfit
    public get_misfits
    public get_principal_axes
    public output_cross_correlations
    public shift_ref_seismogram
    public autoshift_ref_seismogram
        
    type(t_psm), save                               :: psm
    real                                            :: effective_dt = 1.
    type(t_tdsm)                                    :: tdsm
    type(t_receiver), dimension(:), allocatable     :: receivers
    type(t_gfdb), save                              :: db
    integer                                         :: misfit_method = L2NORM
    real                                            :: misfit
    type(t_plf),save                                :: filter
    logical                                         :: interpolate = .false.
    
    logical :: database_inited = .false.
    logical :: probes_inited = .false.
    logical :: receivers_inited = .false.
    logical :: source_inited = .false.
    logical :: source_location_inited = .false.
    logical :: seismograms_inited = .false.
    logical :: misfits_inited = .false.
    
    logical :: database_dirty = .true.
    logical :: probes_dirty = .true.
    logical :: receivers_dirty = .true.
    logical :: source_dirty = .true.
    logical :: source_location_dirty = .true.
    logical :: seismograms_dirty = .true.
    logical :: misfits_dirty = .true.
    
    integer :: iterations ! needed by lm_forward_step and minmize_lm
  
  contains
  
    subroutine set_database( db_path, nipx, nipz, ok )
              
        type(varying_string), intent(in)  :: db_path
        integer, intent(in)               :: nipx, nipz
        logical, intent(out)              :: ok
        
        ok = .true.
        
        call gfdb_init(db, db_path, nipx=nipx, nipz=nipz ) ! dies program if not successful
        
        database_inited = .true.
        call dirtyfy_database()
        
    end subroutine
    
    subroutine set_local_interpolation( state )
    
        logical, intent(in) :: state
        interpolate = state
        call dirtyfy_seismograms()
    end subroutine
    
    
    subroutine set_receivers( receiversfn, answer, ok )
    
      ! load receiver list from file
            
        type(varying_string), intent(in)  :: receiversfn
        type(varying_string), intent(out) :: answer
        logical, intent(out)              :: ok
        
        character(len=1024)                 :: components
        integer                             :: ireceiver, nreceivers
        integer                             :: iostat, nskip, iunit
        type(t_geo_coords)                  :: origin
     
      ! this subroutine will be a pain in fortran   
     
        answer = ''
        ok = .true.
        call cleanup_receivers()
        
      ! open the file
        
        call claim_unit( iunit )
        open( unit=iunit, file=char(receiversfn), status="old", action="read", iostat=iostat )
        if (iostat /= 0) then
            call release_unit(iunit)
            call error( "can't open file " // receiversfn )
            ok = .false.
            return
        end if
      
      ! determine how many receivers have to be allocated  and allocate them
      
        nreceivers = count_non_comment_lines( iunit, iostat )
        if (iostat /= 0) then
            close(iunit) 
            call release_unit(iunit)
            call error( "error occured while counting non comment lines in " // receiversfn )
            ok = .false.
            return
        end if
        
        allocate( receivers( nreceivers ) )
  
      ! now really read the file and initialize the receivers
      
        ireceiver = 0
        line_loop : do
            
            nskip  = skip_comments(iunit,iostat)
            if (iostat == IOSTAT_EOF .or. nskip < 0) exit line_loop
            if (iostat /= 0) then
                ok = .false.
                call error("io error occured while skipping comments on file " // receiversfn )
                exit line_loop
            end if
        
            read (iunit,*,iostat=iostat) origin%lat, origin%lon, components
            if (iostat == IOSTAT_EOF) exit line_loop
            if (iostat /= 0) then
                ok = .false.
                call error("io error occured while reading " // receiversfn // " at receiver no " // (ireceiver+1)  )
                exit line_loop
            end if
            
            ireceiver = ireceiver + 1
            if (ireceiver > nreceivers) exit line_loop
            
            call receiver_init(receivers(ireceiver), d2r(origin), components, db%dt, ok )
            if (.not. ok) then 
                call error("initializing receiver failed: possibly a forbidden "// &
                           "combination of receiver components has been given at receiver no. "// ireceiver)
                exit line_loop
            end if
            
        end do line_loop
        
        close(iunit)
        call release_unit(iunit)
        
      ! cleanup and say goodbye if something went wrong
      
        if (.not. ok) then
            call cleanup_receivers()
            return
        end if
        
      ! set filter if one has already been defined
        if (plf_defined(filter)) then
            do ireceiver=1,nreceivers
                call receiver_set_filter( receivers(ireceiver), filter )
            end do
        end if
        
        receivers_inited = .true.
        probes_inited = .false.
        call dirtyfy_receivers()
        
    end subroutine
    
    
    subroutine set_ref_seismograms( reffnbase, refformat, ok )
    
        type(varying_string), intent(in)   :: reffnbase, refformat
        logical, intent(out) :: ok

      ! read a set of reference seismograms from ascii or sac files
        
        integer :: ireceiver, nreceivers
        type(varying_string) :: reffn
        
        call update_receivers( ok )
        if (.not. ok) return
        
        nreceivers = size(receivers)
        
        do ireceiver=1,nreceivers
            reffn = reffnbase // "-" // ireceiver
            call receiver_set_ref_seismogram( receivers(ireceiver), reffn, refformat, ok )
        end do
        
        probes_inited = .true.
        call dirtyfy_probes()
        
    end subroutine
    
    subroutine shift_ref_seismogram( ireceiver, shift, ok )

        integer, intent(in)  :: ireceiver
        real, intent(in)     :: shift
        logical, intent(out) :: ok

        integer :: nreceivers
        integer :: ishift
        
        call update_probes( ok )
        if (.not. ok) return
        
        nreceivers = size(receivers)
        if (ireceiver < 1 .or. nreceivers < ireceiver) then
            ok = .false.
            call error( 'receiver index out of range' )
            return
        end if
        
        ishift = int(nint(shift/db%dt))
        call receiver_shift_ref_seismogram( receivers(ireceiver), ishift )

        call dirtyfy_probes()
        
    end subroutine

    subroutine autoshift_ref_seismogram( ireceiver, shiftrange, shifts, ok )

        integer, intent(in)               :: ireceiver
        real, dimension(2), intent(in)    :: shiftrange
        real, dimension(:), allocatable, intent(inout)   :: shifts
        logical, intent(out)              :: ok

        integer :: nreceivers, irec, ishift
        integer, dimension(2) :: ishiftrange
        
        ok = .true.
        if (allocated(shifts)) deallocate(shifts)

        call update_misfits(ok)
        if (.not. ok) return

        nreceivers = size(receivers)
        ishiftrange(:) = int(nint(shiftrange(:)/db%dt))

        if (ireceiver == 0) then ! apply to all
            allocate( shifts(nreceivers) )
            do irec=1,nreceivers
                call receiver_autoshift_ref_seismogram( receivers(irec), ishiftrange, ishift )
                shifts(irec) = ishift*db%dt
            end do
        else
            if (ireceiver < 1 .or. nreceivers < ireceiver) then
                ok = .false.
                call error( 'receiver index out of range' )
                return
            end if
            allocate(shifts(1))
            call receiver_autoshift_ref_seismogram( receivers(ireceiver), ishiftrange, ishift )
            shifts(1) = ishift*db%dt

        end if
        
        call dirtyfy_probes()
        
    end subroutine

    subroutine set_source_location( lat, lon, ref_time )

        real, intent(in)               :: lat, lon
        double precision, intent(in)   :: ref_time

        type(t_geo_coords) :: origin

        origin%lat = lat
        origin%lon = lon
                
        call psm_set_origin_and_time(psm, origin, ref_time)
        source_location_inited = .true.
        call dirtyfy_source_location()
        
    end subroutine

    subroutine set_source_crustal_thickness_limit( thickness_limit )

        real, intent(in)                 :: thickness_limit

        call psm_set_crustal_thickness_limit(psm, thickness_limit)
        call dirtyfy_source()
        
    end subroutine
    
    subroutine set_source_params( sourcetype, sourceparams, ok )

        integer, intent(in)              :: sourcetype
        real, dimension(:),intent(in)    :: sourceparams
        logical, intent(out) :: ok
        
        call update_source_location( ok )
        if (.not. ok) return
        
        call psm_set(psm, sourcetype, sourceparams )
        
        source_inited = .true.
        call dirtyfy_source()
        
    end subroutine
        
    subroutine set_source_params_mask( params_mask , ok)
    
        logical, dimension(:), intent(in)  :: params_mask
        logical, intent(out) :: ok
        
        call update_source( ok )
        if (.not. ok) return
        
        if (size(psm%params) /= size(params_mask)) then
            ok = .false.
            call error( 'wrong number of elements in mask' )
            return
        end if
        
        call psm_set_mask( psm, params_mask )
        
    end subroutine
    
    subroutine set_source_subparams( subparams, ok )
    
        real, dimension(:), intent(in) :: subparams
        logical, intent(out)              :: ok
         
        ok = .true.
        if (.not. source_inited) then
            ok = .false.
            call error( 'source parameters must be set prior to setting parameter subset' )
            return
        end if
        
        if (count(psm%params_mask) /= size(subparams)) then
            ok = .false.
            call error( 'wrong number of subparams' )
            return
        end if
        
        call psm_set_subparams( psm, subparams )
        call dirtyfy_source()
    
    end subroutine
    
    subroutine set_effective_dt( effective_dt_ )
    
        real, intent(in) :: effective_dt_
        
        effective_dt = effective_dt_
        
        if (source_inited) call discretize_source()
    
        call dirtyfy_source()
        
    end subroutine
    
    subroutine set_misfit_method( norm )
    
        integer, intent(in) :: norm
        
        misfit_method = norm
    
        call dirtyfy_misfits()
        
    end subroutine
        
    subroutine set_misfit_filter( x, y )
    
        real, dimension(:), intent(in) :: x,y
        
        integer :: ireceiver, nreceivers
        
        call plf_make( filter, x, y )
        
        if (allocated(receivers)) then
            nreceivers = size(receivers)
            do ireceiver=1,nreceivers
                call receiver_set_filter( receivers(ireceiver), filter )
            end do
        end if
        
        call plf_destroy( filter )
        
        call dirtyfy_misfits()
        
    end subroutine
    
    subroutine set_misfit_taper( ireceiver, x, y, ok )
        
        integer, intent(in) :: ireceiver
        real, dimension(:), intent(in) :: x,y
        logical, intent(out)              :: ok        
        
        integer :: nreceivers
        type(t_plf) :: taper
         
        call update_probes( ok )
        if (.not. ok) return
        
        nreceivers = size(receivers)
        if (ireceiver < 1 .or. nreceivers < ireceiver) then
            ok = .false.
            call error( 'receiver index out of range' )
            return
        end if
        
        call plf_make( taper, x, y )
        
        call receiver_set_taper( receivers(ireceiver), taper )
        
        call plf_destroy( taper )
        
        call dirtyfy_misfits()
        
    end subroutine
    
    pure function get_nmisfits(receivers)
    
        integer :: get_nmisfits
        type(t_receiver), dimension(:), intent(in) :: receivers
        
        integer :: i
        
        get_nmisfits = 0
        
        do i=1,size(receivers)
            get_nmisfits = get_nmisfits + receivers(i)%ncomponents
        end do
    
    end function
    
    
    subroutine minimize_lm( info, iterations_, misfit_, ok )
      
        integer, intent(out)                        :: info, iterations_
        real, intent(out)                           :: misfit_
        logical, intent(out)                        :: ok
        
        call update_misfits( ok )
        if (.not. ok) return
        
        call minimize_lm_( info, iterations_, misfit_, ok )
    
    end subroutine
    
    subroutine minimize_lm_( info, iterations_, misfit_, ok )
      
        integer, intent(out)                        :: info, iterations_
        real, intent(out)                           :: misfit_
        logical, intent(out)                        :: ok
        
        real, dimension(:), allocatable             :: subparams
        real, dimension(get_nmisfits(receivers))             :: misfits
        integer, dimension(count(psm%params_mask))  :: iwa
        integer, dimension(get_nmisfits(receivers)*count(psm%params_mask)+5*count(psm%params_mask)+get_nmisfits(receivers)) :: wa
        integer                                     :: lwa, nsubparams
        integer                                     :: nmisfits
        real                                        :: tol
        real,dimension(count(psm%params_mask))      :: diag
        
        integer :: maxfev,mode,mp5n,nfev,nprint
        real    :: epsfcn,ftol,gtol,xtol,factor
        
        real :: spmpar ! external function (sminpack)
        
        ok = .true.
        lwa = size(wa)
        nmisfits = size(misfits)

        call psm_get_subparams( psm, subparams, normalized_=.true. )
        nsubparams = size(subparams)
        
      ! set tol to the square root of the machine precision.
      ! unless high precision solutions are required,
      ! this is the recommended setting.
  
        tol = sqrt(spmpar(1))
        iterations = 0
        
        info = 0
        
        if (nsubparams .le. 0 .or. nmisfits .lt. nsubparams .or. tol .lt. 0. &
            .or. lwa .lt. nmisfits*nsubparams + 5*nsubparams + nmisfits) &
                call die("something went wrong in minimize_lm")
        
        maxfev = 500*(nsubparams + 1)
        ftol = tol
        xtol = tol
        gtol = 0.
        epsfcn = 0.
        mode = 2
        nprint = 0
        factor = 0.01
        mp5n = nmisfits + 5*nsubparams
        
        diag(:) = 1.
        
        call lmdif(lm_forward_step,nmisfits,nsubparams,subparams,misfits, &
                    ftol,xtol,gtol,maxfev,epsfcn,diag, &
                    mode,factor,nprint,info,nfev,wa(mp5n+1),nmisfits,iwa, &
                    wa(nsubparams+1),wa(2*nsubparams+1),wa(3*nsubparams+1), &
                    wa(4*nsubparams+1),wa(5*nsubparams+1))
        if (info .eq. 8) info = 4
    
        call resize( subparams, 1, 0 )
        iterations_ = iterations
        misfit_ = misfit
        
    end subroutine
    
    subroutine lm_forward_step( nmisfits, nsubparams, subparams, misfits, iflag )
    
      ! called by lmdif
    
        integer :: nmisfits, nsubparams, iflag
        real    :: subparams(nsubparams), misfits(nmisfits)
        
        integer                             :: imisfit
        integer                             :: ireceiver, icomponent, nreceivers
        logical                             :: ok
        real, dimension(:), allocatable     :: subparams_nn
        
        call psm_set_subparams( psm, subparams, normalized_=.true. )
        call dirtyfy_source()
        
      ! print not normalize subparams 
        call psm_get_subparams( psm, subparams_nn, normalized_=.false. )
        write (stderr,*) subparams_nn
        deallocate( subparams_nn )
        
        call update_misfits( ok )
        if ( .not. ok ) then
            iflag = -2
            return
        end if
        
      ! gather misfits which are stored in receiver objects in misfits array
        imisfit = 1
        nreceivers = size(receivers)
        do ireceiver=1,nreceivers
            do icomponent=1,receivers(ireceiver)%ncomponents
                misfits(imisfit) = receivers(ireceiver)%misfits(icomponent)
                imisfit = imisfit + 1
            end do
        end do
        
        iterations = iterations+1
        
    end subroutine
    
    subroutine discretize_source()
        
        call inform("discretizing source")
      ! convert to discrete source
        call psm_to_tdsm( psm, tdsm, effective_dt )
    
    end subroutine
    
    subroutine calculate_seismograms()
          
      ! Seismograms are calculated for the current configuration
 
        integer                     :: ireceiver, nreceivers
        
        call inform("calculating seismograms")
        nreceivers = size(receivers)
        
        do ireceiver=1,nreceivers
            call make_seismogram( tdsm, receivers(ireceiver), db, interpolate )
        end do
        
        seismograms_inited = .true.
        
    end subroutine
    
    subroutine calculate_misfits()
    
      ! calculate distance between reference and synthetic seismograms
        
        integer :: ireceiver, nreceivers
        real :: misfit_norm_factor 
        
        call inform("calculating misfits")
        nreceivers = size(receivers)        
        
      ! let receivers do the misfit calculation and gather the global misfit
        misfit = 0.
        misfit_norm_factor = 0.
        do ireceiver=1,nreceivers
            call receiver_calculate_misfits( receivers(ireceiver), misfit_method )
            misfit = misfit + sum( receivers(ireceiver)%misfits**2 )
            misfit_norm_factor = misfit_norm_factor + sum( receivers(ireceiver)%misfits_norm_factors**2 )
        end do
        misfit = sqrt(misfit) / sqrt(misfit_norm_factor)
        misfits_inited = .true.
        
    end subroutine
    
    
    subroutine output_source_model( filenamebase,ok )
    
        type(varying_string), intent(in)    :: filenamebase
        logical, intent(out)                :: ok
        
        type(varying_string) :: infofn
        integer :: ofile, icentroid, iostat
    
        call update_source( ok )
        if (.not. ok) return
        
        infofn = filenamebase // "-psm.info"
        call psm_write_info_file( psm, infofn )
        
        infofn = filenamebase // "-tdsm.info"
        call tdsm_write_info_file( tdsm, infofn )
    
        ! dump discrete source centroids to file
        call claim_unit( ofile )
        infofn = filenamebase // "-dsm.table"
        open( unit=ofile, file=char(infofn), status='unknown', iostat=iostat )
        if (iostat /= 0) call die( "failed to open output file: " // infofn )
        do icentroid=1,size(tdsm%centroids)
            write (unit=ofile, fmt=*) &
                tdsm%centroids(icentroid)%north, tdsm%centroids(icentroid)%east, &
                tdsm%centroids(icentroid)%depth, tdsm%centroids(icentroid)%time
        end do
        close( ofile )
        call release_unit( ofile )
    
    end subroutine
        
    subroutine output_seismograms( filenamebase, fileformat, which_probe, which_processing, ok )
        
        type(varying_string), intent(in)  :: filenamebase, fileformat
        integer, intent(in)               :: which_probe, which_processing
        logical, intent(out)              :: ok
        
        type(varying_string)        :: outfn
        integer                     :: ireceiver, nreceivers
        
        if (which_probe == SYNTHETICS) then
            call update_seismograms( ok )
            if (.not. ok) return
        else if (which_probe == REFERENCES) then
            call update_probes( ok )
            if (.not. ok) return
        else
            ok = .false.
            call error("output_seismograms(): which_probe has invalid value")
            return
        end if 
        
        nreceivers = size(receivers)
        do ireceiver=1,nreceivers
            outfn = filenamebase // "-" // ireceiver
            call receiver_output_seismogram( receivers(ireceiver), outfn, fileformat, which_probe, which_processing, ok )
            if (.not. ok) return
        end do
        
        
    end subroutine
    
    subroutine output_seismogram_spectra( filenamebase, which_probe, which_reference, ok )
    
        type(varying_string), intent(in)  :: filenamebase
        integer, intent(in)               :: which_probe, which_reference
        logical, intent(out)              :: ok
        
        type(varying_string)        :: outfn
        integer                     :: ireceiver
        
        if (which_probe == SYNTHETICS) then
            call update_seismograms( ok )
            if (.not. ok) return
        else if (which_probe == REFERENCES) then
            call update_probes( ok )
            if (.not. ok) return
        else
            ok = .false.
            call error("output_seismogram_spectra(): which_probe has invalid value")
            return
        end if 
        
        do ireceiver=1,size(receivers)
            outfn = filenamebase // "-" // ireceiver
            call receiver_output_seismogram_spectra( receivers(ireceiver), outfn, which_probe, which_reference, ok )
            if (.not. ok) return
        end do

    end subroutine
    
    subroutine cleanup_receivers()
    
        integer :: ireceiver
        
        if (allocated(receivers)) then
            do ireceiver=1,size(receivers,1)
                call receiver_destroy( receivers(ireceiver) )
            end do
            deallocate( receivers )
        end if
        
        call dirtyfy_receivers()
        receivers_inited = .false.
        
    end subroutine
    
    subroutine cleanup_minimizer()
        
        call cleanup_receivers()
        
        call tdsm_destroy( tdsm )
        call psm_destroy( psm )
        call gfdb_destroy( db )
        
        call cleanup_comparator()
        call plf_destroy( filter )
        
    end subroutine

    subroutine get_source_subparams( subparams, ok )
        
        real, intent(inout), dimension(:), allocatable :: subparams
        logical, intent(out) :: ok
        ok = .true.
        if (.not. source_inited) then
            ok = .false.
            call error( 'must set source parameters before retrieving them' )
            return
        end if
        call psm_get_subparams( psm, subparams )
    
    end subroutine    
    
    subroutine get_global_misfit( misfit_, ok )
    
        real, intent(out)     :: misfit_
        logical, intent(out)  :: ok
        
        call update_misfits( ok )
        if ( .not. ok ) return
            
        misfit_ = misfit
    
    end subroutine
    
    subroutine get_misfits( misfits_, ok )
    
        real, dimension(:,:), allocatable, intent(inout) :: misfits_
        logical, intent(out)  :: ok
        
        integer :: ireceiver, nreceivers
        integer :: icomp, ncomps
        integer :: imisfit, nmisfits
        
        call update_misfits( ok )
        if ( .not. ok ) return
        
      ! how many are needed?
        nreceivers = size(receivers)
        nmisfits = 0
        do ireceiver=1,nreceivers
            ncomps = size(receivers(ireceiver)%misfits)
            nmisfits = nmisfits + ncomps
        end do
        
        if ( allocated(misfits_) ) deallocate(misfits_)
        allocate( misfits_(2,nmisfits) )
        
      ! fill into temporary array
        imisfit = 1
        do ireceiver=1,nreceivers
            ncomps = size(receivers(ireceiver)%misfits)
            do icomp=1,ncomps
                misfits_(1,imisfit) = receivers(ireceiver)%misfits(icomp)
                misfits_(2,imisfit) = receivers(ireceiver)%misfits_norm_factors(icomp)
                imisfit = imisfit + 1
            end do
        end do
        
    end subroutine
        
    subroutine get_principal_axes( pax, tax, ok )
        
        real, dimension(2), intent(out)  :: pax, tax
        logical, intent(out)  :: ok
   
        call update_source( ok )
        if ( .not. ok ) return
            
        pax(1:2) = psm%pax(1:2)
        tax(1:2) = psm%tax(1:2)
    end subroutine
        
    subroutine get_distances( distances, azimuths, ok )
    
        real(kind=8), dimension(:), allocatable, intent(inout) :: distances, azimuths
        logical, intent(out) :: ok
        
        integer :: ireceiver
    
        call update_source_location( ok )
        if (.not. ok) return
        
        call update_receivers( ok )
        if (.not. ok) return
        
        call resize(distances,1,size(receivers))
        call resize(azimuths,1,size(receivers))
        
        do ireceiver=1,size(receivers)
            call azidist(psm%origin,receivers(ireceiver)%origin, azimuths(ireceiver), distances(ireceiver))
        end do
    
    end subroutine
    
    subroutine output_cross_correlations( filenamebase, shiftrange_, ok )

        type(varying_string), intent(in)  :: filenamebase
        real, dimension(2), intent(in)    :: shiftrange_
        logical, intent(out)              :: ok

        type(varying_string)              :: outfn
        integer                           :: ireceiver
        integer, dimension(2)             :: shiftrange

        call update_seismograms( ok )
        if (.not. ok) return
        call update_probes( ok )
        if (.not. ok) return
        
        shiftrange(:) = int( nint(shiftrange_(:)/db%dt) )

        do ireceiver=1,size(receivers)
            outfn = filenamebase // "-" // ireceiver
            call receiver_calculate_cross_correlations( receivers(ireceiver), shiftrange )
            call receiver_output_cross_correlations( receivers(ireceiver), outfn, ok )
            if (.not. ok) return
        end do

    end subroutine
    
  ! data flow update routines
  
    subroutine update_receivers( ok )
    
        logical, intent(out) :: ok
        
        ok = .true.
        if (.not. receivers_inited) then
            call error("no receivers set")
            ok = .false.
            return
        end if
        
        receivers_dirty = .false.
    
    end subroutine
    
    subroutine update_database( ok )
    
        logical, intent(out) :: ok
        
        ok = .true.
        if (.not. database_inited) then
            call error("no database set")
            ok = .false.
            return
        end if
        
        database_dirty = .false.
    
    end subroutine
    
    subroutine update_source_location( ok )
        
        logical, intent(out) :: ok
        
        ok = .true.
        if (.not. source_location_inited) then
            call error("no source location set")
            ok = .false.
            return
        end if
        
        source_location_dirty = .false.
    
    end subroutine
  
    subroutine update_source( ok )
    
        logical, intent(out) :: ok
                
        call update_source_location( ok )
        if (.not. ok) return
        
        if (.not. source_inited) then
            call error("no source parameters set")
            ok = .false.
            return
        end if
        
        if (source_dirty) then
            call discretize_source()
        end if
        source_dirty = .false.
        
    end subroutine
  
    subroutine update_seismograms( ok )
    
        logical, intent(out) :: ok
                
        call update_source( ok )
        if (.not. ok) return
        call update_database( ok )
        if (.not. ok) return
        call update_receivers( ok )
        if (.not. ok) return
        
        if (seismograms_dirty) then
            call calculate_seismograms()
        end if
        seismograms_dirty = .false.
        
    end subroutine
    
    subroutine update_probes( ok )
    
        logical, intent(out) :: ok
        
        call update_receivers( ok )
        if (.not. ok) return
        
        if (.not. probes_inited) then
            call error("no reference seismograms set")
            ok = .false.
            return
        end if 
        
        probes_dirty = .false.
        
    end subroutine
    
    subroutine update_misfits( ok )
    
        logical, intent(out) :: ok
                
        call update_probes( ok )
        if (.not. ok) return
        call update_seismograms( ok )
        if (.not. ok) return
        
        if (misfits_dirty) then
            call calculate_misfits( )
        end if
        misfits_dirty = .false.
        
    end subroutine

  ! dataflow dirtyfy routines
    
    subroutine dirtyfy_source_location()
        source_location_dirty = .true.
        call dirtyfy_source()
    end subroutine
    
    subroutine dirtyfy_source()
        source_dirty = .true.
        call dirtyfy_seismograms()
    end subroutine
    
    subroutine dirtyfy_database()
        database_dirty = .true.
        call dirtyfy_seismograms()
    end subroutine
    
    subroutine dirtyfy_receivers()
        receivers_dirty = .true.
        call dirtyfy_seismograms()
        call dirtyfy_probes()
    end subroutine
    
    subroutine dirtyfy_seismograms()
        seismograms_dirty = .true.
        call dirtyfy_misfits()
    end subroutine
    
    subroutine dirtyfy_probes()
        probes_dirty = .true.
        call dirtyfy_misfits()
    end subroutine
    
    subroutine dirtyfy_misfits()
        misfits_dirty = .true.
    end subroutine
    
end module
    

