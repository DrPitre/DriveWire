# RFM rename protocol

The parent directory must be open in directory/write mode. The host checks its
current filesystem write permission; child read/write permissions do not
control rename. Requests do not overwrite an existing destination or move an
entry between directories.

- Support probe: `D6 0B path 2D`; reply is one OS-9 status byte (0 for supported,
  201 for an unknown handle). Old servers send no response; the updated guest
  treats the bounded probe timeout as `E$UnkSvc` and sends no rename payload.
- Rename: `D6 0C path 2D old[30] new[30]`; reply is one OS-9 status byte.
- Each basename is 1–29 printable ASCII bytes followed by NUL and zero padding.
  Spaces, slash, backslash, colon, dot, and dot-dot names are rejected (dots
  inside a longer name are allowed).
- Invalid records return 215, invalid handles 201, denied access 214, missing
  sources 216, and destination collisions 218. Unknown SetStat codes return 208.

Directory cookies retain their IDs; open descendant paths and legacy working
directory mappings follow a successful rename. Symlinks themselves are renamed.
Host restrictions on moving open files/directories still apply. Existing
in-memory directory listings are refreshed after success.

The NitrOS-9 guest interface is `I$SetStt SS.Rename` ($2D), with A identifying the
parent directory path, X pointing to the 60-byte record, and Y set to 60. It is
also implemented by RBF without sending any DriveWire traffic.
