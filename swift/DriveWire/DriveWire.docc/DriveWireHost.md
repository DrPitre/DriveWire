# ``DriveWire/DriveWireHost``

`DriveWireHost` implements the DriveWire protocol state machine, virtual disk
access, virtual serial ports, named object support, remote file manager support,
and the `/midi` virtual serial channel.

## MIDI virtual channel

The host treats virtual serial channel 14 as the MIDI device exposed to the
guest as `/midi`. Standard MIDI Files are buffered for the lifetime of the open
channel and parsed when the guest closes the stream, so `merge song.mid >/midi`
and larger-buffer variants such as `merge #32k song.mid >/midi` can transfer the
whole file before playback starts. Raw MIDI byte streams that are not Standard
MIDI Files are sent directly to the selected MIDI backend when the stream
finishes.

The MIDI status published by the host reports the backend, selected output,
availability, received byte counts, Standard MIDI File byte and track progress,
message count, and the most recent error. Calling ``stopMIDIPlayback()`` stops
scheduled playback and resets the MIDI output.

## Printer output

Printer bytes received through ``OPPRINT`` are routed through the host's printer
backend. The initial backend keeps raw printer bytes in memory, exposes a preview
for the macOS app, and clears pending bytes when ``OPPRINTFLUSH`` is received.
The published printer status reports backend name, state, bytes received,
pending bytes, flush count, last flush time, preview text, and the most recent
error.

## Topics

### Creating the host

- ``init(delegate:)``

### Verifying data transfers

- ``compute16BitChecksum(data:)``

### Sending information to the host

- ``send(data:)``

### Getting operational information

- ``currentTransaction``
- ``statistics``

### Getting and setting status

- ``OPGETSTAT``
- ``OPSETSTAT``
- ``OPSERGETSTAT``
- ``OPSERSETSTAT``

### Initializing and terminating

- ``OPINIT``
- ``OPTERM``
- ``OPDWINIT``
- ``OPDWTERM``
- ``OPSERINIT``
- ``OPSERTERM``

### Reading and writing virtual disks

- ``OPREAD``
- ``OPREREAD``
- ``OPREADEX``
- ``OPREREADEX``
- ``OPWRITE``
- ``OPREWRITE``
- ``OPWRITEX``
- ``OPREWRITEX``

### Managing virtual drives

- ``VirtualDrive``
- ``virtualDrives``
- ``insertVirtualDisk(driveNumber:imagePath:)``
- ``ejectVirtualDisk(driveNumber:)``


### Printing to virtual printers

- ``OPPRINT``
- ``OPPRINTFLUSH``
- ``printerStatus``

### Reading and writing virtual serial ports

- ``OPSERREAD``
- ``OPSERREADM``
- ``OPSERWRITE``
- ``OPSERWRITEM``
- ``virtualSerialChannels``

### Playing MIDI

- ``midiMonitorStatus``
- ``stopMIDIPlayback()``

### Creating and mounting named objects

- ``OPNAMEOBJMOUNT``
- ``OPNAMEOBJCREATE``

### Detecting reset

- ``OPRESET``
- ``OPRESET2``
- ``OPRESET3``

### Getting time

- ``OPTIME``

### Debugging

- ``OPWIREBUG``
- ``OPNOP``
- ``DWWirebugOpCode``
