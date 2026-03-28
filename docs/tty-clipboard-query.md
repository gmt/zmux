# TTY Clipboard Query

## Current State

- `refresh-client -l` queries the outer terminal clipboard through
  `tty_clipboard_query`.
- Attached-client input consumes OSC 52 replies from the outer tty, accepts BEL
  or ST terminators, and decodes the reply payload before normal key handling.
- A decoded reply becomes an automatic paste buffer only while
  `TTY_OSC52QUERY` is pending on the tty.
- Valid unsolicited OSC 52 replies are ignored after parsing instead of
  surfacing as attached key input.

## Future Intent

- Route decoded clipboard replies through a shared request/reply seam when the
  broader tty/input clipboard request runtime lands.
