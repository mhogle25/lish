# lish-zig

A Lisp-family expression language interpreter for Zig. Designed to be embedded in other Zig projects as a scripting/configuration DSL or a shell-like utility.

## Not quite Lisp

lish borrows Lisp's prefix notation and parenthesized sub-expressions, but diverges significantly in several areas. If you're coming from Scheme, Common Lisp, or Clojure, expect these differences:

- **No parentheses at the top level.** `+ 1 2` is a complete expression. Parens only appear when nesting: `+ 1 (* 2 3)`.
- **No symbols.** Bare words are strings, not a distinct symbol type. The `'expr` quote operator does not exist — `'...'` is simply a string literal that allows whitespace.
- **No booleans.** There are no `true`/`false`, `t`/`nil` values. Truthiness is existential: any non-null value is truthy, `null` is falsy.
- **Call-by-name, not call-by-value.** Arguments are not evaluated before the call. They are re-evaluated each time the callee accesses them. This applies uniformly to all operations, not just special forms.
- **No cons cells.** Lists are flat arrays. There is no `car`, `cdr`, or dotted pair notation.
- **No first-class functions.** There is no `lambda` and no closures. Macros are named parameter-substitution patterns evaluated at call time, not compile-time code transformers.
- **No mutable state.** There is no `set`, `define`, or `setq`. Host state flows in through scope thunks and is read-only from within lish. The one existing binding form is `let`, which introduces an immutable, lexically-scoped name for a value. The binding evaporates at the end of its body and cannot be reassigned.

## Features

- **Deferred evaluation** — arguments are evaluated on demand, not ahead of time
- **Macro system** — define reusable patterns with `|name params| body`
- **Existential truthiness** — no booleans; values either exist (`?Value`) or they don't (`null`)
- **Arena allocation** — parse and execute within a single arena lifecycle
- **Expression caching** — generic LRU cache avoids redundant parsing
- **93 built-in operations** — arithmetic, comparison, logic, control flow, string, list, higher-order, type, math, binding, and meta functions
- **Binding form for iteration** — `map`, `filter`, `reduce`, etc. take a binding name and a sub-expression body, so transforms live inline at the call site
- **Session API** — backend-agnostic REPL core
- **AST builder** — fluent Zig API for constructing lish expressions and macro definitions programmatically
- **AST serializer** — convert any AST node back to lish source text
- **Embeddable** — use as a Zig module with `zig fetch`

## Syntax Overview

Top-level expressions don't need parens:
```
say hello 42
```

Parens create sub-expressions:
```
+ 1 (* 2 3)
```

Bare terms, `'single-quoted'`, and `"double-quoted"` strings are all string literals:
```
say hello
say 'hello world'
say "hello world"
```

Quoted strings support escape sequences:

| Sequence | Character |
|----------|-----------|
| `\\` | Backslash |
| `\"` | Double quote |
| `\'` | Single quote |
| `\n` | Newline |
| `\r` | Carriage return |
| `\t` | Tab |
| `\0` | Null |
| `\a` | Bell |
| `\b` | Backspace |
| `\e` | Escape (0x1B) |
| `\f` | Form feed |
| `\v` | Vertical tab |

`$term` for single-term expressions, `:name` for scope references:
```
say $some :myVar
```

Lists and blocks (`[...]` is sugar for `list`, `{...}` is sugar for `proc`):
```
[1 2 3]
{(say hello) (say world)}
```

At the top level, use the operation names directly since the sugar forms become sub-expressions:
```
list 1 2 3
proc (say hello) (say world)
```

Comments with `##` (inline or to end of line):
```
+ 1 ## this is a comment ## 2
say hello ## rest of line is ignored
```

Macros (params accessed with `:`):
```
|greet name| say (concat "hello " :name)
```

### Key Concepts

- `$term` — single-term expression (evaluates the term as a zero-argument call)
- `:name` — scope thunk (looks up a named entry in the current scope; used to access macro parameters)
- `[...]` — list sugar
- `{...}` — block sugar (desugars to `proc`; evaluates each sub-expression in order, returns the last)
- `~param` — deferred parameter in macro definitions (not evaluated until accessed)
- `?Value` = truthy, `null` = falsy

