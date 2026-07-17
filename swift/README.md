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
