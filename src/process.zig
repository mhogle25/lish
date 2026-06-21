const std = @import("std");
const expr_parser = @import("parser.zig");
const validation_mod = @import("validation.zig");
const macro_parser_mod = @import("macro_parser.zig");
const exec_mod = @import("exec.zig");
const val = @import("value.zig");
const cache_mod = @import("cache.zig");

const Allocator = std.mem.Allocator;
const Value = val.Value;
const Env = exec_mod.Env;
const Scope = exec_mod.Scope;
const Registry = exec_mod.Registry;
const Expression = exec_mod.Expression;
const RuntimeErr = exec_mod.RuntimeErr;
const ValidationError = validation_mod.ValidationError;
pub const ExpressionCache = cache_mod.ExpressionCache;
pub const LruCache = cache_mod.LruCache;

pub const MACRO_EXTENSION = ".lishmacro";
pub const LISH_EXTENSION  = ".lish";

/// Maximum size of a single `.lishmacro` file loaded from disk. Larger files
/// fail with an IO error rather than silently consuming memory.
pub const MACRO_FILE_MAX_SIZE = 1024 * 1024;

/// Maximum size of a single `.lish` file (single-expression source) loaded
/// from disk. Larger files fail with an IO error.
pub const LISH_FILE_MAX_SIZE = 1024 * 1024;


/// Result of processing a raw expression string.
pub const ProcessResult = union(enum) {
    ok: ?Value,
    validation_err: []const ValidationError,
    runtime_err: RuntimeErr,
};

/// Result of loading a macro module from source.
pub const MacroLoadResult = union(enum) {
    ok: usize,
    io_error: anyerror,
    validation_err: []const ValidationError,

};

/// Result of loading a directory of macro files.
pub const MacroDirResult = struct {
    loaded_count: usize,
    file_errors: []const FileError,

    pub const FileError = struct {
        path: []const u8,
        io_error: ?anyerror = null,
        errors: []const ValidationError = &.{},
    };

    pub fn deinit(self: MacroDirResult, allocator: Allocator) void {
        for (self.file_errors) |file_error| {
            allocator.free(file_error.path);
        }
        if (self.file_errors.len > 0) allocator.free(@constCast(self.file_errors));
    }
};

/// A function that registers operations into a Registry.
/// Allows modular operation registration.
pub const RegistryFragment = *const fn (*Registry, Allocator) Allocator.Error!void;


/// Parse, validate, and execute a raw expression string in one call.
pub fn processRaw(
    env: *Env,
    source: []const u8,
    scope: ?*const Scope,
) (Allocator.Error)!ProcessResult {
    const ast_root = try expr_parser.parse(env.allocator, source);
    const validation_result = try validation_mod.validate(env.allocator, ast_root);

    switch (validation_result) {
        .ok => |expression| {
            exec_mod.stampExpression(@constCast(&expression), env.registry);
            return executeExpression(env, expression, scope);
        },
        .err => |errors| return .{ .validation_err = errors },
    }
}

/// Parse (cached), validate, and execute. The cached expression is allocated in
/// `parse_allocator` (must outlive the cache); execution allocates transient
/// values in `env.allocator`.
pub fn processRawCached(
    env: *Env,
    parse_allocator: Allocator,
    expression_cache: *ExpressionCache,
    source: []const u8,
    scope: ?*const Scope,
) (Allocator.Error)!ProcessResult {
    // Cache hit: skip parse + validate
    if (expression_cache.get(source)) |expression| {
        return executeExpression(env, expression, scope);
    }

    // Cache miss: parse + validate into parse_allocator, cache, then execute.
    const ast_root = try expr_parser.parse(parse_allocator, source);
    const validation_result = try validation_mod.validate(parse_allocator, ast_root);

    switch (validation_result) {
        .ok => |expression| {
            exec_mod.stampExpression(@constCast(&expression), env.registry);
            try expression_cache.put(source, expression);
            return executeExpression(env, expression, scope);
        },
        .err => |errors| return .{ .validation_err = errors },
    }
}

