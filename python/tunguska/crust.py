
from tunguska import util
import numpy as num
import os, sys
import copy

LICE, LWATER, LSOFTSED, LHARDSED, LUPPERCRUST, LMIDDLECRUST, LLOWERCRUST, LBELOWCRUST = range(8)

class Crust2Profile:
    
    layer_names = ('ice', 'water', 'soft sed.', 'hard sed.', 'upper crust', 'middle crust', 'lower crust')
    
    def __init__(self, ident, name, vp, vs, rho, thickness, elevation):
        self._ident = ident
        self._name = name
        self._vp = vp
        self._vs = vs
        self._rho = rho
        self._thickness = thickness
        self._elevation = elevation
        
    def set_elevation(self, elevation):
        self._elevation = elevation
        
    def set_thickness(self, ilayer, thickness):
        self._thickness[ilayer] = thickness
        
    def elevation(self):
        return self._elevation
    
    def __str__(self):
        
        vvp, vvs, vrho, vthi = self.averages()
        
        return '''type, name:              %s, %s
elevation:               %15.5g
crustal thickness:       %15.5g
average vp, vs, rho:     %15.5g %15.5g %15.5g
mantle ave. vp, vs, rho: %15.5g %15.5g %15.5g

%s''' % (self._ident, self._name, self._elevation, vthi, vvp, vvs, vrho,
    self._vp[LBELOWCRUST],self._vs[LBELOWCRUST],self._rho[LBELOWCRUST],
    '\n'.join( [ '%15.5g %15.5g %15.5g %15.5g   %s' % x for x in zip(
        self._thickness, self._vp[:-1], self._vs[:-1], self._rho[0:-1],
        Crust2Profile.layer_names ) ])
      )
   

    def averages(self):
        '''Get crustal averages for vp, vs and density and total crustal thickness,
      
        Takes into account ice layer.
        Does not take into account water layer.
        '''
        
        vthi = num.sum(self._thickness[3:]) + self._thickness[LICE]
        vvp = num.sum(self._thickness[3:] / self._vp[3:-1]) + self._thickness[LICE] / self._vp[LICE]
        vvs = num.sum(self._thickness[3:] / self._vs[3:-1]) + self._thickness[LICE] / self._vs[LICE]
        vrho = num.sum(self._thickness[3:] * self._rho[3:-1]) + self._thickness[LICE] * self._rho[LICE]
            
        vvp = vthi / vvp
        vvs = vthi / vvs
        vrho = vrho / vthi
    
        return vvp, vvs, vrho, vthi
        
def sa2arr(sa):
    return num.array([ float(x) for x in sa ], dtype=num.float)

def wrap(x, mi, ma):
    if mi <= x and x <= ma: return x
    return x - math.floor((x-mi)/(ma-mi)) * (ma-mi)

def clip(x, mi, ma):
    return min(max(mi,x),ma)

class Crust2:
    
    fn_keys      = 'CNtype2_key.txt'
    fn_elevation = 'CNelevatio2.txt'
    fn_map       = 'CNtype2.txt'
    
    nlo = 180
    nla = 90
    
    def __init__(self, directory):
        self._directory = directory
        self._typemap = None
        self._load_crustal_model()
        
    def get_profile(self, lat, lon):
        '''Get crustal profile at a specific location.'''
        
        return self._typemap[self._indices(float(lat),float(lon))]
        
    def _indices(self, lat,lon):
        lat = clip(lat, -90., 90.)
        lon = wrap(lon, -180., 180.)
        dlo = 360./Crust2.nlo
        dla = 180./Crust2.nla
        cola = 90.-lat
        ilat = int(cola/dla)
        ilon = int((lon+180.)/dlo)
        return ilat, ilon
        
    def _load_crustal_model(self):
        
        path_keys = os.path.join(self._directory, Crust2.fn_keys)
        f = open(path_keys, 'r')
        
        # skip header
        for i in range(5):
            f.readline()
                    
        profiles = {}
        while True:
            line = f.readline()
            if not line:
                break
            ident, name = line.split(None, 1)
            line = f.readline()
            vp = sa2arr(line.split()) * 1000.
            line = f.readline()
            vs = sa2arr(line.split()) * 1000.
            line = f.readline()
            rho = sa2arr(line.split()) * 1000.
            line = f.readline()
            toks = line.split()
            thickness = sa2arr(toks[:-2]) * 1000.
            
            profiles[ident] = Crust2Profile(ident.strip(), name.strip(), vp, vs, rho, thickness, 0.0)
            
        f.close()
        
        path_map = os.path.join(self._directory, Crust2.fn_map)
        f = open(path_map, 'r')
        f.readline() # header
        
        amap = {}
        for ila, line in enumerate(f):
            keys = line.split()[1:]
            for ilo, key in enumerate(keys):
                amap[ila,ilo] = copy.deepcopy(profiles[key])
            
        f.close()
        
        path_elevation = os.path.join(self._directory, Crust2.fn_elevation)
        f = open(path_elevation, 'r')
        f.readline()
        for ila, line in enumerate(f):
            for ilo, s in enumerate(line.split()[1:]):
                p = amap[ila,ilo]
                p.set_elevation(float(s))
                if p.elevation() < 0.:
                    p.set_thickness(LWATER, -p.elevation())
        
        f.close()
        
        self._typemap = amap
        
        
d = os.path.join(util.kiwi_aux_dir(), 'crust2x2')
c = Crust2(d)
p = c.get_profile(sys.argv[1], sys.argv[2])

print p
