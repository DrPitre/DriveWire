"""Read Windows PE architecture without depending on the Python/host CPU."""
import pathlib
import struct


def pe_architecture(path):
    with pathlib.Path(path).open('rb') as image:
        if image.read(2) != b'MZ':
            raise ValueError(f'Not a Windows executable: {path}')
        image.seek(0x3c)
        offset = image.read(4)
        if len(offset) != 4:
            raise ValueError(f'Truncated DOS header: {path}')
        image.seek(struct.unpack('<I', offset)[0])
        if image.read(4) != b'PE\0\0':
            raise ValueError(f'Invalid PE signature: {path}')
        machine = image.read(2)
        if len(machine) != 2:
            raise ValueError(f'Truncated PE header: {path}')
        architectures = {0x8664: 'AMD64', 0xAA64: 'ARM64', 0x14c: 'X86'}
        value = struct.unpack('<H', machine)[0]
        if value not in architectures:
            raise ValueError(f'Unsupported PE machine {value:#x}: {path}')
        return architectures[value]
