#!/usr/bin/env python3
"""Resolve Swift dependencies and apply the pinned Windows SwiftNIO fix.

SwiftNIO 2.105.0's WSAPoll compaction removes a registration a second time.
A recycled WinSock handle can already belong to a new connection at that point.
SelectorGeneric.deregister has already removed the old registration, so the
compaction pass must only remove the old poll entry, not the registration map.
Run before building on Windows. Safe and idempotent; refuses unknown source.
"""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(['swift', 'package', '--package-path', str(root / 'swift'), 'resolve'], check=True)
if sys.platform == 'win32':
    source = root / 'swift/.build/checkouts/swift-nio/Sources/NIOPosix/SelectorWSAPoll.swift'
    original = source.read_text(encoding='utf-8')
    bad = '''                        let fd = self.pollFDs[read].fd
                        self.registrations.removeValue(forKey: Int(fd))'''
    good = '''                        // DriveWire: deregister already removed the old registration.
                        // A recycled handle may now belong to a new channel.'''
    if bad in original:
        if original.count(bad) != 1:
            raise SystemExit('Unexpected SwiftNIO source; review WSAPoll patch')
        source.chmod(source.stat().st_mode | 0o200)
        source.write_text(original.replace(bad, good), encoding='utf-8', newline='\n')
        print('Applied SwiftNIO 2.105.0 Windows recycled-handle fix')
    elif good not in original:
        raise SystemExit('Unknown SwiftNIO source; review WSAPoll patch')
    else:
        print('Windows SwiftNIO fix already present')
