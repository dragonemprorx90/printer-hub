"""Slices a cube for both printers through the HTTP API and checks the G-code
reaches a fake Moonraker. Runs in the Docker image (CI) and on a Mac with
OrcaSlicer installed:  python3 slicer/test_server.py
"""
import glob
import json
import os
import shutil
import struct
import sys
import tempfile
import threading
import time
import urllib.error
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


def cube():
    v = [(0, 0, 0), (20, 0, 0), (20, 20, 0), (0, 20, 0), (0, 0, 20), (20, 0, 20), (20, 20, 20), (0, 20, 20)]
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


def slice_job(query):
    status, j = call('POST', f'/slicer/jobs?{query}', cube())
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
    assert [x['id'] for x in p['printers']] == ['k2plus', 'u1'], p

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
