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
