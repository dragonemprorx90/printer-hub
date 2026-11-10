"""Slices a cube for both printers through the HTTP API and checks the G-code
reaches a fake Moonraker. Runs in the Docker image (CI) and on a Mac with
OrcaSlicer installed:  python3 slicer/test_server.py
"""
import glob
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAC = '/Applications/OrcaSlicer.app/Contents'
if 'ORCA' not in os.environ and os.path.isdir(MAC):
    data = tempfile.mkdtemp()
    os.makedirs(f'{data}/system')
    for v in ('Creality', 'Snapmaker', 'OrcaFilamentLibrary', 'Custom'):
        shutil.copy(f'{MAC}/Resources/profiles/{v}.opc', f'{data}/system/')
    os.environ.update(ORCA=f'{MAC}/MacOS/OrcaSlicer', ORCA_DATA=data)
os.environ.update(PRINTER_HOST='127.0.0.1', MOONRAKER_PORT='7199', SLICER_PORT='7198')
sys.path.insert(0, os.path.dirname(__file__))
import server  # noqa: E402

uploads = []


class FakeMoonraker(BaseHTTPRequestHandler):
    def do_POST(self):
        uploads.append((self.path, self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b'{}')

    def log_message(self, *a):
        pass


def cube(x=0, y=0, h=20):
    v = [(x + a, y + b, c * h) for a, b, c in
         ((0, 0, 0), (20, 0, 0), (20, 20, 0), (0, 20, 0), (0, 0, 1), (20, 0, 1), (20, 20, 1), (0, 20, 1))]
    f = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
         (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
    out = b'\0' * 80 + struct.pack('<I', len(f))
    for t in f:
        out += struct.pack('<3f', 0, 0, 0) + b''.join(struct.pack('<3f', *v[i]) for i in t) + b'\0\0'
    return out


def call(method, path, body=None):
    req = urllib.request.Request(f'http://127.0.0.1:7198{path}', data=body, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def slice_job(query, model=None):
    status, j = call('POST', f'/slicer/jobs?{query}', model or cube())
    assert status == 200, j
    for _ in range(600):
        _, s = call('GET', f'/slicer/jobs/{j["id"]}')
        if s['state'] in ('done', 'error'):
            return s
        time.sleep(0.5)
    raise AssertionError('slice never finished')


if __name__ == '__main__':
    for port, h in ((7199, FakeMoonraker), (7198, server.Handler)):
        threading.Thread(target=ThreadingHTTPServer(('127.0.0.1', port), h).serve_forever, daemon=True).start()

    _, p = call('GET', '/slicer/presets')
    assert [(x['id'], x['bed'][0]) for x in p['printers']] == [('k2plus', 350), ('u1', 270)], p

    # Bad input is refused before anything runs.
    assert call('POST', '/slicer/jobs?printer=k2plus&name=x.exe', b'1')[0] == 400
    assert call('POST', '/slicer/jobs?printer=nope&name=a.stl', b'1')[0] == 400
    assert call('POST', '/slicer/jobs?printer=u1&name=a.stl&tool=3&filaments=Generic%20PLA', b'1')[0] == 400

    s = slice_job('printer=k2plus&name=cube.stl&folder=Sliced')
    assert s['state'] == 'done', s
    assert s['files'] == ['Sliced/cube.gcode'] and s['time'] > 0 and s['weight'] > 0, s
    body = uploads[-1][1]
    assert b'name="path"\r\n\r\nSliced' in body and b'printer_model = Creality K2 Plus' in body

    s = slice_job('printer=u1&name=cube.stl&tool=1&filaments=Generic%20PLA;Generic%20PETG;Generic%20PLA;Generic%20TPU')
    assert s['state'] == 'done', s
    body = uploads[-1][1]
    assert b'printer_model = Snapmaker U1' in body and b'filament_type = PLA;PETG;PLA;TPU' in body
    assert b'\nT1\n' in body, 'object should print on toolhead 2'

    # Overrides from the app's print settings end up in the G-code.
    settings = json.dumps({
        'process': {'layer_height': '0.28', 'enable_support': True, 'support_type': 'tree(auto)',
                    'sparse_infill_density': '35%', 'sparse_infill_pattern': 'gyroid', 'wall_loops': 4},
        'filaments': [{'nozzle_temperature': 225, 'bed_temperature': 65, 'filament_flow_ratio': '0.95'}]})
    s = slice_job('printer=k2plus&name=cube.stl&settings=' + urllib.parse.quote(settings))
    assert s['state'] == 'done', s
    body = uploads[-1][1]
    for line in (b'; layer_height = 0.28', b'; enable_support = 1', b'; support_type = tree(auto)',
                 b'; sparse_infill_density = 35%', b'; sparse_infill_pattern = gyroid', b'; wall_loops = 4',
                 b'; nozzle_temperature = 225', b'; nozzle_temperature_initial_layer = 225',
                 b'; filament_flow_ratio = 0.95', b'; textured_plate_temp = 65'):
        assert line + b'\n' in body, line
    bad = urllib.parse.quote(json.dumps({'process': {'machine_start_gcode': 'G28'}}))
    assert call('POST', f'/slicer/jobs?printer=k2plus&name=a.stl&settings={bad}', b'1')[0] == 400
    assert call('POST', '/slicer/jobs?printer=k2plus&name=a.stl&settings=%7B', b'1')[0] == 400

    # arrange=0 keeps the app's placement (a cube at X 200-220, Y 50-70).
    def xy(body):
        return [(float(a), float(b)) for a, b in re.findall(rb'\nG1 X([\d.]+) Y([\d.]+) E[\d.]', body)]
    s = slice_job('printer=k2plus&name=cube.stl&arrange=0', cube(200, 50))
    assert s['state'] == 'done', s
    assert any(200 <= x <= 220 and 50 <= y <= 70 for x, y in xy(uploads[-1][1]))
    s = slice_job('printer=k2plus&name=cube.stl', cube(200, 50))
    assert not any(200 <= x <= 220 and 50 <= y <= 70 for x, y in xy(uploads[-1][1])), 'arranged by default'

    # The editor's mesh: centred on the plate, auto-orient lays a tall box down.
    req = urllib.request.Request('http://127.0.0.1:7198/slicer/mesh?printer=k2plus&name=box.stl&orient=1',
                                 data=cube(h=60), method='POST')
    with urllib.request.urlopen(req, timeout=120) as r:
        stl = r.read()
    n = struct.unpack_from('<I', stl, 80)[0]
    pts = [struct.unpack_from('<3f', stl, 84 + i * 50 + 12 + k * 12) for i in range(n) for k in range(3)]
    lo, hi = [min(p[a] for p in pts) for a in range(3)], [max(p[a] for p in pts) for a in range(3)]
    assert n == 12 and abs(lo[2]) < 0.01 and hi[2] < 21, (n, lo, hi)
    assert abs((lo[0] + hi[0]) / 2 - 175) < 1 and abs((lo[1] + hi[1]) / 2 - 175) < 1, (lo, hi)

    try:
        import gmsh
    except ImportError:
        gmsh = None
        print('no gmsh: STEP not tested')
    if gmsh:
        step = os.path.join(tempfile.mkdtemp(), 'box.step')
        gmsh.initialize(interruptible=False)
        gmsh.model.occ.addCylinder(0, 0, 0, 0, 0, 15, 10)
        gmsh.model.occ.synchronize()
        gmsh.write(step)
        gmsh.finalize()
        with open(step, 'rb') as f:
            status, j = call('POST', '/slicer/jobs?printer=k2plus&name=box.step', f.read())
        assert status == 200, j
        for _ in range(600):
            _, s = call('GET', f'/slicer/jobs/{j["id"]}')
            if s['state'] in ('done', 'error'):
                break
            time.sleep(0.5)
        assert s['state'] == 'done' and s['files'] == ['box.gcode'], s

    assert not glob.glob(os.path.join(server.USER, '*', 'hub-*')), 'job presets left behind'
    print('slicer OK')
