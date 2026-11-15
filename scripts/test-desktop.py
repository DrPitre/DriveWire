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
import threading
import time
import select
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('app')
parser.add_argument('--server', required=True)
parser.add_argument('--isolate-runtime', action='store_true')
parser.add_argument('--serial', action='store_true', help='Exercise serial UI using a PTY, or missing-COM behavior on Windows')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='DriveWire desktop ') as folder:
    root = pathlib.Path(folder)
    (root / 'DD').mkdir()
    (root / 'disk ü.dsk').write_bytes(bytes(512))
    master = None
    guest = None
    failures = []
    if args.serial:
        if os.name == 'nt':
            (root/'serial-port.txt').write_text('COM98765')
            (root/'serial-missing.txt').write_text('missing')
        else:
            import pty
            master, slave = pty.openpty()
            (root/'serial-port.txt').write_text(os.ttyname(slave))
            os.close(slave)
            def serial_guest():
                try:
                    end=time.monotonic()+30
                    while not (root/'serial-ready').exists():
                        assert time.monotonic()<end,'GUI did not open serial port'
                        time.sleep(.02)
                    def exchange(packet, expected):
                        os.write(master,packet)
                        assert select.select([master],[],[],5)[0],'Serial GUI response timed out'
                        assert os.read(master,1)==expected
                    exchange(b'\x5a\x01',b'\xff')
                    exchange(b'\x57\0\0\0\0'+b'A'*256+b'\x41\0',b'\0')
                    (root/'serial-guest-ok').write_text('ok')
                except Exception as error:
                    failures.append(str(error))
            guest=threading.Thread(target=serial_guest,daemon=True)
            guest.start()
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
    if guest: guest.join(timeout=1)
    if master is not None: os.close(master)
    if failures: raise SystemExit('FAIL: serial guest: '+str(failures))
    result_path = root / 'ui-result.json'
    if not result_path.exists():
        raise SystemExit(f'FAIL: desktop exited {code} without a result\n' + (root / 'gui.log').read_text(errors='replace'))
    result = json.loads(result_path.read_text())
    if code or not result.get('ok'):
        raise SystemExit(f'FAIL: desktop exited {code}: {result}\n' + (root / 'gui.log').read_text(errors='replace'))
    print('PASS: wxWidgets desktop: ' + ', '.join(result['checks']))
