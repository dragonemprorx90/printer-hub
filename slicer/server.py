#!/usr/bin/env python3
"""Printer Hub slicer: OrcaSlicer's command line behind a tiny HTTP API.

Runs next to the home bridge (127.0.0.1 only). The app reaches it through the
bridge's end-to-end encrypted relay at /slicer/*:

  GET  /slicer/presets                       printers, processes, filaments
  POST /slicer/jobs?printer=&process=&filaments=a;b&tool=&name=&folder=
       body: the model (STL / 3MF / STEP / OBJ)  -> {"id": ...}
  GET  /slicer/jobs/<id>                     {"state", "error", "files", "time", "weight"}

Finished G-code goes straight to the printer (PRINTER_HOST) over the LAN.
Standard library only.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ORCA = os.environ.get('ORCA', '/opt/orca/AppRun').split()
DATA = os.environ.get('ORCA_DATA', '/opt/orca-data')
USER = os.path.join(DATA, 'user', 'default')  # your own presets live here too
PRINTER = os.environ.get('PRINTER_HOST', '')
MOONRAKER = os.environ.get('MOONRAKER_PORT', '7125')
PORT = int(os.environ.get('SLICER_PORT', '7070'))
MAX_MODEL = 200 * 1024 * 1024
MODEL_EXT = ('.stl', '.3mf', '.step', '.stp', '.obj')

# Orca's own system presets (0.4 mm nozzles). Names must match Orca exactly.
PRINTERS = {
    'k2plus': {
        'name': 'Creality K2 Plus',
        'machine': 'Creality K2 Plus 0.4 nozzle',
        'tools': 1,
        'process': '0.20mm Standard',
        'processes': {p: f'{p} @Creality K2 Plus 0.4 nozzle' for p in (
            '0.12mm Detail', '0.16mm Optimal', '0.20mm Standard',
            '0.20mm Strength', '0.24mm Draft', '0.28mm SuperDraft')},
        'filaments': {f: f'{f} @K2 Plus-all' for f in (
            'Generic PLA', 'Hyper PLA', 'CR-PLA', 'Generic PLA-CF', 'Generic PETG',
            'Generic PETG-CF', 'Generic ABS', 'Generic ASA', 'Generic TPU')},
    },
    'u1': {
        'name': 'Snapmaker U1',
        'machine': 'Snapmaker U1 (0.4 nozzle)',
        'tools': 4,
        'process': '0.20 Standard',
        'processes': {p: f'{p} @Snapmaker U1 (0.4 nozzle)' for p in (
            '0.12 Fine', '0.16 Optimal', '0.20 Standard', '0.20 Strength',
            '0.20 Support', '0.24 Draft', '0.28 Extra Draft')},
        'filaments': {f: f'{f} @U1 0.4 nozzle' for f in (
            'Generic PLA', 'Generic PLA High Speed', 'Generic PLA Silk', 'Generic PLA-CF',
            'Generic PETG', 'Generic PETG-CF', 'Generic TPU')},
    },
}

jobs = {}
lock = threading.Lock()  # ponytail: one slice at a time; a NAS core is busy enough


def own_presets(kind):
    """Presets you exported from desktop Orca into slicer-profiles/<kind>/."""
    d = os.path.join(USER, kind)
    if not os.path.isdir(d):
        return []
    return sorted(f[:-5] for f in os.listdir(d) if f.endswith('.json') and not f.startswith('hub-'))


def presets():
    mine_p, mine_f = own_presets('process'), own_presets('filament')
    return {'printers': [
        {'id': k, 'name': p['name'], 'tools': p['tools'], 'process': p['process'],
         'processes': list(p['processes']) + mine_p,
         'filaments': list(p['filaments']) + mine_f}
        for k, p in PRINTERS.items()]}


def safe_name(name):
    base = os.path.basename(name or 'model.stl')
    base = re.sub(r'[^\w.\- ()]+', '_', base).strip(' .') or 'model.stl'
    if not base.lower().endswith(MODEL_EXT):
        raise ValueError('Send an STL, 3MF, STEP or OBJ model')
    return base


def preset_file(job, kind, name, system, idx=0):
    """Path of a preset the CLI can load. Orca only resolves 'inherits' for
    presets inside its user folder, so system presets get a small stub there."""
    if name in own_presets(kind):
        return os.path.join(USER, kind, name + '.json')
    if name not in system:
        raise ValueError(f'Unknown {kind} preset: {name}')
    os.makedirs(os.path.join(USER, kind), exist_ok=True)
    stub = f'hub-{job}-{idx}'
    d = {'type': kind, 'from': 'User', 'inherits': system[name], 'name': stub, 'version': '2.5.0.0'}
    d[{'machine': 'printer_settings_id', 'process': 'print_settings_id'}.get(kind, 'filament_settings_id')] = \
        [stub] if kind == 'filament' else stub
    path = os.path.join(USER, kind, stub + '.json')
    with open(path, 'w') as f:
        json.dump(d, f)
    return path


def plan(job, q, name):
    """CLI arguments for one job (no model path yet). Raises ValueError on bad input."""
    p = PRINTERS.get(q.get('printer', ''))
    if not p:
        raise ValueError('Unknown printer')
    machine = preset_file(job, 'machine', p['machine'], {p['machine']: p['machine']})
    process = preset_file(job, 'process', q.get('process') or p['process'], p['processes'])
    fils = [f for f in (q.get('filaments') or 'Generic PLA').split(';') if f][:p['tools']]
    fil_paths = [preset_file(job, 'filament', f, p['filaments'], i) for i, f in enumerate(fils)]
    args = ['--slice', '0', '--export-statistics',
            '--load-settings', f'{machine};{process}', '--load-filaments', ';'.join(fil_paths)]
    if not name.lower().endswith('.3mf'):
        tool = int(q.get('tool') or 0)
        if not 0 <= tool < len(fils):
            raise ValueError('That toolhead has no filament')
        args += ['--arrange', '1', '--load-filament-ids', str(tool + 1)]
    return args


def upload(path, name, folder):
    """Multipart upload to Moonraker, the same as the app's own upload."""
    boundary = uuid.uuid4().hex
    with open(path, 'rb') as f:
        data = f.read()
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
             for k, v in (('root', 'gcodes'), ('path', folder))]
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
                 'Content-Type: application/octet-stream\r\n\r\n'.encode() + data + b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    req = urllib.request.Request(f'http://{PRINTER}:{MOONRAKER}/server/files/upload', data=b''.join(parts),
                                 headers={'Content-Type': f'multipart/form-data; boundary={boundary}'})
    urllib.request.urlopen(req, timeout=120).read()