fn executeExpression(env: *Env, expression: Expression, scope: ?*const Scope) (Allocator.Error)!ProcessResult {
    const exec_scope = scope orelse &Scope.EMPTY;
    const result = env.processExpression(expression, exec_scope) catch |err| switch (err) {
        error.RuntimeError => return .{ .runtime_err = env.runtime_error orelse .{ .category = .internal, .message = "Unknown runtime error" } },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .ok = result };
}

/// Parse a macro module source string, validate it, and register all macros
/// into the provided registry.
pub fn loadMacroModule(
    registry: *Registry,
    source: []const u8,
) Allocator.Error!MacroLoadResult {
    const alloc = registry.macroAllocator();

    // 1. Parse macro module
    const module = try macro_parser_mod.parseMacroModule(alloc, source);

    // 2. Validate
    const validation_result = try macro_parser_mod.validateMacroModule(alloc, module);

    switch (validation_result) {
        .ok => |macros| {
            // 3. Register all macros and stamp their body call sites with site ids.
            for (macros) |*macro| {
                try registry.registerMacro(macro.id, macro);
                exec_mod.stampExpression(@constCast(&macro.body), registry);
            }
            // 4. New names are now visible; drop memoized resolutions so call sites
            //    re-resolve against the updated registry.
            registry.clearResolution();
            return .{ .ok = macros.len };
        },
        .err => |errors| return .{ .validation_err = errors },
    }
}

/// Lish standard library source, bundled into the compiled binary.
pub const STDLIB_SOURCE = @embedFile("stdlib" ++ MACRO_EXTENSION);

/// Load the bundled standard library macros into a registry.
/// Library consumers opt into the stdlib by calling this after Session init.
pub fn loadStdlib(registry: *Registry) Allocator.Error!MacroLoadResult {
    return loadMacroModule(registry, STDLIB_SOURCE);
}

/// Load multiple registry fragments into a registry.
pub fn loadFragments(
    registry: *Registry,
    allocator: Allocator,
    fragments: []const RegistryFragment,
) Allocator.Error!void {
    for (fragments) |fragment| {
        try fragment(registry, allocator);
    }
}

/// Read a .lishmacro file from disk, parse, validate, and register macros.
pub fn loadMacroFile(
    io: std.Io,
    allocator: Allocator,
    registry: *Registry,
    file_path: []const u8,
) Allocator.Error!MacroLoadResult {
    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(MACRO_FILE_MAX_SIZE)) catch |err| {
        return .{ .io_error = err };
    };
    defer allocator.free(source);

    return loadMacroModule(registry, source);
}

/// Read a `.lish` file (a single expression) from disk, parse, validate, and
/// evaluate against the given environment. IO errors propagate as a Zig
/// error union; parse/runtime errors surface inside the ProcessResult.
pub fn loadLishFile(
    io: std.Io,
    env: *Env,
    file_path: []const u8,
    scope: ?*const Scope,
) !ProcessResult {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, file_path, env.allocator, .limited(LISH_FILE_MAX_SIZE));
    defer env.allocator.free(source);
    return processRaw(env, source, scope);
}

/// Scan a directory for .lishmacro files and load each one.
pub fn loadMacroDir(
    io: std.Io,
    allocator: Allocator,
    registry: *Registry,
    dir_path: []const u8,
) !MacroDirResult {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        const file_errors = try allocator.alloc(MacroDirResult.FileError, 1);
        file_errors[0] = .{ .path = try allocator.dupe(u8, dir_path), .io_error = err };
        return .{ .loaded_count = 0, .file_errors = file_errors };
    };
    defer dir.close(io);

    var loaded_count: usize = 0;
    var file_errors: std.ArrayListUnmanaged(MacroDirResult.FileError) = .empty;

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, MACRO_EXTENSION)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        const result = try loadMacroFile(io, allocator, registry, full_path);
        switch (result) {
            .ok => |count| {
                allocator.free(full_path);
                loaded_count += count;
            },
            .io_error => |err| {
                try file_errors.append(allocator, .{ .path = full_path, .io_error = err });
            },
            .validation_err => |errors| {
                try file_errors.append(allocator, .{ .path = full_path, .errors = errors });
            },
        }
    }

    return .{
        .loaded_count = loaded_count,
        .file_errors = try file_errors.toOwnedSlice(allocator),
    };
}


