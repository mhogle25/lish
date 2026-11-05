# REPL & CLI

Launch the terminal REPL:

```sh
zig build run
```

Pass macro files or directories (`-m`/`--macros` may be repeated, max 16):

```sh
zig build run -- -m path/to/macros/
zig build run -- -m macros/math.lishmacro
zig build run -- --macros macros/math --macros macros/utils
```

Run a script file (a `.lish` file is a single expression; prints `=> <value>`):

```sh
zig build run -- path/to/script.lish
zig build run -- script.lish -m sibling-macros/
```

Dump the registry's vocabulary as JSON (for editor tooling / docs):

```sh
zig build run -- --dump-ops      # every operation: name, category, signature, description
zig build run -- --dump-macros   # every stdlib macro: name + derived signature
```

## REPL Commands

| Command       | Action              |
|---------------|---------------------|
| `exit`, `quit`| Exit the REPL       |
| `clear`       | Clear the screen    |

The line editor supports:

- **History navigation** (Up/Down or Ctrl+P/N) with new-line-aware behavior: pressing Up from inside a multi-line buffer moves up a visual row first, then recalls the previous history entry once the cursor reaches the top.
- **Cursor movement** (Left/Right, Home, End) and **word movement** (Alt+Left/Right).
- **Multi-line input.** Enter always submits. Alt+Enter inserts a newline and copies the leading whitespace of the previous line, so block bodies stay aligned.
- **Indent control.** Tab inserts two spaces at the cursor; Shift+Tab removes up to two leading spaces from the current line.
- **Bracketed paste.** Pasted text is inserted verbatim (no autopairing, no submit-on-newline), so multi-line pastes round-trip cleanly.
- **Standard readline shortcuts:** Ctrl+A/E/K/U/W/L.

## REPL Configuration

The REPL reads `$XDG_CONFIG_HOME/lish/config.lish` on startup, falling back to `~/.config/lish/config.lish`. The file is a single lish expression evaluated with the full set of core built-ins available. If the file does not exist all settings use their defaults. (`lish --init-config` scaffolds a starter file.)

File extensions used by lish:

| Extension | Purpose | Parser |
|---|---|---|
| `.lish` | A single expression (config files, one-off scripts) | `parser.parse` -> `processRaw` |
| `.lishmacro` | One or more macro declarations | `macro_parser` -> `loadMacroModule` |

| Setting             | Default | Description |
|---------------------|---------|-------------|
| `autopair-insert`   | `$on`   | Typing `(`, `[`, `{`, `"`, or `'` inserts the matching closing delimiter with the cursor positioned between the pair. |
| `autopair-delete`   | `$on`   | Pressing backspace between a matched pair deletes both brackets. |
| `bracket-expand`    | `$on`   | Pressing Alt+Enter with the cursor between `()`, `[]`, or `{}` expands the pair across two lines with the cursor on an indented middle line. Backspace on that indented middle line collapses the expansion back to a single-line `()`. |
| `highlight`         | `$on`   | Syntax highlighting in the REPL renderer (comments, strings, numbers, scope refs, sigils). |
| `indent-width`      | `4`     | Number of spaces inserted per indent level (Tab / auto-indent). |
| `prompt`            | `> `    | The REPL prompt string. |
| `history-size`      | `1024`  | Maximum number of entries retained in REPL history. |
| `macros`            | n/a     | Load `.lishmacro` macros from the given path. Accepts a single `.lishmacro` file or a directory (all `.lishmacro` files in the directory are loaded). May be called multiple times. |
| `max-call-depth`    | `1024`  | Maximum recursion depth (`processExpression` nesting). Prevents Zig stack overflow from runaway macros. Positive integer required. |
| `fuel`              | `$off`  | Maximum total expression evaluations per top-level execute. Halts long-running scripts with a fuel-exhausted error. Positive integer to enable, `$off` for unlimited. |
| `max-list-length`   | `$off`  | Maximum element count for any list constructed at runtime (`range`, `fill`, `map`, `filter`, etc.). Positive integer to enable, `$off` for unlimited. |
| `max-string-length` | `$off`  | Maximum byte length for any string constructed at runtime (`concat`, `join`, `format`, `replace`). Positive integer to enable, `$off` for unlimited. |
| `max-eval-bytes`    | `$off`  | Maximum total bytes one evaluation may allocate. Halts runaway allocation with a memory-exhausted error instead of growing until the OS kills the process. Positive integer to enable, `$off` for unlimited. |

The config file is evaluated as a single lish expression. Use `proc` to sequence multiple settings:

```
proc
    (autopair-insert $off)
    (autopair-delete $off)
    (macros '~/.config/lish/macros')
    (max-call-depth 512)
    (fuel 100000)
    (max-list-length 100000)
    (max-string-length 65536)
```

The config context includes two convenience macros, `$on` and `$off`, for toggling boolean settings. Calling a boolean setting with no argument also enables it. `macros` takes exactly one path argument. An empty file or a file containing only comments is a no-op.

Note: `say` and `error` are not available in the config context; they are excluded to prevent accidental terminal output on every REPL startup.

## Resource bounds

lish enforces parse-time and runtime bounds to prevent malformed or malicious scripts from crashing the host. Parse-time bounds (string/identifier length, expression nesting, parameter count) are compile-time constants. Runtime bounds are configurable per session via `SessionConfig.bounds` (Zig) or the REPL config options above:

| Bound | Field | Default | Catches |
|---|---|---|---|
| Recursion depth | `max_call_depth` | 1024 | Runaway recursive macros (would otherwise overflow the Zig stack and crash the host) |
| Fuel | `fuel` | `null` (unlimited) | Long-running loops or compounding `fillby`-style allocations |
| List length | `max_list_length` | `null` (unlimited) | Huge single allocations from `range`, `fill`, `map`, etc. |
| String length | `max_string_length` | `null` (unlimited) | Exponential string growth via repeated `concat`/`replace` |

Embedded consumers set these directly:

```zig
var session = try lish.Session.init(allocator, .{
    .io = io,
    .fragments = &.{&lish.builtins.registerAll},
    .bounds = .{
        .max_call_depth = 256,
        .fuel = 100_000,
        .max_list_length = 100_000,
        .max_string_length = 64 * 1024,
    },
});
```

When a bound trips, the script returns a `RuntimeError` whose message identifies the bound (`"Recursion depth exceeded ..."`, `"Fuel exhausted"`, `"List length N exceeds limit M"`, `"String length N exceeds limit M"`). The host can distinguish resource exhaustion from other runtime errors via message inspection if needed.

Defaults are permissive (recursion depth aside) so existing scripts and library consumers see no behavior change. Tighten the bounds when running untrusted or user-supplied scripts.
