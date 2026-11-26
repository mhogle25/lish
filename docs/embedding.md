# Embedding lish in a Zig project

Add as a dependency in your `build.zig.zon`:

```
zig fetch --save git+https://github.com/mhogle25/lish.git
```

Then in your `build.zig`:

```zig build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const lish_dep = b.dependency("lish", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("lish", lish_dep.module("lish"));
    b.installArtifact(exe);
}
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
                std.debug.print("Result: {s}\n", .{try value.getS(&buf)});
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
const std = @import("std");
const lish = @import("lish");

pub fn runSession(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &.{});
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &.{});

    var session = try lish.Session.init(allocator, .{
        .io = io,
        .fragments = &.{&lish.builtins.registerAll},
        // LRU cache capacity for parsed expressions (default: 256, 0 disables it)
        .expression_cache_capacity = 512,
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
    });
    defer session.deinit();

    // The same result shape as `processRaw`
    _ = try session.execute("+ 1 2");
}
```

## Loading Macros

From source strings:

```zig
const std = @import("std");
const lish = @import("lish");

pub fn loadMyMacros(registry: *lish.Registry) !void {
    const macro_source =
        \\double x | * :x 2 ;
        \\greet name | say (concat "Hello, " :name) ;
    ;

    switch (try lish.loadMacroModule(registry, macro_source)) {
        .ok => |count| std.debug.print("Loaded {d} macros\n", .{count}),
        .validation_err => |errors| for (errors) |err| std.debug.print("{s}\n", .{err.message}),
    }
}
```

From a `.lishmacro` file, or a directory of them:

```zig
const std = @import("std");
const lish = @import("lish");

/// `allocator` is the one the session was made with.
pub fn loadMacroFolder(session: *lish.Session, allocator: std.mem.Allocator) !void {
    const result = try session.loadMacroPath("macros/");
    defer result.deinit(allocator);

    for (result.problems) |problem| switch (problem.kind) {
        .unreadable => |reason| std.debug.print("cannot read {s}: {s}\n", .{ problem.path, @errorName(reason) }),
        .invalid => |invalid| for (invalid.errors) |err| {
            std.debug.print("{s}: {s}\n", .{ problem.path, err.message });
        },
    };
}
```

A file with any problem loads none of its macros; the other files in the directory still load, in name order. A macro name can be defined once: a macro named like an operation or an already-loaded macro is a problem too. An invalid file's errors are byte offsets into `invalid.text`; `lish.diagnostics.writeValidationReport` prints one as `path:line:column: message` with the line marked.

Or pass macro files or directories at the CLI:

```sh
zig build run -- -m macros/
zig build run -- -m macros/math.lishmacro
```

## The bundled stdlib

lish ships a small standard-library macro file (`src/stdlib.lishmacro`) compiled into the binary via `@embedFile`. `builtins.registerCore` (and therefore `builtins.registerAll`) loads it automatically; consumers calling those functions get the stdlib macros without any extra setup.

`lish.loadStdlib(&registry)` loads it into a registry that doesn't have it yet. Loading it into one that does is refused like any repeated macro name. The stdlib is bundled text, so `loadStdlib` panics with any problem instead of returning it: a problem there means lish itself, or the way it's being set up, is broken. Macro text compiled into your own program can be loaded the same way with `lish.loadMacroBundle(&registry, source)`. Its `source` must be known at compile time (a string literal, a constant, `@embedFile`), so a file read at runtime can't be passed; load those with `loadMacroModule` or `loadMacroPath`, which return their problems.

The raw source is also exposed as `lish.STDLIB_SOURCE` for consumers that want to inspect or pre-process it.

## Building AST Programmatically

`AstBuilder` provides a fluent API for constructing lish expressions and macro definitions from Zig code, without parsing source text.

```zig
const std = @import("std");
const lish = @import("lish");

pub fn buildExamples(allocator: std.mem.Allocator, registry: *lish.Registry) !void {
    const b = lish.AstBuilder.init(allocator);

    // Leaf nodes
    _ = try b.int(42);         // 42
    _ = try b.float(3.14);     // 3.14
    _ = try b.string("hello"); // hello
    _ = try b.scope("x");      // :x  (scope reference)
    _ = try b.call("none");    // $none  (zero-argument call)

    // Expressions: chain .arg(), finish with .build()
    var sum_builder = b.expr("+");
    const sum = try sum_builder.arg(try b.int(1)).arg(try b.int(2)).build(); // + 1 2

    // Nested sub-expressions
    var outer_builder = b.expr("+");
    _ = try outer_builder.arg(sum).arg(try b.int(3)).build(); // + (+ 1 2) 3

    // Sugar types: meta type locked at construction
    var list_builder = b.list();
    _ = try list_builder.arg(try b.int(1)).arg(try b.int(2)).build(); // .list_literal
    var block_builder = b.block();
    _ = try block_builder.arg(sum).arg(sum).build();                  // .block_literal

    // Top-level metadata override (rare)
    var top_builder = b.expr("+");
    _ = try top_builder.arg(try b.int(1)).asTopLevel().build(); // .top_level

    // Macro definitions
    var concat_builder = b.expr("concat");
    const concat_node = try concat_builder
        .arg(try b.string("hello "))
        .arg(try b.scope("name"))
        .build();
    var say_builder = b.expr("say");
    const body = try say_builder.arg(concat_node).build();

    var macro_builder = b.macro("greet");
    const greet = try macro_builder.param("name").body(body); // greet name | say (concat "hello " :name) ;

    // Load built macros into a registry
    _ = try lish.loadBuiltMacros(registry, &.{greet});
}
```

