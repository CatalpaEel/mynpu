"""Read GDS records and flatten selected polygons for local geometry audits."""
import gzip
import math
import struct
from pathlib import Path

def real8(data):
    if not any(data):
        return 0.0
    return (-1 if data[0] & 128 else 1) * 16.0 ** ((data[0] & 127) - 64) * int.from_bytes(data[1:], 'big') / 2.0 ** 56

def read_gds(path):
    path = Path(path)
    data = gzip.open(str(path), 'rb').read() if path.suffix == '.gz' else path.read_bytes()
    offset = 0
    cells = {}
    current = None
    element = None
    scale = None
    endlib = False
    while offset + 4 <= len(data):
        size, kind, dtype = struct.unpack('>HBB', data[offset:offset+4])
        if size < 4 or offset + size > len(data):
            raise ValueError('Invalid GDS record at {}'.format(offset))
        payload = data[offset+4:offset+size]
        offset += size
        if kind == 4:
            endlib = True
            break
        if kind == 3:
            scale = real8(payload[8:16]) * 1e6
        elif kind == 6:
            current = payload.rstrip(b'\0').decode()
            cells[current] = []
        elif kind in (8, 9, 10, 11, 12, 21):
            element = {'kind': kind, 'mirror': False, 'angle': 0, 'mag': 1}
        elif element is not None:
            if kind == 13:
                element['layer'] = struct.unpack('>H', payload)[0]
            elif kind == 16:
                coords = struct.unpack('>' + str(len(payload)//4) + 'i', payload)
                element['xy'] = list(zip(coords[::2], coords[1::2]))
            elif kind == 18:
                element['ref'] = payload.rstrip(b'\0').decode()
            elif kind == 19:
                element['array'] = struct.unpack('>HH', payload)
            elif kind == 25:
                element['text'] = payload.rstrip(b'\0').decode(errors='replace')
            elif kind == 26:
                element['mirror'] = bool(struct.unpack('>H', payload)[0] & 0x8000)
            elif kind == 27:
                element['mag'] = real8(payload)
            elif kind == 28:
                element['angle'] = real8(payload)
            elif kind == 17:
                cells[current].append(element)
                element = None
    if not endlib or scale is None:
        raise ValueError('GDS ENDLIB/UNITS missing')
    refs = {e['ref'] for entries in cells.values() for e in entries if 'ref' in e}
    return cells, scale, sorted(refs - set(cells))

def flatten(cells, name, layers, matrix=(1, 0, 0, 1, 0, 0), depth=0):
    if depth > 32:
        raise ValueError('Excessive hierarchy depth')
    a, b, c, d, tx, ty = matrix
    def point(p):
        x, y = p
        return (a*x+b*y+tx, c*x+d*y+ty)
    for e in cells[name]:
        if 'ref' in e:
            if e['ref'] not in cells:
                raise ValueError('Missing structure ' + e['ref'])
            angle = math.radians(e['angle'])
            co, si = math.cos(angle)*e['mag'], math.sin(angle)*e['mag']
            sign = -1 if e['mirror'] else 1
            ra, rb, rc, rd = co, -si*sign, si, co*sign
            origins = [e['xy'][0]]
            if 'array' in e:
                nx, ny = e['array']
                p0, px, py = e['xy']
                origins = [(p0[0]+i*(px[0]-p0[0])/nx+j*(py[0]-p0[0])/ny,
                            p0[1]+i*(px[1]-p0[1])/nx+j*(py[1]-p0[1])/ny)
                           for i in range(nx) for j in range(ny)]
            for origin in origins:
                ox, oy = point(origin)
                nested = (a*ra+b*rc, a*rb+b*rd, c*ra+d*rc, c*rb+d*rd, ox, oy)
                for item in flatten(cells, e['ref'], layers, nested, depth+1):
                    yield item
        elif e.get('layer') in layers and e['kind'] in (8, 12):
            yield dict(e, xy=[point(p) for p in e['xy']])
