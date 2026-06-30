# Embedding lish in a Zig project

Add as a dependency in your `build.zig.zon`:

```
zig fetch --save git+https://github.com/mhogle25/lish.git
```

Then in your `build.zig`:

```zig
const lish_dep = b.dependency("lish", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("lish", lish_dep.module("lish"));
```

## Basic Example

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
        .runtime_err => |err| std.debug.print("Runtime [{s}]: {s}\n", .{ @tagName(err.category), err.message }),
    }
}
```

## Using Sessions

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

## Loading Macros

From source strings:

```zig
const macro_source =
    \\double x | * :x 2 ;
    \\greet name | say (concat "Hello, " :name) ;
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

## The bundled stdlib

lish ships a small standard-library macro file (`src/stdlib.lishmacro`) compiled into the binary via `@embedFile`. `builtins.registerCore` (and therefore `builtins.registerAll`) loads it automatically; consumers calling those functions get the stdlib macros without any extra setup.

For consumers wiring up a custom registry that doesn't go through `registerCore`, load it explicitly:

```zig
_ = try lish.loadStdlib(&session.registry);
```

The raw source is also exposed as `lish.STDLIB_SOURCE` for consumers that want to inspect or pre-process it.

## Building AST Programmatically

`AstBuilder` provides a fluent API for constructing lish expressions and macro definitions from Zig code, without parsing source text.

```zig
const b = lish.AstBuilder.init(allocator);

// Leaf nodes
try b.int(42)            // 42
try b.float(3.14)        // 3.14
try b.string("hello")    // hello
try b.scope("x")         // :x  (scope reference)
try b.call("none")       // $none  (zero-argument call)

// Expressions: chain .arg(), finish with .build()
var eb = b.expr("+");
const node = try eb.arg(try b.int(1)).arg(try b.int(2)).build();
// -> + 1 2

// Nested sub-expressions
var inner = b.expr("+");
const inner_node = try inner.arg(try b.int(1)).arg(try b.int(2)).build();
var outer = b.expr("+");
const root = try outer.arg(inner_node).arg(try b.int(3)).build();
// -> + (+ 1 2) 3

// Sugar types: meta type locked at construction
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
// -> greet name | say (concat "hello " :name) ;
```

## Serializing AST to Source

Any AST node or macro definition can be serialized back to lish source text:

```zig
// Expression node -> source string
try lish.serializeExpression(node, writer);

// Single macro definition
try lish.serializeMacro(macro_def, writer);

// Slice of macro definitions (newline-separated, suitable for a .lishmacro file)
try lish.serializeMacroModule(macros, writer);
```

Serialization always emits the canonical desugared form: `list` instead of `[...]`, `proc` instead of `{...}`. Comments are not preserved (they are discarded by the lexer during parsing).

## Populating a Scope

`Scope` lets you pass host state into lish expressions. Variables bound in a scope are accessible via `:varname` in any expression evaluated against that scope.

```zig
var scope = lish.Scope{};

// Bind a static value: accessed instantly, no re-evaluation
try scope.setValue(allocator, "playerName", .{ .string = "Aiden" });

// Bind a lazily-evaluated expression: re-evaluated each time :varName is accessed
const expr: lish.exec.Expression = ...; // built or validated externally
try scope.setExpression(allocator, "greeting", expr);

// Low-level: bind any Thunk with an explicit entry scope
try scope.setEntry(allocator, "key", thunk_ptr, entry_scope_ptr);
```

In lish expressions, reference scope entries with `:name`:
```
concat "Hello, " :playerName
```

## Custom Operations

Every operation carries required metadata: a structured `Signature` (parameters +
return) and a one-line description. Both are surfaced by introspection
(`lish --dump-ops`) and the LSP. The display string (`my-op x -> any`) is rendered
from the structured signature.

```zig
// Stateless operation (no context)
fn myOperation(args: lish.Args) lish.exec.ExecError!?lish.Value {
    const value = try args.at(0).resolve();
    return value; // echo back the first argument
}

// The params slice escapes into the long-lived Operation, so it needs static
// lifetime: write it as `comptime &.{...}` (or hoist it to a module-level const).
try registry.registerOperation(allocator, "my-op", lish.Operation.fromFn(myOperation, .{
    .signature = .{ .params = comptime &.{lish.Param.value("x")}, .returns = "any" },
    .description = "Echo back the first argument.",
}));

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
    lish.Operation.fromBoundFn(MySystem, MySystem.countOp, &system, .{
        .signature = .{ .params = comptime &.{}, .returns = "$none" },
        .description = "Increment the system counter.",
    }),
);
```

`lish.Param` has terse constructors for each role/arity: `Param.value`,
`Param.optional`, `Param.variadic`, `Param.binding`, `Param.body`.

An operation name can be any bare term, including operator glyphs. The built-in
bitwise ops are named `&`, `|`, `^`, `~`, `<<`, `>>`, and a host is free to
register or shadow ops with those names: `|` and `~` are only special inside a
macro *header* (the header/body separator and the deferred-parameter marker), so
in expression position they are ordinary operator terms. The structural
characters that can never be op names are the base walls (`( ) [ ] { } : $ " ' ;`).
