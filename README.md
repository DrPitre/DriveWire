#  DriveWire 

This is the official repository for DriveWire.

DriveWire defines a standard for guest computers to access input/output resources on a host computer. This model gives the guest computer the appearance that it is directly connected to a large storage device, when in fact, connectivity is achieved using a serial cable connected to the host.

There are distinct advantages in utilizing DriveWire as a storage medium:

- **Cost and space savings:** No additional hardware is needed for a guest to use mass storage; no floppy controller, hard drive controller or hard drives are required.
- **Remote operation:** The serial cable that tethers the guest to the host can extend for some length, allowing the guest to be positioned a considerable distance.
- **Easy data management:** Virtual disks that reside on the host can be easily copied, emailed or archived for backup purposes.

The essence of communication between the guest and host is a documented set of uni- and bi-directional messages called *transactions*. Each transaction is composed of one or more packets, which are passed between the guest and host through a serial line connection.

[The DriveWire Specification](https://github.com/boisy/DriveWire/wiki/DriveWire-Specification) provides the information needed to implement both a host and a guest.

## Host platforms

This repository has DriveWire host implementations for supported platforms:

- UNIX: [C](c)
- Mac: [Swift](swift) and [Objective-C](objc)
- Windows and Linux: [portable Swift command-line server](swift/PORTABLE.md)
- Legacy Windows implementation: [Delphi](delphi)

There are other repositories that host DriveWire implementations:

- Python: Mike Furman hosts [pyDriveWire](https://github.com/n6il/pyDriveWire).
- Java: Aaron Wolfe's [DriveWire 4 Server](https://github.com/qbancoffee/drivewire4) updated by Rocky Hill.

## History

DriveWire began life in 2003 as a solution for the Tandy Color Computer. Floppy drives were starting to wane and modern storage options for older computer systems were still years from being developed. [Boisy Pitre](http://www.pitre.org/) gave [this talk](https://www.youtube.com/watch?v=-w7X0CfqFbc) on DriveWire's history and development at Tandy Assembly on October 2, 2021.

In January 2010, Aaron Wolfe, Boisy Pitre, and Jim Hathaway expanded the protocol to include networking services. [This work](https://web.archive.org/web/20100121100655/http://home.spogbiper.com/) became the 1st place winner in the [2010 RetroChallenge Winter Warmup](https://web.archive.org/web/20100110223653/http://www.retrochallenge.net/updates.html). Aaron went on to create DriveWire 4, a Java-based host.

DriveWire is still in use today, and there are a number of [YouTube videos](https://www.youtube.com/results?search_query=drivewire+coco) showing it in action.

## Cross-platform desktop

[DriveWire Desktop](desktop/README.md) uses wxWidgets on Windows, Linux and
macOS with the shared Swift server. The original native Swift Mac application
remains in `swift/DriveWire.xcodeproj`.
