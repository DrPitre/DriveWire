# RFM protocol extension

RFM exposes host files and directories through the Swift DriveWire engine.
It is an extension to DriveWire, not a requirement of every DriveWire server.
This reference describes the current implementation in
[DriveWireHost+RFM.swift](../swift/DriveWire/Model/DriveWireHost+RFM.swift).

## Framing

Each request begins with `D6` (OP_RFM), followed by a one-byte sub-operation.
The tables below describe bytes after that prefix. Integers are unsigned and
big-endian. `path` is a one-byte guest-selected open-path number. Pathnames are
ASCII terminated by CR (`0D`); the parser masks their high bits. A status reply
is one byte, with zero meaning success. There is no checksum in this envelope.

Do not infer reply sizes from OS-9 register sizes or send an extra acknowledgement.
Some operations return a status, some return raw data, and writes return nothing.

## Path operations

| Sub-operation | Legacy request payload | Reply |
| --- | --- | --- |
| `01` CREATE | path, PID, directory-owner PID, mode, pathname CR | status |
| `02` OPEN | path, PID, directory-owner PID, mode, pathname CR | status |
| `03` MAKDIR | path, PID, directory-owner PID, mode, pathname CR | status |
| `04` CHGDIR | path, PID, directory-owner PID, mode, pathname CR | status |
| `05` DELETE | path, PID, directory-owner PID, mode, pathname CR | status |

Each header field is one byte. Legacy requests track data and execution
directories separately. Mode bits `24` (hex) select execution context; ordinary
data operations use the data context. Directory mode includes bit `80`.

Sub-operations `11` through `15` perform the same five operations using an
explicit directory context. Their payload is:

```text
path(1), PID(1), directory cookie(3), mode(1), pathname CR
```

An absolute pathname does not require a cookie. Relative names require a valid
nonzero cookie; a missing or retired cookie returns 216, without falling back to
PID-based state. Successful context CHGDIR (`14`) returns status zero followed
by a three-byte cookie. Failure returns only the status. Cookies are opaque host
identities, not disk sector addresses, and are invalidated when RFM state resets.

The configured RFM root contains device directories: `/DD/CMDS` refers to
`<root>/DD/CMDS`. Parent traversal is bounded at the selected device root.
OS-9 multi-dot components are supported (`...` means two parent references).
Host permissions still apply. These pathname rules are not a claim of a secure
filesystem sandbox against host symlinks or concurrent host changes.

## Open-path operations

| Sub-operation | Request payload | Reply |
| --- | --- | --- |
| `06` SEEK | path, position(4) | status |
| `07` READ | path, maximum count(2) | actual count(2), then that many bytes |
| `08` WRITE | path, count(2), bytes | none |
| `09` READLN | path, maximum count(2) | actual count(2), then that many bytes |
| `0A` WRITLN | path, count(2), bytes | none |
| `0B` GETSTT | path, status code, code-specific payload | see below |
| `0C` SETSTT | path, status code, code-specific payload | see below |
| `0D` CLOSE | path | status |

READ and READLN return a **two-byte** count. Zero represents EOF or a read
failure; these operations do not return a separate error byte. The logical
cursor controls subsequent reads and writes, including seek followed by write.
READLN ends at CR or LF and returns CR as the terminator. WRITLN converts its
first CR to host LF and ignores the remaining bytes in that declared payload.
WRITLN also stops at `FF` padding. WRITE is binary. Neither write operation reports host write errors on the wire.
CLOSE releases the selected descriptor and host file handle.

## GETSTT and SETSTT

| GETSTT code | Extra request bytes | Reply |
| --- | --- | --- |
| `02` SS.Size | none | size(4), no leading status |
| `05` SS.Pos | none | position(4), no leading status |
| `06` SS.EOF | none | 0 if not EOF, otherwise 211 |
| `0F` SS.FD | requested count(2) | synthesized FD bytes, capped at 256; no leading status |
| `20` SS.FDInf | ID high byte, length byte, ID middle byte, ID low byte | 256 synthesized FD bytes; length byte is currently ignored |
| `2D` SS.Rename probe | none | 0 for an open path, 201 otherwise |
| `2E` SS.ReadDir | wait for ready status, then result size(2) | result status and, only on success, the record |

Unknown GETSTT codes currently produce no reply. SS.Size/SS.Pos return zero
for an unknown path; SS.EOF returns 211. SS.FD returns zero bytes of the requested
length for an unknown path. These are implementation limitations, not generalized
OS-9 error guarantees.

SETSTT `2D` takes two zero-padded 30-byte basenames after the path and status
code. It renames within the directory opened by that path and returns a status.
Other SETSTT codes currently return success without applying a change.
See [SS.Rename](rfm-rename.md) for validation and directory-cookie behavior.

[SS.ReadDir](rfm-readdir.md) returns 32-byte name/ID records or 45-byte records
with metadata. Its ready handshake is mandatory; send the result size only after
status zero. It shares the directory cursor with READ and SEEK; SEEK zero rewinds.

Legacy directory READ exposes synthesized 32-byte entries: 29 name bytes (high
bit set on the last character), then a three-byte opaque ID. SS.FDInf uses that
ID to obtain host metadata. An FD contains attributes, owner, modification date,
link count, size and creation date in OS-9 layout, followed by zero segment data.
No physical allocation map is available through RFM.

## Receive boundaries and errors

The guest receives READ/READLN counts separately from their payloads, context
CHGDIR status separately from its cookie, and ReadDir status separately from its
record. The portable serial transport paces these boundaries for bitbanger
receivers. TCP carries the same bytes without that transport delay.

Relevant status values include 201 (bad path), 211 (EOF), 214 (access/mode
failure), 215 (invalid request or nonempty directory, depending on operation),
216 (missing path/context), and 218 (rename destination exists). Consult the
specific operation rather than assuming every host error is distinguishable.

The protocol is exercised in
[DriveWireTests.swift](../swift/DriveWireTests/DriveWireTests.swift) and the
[serial integration test](../scripts/test-serial-server.py). For current server
configuration and serial behavior, see the [desktop guide](../desktop/README.md).
