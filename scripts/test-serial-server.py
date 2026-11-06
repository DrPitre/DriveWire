#!/usr/bin/env python3
"""Serial protocol/lifecycle tests. POSIX uses real OS PTYs, not a mocked stream.
Windows validates discovery and missing-port retry/stop; a COM adapter or virtual
COM driver is needed there for hardware byte-transfer validation.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import select
import subprocess
import tempfile
import threading
import time

parser=argparse.ArgumentParser()
parser.add_argument('server')
args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='DriveWire serial ') as directory:
    root=Path(directory);(root/'DD').mkdir();(root/'OS9Boot').write_bytes(bytes(range(256))*4)
    image=root/'disk.dsk';image.write_bytes(bytes(512))
    process=subprocess.Popen([str(Path(args.server).resolve()),'--managed'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    replies=queue.Queue()
    def reader():
        for line in process.stdout:
            marker=line.find(b'@drivewire ')
            if marker>=0:replies.put(json.loads(line[marker+11:]))
    threading.Thread(target=reader,daemon=True).start()
    serial=0;master=None
    def command(name,**fields):
        global serial
        serial+=1;process.stdin.write((json.dumps(dict(command=name,id=serial,**fields))+'\n').encode());process.stdin.flush()
        reply=replies.get(timeout=15);assert reply['id']==serial and reply['ok'],reply
        return reply
    def wait_state(predicate):
        end=time.monotonic()+12
        while time.monotonic()<end:
            state=command('status')['state']
            if predicate(state):return state
            time.sleep(.05)
        raise AssertionError(('Serial state timed out',state))
    def receive(count):
        data=b'';end=time.monotonic()+5
        while len(data)<count:
            remaining=end-time.monotonic()
            assert remaining>0,('Serial response timed out',data,count)
            assert select.select([master],[],[],remaining)[0]
            data+=os.read(master,count-len(data))
        return data
    def request(data,count):
        os.write(master,data);return receive(count)
    try:
        assert replies.get(timeout=15)['id']==0
        assert isinstance(command('ports')['ports'],list)
        missing='COM98765' if os.name=='nt' else str(root/'missing-port')
        command('configure',transport='serial',serialPath=missing,baud=57600,root=str(root),dtr=True,rts=True)
        state=command('start')['state'];assert state['running'] and not state['connected']
        wait_state(lambda state:bool(state['serialError']))
        command('stop');time.sleep(2.2)
        state=command('status')['state'];assert not state['running'] and not state['connected']
        if os.name!='nt':
            import pty
            def pair():
                import termios
                first,second=pty.openpty()
                # A previously used port may have software flow control enabled.
                attributes=termios.tcgetattr(second)
                attributes[0] |= termios.IXON|termios.IXOFF|termios.IXANY
                termios.tcsetattr(second,termios.TCSANOW,attributes)
                path=os.ttyname(second);os.close(second);return first,path
            master,path=pair();link=root/'selected-port';link.symlink_to(path)
            command('configure',transport='serial',serialPath=str(link),baud=115200,root=str(root))
            command('mount',drive=0,path=str(image));command('start')
            wait_state(lambda state:state['connected'])
            import termios
            attributes=termios.tcgetattr(master)
            assert attributes[4]==termios.B115200 and attributes[5]==termios.B115200
            assert not attributes[0] & (termios.IXON|termios.IXOFF|termios.IXANY|termios.ICRNL)
            assert not attributes[1] & termios.OPOST
            assert not attributes[3] & (termios.ICANON|termios.ECHO)
            os.write(master,b'\x5a');assert request(b'\x01\0\x5a\x01',2)==b'\xff\xff'
            # All byte values include XON/XOFF, NUL, CR/LF and 0xff.
            payload=bytes(range(256));packet=b'\x57\0\0\0\0'+payload+sum(payload).to_bytes(2,'big')
            assert request(packet,1)==b'\0';assert command('status')['state']['disks'][0]['dirty']
            command('save',drive=0);assert image.read_bytes()[:256]==payload
            assert request(b'\xd6\x02\x01\0\0\x01OS9Boot\r',1)==b'\0'
            assert request(b'\xd6\x0b\x01\x02',4)==(1024).to_bytes(4,'big')
            os.write(master,b'\xd6\x07\x01\x04\0');assert receive(2)==b'\x04\0';assert receive(1024)==payload*4
            assert request(b'\xd6\x0d\x01',1)==b'\0'
            # Keep an RFM cookie and a partial pathname across an actual hangup.
            cookie=request(b'\xd6\x14\x01\x01\0\0\0\x85/DD\r',4)[1:]
            assert cookie!=b'\0\0\0'
            os.write(master,b'\xd6\x12\x02\x01'+cookie+b'\x01unfinished')
            os.close(master);master=None
            wait_state(lambda state:not state['connected'] and bool(state['serialError']))
            master,path=pair();link.unlink();link.symlink_to(path)
            wait_state(lambda state:state['connected'])
            # Test stale cookies before DWINIT, which itself resets guest state.
            assert request(b'\xd6\x12\x01\x02'+cookie+b'\x81.\r',1)==b'\xd8'
            assert request(b'\x5a\x01',1)==b'\xff'
            changed=b'C'*256
            assert request(b'\x57\0\0\0\0'+changed+sum(changed).to_bytes(2,'big'),1)==b'\0'
            # Stop and switching back to TCP must retain unsaved guest writes.
            command('stop');time.sleep(.3)
            command('configure',transport='tcp',port=0)
            state=command('start')['state'];assert state['port']>0 and state['disks'][0]['dirty']
            command('saveAll');assert image.read_bytes()[:256]==changed
            command('stop')
        command('shutdown');assert process.wait(timeout=5)==0
        print('PASS: serial discovery, missing-port retry/stop'+(', PTY fragmented protocol, binary disk I/O, RFM bootfile, hangup/reconnect, stale cookie retirement and transport switching' if os.name!='nt' else ' (Windows physical COM byte transfer still needs hardware validation)'))
    finally:
        if master is not None:os.close(master)
        if process.poll() is None:
            process.stdin.close()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait()