## Built-in Operations

| Category          | Operations                                                                                                                       |
|-------------------|----------------------------------------------------------------------------------------------------------------------------------|
| Constants         | `some`, `none`                                                                                                                   |
| Arithmetic        | `+`, `-`, `*`, `/`, `%`, `^`                                                                                                     |
| Comparison        | `<`, `<=`, `>`, `>=`, `is`, `isnt`, `compare`                                                                                    |
| Logic             | `and`, `or`, `not`                                                                                                               |
| Control Flow      | `if`, `when`, `match`, `assert`                                                                                                  |
| String            | `concat`, `join`, `split`, `trim`, `upper`, `lower`, `replace`, `format`                                                         |
| String Predicates | `prefix`, `suffix`, `in`, `find`                                                                                                 |
| Output            | `say`, `error`                                                                                                                   |
| List              | `list`, `flat`, `flatten`, `range`, `until`, `sort`, `sortby`, `sortwith`, `fill`, `fillby`                                      |
| Collection        | `length`, `first`, `last`, `rest`, `at`, `reverse`, `take`, `drop`, `slice`, `zip`                                               |
| Higher-Order      | `map`, `foreach`, `filter`, `reduce`, `any`, `all`, `count`, `findby`                                                            |
| Meta              | `apply`, `known`, `ops`                                                                                                          |
| Math              | `min`, `max`, `clamp`, `abs`, `floor`, `ceil`, `round`, `even`, `odd`, `sign`, `pi`, `sqrt`, `sin`, `cos`, `atan2`, `log`, `exp` |
| Type              | `type`, `int`, `float`, `string`                                                                                                 |
| Sequencing        | `proc`, `loop`, `while`                                                                                                          |
| Binding           | `let`, `pipe`                                                                                                                    |

`proc` takes its name from three overlapping meanings: **procedure** (execute a sequence of steps), **procure** (retrieve a value), and **process** (transform a sequence). With one argument it returns that argument's value; with multiple arguments it evaluates each in order and returns the last.

`let NAME EXPR BODY` evaluates `EXPR` once, binds the result to `NAME` for the duration of `BODY`, and returns the body's value. Inside `BODY`, references via `:NAME` resolve to the bound value. Bindings are immutable, lexically scoped, and do not leak into sibling expressions or called macros. `let` accepts multiple name/value pairs before the body, evaluated sequentially so later pairs can reference earlier ones.

`pipe NAME INITIAL STEP...` threads a value through a sequence of transformations. The first step is evaluated with `:NAME` bound to `INITIAL`; each subsequent step receives the previous step's result via the same binding. Returns the final step's value. Example: `pipe x 25 (sqrt :x) (+ :x 3)` → `(+ (sqrt 25) 3)` → `8`.

### Binding form for iterative ops

`map`, `foreach`, `filter`, `reduce`, `any`, `all`, `count`, `findby`, `sortby`, and `sortwith` all take a **binding name** followed by a **source** and a **body expression**. Inside the body, `:NAME` refers to the current element (or accumulator).

```
map x [1 2 3] (* :x 2)                              ## [2 4 6]
filter n [1 2 3 4 5 6] (even :n)                    ## [2 4 6]
reduce acc 0 x [1 2 3 4 5] (+ :acc :x)              ## 15
findby x [1 2 3 4] (> :x 2)                         ## 3
sortby x [3 1 2] :x                                 ## [1 2 3]
sortwith a b [3 1 2] (compare :a :b)                ## [1 2 3]
```

`reduce` is the only op with two bindings — an accumulator name with its initial value, then an item name with its source list, then the body. `sortwith` is similar in shape: two element names (`a` and `b`) compared per swap.

`loop` and `fillby` accept an **optional** binding for the iteration index — `loop n body` repeats N times without exposing the index; `loop i n body` binds `:i` to `0..N-1` in each iteration. `fillby` mirrors this for slot index.

### Meta operations