def step_to_stl(src):
    """Orca's command line can't read STEP, so mesh it with gmsh first
    (in its own process: gmsh isn't thread-safe and can be memory hungry)."""
    dst = os.path.splitext(src)[0] + '.stl'
    r = subprocess.run([sys.executable, __file__, '--step', src, dst], capture_output=True, text=True, timeout=900)
    if r.returncode != 0 or not os.path.exists(dst):
        raise RuntimeError('Could not read this STEP file. Export it as STL or 3MF instead.')
    return dst


def mesh_step(src, dst):
    import gmsh
    gmsh.initialize(interruptible=False)
    gmsh.option.setNumber('General.Terminal', 0)
    gmsh.option.setString('Geometry.OCCTargetUnit', 'MM')
    gmsh.model.occ.importShapes(src)
    gmsh.model.occ.synchronize()
    gmsh.option.setNumber('Mesh.MeshSizeFromCurvature', 36)  # segments per full circle
    gmsh.option.setNumber('Mesh.MeshSizeMax', 5)
    gmsh.option.setNumber('Mesh.Binary', 1)
    gmsh.model.mesh.generate(2)
    gmsh.write(dst)
    gmsh.finalize()


def why(out):
    """The useful line of Orca's output when a slice fails."""
    lines = [l.strip() for l in out.splitlines() if l.strip() and 'run found error' not in l]
    return (lines[-1] if lines else 'Slicing failed')[:300]


