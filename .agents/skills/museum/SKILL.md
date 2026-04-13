---
name: museum
description: Use this skill when you need to look up tmux reference source — function definitions, callers, callees, or behaviour — while working on zmux. Trigger on questions like "what does tmux do here?", "who calls this in tmux?", or any porting gap analysis. Do not trigger for pure zmux Zig questions that don't require tmux comparison.
---

# tmux Museum

`tmux-museum/` contains a pristine read-only copy of the upstream tmux C source,
plus tooling to navigate it.

**Never write to `tmux-museum/src/`.** All generated material (cscope database,
debug builds) lives in `tmux-museum/out/` which is gitignored.

## Finding things

### Quick grep (no setup required)
```bash
grep -rn "function_name" tmux-museum/src/
```

### Scriptable cross-reference queries
```bash
tmux-museum/bin/museum-lookup <type> <symbol>
```

| Type | Meaning |
|------|---------|
| `def` | global definition |
| `callers` | functions that call this function |
| `callees` | functions called by this function |
| `symbol` | every use of this symbol |
| `text` | literal string search |
| `file` | files matching this name |

Output is tab-separated: `file  function  line  text`

Builds the cscope database automatically on first use.

### Interactive browsing (humans)
```bash
tmux-museum/bin/museum-cscope
```

### Rebuild the database
```bash
tmux-museum/bin/refresh-museum.sh xref
```

## Porting gap analysis process

1. `museum-lookup def <fn>` — read the tmux implementation
2. `museum-lookup callers <fn>` — find every tmux callsite
3. `grep -rn <fn> src/` — compare zmux callsite count
4. For each tmux callsite missing in zmux: read surrounding context and determine
   if zmux handles it differently or if it is a genuine gap
5. Document confirmed gaps in `docs/zmux-porting-todo.md`

## Protocol Tracing

For runtime behavior analysis — when you need to see what messages actually cross
the wire, not just what the code says. Complements grep/cscope (static) with
live captures (dynamic).

### When to use tracing

| Need | Tool |
|------|------|
| "What function handles this?" | `museum-lookup`, grep |
| "What does zmux actually send on the wire?" | `museum-trace` |
| "How does tmux's wire sequence differ from zmux's?" | `museum-trace` + `diff` |
| "Is this a code bug or a protocol bug?" | `museum-trace` |

### Capture + compare workflow

```bash
# Capture a zmux wire trace
tmux-museum/bin/museum-trace capture --zmux new-session -d -s test
# → writes trace-NNNN.spy-log in current directory

# Capture the same command via tmux museum build
tmux-museum/bin/museum-trace capture --tmux new-session -d -s test

# Compare message sequences (expect PID/path noise; focus on message types and order)
diff -u tmux-trace-*.spy-log zmux-trace-*.spy-log
```

Specify an explicit output path:
```bash
tmux-museum/bin/museum-trace capture --zmux --output zmux-new-session.spy-log new-session -d -s test
tmux-museum/bin/museum-trace capture --tmux --output tmux-new-session.spy-log new-session -d -s test
diff -u tmux-new-session.spy-log zmux-new-session.spy-log
```

Use any binary:
```bash
tmux-museum/bin/museum-trace capture --binary /path/to/custom/zmux "kill-server"
```

### Reading a trace

```
# socket-spy trace
# server: /tmp/museum-trace-12345/server.sock
# proxy: /tmp/museum-trace-12345/proxy.sock
# started: 2026-04-13T04:30:00Z
#
    1  →  identify_flags(100)     len=24    peerid=0   pid=9876
    2  →  identify_term(101)      len=40    peerid=0   pid=9876  string="xterm-256color"
    3  →  identify_cwd(108)       len=48    peerid=0   pid=9876  string="/home/greg"
    4  →  identify_done(106)      len=16    peerid=0   pid=9876
    5  ←  version(12)             len=16    peerid=0   pid=0
    6  ←  ready(207)              len=16    peerid=0   pid=0
    7  →  command(200)            len=52    peerid=0   pid=9876  argc=3 argv=["new-session", "-d", "-s", "test"]
    8  ←  exit(203)               len=16    peerid=0   pid=0
```

- `→` = client sent to server
- `←` = server sent to client
- Sequence numbers (not timestamps) make `diff` output stable across runs
- PIDs and socket paths differ between tmux/zmux runs — that is expected noise

### Standalone socket_spy.py

For fine-grained control, run `regress/socket_spy.py` directly:

```bash
# Intercept an already-running server
python3 regress/socket_spy.py \
    --listen /tmp/my-proxy.sock \
    --connect /tmp/zmux-$(id -u)/default \
    --output trace.spy-log

# With hex dumps of every message payload
python3 regress/socket_spy.py \
    --listen /tmp/my-proxy.sock \
    --connect /tmp/zmux-$(id -u)/default \
    --output trace.spy-log \
    --verbose

# Also save raw binary for offline re-analysis
python3 regress/socket_spy.py \
    --listen /tmp/my-proxy.sock \
    --connect /tmp/zmux-$(id -u)/default \
    --output trace.spy-log \
    --raw trace.bin
```

Point clients at the proxy socket instead of the real server:
```bash
zmux -S /tmp/my-proxy.sock list-sessions
```
