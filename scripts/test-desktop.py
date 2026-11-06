#!/usr/bin/env python3
"""Launch the real wxWidgets app and exercise its controls and Swift child.

On Linux run under xvfb-run. Requires a GUI session on macOS/Windows.
No user preferences or disk images are modified.
"""
import argparse
import json
import pathlib
import os
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('app')
parser.add_argument('--server', required=True)
parser.add_argument('--isolate-runtime', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='DriveWire desktop ') as folder:
    root = pathlib.Path(folder)
    (root / 'DD').mkdir()
    (root / 'disk ü.dsk').write_bytes(bytes(512))
    env = os.environ.copy()
    if args.isolate_runtime:
        for key in ['LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH']:
            env.pop(key, None)
        if os.name == 'nt':
            system = next(value for key, value in env.items() if key.upper() == 'SYSTEMROOT')
            env['PATH'] = os.pathsep.join([str(pathlib.Path(args.app).resolve().parent), system + '\\System32', system])
    with (root / 'gui.log').open('wb') as log:
        process = subprocess.Popen([str(pathlib.Path(args.app).resolve()), '--server',
                                    str(pathlib.Path(args.server).resolve()), '--smoke-test', folder],
                                   stdout=log, stderr=subprocess.STDOUT, env=env)
        try:
            code = process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise SystemExit('FAIL: desktop timed out\n' + (root / 'gui.log').read_text(errors='replace'))
    result_path = root / 'ui-result.json'
    if not result_path.exists():
        raise SystemExit(f'FAIL: desktop exited {code} without a result\n' + (root / 'gui.log').read_text(errors='replace'))
    result = json.loads(result_path.read_text())
    if code or not result.get('ok'):
        raise SystemExit(f'FAIL: desktop exited {code}: {result}\n' + (root / 'gui.log').read_text(errors='replace'))
    print('PASS: wxWidgets desktop: ' + ', '.join(result['checks']))