def run(job, args, model, name, folder):
    j = jobs[job]
    work = os.path.dirname(model)
    try:
        with lock:
            if name.lower().endswith(('.step', '.stp')):
                j['state'] = 'converting'
                model = step_to_stl(model)
            j['state'] = 'slicing'
            out_dir = os.path.join(work, 'out')
            os.makedirs(out_dir)
            r = subprocess.run(ORCA + ['--datadir', DATA, *args, '--outputdir', out_dir, model],
                               capture_output=True, text=True, timeout=1800)
        plates = sorted(f for f in os.listdir(out_dir) if f.endswith('.gcode'))
        if r.returncode != 0 or not plates:
            raise RuntimeError(why(r.stdout + r.stderr))
        stem = os.path.splitext(name)[0]
        j['state'] = 'uploading'
        files, secs, grams = [], 0.0, 0.0
        for g in plates:
            n = int(re.sub(r'\D', '', g) or 1)
            gname = f'{stem}.gcode' if len(plates) == 1 else f'{stem}_plate{n}.gcode'
            upload(os.path.join(out_dir, g), gname, folder)
            files.append(f'{folder}/{gname}' if folder else gname)
            try:
                with open(os.path.join(out_dir, g.replace('.gcode', '.statistics.json'))) as f:
                    s = json.load(f)['summary']
                secs, grams = secs + s.get('time', 0), grams + s.get('weight', 0)
            except (OSError, KeyError, ValueError):
                pass
        j.update(state='done', files=files, time=round(secs), weight=round(grams, 1))
    except subprocess.TimeoutExpired:
        j.update(state='error', error='Slicing took over 30 minutes and was stopped')
    except Exception as e:  # reported to the app, never crashes the server
        j.update(state='error', error=str(e) or type(e).__name__)
    finally:
        shutil.rmtree(work, ignore_errors=True)
        forget(job)


def forget(job):
    """Removes the job's preset stubs."""
    for kind in ('machine', 'process', 'filament'):
        d = os.path.join(USER, kind)
        for f in os.listdir(d) if os.path.isdir(d) else ():
            if f.startswith(f'hub-{job}-'):
                os.remove(os.path.join(d, f))


def new_job(q, body):
    name = safe_name(q.get('name', ''))
    folder = '/'.join(p for p in (q.get('folder') or '').split('/') if p not in ('', '.', '..'))
    job = uuid.uuid4().hex[:12]
    try:
        args = plan(job, q, name)
    except ValueError:
        forget(job)
        raise
    work = tempfile.mkdtemp(prefix='slice-')
    model = os.path.join(work, name)
    with open(model, 'wb') as f:
        f.write(body)
    jobs[job] = {'state': 'queued', 'name': name, 'created': time.time()}
    for old in sorted(jobs, key=lambda k: jobs[k]['created'])[:-20]:  # keep the last 20
        jobs.pop(old, None)
    threading.Thread(target=run, args=(job, args, model, name, folder), daemon=True).start()
    return job


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, obj):
        b = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def route(self):
        path, _, query = self.path.partition('?')
        return path.rstrip('/'), dict(urllib.parse.parse_qsl(query))

    def do_GET(self):
        path, _ = self.route()
        if path == '/slicer/presets':
            return self.reply(200, presets())
        m = re.fullmatch(r'/slicer/jobs/(\w+)', path)
        if m and m.group(1) in jobs:
            return self.reply(200, {k: v for k, v in jobs[m.group(1)].items() if k != 'created'})
        self.reply(404, {'error': 'Not found'})

    def do_POST(self):
        path, q = self.route()
        if path != '/slicer/jobs':
            return self.reply(404, {'error': 'Not found'})
        n = int(self.headers.get('Content-Length') or 0)
        if not 0 < n <= MAX_MODEL:
            return self.reply(413, {'error': 'Models up to 200 MB'})
        try:
            self.reply(200, {'id': new_job(q, self.rfile.read(n))})
        except ValueError as e:
            self.reply(400, {'error': str(e)})

    def log_message(self, fmt, *args):
        pass


if __name__ == '__main__':
    if sys.argv[1:2] == ['--step']:
        raise SystemExit(mesh_step(*sys.argv[2:4]))
    if not PRINTER:
        raise SystemExit('Set PRINTER_HOST (the same .env as the bridge)')
    print(f'Printer Hub slicer on 127.0.0.1:{PORT}, printer {PRINTER}:{MOONRAKER}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
