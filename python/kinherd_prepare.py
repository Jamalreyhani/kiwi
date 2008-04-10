


# Quick and ugly hack to preprocess iris seed volumes.
# data is



import ugly_minimizer as minimizer
import subprocess
import os
import sys
import re
import copy
import glob
import tempfile
import time, calendar
import pickle
import shutil
from optparse import OptionParser

pjoin = os.path.join

def get_stations_blacklist(blacklist_station_file):

    blacklist = {}
    if os.path.exists(blacklist_station_file):
        f = open(blacklist_station_file, 'r')
        for line in f:
            toks = line.split()
            if toks:
                if toks[0][0] == '#': continue
                station = toks.pop(0)
                blacklist[station] = set(toks)
        f.close()
    return blacklist
    
class Station:
    def __init__(self, sid, nid, lat, lon, elevation, name='', components=None):
        self.sid = sid
        self.nid = nid
        self.lat = lat
        self.lon = lon
        self.elevation = elevation
        self.name = name
        if components is None:
            self.components = set()
        else:
            self.components = components
            
        self.dist_deg = None
        self.dist_m = None
        self.azimuth = None

    def set_event_relative_data( self, dist_deg, dist_m, azi, timerange ):
        self.dist_deg = dist_deg
        self.dist_m = dist_m
        self.azimuth = azi
        self.timerange = timerange
        
class Event:
    def __init__(self, lat, lon, time):
        self.lat = lat
        self.lon = lon
        self.time = time
        
class Trace:   
    def __init__(self, sacfile, polezerofile, respfile, sid, nid, component, locid ):
        header_vars =  { 'B':None, 'E':None, 'KZDATE':None, 'KZTIME':None, 'DELTA':None, 'NPTS':None }
        sac_cmd = 'readhdr %s\nlisthdr %s\n' % (sacfile, ' '.join(header_vars.keys()))
        (out,err) = sac_exec( sac_cmd )
        
        for line in out.splitlines():
            toks = line.strip().split(' = ',1)
            if len(toks) == 2:
                k,v = toks
                if k in header_vars:
                    header_vars[k] = v
        
        for k,v in header_vars.iteritems():
            if v is None:
                raise Exception("can't get header value '%s' from file '%s'" % (k, sacfile))
        
        secs = sac_datetime_to_secs( header_vars['KZDATE'], header_vars['KZTIME'] )
        
        begin = secs + float( header_vars['B'] )
        end = secs + float( header_vars['E'] )
        
        self.sac_reftime = secs
        self.begin = begin
        self.end = end
        self.delta = float(header_vars['DELTA'])
        self.length = int(header_vars['NPTS'])
        self.filename = sacfile
        self.polezero_filename = polezerofile
        self.resp_filename = respfile
        self.sid = sid
        self.nid = nid
        self.component = component
        self.locid = locid
    
    def __cmp__(self,other):
         return cmp(self.sid, other.sid) or cmp(self.component, other.component) or cmp(self.locid, other.locid) or cmp(self.nid, other.nid) 
    
def get_events_from_file( rdseed_event_file ):
    f = open(rdseed_event_file, 'r')
    events = []
    for line in f:
        toks = line.split(', ')
        if len(toks) > 4:
            datetime = toks[1].split('.')[0]
            lat = toks[2]
            lon = toks[3]
            format = '%Y/%m/%d %H:%M:%S'
            secs = calendar.timegm( time.strptime(datetime, format))
            e = Event(
                lat = float(lat),
                lon = float(lon),
                time = secs
            )
            events.append(e)
            
    f.close()
    return events

def dumb_parser( data ):
    
    (in_ws, in_kw, in_str) = (1,2,3)
    
    state = in_ws
    
    rows = []
    cols = []
    accu = ''
    for c in data:
        if state == in_ws:
            if c == '"':
                new_state = in_str
                
            elif c not in (' ', '\t', '\n', '\r'):
                new_state = in_kw
        
        if state == in_kw:
            if c in (' ', '\t', '\n', '\r'):
                cols.append(accu)
                accu = ''
                if c in ('\n','\r'):
                    rows.append(cols)
                    cols = []
                new_state = in_ws
                
        if state == in_str:
            if c == '"':
                accu += c
                cols.append(accu[1:-1])
                accu = ''
                if c in ('\n','\r'):
                    rows.append(cols)
                    cols = []
                new_state = in_ws
        
        state = new_state
    
        if state in (in_kw, in_str):
             accu += c
    if len(cols) != 0:
       rows.append( cols )
       
    return rows


