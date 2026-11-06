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
import sys

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
    info=json.loads(subprocess.check_output(['swift','-print-target-info']))
    def rpaths(binary):
        load=subprocess.check_output(['otool','-l',str(binary)],text=True)
        return re.findall(r'cmd LC_RPATH\n.*?\n\s*path (.*?) \(offset',load)
    binaries=list((app/'Contents/MacOS').iterdir())
    search=[]
    for binary in binaries:
        search.extend(pathlib.Path(path) for path in rpaths(binary) if path.startswith('/'))
    search.extend(pathlib.Path(path) for path in info['paths']['runtimeLibraryPaths'])
    # Compatibility libraries can live in swift-6.2/macosx rather than
    # swift/macosx. The executable's linker rpaths identify the right version.
    resource=pathlib.Path(info['paths']['runtimeResourcePath'])
    search.extend(resource.parent.glob('swift*/macosx'))
    queue=list(binaries)
    copied=set()
    while queue:
        binary=queue.pop()
        dependencies=subprocess.check_output(['otool','-L',str(binary)],text=True)
        for library_name in re.findall(r'^\s*@rpath/([^ ]+\.dylib) ',dependencies,re.MULTILINE):
            if library_name in copied: continue
            source=next((directory/library_name for directory in search if (directory/library_name).is_file()),None)
            if source is None: raise RuntimeError('Cannot bundle required Swift library: '+library_name)
            destination=frameworks/library_name
            shutil.copy2(source,destination)
            copied.add(library_name)
            queue.append(destination)
    # Remove development-machine fallbacks. A staged test must succeed using
    # its bundle and system libraries, even when Xcode/Swiftly are installed.
    for binary in binaries+list(frameworks.iterdir()):
        for path in rpaths(binary):
            if path.startswith('/') and not path.startswith('/usr/lib'):
                subprocess.run(['install_name_tool','-delete_rpath',path,str(binary)],check=True)
    for binary in binaries:
        if '@executable_path/../Frameworks' not in rpaths(binary):
            subprocess.run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(binary)],check=True)
    subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
    subprocess.run([sys.executable, str(repo/'scripts/test-desktop.py'), str(app/'Contents/MacOS/DriveWire Desktop'),
                    '--server', str(app/'Contents/MacOS/drivewire-server'), '--isolate-runtime'], check=True)
    archive=shutil.make_archive(str(out/name),'zip',stage)
    print(archive)
elif platform.system() == 'Windows':
    source=build/'Release'
    for file in source.iterdir():
        if file.suffix.lower() in ['.exe','.dll']: shutil.copy2(file,stage/file.name)
    subprocess.run([sys.executable, str(repo/'scripts/test-desktop.py'), str(stage/'DriveWire Desktop.exe'),
                    '--server', str(stage/'drivewire-server.exe'), '--isolate-runtime'], check=True)
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
    test=[sys.executable, str(repo/'scripts/test-desktop.py'), str(stage/'DriveWire Desktop'),
          '--server', str(stage/'drivewire-server'), '--isolate-runtime']
    if not os.environ.get('DISPLAY'): test=['xvfb-run','-a']+test
    subprocess.run(test, check=True)
    launcher=stage/'drivewire'
    launcher.write_text('#!/bin/sh\ncd -- "$(dirname -- "$0")"\nexec "./DriveWire Desktop" "$@"\n')
    launcher.chmod(0o755)
    archive=shutil.make_archive(str(out/name),'gztar',stage)
    print(archive)
