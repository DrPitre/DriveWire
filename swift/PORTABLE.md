# Portable Swift server

The Swift package builds the same protocol source files used by the Mac
application. It provides a command-line TCP server for Windows, macOS and Linux;
RFM is shared, including remote OS9Boot loading, fork-inherited directory
cookies and device-root parent traversal.

## Build and run

Install Swift 6.4.2 (or a compatible newer toolchain), then from this directory:

```sh
swift build -c release
swift test
swift run drivewire-server --tcp-port 65504 --rfm-root /path/to/host
```

On Windows, use a native Windows root path:

```powershell
swift run drivewire-server --tcp-port 65504 --rfm-root C:\DriveWire\host
```

An RFM system root has this layout:

```text
host/
  OS9Boot
  DD/
    sysgo
    CMDS/
    SYS/
```

The listener binds to `127.0.0.1` by default. Use `--bind` to select another
interface. Optional `--disk0` through `--disk3` mount virtual disk images;
`--verbose` logs wire bytes. The server accepts one persistent DriveWire guest,
retiring its paths and parser state on disconnect or replacement.

This executable uses TCP for Becker-port emulators. Physical serial transport,
a Windows GUI, and Windows-native MIDI and system-printer output are not part
of this initial executable. The existing Mac application retains its serial,
GUI, MIDI and printing backends. Portable virtual serial TCP connect/listen/join,
Telnet decoding, virtual disks, virtual windows and in-memory printer handling
are included. File-based printer jobs use the shared core implementation.

## Structure

- `DriveWireCore`: existing `DriveWire/Model` protocol sources and MIDI backend
  interfaces, compiled without AppKit, AppIntents, Combine or Apple Network.
- `DriveWireNetworking`: ordered TCP byte streams using SwiftNIO, with callbacks
  delivered to the main dispatch queue on every platform.
- `DriveWireServer`: connection ownership and serialized protocol execution.
- `drivewire-server`: command-line configuration and dispatch executor.

The Xcode project continues to compile the same model files for the Mac app.
Its native Apple networking backend is selected outside SwiftPM. SwiftPM uses
portable networking even on macOS, so local tests exercise that backend.

## Validation

```sh
swift test
swift build -c release
python3 ../scripts/test-portable-server.py "$(swift build -c release --show-bin-path)/drivewire-server"
```

The shared XCTest suite covers disk transactions, printer processing, Telnet,
and RFM. Additional TCP integration tests cover fragmented/coalesced packets,
connection replacement, retired handles/cookies, listen failures and virtual
serial connect/listen/join. Tests use temporary fixtures, not user disk images.

The GitHub Actions workflow builds and tests on Windows, macOS and Linux. Its
Windows artifact bundles the Swift runtime DLLs and runs the external TCP test
with the toolchain removed from the child's PATH, checking deployment as well
as compilation. Windows still requires the Microsoft C/C++ runtime.

The companion NitrOS-9 `recipes/coco3/rfm_boot_test` accepts this executable:

```sh
make check DRIVEWIRE_CLI=/absolute/path/to/drivewire-server
```

That boots from a local kernel track with no local OS9Boot and no RBF modules,
loads the remaining system through RFM, and verifies the live module directory,
a remote directory listing and a completion marker.
