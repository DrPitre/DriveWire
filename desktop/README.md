# DriveWire Desktop

A wxWidgets desktop application for Windows, Linux and macOS, using the same
Swift DriveWire protocol engine as the native Mac app. The existing SwiftUI
application and its Xcode project remain supported and separate.

## Features

- Choose TCP/Becker or a physical serial port, start/stop, and disconnect a guest.
- Discover serial ports, choose baud rate and DTR/RTS, and reconnect after unplug.
- Select the RFM host root; remote OS9Boot and device directories are shared.
- Mount four disk images, save guest changes, Save As, eject.
  Changed disks are protected against accidental replacement or shutdown.
- Live connection and traffic counters, virtual serial channel status.
- View virtual windows and send a line of input to a selected window.
- Printer text preview and export, bounded live log and log export.
- Remember settings, import/export JSON configurations, recover a crashed backend.

The portable server supports TCP and physical serial on Windows, Linux and
macOS. Serial uses 8 data bits, no parity, one stop bit, and no XON/XOFF or
RTS/CTS flow control. DTR and RTS are asserted by default for USB CDC adapters.
Native MIDI output and system-printer integration remain features of the native
Swift Mac app. The desktop printer tab exports received text.

## Build

Requires CMake 3.24+, C++17, wxWidgets 3.2+, Python 3.10+ and Swift 6.4.2.
The Mac build targets macOS 14 or newer. Linux artifacts target Ubuntu 24.04
and compatible distributions; Windows x64 builds are tested on Server 2022.
Build the Swift server first from the repository root:

```sh
python3 scripts/prepare-swift.py
swift build --package-path swift -c release
```

On Windows use `python` for the preparation script. This applies a narrowly
scoped SwiftNIO 2.105.0 Windows fix for recycled socket handles. The script is
idempotent and refuses an unexpected dependency source. The patch is unnecessary
on macOS/Linux. It is required after resetting SwiftPM dependencies on Windows.

On macOS (`brew install wxwidgets cmake`) or Linux
(`sudo apt install libwxgtk3.2-dev cmake`):

```sh
cmake -S desktop -B desktop/build -DCMAKE_BUILD_TYPE=Release \
  -DDRIVEWIRE_SERVER="$(swift build --package-path swift -c release --show-bin-path)/drivewire-server"
cmake --build desktop/build --config Release --parallel
```

On Windows from a developer PowerShell with Swift and Visual Studio C++ tools:

```powershell
python scripts/prepare-swift.py
swift build --package-path swift -c release
$server = "$(swift build --package-path swift -c release --show-bin-path)/drivewire-server.exe"
cmake -S desktop -B desktop/build -DDRIVEWIRE_FETCH_WX=ON -DDRIVEWIRE_SERVER="$server"
cmake --build desktop/build --config Release --parallel 4
```

`DRIVEWIRE_FETCH_WX=ON` builds pinned wxWidgets 3.2.8 statically on any platform.
This avoids requiring a wxWidgets DLL installation on Windows. macOS produces
`DriveWire Desktop.app`; other platforms produce `DriveWire Desktop[.exe]`.
The backend is placed next to the UI executable. `--server PATH` selects a
different backend without shell quoting or PATH lookup.

## Run and data safety

Choose an RFM root containing `OS9Boot` and device folders (for example `DD`),
optionally mount disks, and choose a transport before clicking Start server.
For TCP, point the emulator's Becker port at the displayed address and port
(default loopback, port 65504). For physical serial, choose **Serial port**, click
**Refresh**, select a port or type its path, and match the guest's baud rate.
The default is 57600 baud with DTR and RTS enabled. Those checkboxes control
line assertion; they do not enable hardware flow control.

Missing, busy or unplugged ports show **Waiting for serial port**, with the
reason in the log, and retry every two seconds. Stop cancels retries; Disconnect
closes the serial link, clears guest state and reopens it after the retry delay.
On Linux, serial-device permissions must allow your user to open the port;
selecting a `/dev/serial/by-id/...` path preserves selection across device-node
renumbering. On macOS use `/dev/cu.*`; on Windows use a name such as `COM3`.
Changing transport preserves mounted disks and unsaved disk changes.
Stop the server to change connection settings; disk saves and mounts work live.

Disk writes are held in memory until Save or Save all disk changes. Quit and
eject offer Save/Discard/Cancel when needed. If the frontend unexpectedly
closes its pipe, the backend attempts to save changed disks before exiting.
Save As changes the backing image path. RFM writes go directly to host files.

Preferences are stored using wxFileConfig in the user's platform configuration
location, separate from the native Mac application's settings. The desktop
does not automatically start serving on launch. Configuration JSON contains
absolute paths; adjust those paths when moving between computers.

## Testing

```sh
python3 scripts/test-managed-server.py /path/to/drivewire-server
python3 scripts/test-serial-server.py /path/to/drivewire-server
python3 scripts/test-desktop.py /path/to/gui-executable --server /path/to/drivewire-server
```

On Linux prefix the second command with `xvfb-run -a`. The desktop test creates
an isolated configuration and temporary image, exercises real Start/Save/Stop
controls, sends DWINIT and a sector write over TCP, checks persisted bytes,
and shuts down the child gracefully. It also checks Unicode paths. No user
preferences are changed. Add `--serial` to test the same controls through an OS
PTY on macOS/Linux. Serial integration tests cover raw binary disk I/O, RFM
bootfile reads, partial packets, actual PTY hangup, reopen on a replaced device
path, retired cookies and transport switching. Windows CI compiles the native
Win32 serial implementation and tests port enumeration, missing-COM retry/stop
and serial GUI controls. Physical COM/USB transfer and modem-line behavior still
require validation with real hardware; PTYs cannot verify those electrical lines.
CI builds and tests all three platforms.

## Control protocol

The GUI owns one `drivewire-server --managed` subprocess. UTF-8 JSON requests
are newline-delimited on stdin; responses use `@drivewire ` followed by JSON
on stdout, distinct from existing engine diagnostics. Every response includes
`protocol: 1`, request `id`, `ok`, and a fresh `state`; failures include `error`.
The control interface is a private pipe, never a listening network service.

## Packaged builds

CI artifacts contain a ZIP (Windows/macOS) or tar.gz (Linux). Extract it and
launch `DriveWire Desktop.exe`, `DriveWire Desktop.app`, or `./drivewire`
respectively. The server is included. macOS bundles are signed ad hoc for local
testing, not notarized releases. Windows needs the Microsoft C++ runtime.
Linux needs GTK3/wxWidgets 3.2 runtime libraries (`libwxgtk3.2-1t64` on Ubuntu
24.04); Swift runtime libraries are bundled. Each staged package is tested
again with toolchain library environment overrides removed.

## CoCo bitbanger RFM replies

The portable serial backend drains each RFM status/count prefix and waits 2 ms
before sending the continuation (directory cookie or file data). The CoCo has
no receive FIFO and calls DWRead separately for those pieces. Without the gap,
bytes can arrive while the guest returns from one call and prepares the next,
causing error 244 even though sector reads work.

Only context-aware ChgDir cookies and Read/ReadLn payloads use this gap. Sector
reads and payload bytes remain contiguous; TCP has no added delay. This replaces
the diagnostic delay after every byte. The native SwiftUI/ORSSerial backend is
unchanged by this portable-backend fix.
