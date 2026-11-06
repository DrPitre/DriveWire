#!/usr/bin/env python3
"""Exercise the parent/child control protocol without a GUI or user settings."""
import argparse
import json
import pathlib
import queue
import socket
import subprocess
import tempfile
import threading

parser = argparse.ArgumentParser()
parser.add_argument('server')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='DriveWire control ') as folder:
    root = pathlib.Path(folder)
    (root/'DD').mkdir()
    image = root/'disk ü.dsk'
    image.write_bytes(bytes(512))
    process = subprocess.Popen([str(pathlib.Path(args.server).resolve()), '--managed'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    messages = queue.Queue()
    def read():
        for line in process.stdout:
            marker = line.find(b'@drivewire ')
            if marker >= 0:
                messages.put(json.loads(line[marker+11:]))
    threading.Thread(target=read, daemon=True).start()
    serial = 0
    def command(name, ok=True, **fields):
        global serial
        serial += 1
        process.stdin.write((json.dumps(dict(command=name,id=serial,**fields))+'\n').encode())
        process.stdin.flush()
        reply = messages.get(timeout=15)
        assert reply['id']==serial and reply['ok']==ok, reply
        return reply['state']
    try:
        assert messages.get(timeout=15)['id']==0
        command('nonsense',ok=False)
        command('configure',root=str(root/'missing'),ok=False)
        command('configure',bind='127.0.0.1',port=0,root=str(root))
        command('mount',drive=0,path=str(image))
        command('mount',drive=0,path=str(root/'missing'),ok=False)
        state=command('start')
        command('configure',port=65504,ok=False)
        with socket.create_connection(('127.0.0.1',state['port']),timeout=5) as guest:
            guest.sendall(bytes([0x5a,1]));assert guest.recv(1)==b'\xff'
            guest.sendall(bytes([0x57,0,0,0,0])+b'A'*256+bytes([0x41,0]));assert guest.recv(1)==b'\0'
            state=command('status');assert state['disks'][0]['dirty']
            command('eject',drive=0,ok=False)
            command('mount',drive=0,path=str(image),ok=False)
            command('shutdown',ok=False)
            state=command('save',drive=0);assert not state['disks'][0]['dirty']
            assert image.read_bytes()[:256]==b'A'*256
            disconnected=command('disconnect')
            assert disconnected['running'] and disconnected['port']==state['port']
            assert guest.recv(1)==b''
            with socket.create_connection(('127.0.0.1',disconnected['port']),timeout=5) as next_guest:
                next_guest.sendall(bytes([0x57,0,0,0,0])+b'B'*256+bytes([0x42,0]))
                assert next_guest.recv(1)==b'\0'
                # Save and replace occur in one command, preserving writes
                # that arrived after the frontend's previous status snapshot.
                replaced=command('mount',drive=0,path=str(image),saveBefore=True)
                assert not replaced['disks'][0]['dirty']
                assert image.read_bytes()[:256]==b'B'*256
            command('stop')
        assert command('start')['running']
        command('stop')
        command('eject',drive=0)
        assert not command('status')['disks']
        command('shutdown')
        assert process.wait(timeout=10)==0
        print('PASS: managed configuration, validation, listener lifecycle, Unicode disk paths, guest writes, dirty protection, save, eject and shutdown')
    finally:
        if process.poll() is None:
            process.stdin.close()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill();process.wait()
