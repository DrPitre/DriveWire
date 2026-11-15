#!/usr/bin/env python3
"""Bundle only runtime DLLs matching the native Windows server architecture."""
import argparse
import json
import pathlib
import shutil
import subprocess
from windows_arch import pe_architecture

parser = argparse.ArgumentParser()
parser.add_argument('server', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path)
parser.add_argument('--arch', choices=['x64', 'ARM64'], required=True)
args = parser.parse_args()
expected = {'x64': 'AMD64', 'ARM64': 'ARM64'}[args.arch]
actual = pe_architecture(args.server)
if actual != expected:
    raise SystemExit(f'Expected {expected} server, found {actual}')
info = json.loads(subprocess.check_output(['swift', '-print-target-info']))
swift = shutil.which('swift')
if swift is None:
    raise SystemExit('Swift toolchain not found')
paths = [pathlib.Path(path) for path in info['paths']['runtimeLibraryPaths']]
paths.append(pathlib.Path(swift).parent)
args.output.mkdir(parents=True, exist_ok=True)
shutil.copy2(args.server, args.output/args.server.name)
for path in paths:
    for dll in path.glob('*.dll'):
        if pe_architecture(dll) == actual:
            shutil.copy2(dll, args.output/dll.name)
        else:
            print(f'Skipping other-architecture toolchain DLL: {dll.name}')
print(f'Bundled {actual} server and matching runtime DLLs in {args.output}')