const builtins = @import("builtins.zig");

test "processRaw: simple expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "+ 1 2", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
}

test "processRaw: nested expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "+ (+ 1 2) (* 3 4)", null);
    switch (result) {
        .ok => |maybe_value| {
            // (1+2) + (3*4) = 3 + 12 = 15
            try std.testing.expectEqual(@as(i64, 15), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

fn pingOneOp(_: exec_mod.Args) exec_mod.ExecError!?Value {
    return Value{ .int = 1 };
}
fn pingTwoOp(_: exec_mod.Args) exec_mod.ExecError!?Value {
    return Value{ .int = 2 };
}

test "one stamped AST resolves per-registry, not to whoever stamped it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Same name, different behavior per registry; op-only so site ids can't collide.
    var reg_one = Registry.init(alloc);
    defer reg_one.deinit(alloc);
    try reg_one.registerOperation(alloc, "ping", exec_mod.Operation.fromFn(pingOneOp, .{
        .signature = .{ .returns = "int" },
        .description = "ping one",
    }));

    var reg_two = Registry.init(alloc);
    defer reg_two.deinit(alloc);
    try reg_two.registerOperation(alloc, "ping", exec_mod.Operation.fromFn(pingTwoOp, .{
        .signature = .{ .returns = "int" },
        .description = "ping two",
    }));

    // Parse, validate, and stamp the AST exactly once (against reg_one).
    const ast_root = try expr_parser.parse(alloc, "ping");
    var stamped = switch (try validation_mod.validate(alloc, ast_root)) {
        .ok => |e| e,
        .err => return error.TestUnexpectedResult,
    };
    exec_mod.stampExpression(&stamped, &reg_one);

    const scope = Scope.EMPTY;
    var env_one = Env{ .registry = &reg_one, .allocator = alloc };
    var env_two = Env{ .registry = &reg_two, .allocator = alloc };

    // The single immutable AST binds to each registry's own definition.
    try std.testing.expectEqual(@as(i64, 1), (try env_one.processExpression(stamped, &scope)).?.int);
    try std.testing.expectEqual(@as(i64, 2), (try env_two.processExpression(stamped, &scope)).?.int);
    // Re-run under one: memoization stayed registry-local.
    try std.testing.expectEqual(@as(i64, 1), (try env_one.processExpression(stamped, &scope)).?.int);
}

test "processRaw: returns none for none operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "none", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expect(maybe_value == null);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
}

test "processRaw: validation error for empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "", null);
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .validation_err => |errors| {
            try std.testing.expect(errors.len > 0);
        },
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "processRaw: runtime error for unknown operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "nonexistent 1 2", null);
    switch (result) {
        .ok             => return error.TestUnexpectedResult,
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => |re| {
            try std.testing.expect(std.mem.indexOf(u8, re.message, "nonexistent") != null);
        },
    }
}

test "processRaw: with scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    // Set up a scope with "x" = 10
    const value_thunk = try exec_mod.makeValueLiteral(alloc, exec_mod.Position.synthetic, .{ .int = 10 });
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    var scope = Scope{};
    try scope.setEntry(alloc, "x", value_thunk, empty_scope);

    const result = try processRaw(&env, "+ :x 5", &scope);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i64, 15), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
}

test "loadMacroModule: load and execute macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    // Load a macro module
    const load_result = try loadMacroModule(&registry,"| double x | * :x 2");
    switch (load_result) {
        .ok => |count| try std.testing.expectEqual(@as(usize, 1), count),
        .io_error, .validation_err => return error.TestUnexpectedResult,
    }

    // Execute using the loaded macro
    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "double 21", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i64, 42), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
}