`apply NAME LIST` calls the operation named by `NAME` with the elements of `LIST` as positional arguments: `apply "+" [1 2 3]` → `6`. The first argument resolves to a string, looked up in the registry, so dispatch can be dynamic.

`known NAME` returns `NAME` if it is registered as an operation or macro, or null otherwise. Useful for graceful fallback: `apply (or (known "custom-handler") "default") args`.

`ops` (zero args) returns a list of every name registered in the current registry — both operations and macros. Order is unspecified (hashmap iteration). Composes naturally for discovery, counting, or filtering:

```
length (ops)                          ## how many things are callable
sortby x (ops) :x                     ## sorted alphabetically
filter x (ops) (prefix "list-" :x)    ## just list-related names
in "my-op" (ops)                      ## membership check (equivalent to `known`)
```


### `is` and `isnt` are value-preserving

When the comparison succeeds, both ops return the **left argument's value** rather than a generic truthy sentinel — falling back to the sentinel only when the left value is itself null. This lets you thread the actual value through `or` chains and other null-coalescing pipelines:

```
or (isnt (compare (rank :a) (rank :b)) 0)
   (isnt (compare (name :a) (name :b)) 0)
   0
```

The chain returns the first non-zero `compare` result — preserving the sign — and `0` if all compares matched.

## Usage

Add as a dependency in your `build.zig.zon`:

```
zig fetch --save git+https://github.com/mhogle25/lish-zig.git
```

Then in your `build.zig`:

```zig
const lish_dep = b.dependency("lish", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("lish", lish_dep.module("lish"));
```

### Basic Example

```zig
const std = @import("std");
const lish = @import("lish");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Set up a registry with built-in operations
    var registry = lish.Registry.init(allocator);
    try lish.builtins.registerAll(&registry, allocator);

    // Create an execution environment
    var env = lish.Env{
        .registry = &registry,
        .allocator = allocator,
    };

    // Process an expression (use processRawCached with an ExpressionCache to
    // avoid re-parsing repeated inputs)
    const result = try lish.processRaw(&env, "+ 1 2", null);
    switch (result) {
        .ok => |maybe_value| {
            if (maybe_value) |value| {
                var buf: [256]u8 = undefined;
                std.debug.print("Result: {s}\n", .{value.getS(&buf)});
            }
        },
        .validation_err => |errors| {
            for (errors) |err| std.debug.print("Validation: {s}\n", .{err.message});
        },
        .runtime_err => |msg| std.debug.print("Runtime: {s}\n", .{msg}),
    }
}
```

### Using Sessions

The `Session` is the high-level integration point for interactive use. It owns the registry, cache, and arena, and processes one input at a time:

```zig
const lish = @import("lish");

var session = try lish.Session.init(allocator, .{
    .fragments = &.{&lish.builtins.registerAll},
    // Load all .lishmacro files from these directories at init time
    .macro_paths = &.{"macros/"},
    // LRU cache capacity for parsed expressions (default: 256)
    .expression_cache_capacity = 512,
    .stdout = lish.session.fdWriter(std.posix.STDOUT_FILENO),
    .stderr = lish.session.fdWriter(std.posix.STDERR_FILENO),
});
defer session.deinit();

const result = try session.execute("+ 1 2");
```

### Loading Macros

From source strings:

```zig
const macro_source =
    \\|double x| * :x 2
    \\|greet name| say (concat "Hello, " :name)
;

const load_result = try lish.loadMacroModule(&registry, macro_source);
switch (load_result) {
    .ok => |count| std.debug.print("Loaded {d} macros\n", .{count}),
    .io_error  => |err| { /* handle io error */ },
    .validation_err => |errors| { /* handle parse/validation errors */ },
}
```

From `.lishmacro` files:

```zig
// Load a single file
_ = try session.loadMacroFile("macros/math.lishmacro");

// Or scan a directory for all .lishmacro files
_ = try session.loadMacroDir("macros/");
```

Or pass macro files or directories at the CLI:

```sh
zig build run -- -m macros/
zig build run -- -m macros/math.lishmacro
```

### Loading the bundled stdlib

