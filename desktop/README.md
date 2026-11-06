# DriveWire Desktop

A wxWidgets desktop application for Windows, Linux and macOS, using the same
Swift DriveWire protocol engine as the native Mac app. The existing SwiftUI
application and its Xcode project remain supported and separate.

## Features

- Start/stop a TCP Becker-port server, choose address/port, disconnect a guest.
- Select the RFM host root; remote OS9Boot and device directories are shared.
- Mount four disk images, save guest changes, Save As (right-click Save), eject.
  Changed disks are protected against accidental replacement or shutdown.
- Live connection and traffic counters, virtual serial channel status.
- View virtual windows and send a line of input to a selected window.
- Printer text preview and export, bounded live log and log export.
- Remember settings, import/export JSON configurations, recover a crashed backend.

The portable server currently uses TCP, including virtual serial TCP connections.
Physical serial hardware, native MIDI output and system printer integration
remain features of the native Swift Mac app. The desktop printer tab exports
received text. It does not install a platform print driver.

## Build

Requires CMake 3.24+, C++17, wxWidgets 3.2+, Python 3 and Swift 6.4.2.
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
optionally mount disks, then click Start server. Point the emulator's Becker
port to the displayed address and port. The default is loopback, port 65504.
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
python3 scripts/test-desktop.py /path/to/gui-executable --server /path/to/drivewire-server
```

On Linux prefix the second command with `xvfb-run -a`. The desktop test creates
an isolated configuration and temporary image, exercises real Start/Save/Stop
controls, sends DWINIT and a sector write over TCP, checks persisted bytes,
and shuts down the child gracefully. It also checks Unicode paths. No user
preferences are changed. CI builds and tests all three platforms.

## Control protocol

The GUI owns one `drivewire-server --managed` subprocess. UTF-8 JSON requests
are newline-delimited on stdin; responses use `@drivewire ` followed by JSON
on stdout, distinct from existing engine diagnostics. Every response includes
`protocol: 1`, request `id`, `ok`, and a fresh `state`; failures include `error`.
The control interface is a private pipe, never a listening network service.