test "loadMacroModule: multiple macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    const load_result = try loadMacroModule(
        &registry,
        "| double x | * :x 2 | quadruple x | double (double :x)",
    );
    switch (load_result) {
        .ok => |count| try std.testing.expectEqual(@as(usize, 2), count),
        .io_error, .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "quadruple 3", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i64, 12), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
}

test "loadMacroModule: validation errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);

    // Duplicate macro IDs should produce validation errors
    const load_result = try loadMacroModule(&registry,"| foo x | + :x 1 | foo y | + :y 2");
    switch (load_result) {
        .ok, .io_error => return error.TestUnexpectedResult,
        .validation_err => |errors| {
            try std.testing.expect(errors.len > 0);
        },
    }
}

test "loadFragments: load multiple registry fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try loadFragments(&registry, alloc, &.{&builtins.registerAll});

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "+ 1 2", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
}

test "processRaw: full pipeline with macros and scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Set up registry with builtins + macros
    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    const load_result = try loadMacroModule(
        &registry,
        "| add-to-x x amount | + :x :amount",
    );
    try std.testing.expectEqual(MacroLoadResult{ .ok = 1 }, load_result);

    // Set up scope with x = 100
    const value_thunk = try exec_mod.makeValueLiteral(alloc, exec_mod.Position.synthetic, .{ .int = 100 });
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    var scope = Scope{};
    try scope.setEntry(alloc, "x", value_thunk, empty_scope);

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "add-to-x :x 50", &scope);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i64, 150), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
}

test "processRawCached: cache hit skips parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    var expression_cache = try ExpressionCache.init(std.testing.allocator, 16);
    defer expression_cache.deinit();

    // First call: cache miss (parse + validate + cache + execute)
    const result1 = try processRawCached(&env, env.allocator, &expression_cache, "+ 1 2", null);
    switch (result1) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), expression_cache.count());

    // Second call: cache hit (execute only)
    const result2 = try processRawCached(&env, env.allocator, &expression_cache, "+ 1 2", null);
    switch (result2) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
}

test "processRawCached: different expressions get separate cache entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    var expression_cache = try ExpressionCache.init(std.testing.allocator, 16);
    defer expression_cache.deinit();

    const result1 = try processRawCached(&env, env.allocator, &expression_cache, "+ 1 2", null);
    const result2 = try processRawCached(&env, env.allocator, &expression_cache, "* 3 4", null);

    switch (result1) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
    switch (result2) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 12), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 2), expression_cache.count());
}

test "processRawCached: validation errors are not cached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    var expression_cache = try ExpressionCache.init(std.testing.allocator, 16);
    defer expression_cache.deinit();

    const result = try processRawCached(&env, env.allocator, &expression_cache, "", null);
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .validation_err => |errors| try std.testing.expect(errors.len > 0),
        .runtime_err    => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), expression_cache.count());
}


test "let: let-binding does not leak into a called macro's body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    // `grab` references :y, which is NOT one of its params, it should never resolve
    const load_result = try loadMacroModule(&registry, "| grab | proc :y");
    switch (load_result) {
        .ok => {},
        .io_error, .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
    // outer `let` binds y=42; macro is called from the body; macro must not see :y
    const result = try processRaw(&env, "let y 42 (grab)", null);
    switch (result) {
        .ok             => return error.TestUnexpectedResult,
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => {}, // expected, :y not in macro scope
    }
}

test "let: inside macro body, both macro param and let-binding visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    // scale x -> let doubled = x*2 in (doubled + x)
    const load_result = try loadMacroModule(
        &registry,
        "| scale x | let doubled (* :x 2) (+ :doubled :x)",
    );
    switch (load_result) {
        .ok => {},
        .io_error, .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "scale 5", null);
    switch (result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 15), maybe_value.?.int),
        .validation_err, .runtime_err => return error.TestUnexpectedResult,
    }
}