def get_stations_from_file(rdseed_station_file):
    f = open(rdseed_station_file, 'r')
    r = re.compile('(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+"([^"]+)"\s+"([^"]+)"\s+(\S+)\s+(\S+)')
    stations = {}
    
    # sometimes there are line breaks in the station description strings
    fixed_lines = []
    accu = ''
    
    rows = dumb_parser( f.read() )
    
    for cols in rows:
        
            s = Station(
                sid = cols[0],
                nid = cols[1],
                lat = float(cols[2]),
                lon = float(cols[3]),
                elevation = float(cols[4]),
                name = cols[5],
                components = set(cols[6].split())
            )
            stations[(s.sid,s.nid)] = s
            
    f.close()
    
    return stations

def set_time_ranges(event, stations):
    lat = []
    lon = []
    comps = []
    for s in stations:
        lat.append(s.lat)
        lon.append(s.lon)
        comps.append( 'd' )
    
    m = minimizer.Minimizer()
    m.do_set_source_location(event.lat, event.lon, 0.0)
    m.set_receivers(lat, lon, comps)
    dist_deg, dist_m, azi = m.get_distazi()
    
    pbeg = minimizer.Phase('begin')
    pend = minimizer.Phase('end')
    
    for i,s in enumerate(stations):
        s.set_event_relative_data( dist_deg[i], dist_m[i], azi[i], (pbeg(dist_m[i]), pend(dist_m[i])) )
        
    m.close()
    
