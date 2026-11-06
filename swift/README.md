#  DriveWire (Swift)

This is the DriveWire Host written in Swift.

## MIDI virtual channel

DriveWire exposes MIDI output as virtual serial channel 14, normally opened from
NitrOS-9 as `/midi`. Bytes written to that path are accepted by the host through
the DriveWire virtual serial protocol.

Standard MIDI Files are buffered while the channel is open and played after the
guest closes the stream. This works with commands such as:

```sh
merge song.mid >/midi
merge #32k song.mid >/midi
```

Raw MIDI byte streams are sent directly to the selected Core MIDI output. The
macOS app's MIDI view shows receive/playback status, byte counts, track counts,
the selected output, and any parser or device errors. Use the Stop MIDI control
to stop active playback and reset the selected MIDI output.

## Printer output

DriveWire printer bytes are accepted through `OP_PRINT` and `OP_PRINTFLUSH`.
The host routes printer data through a printer backend so raw capture, text
preview, and future printer emulation can share the same protocol path.

The initial backend keeps raw printer bytes in memory and exposes a printable
preview in the macOS app. `OP_PRINTFLUSH` flushes the active job, clears pending
bytes, and increments the printer flush count. The Printer view shows backend,
byte, pending-byte, flush, last-flush, and preview status.

## RFM directory contexts and file handles

The RFM root contains device directories: guest `/y0/file` refers to
`<rfm-root>/y0/file`. New path operations `$11`–`$15` use immutable 24-bit
directory cookies instead of directory-owner PIDs. The client stores separate
data and execution cookies in its process directory records, so `F$Fork`
copies the exact directory state without a server notification. Later changes
by parent or child cannot change the other's cookies, even before the child's
first remote access. Invalid cookies fail without falling back to PID state.

The extended request is `$D6, op, path, PID, cookie[3], mode, pathname, CR`.
Successful extended ChgDir returns `$00, cookie[3]`; all errors return one byte.
Other responses are unchanged. The directory LSN registry supplies cookies and
retains them for the session. Host renames/deletion and recovery across server
resets are not handled. Legacy `$01`–`$05` remain available for old clients, with
their original PID directory behavior. The updated client requires this server
extension; it does not silently downgrade.

Regular-file reads, size, EOF and descriptor-size queries use the live file
handle. Writes are therefore visible after seeking on the same open path and
through other open paths. Synthesized directory records remain snapshots.
ReadLn/WriteLn retain the existing host-LF/guest-CR text conversion.

The `testRFM*` cases in `DriveWireTests` cover directory-owner selection,
relative/self-owner changes, fork cookies before first child I/O, failed changes,
combined directory modes,
read-after-write, independent handles, sparse writes, size/EOF and line cursors.

RFM path traversal stays within the selected OS-9 device: `/DD/..` resolves
back to `/DD`, including multi-dot paths. The same normalization applies to
Open/Create, ChgDir, MakDir, and Delete. This permits CoWin's early
`../CMDS/grfdrv` load when `/DD` is an RFM system device. The companion
NitrOS-9 `rfm_boot_test` recipe verifies a remote OS9Boot and RFM-backed `/DD`
with no RBF modules or server-mounted virtual disks.
