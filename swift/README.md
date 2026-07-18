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
