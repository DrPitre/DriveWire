# RFM SS.ReadDir

GETSTT (`D6 0B path 2E`) now supports directory iteration. The server first
replies with status 0 (ready), or an OS-9 path/mode error. After ready, the
guest sends a two-byte big-endian result size: 32 for a name/ID or 45 for
name/ID plus metadata. The server replies with status, followed by the
record only on success. EOF is 211; invalid size is 215. The ready phase
lets clients detect old servers without sending an unrecognized payload.

The first 29 bytes contain the name, with its final character's high bit
set; the next three bytes are an opaque ID. Optional metadata is attributes
(1), owner (2), modification date (5: year since 1900/month/day/hour/minute),
link count (1), and byte size (4). Integers are big-endian. This uses the
existing directory snapshot and cursor, skips deleted/dot entries, and
fetches host attributes only for extended results. A zero seek rewinds.
The caller must not interpret the ID as a physical sector address.

Status and record are separate guest receive calls. The record is sent
using the delegate's receive-boundary operation so the serial bitbanger
can enter its next DWRead before the payload starts. TCP uses the same
bytes without serial pacing. EOF/errors have no record payload.

Tests exercise ordinary/extended iteration, max-length names, skipped
entries, rewind, mode/count/path errors, failed metadata lookup without
advancing the selected entry, fragmented requests and receive boundaries.
Real CoCo ReadDir testing remains pending. The matching guest implementation
is on NitrOS-9's `codex/ss-readdir` branch.