test "let: macro arguments evaluate in caller's let scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    const load_result = try loadMacroModule(&registry, "| double x | * :x 2");
    switch (load_result) {
        .ok => {},
        .io_error, .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
    // y from outer let is read when the macro's value-param is evaluated
    const result = try processRaw(&env, "let y 5 (double :y)", null);
    switch (result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 10), maybe_value.?.int),
        .validation_err, .runtime_err => return error.TestUnexpectedResult,
    }
}

test "let: deferred param captures let scope as a closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    // run-it takes a deferred body; the body is `(+ :y 100)` which references the
    // outer let-binding via the deferred param's captured scope
    const load_result = try loadMacroModule(&registry, "| run-it ~body | proc :body");
    switch (load_result) {
        .ok => {},
        .io_error, .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "let y 5 (run-it (+ :y 100))", null);
    switch (result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 105), maybe_value.?.int),
        .validation_err, .runtime_err => return error.TestUnexpectedResult,
    }
}

test "loadStdlib: loads bundled stdlib without error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    const result = try loadStdlib(&registry);
    switch (result) {
        .ok => {},
        .io_error, .validation_err => return error.TestUnexpectedResult,
    }
}


test "bounds: recursion depth halts runaway macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    // A macro that calls itself with no termination condition.
    const load = try loadMacroModule(&registry, "|forever| forever");
    try std.testing.expect(load == .ok);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.max_call_depth = 32;

    const result = try processRaw(&env, "forever", null);
    switch (result) {
        .runtime_err => |re| {
            try std.testing.expect(std.mem.indexOf(u8, re.message, "Recursion depth") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bounds: fuel exhaustion halts long loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.fuel = 50;
    env.fuel_remaining = env.bounds.fuel;

    // Sub-expression body forces a processExpression call per iteration.
    const result = try processRaw(&env, "loop 1000 (+ 1 1)", null);
    switch (result) {
        .runtime_err => |re| {
            try std.testing.expect(std.mem.indexOf(u8, re.message, "Fuel exhausted") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bounds: unlimited fuel does not interfere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    var env = Env{ .registry = &registry, .allocator = alloc };
    // fuel defaults to null -> unlimited

    const result = try processRaw(&env, "+ 1 2 3", null);
    switch (result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 6), maybe_value.?.int),
        else => return error.TestUnexpectedResult,
    }
}

test "bounds: list length cap halts huge range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.max_list_length = 100;

    const result = try processRaw(&env, "range 0 100000", null);
    switch (result) {
        .runtime_err => |re| {
            try std.testing.expect(std.mem.indexOf(u8, re.message, "List length") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bounds: list length cap halts huge fill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.max_list_length = 100;

    const result = try processRaw(&env, "fill 1000000 0", null);
    switch (result) {
        .runtime_err => |re| {
            try std.testing.expect(std.mem.indexOf(u8, re.message, "List length") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bounds: string length cap halts huge concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    // Define a doubling macro and chain it.
    const load = try loadMacroModule(&registry, "|double s| concat :s :s");
    try std.testing.expect(load == .ok);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.max_string_length = 100;

    // Each double doubles; 10 nestings = 2^10 = 1024 chars, exceeding 100.
    const result = try processRaw(&env,
        "double (double (double (double (double (double (double (double (double (double \"x\")))))))))", null);
    switch (result) {
        .runtime_err => |re| {
            try std.testing.expect(std.mem.indexOf(u8, re.message, "String length") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bounds: shallow recursion under limit works fine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    // Counts down from :n to 0.
    const load = try loadMacroModule(&registry, "|countdown n| if (> :n 0) (countdown (- :n 1)) :n");
    try std.testing.expect(load == .ok);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.max_call_depth = 1024;

    const result = try processRaw(&env, "countdown 50", null);
    switch (result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 0), maybe_value.?.int),
        else => return error.TestUnexpectedResult,
    }
}