def rdseed( input_fn, output_dir, output_dir_raw, verbose=True ):
    
    # seismograms:
    rdseed_proc = subprocess.Popen([rdseed_prog, '-f', input_fn, '-d', '-z', '3', '-p', '-E', '-R', '-q', output_dir_raw], 
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (out,err) = rdseed_proc.communicate()
    if verbose: sys.stderr.write( 'rdseed: '+err )
    
    # event data:
    rdseed_proc = subprocess.Popen([rdseed_prog, '-f', input_fn, '-e', '-q', output_dir], 
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (out,err) = rdseed_proc.communicate()
    if verbose: sys.stderr.write( 'rdseed: '+err )
    
    # station summary information:
    rdseed_proc = subprocess.Popen([rdseed_prog, '-f', input_fn, '-S', '-q', output_dir], 
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (out,err) = rdseed_proc.communicate()
    if verbose: sys.stderr.write( 'rdseed: '+err )
    
    # station headers:
    rdseed_proc = subprocess.Popen([rdseed_prog, '-f', input_fn, '-s', '-q', output_dir], 
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (out,err) = rdseed_proc.communicate()
    fout = open(os.path.join(ouput_dir,'station_header_infos'),'w')
    fout.write( out )
    fout.close()
    if verbose: sys.stderr.write( 'rdseed: '+err )

def indent( text, indentation='   ' ):
    outtext = ''
    for line in text.splitlines():
        outtext += indentation+line+"\n"
    return outtext
        

def sac_exec( command ):
    sac_macro_file = tempfile.NamedTemporaryFile('w')
    sac_macro_file.write( command )
    sac_macro_file.flush()
    sac = subprocess.Popen([sac_prog, sac_macro_file.name], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (out,err) = sac.communicate()
    sac_macro_file.close()
    
    if err.lower().find('error') != -1 or out.lower().find('error') != -1:
        raise Exception( 'Error occured during processing sac command:\n%s  output:\n%s\n  error:\n%s\n'  % (indent(command), indent(out), indent(err)) )
    
    return (out,err)
    
def sac_datetime_to_secs(sacdate, sactime):
    date = sacdate.split()
    date = ' '.join([date[0],date[1],date[-1]])
    
    mili = float(sactime[-4:])
    format = '%b %d %Y %H:%M:%S'
    secs = calendar.timegm( time.strptime(date+' '+sactime[:-4], format) )
    return secs + mili

def get_traces( stations, datadir_raw ):
    traces = {}
    for s in stations:
        for component in s.components:
            sacfiles = glob.glob( pjoin(datadir_raw,'????.???.??.??.??.????_????.???.??.??.??.????.%s.%s.*.%s.?.SAC' % (s.nid,s.sid,component) ) )
            if not sacfiles:
                sys.exit('no SAC file for station %s.%s compontent %s found' % ( s.sid, s.nid, component ) )
            
            for sacfile in sacfiles:
                print 'reading: ', sacfile
                locid = re.findall( '[A-Z]+\.[A-Z0-9]+\.(\d*)\.[A-Z0-9]+\..\.SAC$', sacfile )[0]
                polezerofiles = glob.glob( os.path.join(datadir_raw, 'SAC_PZs_%s_%s_%s_%s_*' % (s.nid,s.sid,component,locid) ) )
                respfile = os.path.join(datadir_raw, 'RESP.%s.%s.%s.%s' % (s.nid, s.sid, locid, component))
                if not polezerofiles:
                    sys.stderr.write('no polezero file found for SAC file: %s' % sacfile)
                    continue
                if len(polezerofiles) > 1:
                    sys.stderr.write('more than one polezero file for SAC file: %s\n' % sacfile + '\n'.join(polezerofiles) + '\n')
                    continue
                try:
                    traces[(s.nid, s.sid, component, locid, sacfile)] = Trace(sacfile, polezerofiles[0], respfile, s.sid, s.nid, component, locid)
                except:
                    sys.stderr.write(sys.exc_info()[0])
                    
    return traces

def sactime( secs ):
    t = time.gmtime(secs)
    ms = secs % 1
    return ( t[0], t[7], t[3], t[4], t[5], ms )
    
    
def preprocess( datadir_dis, seismograms, ref_time, c_low=0.01, c_high=1., new_delta_t=0.5):

    shutil.rmtree( datadir_dis )
    ensure_dir( datadir_dis )
    
    
    commands = '''read %s
rmean
rtrend
transfer from evalresp fname %s to none freqlimits %g %g %g %g
%s
cutim %g %g
write %s
'''

    processed = []
    
    for s in sorted(seismograms):
        if s.end - s.begin > 1./c_low*3.:
            
            print 'processing:', s.sid, s.nid, s.component, s.locid
            
            displ_filename = pjoin( datadir_dis, os.path.basename(s.filename.replace( '.SAC', '.DIS.SAC' )) )
            
            
            beg = s.begin-s.sac_reftime+1./c_low*2.
            end = s.end-s.sac_reftime
            try:
                if abs(new_delta_t/s.delta - 10.) < 10./10000.:
                    d = (2, 5)
                elif abs(new_delta_t/s.delta - 20.) < 20./10000.:
                    d = (4, 5)
                elif abs(new_delta_t/s.delta - 50.) < 50./10000.:
                    d = (5, 5, 2)
                else:
                    raise Exception('unexpected sampling interval: %g' % s.delta)
                decimations = ''.join(['decimate %i\n' % dd for dd in d])
                    
            
                # correct for instrument response
                sac_command = commands % (s.filename, s.resp_filename, c_low/2., c_low, c_high, c_high*2., decimations, beg, end, displ_filename)
                (out,err) = sac_exec(sac_command)
                
                # set common reference time
                sac_command = '''read %s
chnhdr O gmt %i %i %i %i %i %i
listhdr O
''' % ((displ_filename,)+sactime( ref_time ))
                (out,err) = sac_exec(sac_command)
                
                for line in out.splitlines():
                    toks = line.strip().split(' = ',1)
                    if len(toks) == 2:
                        k,v = toks
                        if k == 'O':
                            offset = float(v)
                
                sac_command = '''read %s
chnhdr ALLT %g IZTYPE IO
chnhdr DELTA %g
write %s
''' % (displ_filename, -offset, new_delta_t, displ_filename)
                (out,err) = sac_exec(sac_command)
                
                
                s_pro = Trace(displ_filename, '', '', s.sid, s.nid, s.component, s.locid)
                
                processed.append( s_pro )
                
            except:
                print 'ignoring:', s.sid, s.nid, s.component, s.locid
                
    return processed
            

def select_traces( traces, event, stations, blacklist, wanted_components ):
    selected = {}
    for trace in sorted(traces.values()):
    
        # check if trace is blacklisted
        if trace.sid in blacklist:
            if blacklist[trace.sid]: # if only certain components are blacklisted
                if trace.component in blacklist[trace.sid]:
                    print 'dropping (component blacklisted):', trace.filename
                    continue
            else:
                print 'dropping (station blacklisted):', trace.filename
                continue
                
        # check if component is wanted:
        if trace.component not in wanted_components:
            print 'dropping (unwanted component):', trace.filename
            continue
       
        # check if time span is in needed time span
        needed_trange = stations[(trace.sid,trace.nid)].timerange
        trace_trange = (trace.begin - event.time, trace.end - event.time)
        if (trace_trange[0] > needed_trange[0] or 
            trace_trange[1] < needed_trange[1]):
            print 'dropping (timespan incomplete):', trace.filename
            continue
        
        # get rid of duplicates
        selected[(trace.nid, trace.sid, trace.component)] = trace
    
    
            
    return selected.values()
    
def ensure_dir(d):
    if not os.path.isdir(d):
        if os.path.exists(d):
            sys.exit(d+' exists and is not a directory')
        os.mkdir( d )


def read_config(filename):
    #try:
        config = {}
        keys = ('seed_file', 
                'gfdb_path', 
                'frequency_range', 
                'blacklist_station_file', 
                'wanted_components',  
                'data_dir', 
                'ieq_data_dir')
                
        file = open(filename,'r')
        for line in file:
            if line.lstrip().startswith('#'): continue
            toks = line.split( ':', 1 )
            if len(toks) == 2:
                k = toks[0].strip()
                if k in keys:
                    config[k] = toks[1].strip()
                    
        file.close()
        return config
        
    #except:
    #    sys.exit("cannot read config file: %s" % filename)
        
steps = ('unpack', 'preprocess', 'setup')

usage = 'usage: preprocess.py config-file ( unpack | preprocess | setup )'
if len(sys.argv) != 3: sys.exit(usage)
config_file = sys.argv[1]
step = sys.argv[2]
if not step in steps: sys.exit(usage)
        
c = read_config(config_file)

seedfile = c['seed_file']
datadir = c['data_dir']
datadir_raw = pjoin(datadir,'raw')
datadir_dis = pjoin(datadir,'displacement')

ieq_datadir = c['ieq_data_dir']

gfdb_path = c['gfdb_path']
frequency_range = [float(x) for x in c['frequency_range'].split()]
blacklist_station_file = c['blacklist_station_file']
wanted_components = c['wanted_components'].split()

component_translate = {'BHN': 'n',
                       'BHE': 'e',
                       'BHZ': 'u'}


ensure_dir( datadir )
ensure_dir( datadir_raw )
ensure_dir( ieq_datadir )

gfdb = minimizer.get_gfdb_infos(gfdb_path)
    
rdseed_prog = 'rdseed'
sac_prog = 'sac'


if step == 'unpack':
    rdseed( seedfile, datadir, datadir_raw  )

if step == 'preprocess':
    event = get_events_from_file( os.path.join(datadir,'rdseed.events') )[0]
    stations = get_stations_from_file( os.path.join(datadir,'rdseed.stations') )

    set_time_ranges( event, stations.values() )
    traces = get_traces( stations.values(), datadir_raw )
    blacklist = get_stations_blacklist( blacklist_station_file )
    selected_traces = select_traces( traces, event, stations, blacklist, set(wanted_components) )
    
    processed_traces = preprocess( datadir_dis, selected_traces, event.time, c_low=frequency_range[0], c_high=frequency_range[1], new_delta_t=gfdb.dt )
    
    summaryfile = os.path.join(datadir, 'preprocess.status')
    f = open(summaryfile,'w')
    f.write('''# processing_date = %s
# frequency_range = %g %g
# sampling_rate = %g
# reference_date = %s
''' % (time.asctime(time.gmtime(time.time())),
       frequency_range[0], frequency_range[1], 
       gfdb.dt,
       time.asctime(time.gmtime(event.time))))
    for t in processed_traces:
        f.write('%s\n' % t.filename)        
    f.close()
    
    cachefile = os.path.join(datadir, 'preprocess.cache')
    f = open(cachefile, 'w')
    pickle.dump( (event, stations, processed_traces), f )
    f.close()
    
if step == 'setup':
    cachefile = os.path.join(datadir, 'preprocess.cache')
    f = open(cachefile, 'r')
    (event, stations, traces) = pickle.load( f )
    f.close()
    
    compo_order = dict([(comp,i) for (i,comp) in enumerate(wanted_components)])
    
    station_components = {}
    for t in traces:
        if (t.sid,t.nid) in station_components:
            station_components[(t.sid,t.nid)].append(t.component)
        else:
            station_components[(t.sid,t.nid)] = [ t.component ]
        
    def compare_component(a,b):
        return cmp(compo_order[a], compo_order[b])
    
    for compolist in station_components.values():
        compolist.sort( cmp=compare_component )
    
    def compare_distance(a,b):
        return cmp(stations[(a.sid,a.nid)].dist_m, stations[(b.sid,b.nid)].dist_m)

    
    traces.sort(cmp=compare_distance)
    stations_seen = set()
    istation = 0
    f = open(os.path.join(ieq_datadir, 'receivers.table'), 'w')
    for t in traces:
        if not (t.sid,t.nid) in stations_seen:
            s = stations[(t.sid,t.nid)]
            compos = ''.join([component_translate[x] for x in  station_components[(t.sid,t.nid)]])
            line = "%15.9g %15.9g %3s %s.%s\n" % ( s.lat, s.lon, compos, s.sid, s.nid )
            f.write(line)
            stations_seen.add((t.sid,t.nid))
            istation += 1
        
        dstfn = os.path.join(ieq_datadir, 'reference-%i-%c.sac' % (istation, component_translate[t.component]))
        shutil.copy(t.filename, dstfn )
    f.close()
    
    f = open(os.path.join(ieq_datadir, 'source-origin.table'), 'w')
    f.write( "%g %g %g\n" % (event.lat, event.lon, 0.0) )
    f.close()
 
    
    