`loadBuiltMacros` writes the macros out as lish text and loads that text like any other macro source. They get the same checks (a repeated parameter name comes back as a validation error), and an error inside one shows that text.

## Serializing AST to Source

Any AST node or macro definition can be serialized back to lish source text:

```zig
const std = @import("std");
const lish = @import("lish");

pub fn writeSource(
    writer: *std.Io.Writer,
    node: *const lish.AstNode,
    macro: lish.macro_parser.AstMacro,
    macros: []const lish.macro_parser.AstMacro,
) !void {
    try lish.serializeExpression(node, writer);    // one expression
    try lish.serializeMacro(macro, writer);        // one macro definition
    try lish.serializeMacroModule(macros, writer); // newline-separated, suitable for a .lishmacro file
}
```

Serialization always emits the canonical desugared form: `list` instead of `[...]`, `proc` instead of `{...}`. Comments are not preserved (they are discarded by the lexer during parsing).

## Populating a Scope

`Scope` lets you pass host state into lish expressions. Variables bound in a scope are accessible via `:varname` in any expression evaluated against that scope.

```zig
const std = @import("std");
const lish = @import("lish");

pub fn greetPlayer(allocator: std.mem.Allocator, env: *lish.Env) !lish.ProcessResult {
    var scope = lish.Scope{};
    defer scope.deinit(allocator);

    try scope.setValue(allocator, "playerName", .{ .string = "Aiden" });
    return lish.processRaw(env, "concat \"Hello, \" :playerName", &scope);
}
```

Expressions read a scope's names with `:name`. Setting a name that's already bound replaces its value.

## Custom Operations

Every operation carries required metadata: a structured `Signature` (parameters +
return) and a one-line description. Both are surfaced by introspection
(`lish --dump-ops`) and the LSP. The display string (`my-op x -> any`) is rendered
from the structured signature.

```zig
const std = @import("std");
const lish = @import("lish");

// Stateless operation (no context)
fn myOperation(args: lish.Args) lish.exec.ExecError!?lish.Value {
    return try args.at(0).resolve(); // echo back the first argument
}

// Bound operation (has access to a context struct)
pub const MySystem = struct {
    count: usize = 0,

    fn countOp(self: *MySystem, args: lish.Args) lish.exec.ExecError!?lish.Value {
        _ = args;
        self.count += 1;
        return null;
    }
};

/// `system` must outlive the registry: the "count" op keeps a pointer to it.
pub fn registerMyOps(allocator: std.mem.Allocator, registry: *lish.Registry, system: *MySystem) !void {
    // The params slice escapes into the long-lived Operation, so it needs static
    // lifetime: write it as `comptime &.{...}` (or hoist it to a module-level const).
    try registry.registerOperation(allocator, "my-op", lish.Operation.fromFn(myOperation, .{
        .signature = .{ .params = comptime &.{lish.Param{ .name = "x" }}, .returns = .any },
        .description = "Echo back the first argument.",
    }));

    try registry.registerOperation(allocator, "count", lish.Operation.fromBoundFn(MySystem, MySystem.countOp, system, .{
        .signature = .{ .params = comptime &.{}, .returns = .none },
        .description = "Increment the system counter.",
    }));
}
```

A `lish.Param` is a `.name` plus three optional fields: `.role` (`.value`, `.binding` or `.body`), `.arity` (`.single`, `.optional` or `.variadic`) and `.type` (`.any` unless set).

An operation name can be any bare term, including operator glyphs. The built-in
bitwise ops are named `&`, `|`, `^`, `~`, `<<`, `>>`, and a host is free to
register or shadow ops with those names: `|` and `~` are only special inside a
macro *header* (the header/body separator and the deferred-parameter marker), so
in expression position they are ordinary operator terms. The structural
characters that can never be op names are the base walls (`( ) [ ] { } : $ " ' ;`).

## Running lish from inside an operation

An operation can run more lish while it executes, for example to load a file.
Pass `processRaw` (source text) or `loadLishFile` (a path) the environment the
code should run in:

- **A separate `Env`**: the code runs isolated, with only the operations and
  macros you register for it, and its own memory and limits. The REPL loads
  `config.lish` this way. Leave out the op doing the loading, or a file that
  calls it will load itself forever.
- **The op's own `args.env`**: the code runs nested inside the current command,
  sharing its operations, macros, memory and limits. It behaves like any other
  sub-expression: it finishes before the op returns.

```zig
const std = @import("std");
const lish = @import("lish");

pub fn loadSettingsOp(args: lish.Args) lish.exec.ExecError!?lish.Value {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var registry = lish.Registry.init(arena.allocator());
    try lish.builtins.registerAll(&registry, arena.allocator());
    var env = lish.Env{ .registry = &registry, .allocator = arena.allocator() };

    const result = lish.loadLishFile(args.env.io.?, &env, "settings.lish", null) catch
        return args.env.fail(.invalid_argument, "cannot read settings.lish");
    return switch (result) {
        .ok => null,
        // The message lives in the arena freed on return, so copy it into the caller's env.
        .runtime_err => |err| args.env.failFmt(err.category, "settings.lish: {s}", .{err.message}),
        .validation_err => args.env.fail(.invalid_argument, "settings.lish is not valid lish"),
    };
}
```

Never call `session.execute()` from inside an operation. It starts a new
top-level run, which resets the memory and limits the current run is still
using, so a session that is already running refuses it with a runtime error.