lish ships a small standard-library macro file (`src/stdlib.lishmacro`) compiled into the binary via `@embedFile`. The REPL loads it by default. Library consumers can opt in with a single call after session init:

```zig
_ = try lish.loadStdlib(&session.registry);
```

The raw source is also exposed as `lish.STDLIB_SOURCE` for consumers that want to inspect or pre-process it.

### Building AST Programmatically

`AstBuilder` provides a fluent API for constructing lish expressions and macro definitions from Zig code, without parsing source text.

```zig
const b = lish.AstBuilder.init(allocator);

// Leaf nodes
try b.int(42)            // 42
try b.float(3.14)        // 3.14
try b.string("hello")    // hello
try b.scope("x")         // :x  (scope reference)
try b.call("none")       // $none  (zero-argument call)

// Expressions — chain .arg(), finish with .build()
var eb = b.expr("+");
const node = try eb.arg(try b.int(1)).arg(try b.int(2)).build();
// → + 1 2

// Nested sub-expressions
var inner = b.expr("+");
const inner_node = try inner.arg(try b.int(1)).arg(try b.int(2)).build();
var outer = b.expr("+");
const root = try outer.arg(inner_node).arg(try b.int(3)).build();
// → + (+ 1 2) 3

// Sugar types — meta type locked at construction
var lb = b.list();
const list_node = try lb.arg(try b.int(1)).arg(try b.int(2)).build();  // .list_literal

var bb = b.block();
const block_node = try bb.arg(stmt1).arg(stmt2).build();                // .block_literal

// Top-level metadata override (rare)
var top_eb = b.expr("+");
const top_node = try top_eb.arg(try b.int(1)).asTopLevel().build();     // .top_level

// Macro definitions
var concat_eb = b.expr("concat");
const concat_node = try concat_eb
    .arg(try b.string("hello "))
    .arg(try b.scope("name"))
    .build();
var say_eb = b.expr("say");
const body = try say_eb.arg(concat_node).build();

var mb = b.macro("greet");
const macro_def = try mb.param("name").body(body);
// → |greet name| say (concat "hello " :name)
```

### Serializing AST to Source

Any AST node or macro definition can be serialized back to lish source text:

```zig
// Expression node → source string
try lish.serializeExpression(node, writer);

// Single macro definition
try lish.serializeMacro(macro_def, writer);

// Slice of macro definitions (newline-separated, suitable for a .lishmacro file)
try lish.serializeMacroModule(macros, writer);
```

Serialization always emits the canonical desugared form — `list` instead of `[...]`, `proc` instead of `{...}`. Comments are not preserved (they are discarded by the lexer during parsing).

### Populating a Scope

`Scope` lets you pass host state into lish expressions. Variables bound in a scope are accessible via `:varname` in any expression evaluated against that scope.

```zig
var scope = lish.Scope{};

// Bind a static value — accessed instantly, no re-evaluation
try scope.setValue(allocator, "playerName", .{ .string = "Aiden" });

// Bind a lazily-evaluated expression — re-evaluated each time :varName is accessed
const expr: lish.exec.Expression = ...; // built or validated externally
try scope.setExpression(allocator, "greeting", expr);

// Low-level: bind any Thunk with an explicit entry scope
try scope.setEntry(allocator, "key", thunk_ptr, entry_scope_ptr);
```

In lish expressions, reference scope entries with `:name`:
```
concat "Hello, " :playerName
```

### Custom Operations

```zig
// Stateless operation (no context)
fn myOperation(args: lish.Args) lish.exec.ExecError!?lish.Value {
    const value = try args.at(0).resolve();
    return value; // echo back the first argument
}

try registry.registerOperation(allocator, "my-op", lish.Operation.fromFn(myOperation));

// Bound operation (has access to a context struct)
const MySystem = struct {
    count: usize = 0,

    fn countOp(self: *MySystem, args: lish.Args) lish.exec.ExecError!?lish.Value {
        _ = args;
        self.count += 1;
        return null;
    }
};

var system = MySystem{};
try registry.registerOperation(
    allocator,
    "count",
    lish.Operation.fromBoundFn(MySystem, MySystem.countOp, &system),
);
```

