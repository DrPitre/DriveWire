#!/usr/bin/env python3
"""Stage a desktop distribution including its server and runtime libraries."""
import argparse
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--build', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parents[1]
build = args.build.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
name = 'DriveWire-Desktop-' + platform.system() + '-' + platform.machine()
stage = out / name
if stage.exists(): shutil.rmtree(stage)
stage.mkdir()
licenses = stage/'licenses'
licenses.mkdir()
shutil.copy2(repo/'desktop/third_party/JSON-LICENSE.MIT',licenses)
shutil.copy2(repo/'desktop/README.md',stage/'README.md')
for license_name in ['LICENSE','LICENSE.txt','LICENSE.md']:
    if (repo/license_name).exists(): shutil.copy2(repo/license_name,licenses/('DriveWire-'+license_name))
for dependency in ['swift-nio','swift-argument-parser','swift-system','swift-collections','swift-atomics']:
    directory=repo/'swift/.build/checkouts'/dependency
    for filename in ['LICENSE','LICENSE.txt','LICENSE.md','NOTICE.txt']:
        if (directory/filename).exists(): shutil.copy2(directory/filename,licenses/(dependency+'-'+filename))
wx_license = build/'_deps/wxwidgets-src/docs/licence.txt'
if wx_license.exists(): shutil.copy2(wx_license,licenses/'wxWidgets-LICENSE.txt')
if platform.system() == 'Darwin':
    app=stage/'DriveWire Desktop.app'
    shutil.copytree(build/'DriveWire Desktop.app',app)
    frameworks=app/'Contents/Frameworks'
    frameworks.mkdir(exist_ok=True)
    for binary in ['DriveWire Desktop','drivewire-server']:
        subprocess.run(['xcrun','swift-stdlib-tool','--copy','--scan-executable',str(app/'Contents/MacOS'/binary),
                        '--destination',str(frameworks),'--platform','macosx'],check=True)
    # Both processes may need Swift compatibility libraries on older macOS.
    for binary in (app/'Contents/MacOS').iterdir():
        subprocess.run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(binary)],check=True)
    subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
    archive=shutil.make_archive(str(out/name),'zip',stage)
    print(archive)
elif platform.system() == 'Windows':
    source=build/'Release'
    for file in source.iterdir():
        if file.suffix.lower() in ['.exe','.dll']: shutil.copy2(file,stage/file.name)
    archive=shutil.make_archive(str(out/name),'zip',stage)
    print(archive)
else:
    for filename in ['DriveWire Desktop','drivewire-server']: shutil.copy2(build/filename,stage/filename)
    info=json.loads(subprocess.check_output(['swift','-print-target-info']))
    lib=stage/'lib';lib.mkdir()
    for directory in info['paths']['runtimeLibraryPaths']:
        for file in pathlib.Path(directory).glob('*.so*'):
            if file.is_file(): shutil.copy2(file,lib/file.name)
    subprocess.run(['patchelf','--set-rpath','$ORIGIN/lib',str(stage/'drivewire-server')],check=True)
    archive=shutil.make_archive(str(out/name),'gztar',stage)
    print(archive)
