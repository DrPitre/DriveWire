#!/usr/bin/env python3
"""Exercise the built server over TCP, including Windows-native RFM file paths."""
import argparse
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def receive(peer, count):
    result = bytearray()
    while len(result) < count:
        chunk = peer.recv(count - len(result))
        if not chunk:
            raise AssertionError('server closed before completing its response')
        result.extend(chunk)
    return bytes(result)


def request(peer, packet, count):
    peer.sendall(bytes(packet))
    return receive(peer, count)


def path_request(peer, op, name, cookie=b'\0\0\0', pid=1, mode=1):
    peer.sendall(bytes([0xd6, op | 0x10, 1, pid]) + cookie + bytes([mode]) + name.encode('ascii') + b'\r')
    result = receive(peer, 1)
    if op == 4 and result == b'\0':
        return receive(peer, 3)
    assert result == b'\0', (op, name, result)
    return result


def read(peer, count):
    peer.sendall(bytes([0xd6, 7, 1]) + count.to_bytes(2, 'big'))
    size = int.from_bytes(receive(peer, 2), 'big')
    assert size <= count
    return receive(peer, size)


def check(binary, isolate_runtime):
    binary = Path(binary).resolve()
    env = os.environ.copy()
    if isolate_runtime and os.name == 'nt':
        system = env['SystemRoot']
        env['PATH'] = os.pathsep.join([str(binary.parent), system + '\\System32', system])
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)/'host files'
        root.mkdir()
        (root/'DD/CMDS').mkdir(parents=True)
        (root/'DD/child').mkdir()
        (root/'DD/marker').write_bytes(b'ROOT')
        (root/'DD/child/marker').write_bytes(b'CHILD')
        (root/'DD/CMDS/grfdrv').write_bytes(b'GRAPHICS')
        boot = bytes(i % 251 for i in range(1025))
        (root/'OS9Boot').write_bytes(boot)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        with (root/'server.log').open('wb') as log:
            server = subprocess.Popen([str(binary), '--tcp-port', str(port), '--rfm-root', str(root)],
                                      stdout=log, stderr=log, env=env)
            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        peer = socket.create_connection(('127.0.0.1', port), timeout=2)
                        break
                    except OSError:
                        if server.poll() is not None or time.monotonic() >= deadline:
                            raise AssertionError(f'server exited with {server.poll()}: ' + (root/'server.log').read_text(errors='replace'))
                        time.sleep(.05)
                with peer:
                    peer.settimeout(5)
                    # Fragment one request and coalesce the next two.
                    peer.sendall(b'\x5a')
                    assert request(peer, b'\x01\x00\x5a\x01', 2) == b'\xff\xff'
                    assert request(peer, b'\xd6\x02\x01\0\0\x01OS9Boot\r', 1) == b'\0'
                    assert request(peer, b'\xd6\x0b\x01\x02', 4) == len(boot).to_bytes(4, 'big')
                    assert read(peer, len(boot)) == boot
                    assert request(peer, b'\xd6\x0d\x01', 1) == b'\0'
                    inherited = path_request(peer, 4, '/DD', mode=0x85)
                    changed = path_request(peer, 4, 'child', inherited, mode=0x85)
                    assert changed != inherited
                    path_request(peer, 2, 'marker', inherited, pid=2)
                    assert read(peer, 32) == b'ROOT'
                    assert request(peer, b'\xd6\x0d\x01', 1) == b'\0'
                    path_request(peer, 2, 'marker', changed)
                    assert read(peer, 32) == b'CHILD'
                    assert request(peer, b'\xd6\x0d\x01', 1) == b'\0'
                    assert path_request(peer, 4, '...', inherited, mode=0x85) == inherited
                    path_request(peer, 2, '../CMDS/grfdrv', inherited, mode=4)
                    assert read(peer, 32) == b'GRAPHICS'
                    assert request(peer, b'\xd6\x0d\x01', 1) == b'\0'
                    path_request(peer, 1, 'file', inherited, mode=3)
                    payload = bytes(range(256)) + b'\0\xff\r'
                    peer.sendall(b'\xd6\x08\x01' + len(payload).to_bytes(2, 'big') + payload)
                    assert request(peer, b'\xd6\x06\x01\0\0\0\0', 1) == b'\0'
                    assert read(peer, 512) == payload
                    assert request(peer, b'\xd6\x0b\x01\x02', 4) == len(payload).to_bytes(4, 'big')
                    # Disconnect halfway through a pathname, leaving a file open.
                    peer.sendall(b'\xd6\x12\x02\x01' + inherited + b'\x01unfinished')
                with socket.create_connection(('127.0.0.1', port), timeout=5) as peer:
                    peer.settimeout(5)
                    assert request(peer, b'\x5a\x01', 1) == b'\xff'
                    stale = b'\xd6\x12\x01\x02' + inherited + b'\x81.\r'
                    assert request(peer, stale, 1) == b'\xd8'
                    (root/'DD/file').unlink()  # verifies retired Windows file handles
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
    print('PASS: portable TCP protocol, remote bootfile, fork cookies, root clamping, live binary I/O and reconnect cleanup')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('--isolate-runtime', action='store_true')
    args = parser.parse_args()
    check(args.binary, args.isolate_runtime)