## Building

Requires **Zig 0.15.2** or later.

```sh
# Run all tests
zig build test

# Build the library and CLI
zig build

# Launch the terminal REPL
zig build run

# Pass macro files or directories to the REPL (-m/--macros may be repeated, max 16)
zig build run -- -m path/to/macros/
zig build run -- -m macros/math.lishmacro
zig build run -- --macros macros/math --macros macros/utils
```

### REPL Commands

| Command       | Action              |
|---------------|---------------------|
| `exit`, `quit`| Exit the REPL       |
| `clear`       | Clear the screen    |

The line editor supports history navigation (↑/↓), cursor movement (←/→, Home, End), word movement (Alt+←/→), and standard readline-style shortcuts (Ctrl+A/E/K/U/W/L).

### REPL Configuration

The REPL reads `$XDG_CONFIG_HOME/lish/config.lish` on startup, falling back to `~/.config/lish/config.lish`. The file is a single lish expression evaluated with the full set of core built-ins available. If the file does not exist all settings use their defaults.

File extensions used by lish:

| Extension | Purpose | Parser |
|---|---|---|
| `.lish` | A single expression (config files, one-off scripts) | `parser.parse` → `processRaw` |
| `.lishmacro` | One or more macro declarations | `macro_parser` → `loadMacroModule` |

| Setting | Default | Description |
|---------|---------|-------------|
| `autopair-insert` | `$some` | Typing `(`, `[`, `{`, `"`, or `'` inserts the matching closing delimiter with the cursor positioned between the pair. |
| `autopair-delete` | `$some` | Pressing backspace between a matched pair deletes both brackets. |
| `macros` | — | Load `.lishmacro` macros from the given path. Accepts a single `.lishmacro` file or a directory (all `.lishmacro` files in the directory are loaded). May be called multiple times. |
| `max-call-depth` | `1024` | Maximum recursion depth (`processExpression` nesting). Prevents Zig stack overflow from runaway macros. Positive integer required. |
| `fuel` | `$off` | Maximum total expression evaluations per top-level execute. Halts long-running scripts with a fuel-exhausted error. Positive integer to enable, `$off` for unlimited. |
| `max-list-length` | `$off` | Maximum element count for any list constructed at runtime (`range`, `fill`, `map`, `filter`, etc.). Positive integer to enable, `$off` for unlimited. |
| `max-string-length` | `$off` | Maximum byte length for any string constructed at runtime (`concat`, `join`, `format`, `replace`). Positive integer to enable, `$off` for unlimited. |

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

Note: `say` and `error` are not available in the config context — they are excluded to prevent accidental terminal output on every REPL startup.

### Resource bounds

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

## Architecture

| File               | Purpose                                              |
|--------------------|------------------------------------------------------|
| `root.zig`         | Public API re-exports                                |
| `value.zig`        | Value tagged union (string, int, float, list)         |
| `token.zig`        | Token types, syntax constants, escape sequences      |
| `lexer.zig`        | Tokenizer with line/column tracking                  |
| `ast.zig`          | AST node types and construction helpers              |
| `parser.zig`       | Recursive descent expression parser                  |
| `validation.zig`   | AST to executable transformation with error checking |
| `exec.zig`         | Runtime: Thunk, Expression, Scope, Env, Registry     |
| `builtins.zig`     | 93 built-in operations                               |
| `macro_parser.zig` | Macro definition parser and validator                |
| `cache.zig`        | Generic LRU cache (`LruCache(V)`)                    |
| `process.zig`      | Convenience API: processRaw, macro file loading      |
| `session.zig`      | Session struct (backend-agnostic REPL core)          |
| `ast_builder.zig`  | Fluent builder for AST nodes and macro definitions   |
| `serializer.zig`   | AST to lish source text serializer                   |
| `line_editor.zig`  | Terminal line editor: raw mode, history, keybindings |
| `main.zig`         | Terminal REPL entry point                            |

## License

[MIT](LICENSE)
