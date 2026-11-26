const std = @import("std");
const expr_parser = @import("parser.zig");
const validation_mod = @import("validation.zig");
const macro_parser_mod = @import("macro_parser.zig");
const serializer_mod = @import("serializer.zig");
const exec_mod = @import("exec.zig");
const val = @import("value.zig");
const cache_mod = @import("cache.zig");

const Allocator = std.mem.Allocator;
const Value = val.Value;
const Env = exec_mod.Env;
const Scope = exec_mod.Scope;
const Registry = exec_mod.Registry;
const Expression = exec_mod.Expression;
const Unit = exec_mod.Unit;
const RuntimeErr = exec_mod.RuntimeErr;
const ValidationError = validation_mod.ValidationError;
const AstMacro = macro_parser_mod.AstMacro;
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

pub const MacroLoadResult = union(enum) {
    ok: usize,
    validation_err: []const ValidationError,
};

pub const MacroFileResult = union(enum) {
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

pub fn processRaw(
    env: *Env,
    source: []const u8,
    scope: ?*const Scope,
) (Allocator.Error)!ProcessResult {
    const ast_root = try expr_parser.parse(env.allocator, source);
    const validation_result = try validation_mod.validate(env.allocator, ast_root);

    switch (validation_result) {
        .ok => |unit| return executeUnit(env, unit, scope),
        .err => |errors| return .{ .validation_err = errors },
    }
}

pub fn processRawCached(
    env: *Env,
    parse_allocator: Allocator,
    expression_cache: *ExpressionCache,
    source: []const u8,
    scope: ?*const Scope,
) (Allocator.Error)!ProcessResult {
    if (expression_cache.get(source)) |unit| {
        return executeUnit(env, unit, scope);
    }

    const ast_root = try expr_parser.parse(parse_allocator, source);
    const validation_result = try validation_mod.validate(parse_allocator, ast_root);

    switch (validation_result) {
        .ok => |unit| {
            try expression_cache.put(source, unit);
            return executeUnit(env, unit, scope);
        },
        .err => |errors| return .{ .validation_err = errors },
    }
}

fn executeUnit(env: *Env, unit: Unit, scope: ?*const Scope) (Allocator.Error)!ProcessResult {
    const exec_scope = scope orelse &Scope.EMPTY;
    const frame = try env.enterUnit(unit.unit_id, unit.site_count);
    defer env.exitUnit(frame);

    const result = unit.root.proc(env, exec_scope) catch |err| switch (err) {
        error.RuntimeError => return .{ .runtime_err = env.runtime_error orelse .{ .category = .internal, .message = "Unknown runtime error" } },
        error.OutOfMemory => {
            if (env.memory_budget_tripped) {
                const budget_error: RuntimeErr = .{ .category = .memory_exhausted, .message = "Memory budget exhausted", .macro = env.current_macro, .position = null };
                env.runtime_error = budget_error;
                return .{ .runtime_err = budget_error };
            }
            return error.OutOfMemory;
        },
    };
    return .{ .ok = result };
}

pub fn loadMacroModule(
    registry: *Registry,
    source: []const u8,
) Allocator.Error!MacroLoadResult {
    const alloc = registry.macroAllocator();

    // The macros keep this copy, so a file's buffer can be freed after loading.
    const text = try alloc.dupe(u8, source);
    const module = (try macro_parser_mod.parseMacroModuleWithComments(alloc, text)).module;

    const validation_result = try macro_parser_mod.validateMacroModule(alloc, module, text);

    switch (validation_result) {
        .ok => |macros| {
            for (macros) |*macro| {
                registry.registerMacro(macro.id, macro) catch |err| switch (err) {
                    error.OutOfMemory            => return error.OutOfMemory,
                    error.DuplicateParameterName => std.debug.panic("macro '{s}' passed validation with a repeated parameter name; the macro parser should have rejected it", .{macro.id}),
                };
            }
            return .{ .ok = macros.len };
        },
        .err => |errors| return .{ .validation_err = errors },
    }
}

pub const LoadBuiltError = Allocator.Error || serializer_mod.SerializeError;

pub fn loadBuiltMacros(registry: *Registry, macros: []const AstMacro) LoadBuiltError!MacroLoadResult {
    var text: std.Io.Writer.Allocating = .init(registry.macroAllocator());
    serializer_mod.serializeMacroModule(macros, &text.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.InvalidNode => return error.InvalidNode,
    };
    return loadMacroModule(registry, text.written());
}

/// Lish standard library source, bundled into the compiled binary.
pub const STDLIB_SOURCE = @embedFile("stdlib" ++ MACRO_EXTENSION);

pub fn loadStdlib(registry: *Registry) Allocator.Error!void {
    return loadMacroBundle(registry, STDLIB_SOURCE);
}

/// Panics on any problem: text fixed at build time is only broken if lish is.
pub fn loadMacroBundle(registry: *Registry, comptime source: []const u8) Allocator.Error!void {
    switch (try loadMacroModule(registry, source)) {
        .ok => {},
        .validation_err => |errors| std.debug.panic("bundled macros failed to load:{f}", .{BundleProblems{ .problems = errors }}),
    }
}

const BundleProblems = struct {
    problems: []const ValidationError,

    pub fn format(self: BundleProblems, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.problems) |problem| {
            try writer.print("\n  {s}", .{problem.message});
            const line = problem.line orelse continue;
            const column = problem.column orelse continue;
            try writer.print(" (line {d}, column {d})", .{ line, column });
        }
    }
};

pub fn loadFragments(
    registry: *Registry,
    allocator: Allocator,
    fragments: []const RegistryFragment,
) Allocator.Error!void {
    for (fragments) |fragment| {
        try fragment(registry, allocator);
    }
}

pub fn loadMacroFile(
    io: std.Io,
    allocator: Allocator,
    registry: *Registry,
    file_path: []const u8,
) Allocator.Error!MacroFileResult {
    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(MACRO_FILE_MAX_SIZE)) catch |err| {
        return .{ .io_error = err };
    };
    defer allocator.free(source);

    return switch (try loadMacroModule(registry, source)) {
        .ok             => |count| .{ .ok = count },
        .validation_err => |errors| .{ .validation_err = errors },
    };
}

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
    var file_errors: std.ArrayList(MacroDirResult.FileError) = .empty;

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, MACRO_EXTENSION)) continue;

        const full_path = try std.Io.Dir.path.join(allocator, &.{ dir_path, entry.name });

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
const ast_builder = @import("ast_builder.zig");
const diagnostics_mod = @import("diagnostics.zig");

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
            try std.testing.expectEqual(@as(i64, 15), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

fn constOneOp(_: exec_mod.Args) exec_mod.ExecError!?Value {
    return Value{ .int = 1 };
}
fn constTwoOp(_: exec_mod.Args) exec_mod.ExecError!?Value {
    return Value{ .int = 2 };
}
fn constThreeOp(_: exec_mod.Args) exec_mod.ExecError!?Value {
    return Value{ .int = 3 };
}

fn intOp(comptime n: i64) exec_mod.Operation {
    return exec_mod.Operation.fromFn(switch (n) {
        1 => constOneOp,
        2 => constTwoOp,
        else => constThreeOp,
    }, .{ .signature = .{ .returns = .int }, .description = "const" });
}

fn validateUnit(alloc: Allocator, source: []const u8) !exec_mod.Unit {
    const ast_root = try expr_parser.parse(alloc, source);
    return switch (try validation_mod.validate(alloc, ast_root)) {
        .ok => |unit| unit,
        .err => error.TestUnexpectedResult,
    };
}

fn runUnit(env: *Env, unit: exec_mod.Unit) exec_mod.ExecError!?Value {
    const frame = try env.enterUnit(unit.unit_id, unit.site_count);
    defer env.exitUnit(frame);
    return unit.root.proc(env, &Scope.EMPTY);
}

test "one lowered unit resolves per-registry, never to whoever ran it first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var reg_one = Registry.init(alloc);
    defer reg_one.deinit(alloc);
    try reg_one.registerOperation(alloc, "ping", intOp(1));

    var reg_two = Registry.init(alloc);
    defer reg_two.deinit(alloc);
    try reg_two.registerOperation(alloc, "ping", intOp(2));

    const unit = try validateUnit(alloc, "ping");
    var env_one = Env{ .registry = &reg_one, .allocator = alloc };
    var env_two = Env{ .registry = &reg_two, .allocator = alloc };

    try std.testing.expectEqual(@as(i64, 1), (try runUnit(&env_one, unit)).?.int);
    try std.testing.expectEqual(@as(i64, 2), (try runUnit(&env_two, unit)).?.int);
    try std.testing.expectEqual(@as(i64, 1), (try runUnit(&env_one, unit)).?.int);
}

test "two units with overlapping local site ids never alias (collision regression)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    defer registry.deinit(alloc);
    try registry.registerOperation(alloc, "a", intOp(1));
    try registry.registerOperation(alloc, "b", intOp(2));

    const unit_a = try validateUnit(alloc, "a");
    const unit_b = try validateUnit(alloc, "b");
    var env = Env{ .registry = &registry, .allocator = alloc };

    try std.testing.expectEqual(@as(i64, 1), (try runUnit(&env, unit_a)).?.int);
    try std.testing.expectEqual(@as(i64, 2), (try runUnit(&env, unit_b)).?.int);
    try std.testing.expectEqual(@as(i64, 1), (try runUnit(&env, unit_a)).?.int);
}

test "evicted unit re-resolves correctly on next use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.initCapacity(alloc, 2);
    defer registry.deinit(alloc);
    try registry.registerOperation(alloc, "a", intOp(1));
    try registry.registerOperation(alloc, "b", intOp(2));
    try registry.registerOperation(alloc, "c", intOp(3));

    const unit_a = try validateUnit(alloc, "a");
    const unit_b = try validateUnit(alloc, "b");
    const unit_c = try validateUnit(alloc, "c");
    var env = Env{ .registry = &registry, .allocator = alloc };

    try std.testing.expectEqual(@as(i64, 1), (try runUnit(&env, unit_a)).?.int);
    try std.testing.expectEqual(@as(i64, 2), (try runUnit(&env, unit_b)).?.int);
    try std.testing.expectEqual(@as(i64, 3), (try runUnit(&env, unit_c)).?.int);
    try std.testing.expectEqual(@as(usize, 2), registry.resolution.count());
    try std.testing.expectEqual(@as(i64, 1), (try runUnit(&env, unit_a)).?.int);
}

test "recursion does not evict a live ancestor unit (pinning)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.initCapacity(alloc, 1);
    defer registry.deinit(alloc);
    try builtins.registerAll(&registry, alloc);
    const load = try loadMacroModule(&registry, "countdown n | if (> :n 0) (countdown (- :n 1)) :n ;");
    try std.testing.expect(load == .ok);

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "countdown 50", null);
    switch (result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 0), maybe_value.?.int),
        else => return error.TestUnexpectedResult,
    }
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
            try std.testing.expect(std.mem.find(u8, re.message, "nonexistent") != null);
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

    const value_thunk = try exec_mod.makeValueLiteral(alloc, exec_mod.Position.synthetic, .{ .int = 10 });
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    var scope = Scope{};
    try scope.setEntry(alloc, "x", value_thunk, empty_scope, &exec_mod.Caller.top_level);

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

    const load_result = try loadMacroModule(&registry,"double x | * :x 2 ;");
    switch (load_result) {
        .ok => |count| try std.testing.expectEqual(@as(usize, 1), count),
        .validation_err => return error.TestUnexpectedResult,
    }

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
        "double x | * :x 2 ; quadruple x | double (double :x) ;",
    );
    switch (load_result) {
        .ok => |count| try std.testing.expectEqual(@as(usize, 2), count),
        .validation_err => return error.TestUnexpectedResult,
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

    const load_result = try loadMacroModule(&registry,"foo x | + :x 1 ; foo y | + :y 2 ;");
    switch (load_result) {
        .ok => return error.TestUnexpectedResult,
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

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    const load_result = try loadMacroModule(
        &registry,
        "add-to-x x amount | + :x :amount ;",
    );
    try std.testing.expectEqual(MacroLoadResult{ .ok = 1 }, load_result);

    const value_thunk = try exec_mod.makeValueLiteral(alloc, exec_mod.Position.synthetic, .{ .int = 100 });
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    var scope = Scope{};
    try scope.setEntry(alloc, "x", value_thunk, empty_scope, &exec_mod.Caller.top_level);

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

    const result1 = try processRawCached(&env, env.allocator, &expression_cache, "+ 1 2", null);
    switch (result1) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err    => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), expression_cache.count());

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

    const load_result = try loadMacroModule(&registry, "grab | proc :y ;");
    switch (load_result) {
        .ok => {},
        .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "let y 42 (grab)", null);
    switch (result) {
        .ok             => return error.TestUnexpectedResult,
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => {},
    }
}

test "let: inside macro body, both macro param and let-binding visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    const load_result = try loadMacroModule(
        &registry,
        "scale x | let doubled (* :x 2) (+ :doubled :x) ;",
    );
    switch (load_result) {
        .ok => {},
        .validation_err => return error.TestUnexpectedResult,
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

    const load_result = try loadMacroModule(&registry, "double x | * :x 2 ;");
    switch (load_result) {
        .ok => {},
        .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
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

    const load_result = try loadMacroModule(&registry, "run-it ~body | proc :body ;");
    switch (load_result) {
        .ok => {},
        .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "let y 5 (run-it (+ :y 100))", null);
    switch (result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 105), maybe_value.?.int),
        .validation_err, .runtime_err => return error.TestUnexpectedResult,
    }
}

test "loadStdlib: loads the bundled stdlib into an empty registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try loadStdlib(&registry);
    try std.testing.expect(registry.getMacro("square") != null);
}

test "loadMacroBundle: loads macro text compiled into the program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try loadMacroBundle(&registry, "double x | * :x 2 ; triple x | * :x 3 ;");
    try std.testing.expect(registry.getMacro("double") != null);
    try std.testing.expect(registry.getMacro("triple") != null);
}

fn runtimeErrorOf(env: *Env, source: []const u8) !RuntimeErr {
    return switch (try processRaw(env, source, null)) {
        .runtime_err => |problem| problem,
        .ok, .validation_err => error.TestUnexpectedResult,
    };
}

fn placeText(run_text: []const u8, macro: ?*const exec_mod.Macro, position: ?exec_mod.Position) []const u8 {
    const text = if (macro) |owner| owner.text else run_text;
    const span = position orelse return "";
    return text[span.start..span.end];
}

fn expectStep(run_text: []const u8, step: exec_mod.ErrorStep, macro: ?*const exec_mod.Macro, written: []const u8, repeats: usize) !void {
    try std.testing.expectEqual(macro, step.macro);
    try std.testing.expectEqualStrings(written, placeText(run_text, step.macro, step.position));
    try std.testing.expectEqual(repeats, step.repeats);
}

fn chainRegistry(alloc: Allocator) !Registry {
    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    const macros =
        \\boom x | + 1 (+ :x "bad") ;
        \\twice ~x | list :x :x ;
        \\pass-along | twice (nosuchop) ;
        \\outer-bad x | + :x "bad" ;
        \\my-clamp v lo hi | min :hi (max :lo :v) ;
        \\my-clamp01 v | my-clamp :v 0 1 ;
        \\runaway n | runaway (+ :n 1) ;
    ;
    try std.testing.expectEqual(MacroLoadResult{ .ok = 7 }, try loadMacroModule(&registry, macros));
    return registry;
}

test "an error in the text that was run has no steps and points at what failed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try chainRegistry(arena.allocator());
    var env = Env{ .registry = &registry, .allocator = arena.allocator() };

    const nested = "list 1 (+ 2 \"x\")";
    const nested_error = try runtimeErrorOf(&env, nested);
    try std.testing.expect(nested_error.macro == null);
    try std.testing.expectEqualStrings("(+ 2 \"x\")", placeText(nested, null, nested_error.position));
    try std.testing.expectEqual(@as(usize, 0), nested_error.steps.len);

    const whole = "nosuchop 1";
    const whole_error = try runtimeErrorOf(&env, whole);
    try std.testing.expectEqualStrings("nosuchop 1", placeText(whole, null, whole_error.position));
    try std.testing.expectEqual(@as(usize, 0), whole_error.steps.len);
}

test "an error inside macros ends at your call, with each macro it left as a step, innermost first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try chainRegistry(arena.allocator());
    var env = Env{ .registry = &registry, .allocator = arena.allocator() };

    const nested = "list 1 (boom 2)";
    const nested_error = try runtimeErrorOf(&env, nested);
    try std.testing.expectEqualStrings("(boom 2)", placeText(nested, nested_error.macro, nested_error.position));
    try std.testing.expectEqual(@as(usize, 1), nested_error.steps.len);
    try expectStep(nested, nested_error.steps[0], registry.getMacro("boom"), "(+ :x \"bad\")", 0);

    const outermost = "list 1 (outer-bad 2)";
    const outermost_error = try runtimeErrorOf(&env, outermost);
    try std.testing.expectEqualStrings("(outer-bad 2)", placeText(outermost, outermost_error.macro, outermost_error.position));
    try expectStep(outermost, outermost_error.steps[0], registry.getMacro("outer-bad"), "+ :x \"bad\"", 0);

    const two_deep = "my-clamp01 \"a\"";
    const two_deep_error = try runtimeErrorOf(&env, two_deep);
    try std.testing.expectEqualStrings("my-clamp01 \"a\"", placeText(two_deep, two_deep_error.macro, two_deep_error.position));
    try std.testing.expectEqual(@as(usize, 2), two_deep_error.steps.len);
    try expectStep(two_deep, two_deep_error.steps[0], registry.getMacro("my-clamp"), "(max :lo :v)", 0);
    try expectStep(two_deep, two_deep_error.steps[1], registry.getMacro("my-clamp01"), "my-clamp :v 0 1", 0);
}

test "an error in a deferred argument steps back into the text it was written in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try chainRegistry(arena.allocator());
    var env = Env{ .registry = &registry, .allocator = arena.allocator() };

    const yours = "twice (nosuchop)";
    const yours_error = try runtimeErrorOf(&env, yours);
    try std.testing.expectEqualStrings("twice (nosuchop)", placeText(yours, yours_error.macro, yours_error.position));
    try std.testing.expectEqual(@as(usize, 2), yours_error.steps.len);
    try expectStep(yours, yours_error.steps[0], null, "(nosuchop)", 0);
    try expectStep(yours, yours_error.steps[1], registry.getMacro("twice"), ":x", 0);

    const passed = "pass-along";
    const passed_error = try runtimeErrorOf(&env, passed);
    try std.testing.expectEqualStrings("pass-along", placeText(passed, passed_error.macro, passed_error.position));
    try std.testing.expectEqual(@as(usize, 3), passed_error.steps.len);
    try expectStep(passed, passed_error.steps[0], registry.getMacro("pass-along"), "(nosuchop)", 0);
    try expectStep(passed, passed_error.steps[1], registry.getMacro("twice"), ":x", 0);
    try expectStep(passed, passed_error.steps[2], registry.getMacro("pass-along"), "twice (nosuchop)", 0);
}

test "runaway recursion collapses into one repeated step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try chainRegistry(arena.allocator());
    var env = Env{ .registry = &registry, .allocator = arena.allocator() };

    const command = "runaway 0";
    const problem = try runtimeErrorOf(&env, command);
    try std.testing.expectEqualStrings("runaway 0", placeText(command, problem.macro, problem.position));
    try std.testing.expectEqual(@as(usize, 2), problem.steps.len);
    try expectStep(command, problem.steps[0], registry.getMacro("runaway"), "(+ :n 1)", 0);
    try std.testing.expectEqualStrings("runaway (+ :n 1)", placeText(command, problem.steps[1].macro, problem.steps[1].position));
    try std.testing.expect(problem.steps[1].repeats > 1000);
}

test "a real error through macros prints as the full report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try chainRegistry(arena.allocator());
    var env = Env{ .registry = &registry, .allocator = arena.allocator() };

    const script = "list 1\n  (my-clamp01 \"a\")\n";
    const problem = try runtimeErrorOf(&env, script);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try diagnostics_mod.writeRuntimeReport(&output.writer, .{ .name = "backup.lish", .text = script }, problem, false);
    try std.testing.expectEqualStrings(
        \\backup.lish:2:3: 'max' expects numbers, got string
        \\  (my-clamp01 "a")
        \\  ^^^^^^^^^^^^^^^^
        \\in macro my-clamp01:
        \\  my-clamp01 v | my-clamp :v 0 1 ;
        \\                 ^^^^^^^^^^^^^^^
        \\in macro my-clamp:
        \\  my-clamp v lo hi | min :hi (max :lo :v) ;
        \\                             ^^^^^^^^^^^^
        \\
    , output.written());
}

test "loadMacroModule: each macro keeps the text it was loaded from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = Registry.init(arena.allocator());

    const source = "double x | * :x 2 ;\ntriple x | * :x 3 ;";
    try std.testing.expectEqual(MacroLoadResult{ .ok = 2 }, try loadMacroModule(&registry, source));
    try std.testing.expectEqualStrings(source, registry.getMacro("double").?.text);
    try std.testing.expectEqualStrings(source, registry.getMacro("triple").?.text);
}

test "loadMacroFile: a macro keeps its text after the file's buffer is freed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var io_instance: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "double.lishmacro", .data = "double x | * :x 2 ;" });
    const path = try std.Io.Dir.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "double.lishmacro" });

    var registry = Registry.init(arena.allocator());
    try std.testing.expectEqual(MacroFileResult{ .ok = 1 }, try loadMacroFile(io, std.testing.allocator, &registry, path));
    try std.testing.expectEqualStrings("double x | * :x 2 ;", registry.getMacro("double").?.text);
}

fn buildGreetMacro(b: ast_builder.AstBuilder) !AstMacro {
    var concat_builder = b.expr("concat");
    const concat_node = try concat_builder.arg(try b.string("hello ")).arg(try b.scope("name")).build();
    var say_builder = b.expr("say");
    const body = try say_builder.arg(concat_node).build();
    var macro_builder = b.macro("greet");
    return macro_builder.param("name").body(body);
}

test "loadBuiltMacros: a built macro carries its written-out text and real positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    const greet = try buildGreetMacro(ast_builder.AstBuilder.init(alloc));
    try std.testing.expectEqual(MacroLoadResult{ .ok = 1 }, try loadBuiltMacros(&registry, &.{greet}));

    const macro = registry.getMacro("greet").?;
    try std.testing.expectEqualStrings("greet name | say (concat \"hello \" :name) ;", macro.text);
    const concat_position = macro.body.args[0].position;
    try std.testing.expectEqualStrings("(concat \"hello \" :name)", macro.text[concat_position.start..concat_position.end]);
}

test "loadBuiltMacros: a built macro with a repeated parameter is rejected like written text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const b = ast_builder.AstBuilder.init(alloc);
    var body_builder = b.expr("+");
    const body = try body_builder.arg(try b.scope("a")).arg(try b.int(0)).build();
    var macro_builder = b.macro("pick");
    const pick = try macro_builder.param("a").param("a").body(body);

    var registry = Registry.init(alloc);
    switch (try loadBuiltMacros(&registry, &.{pick})) {
        .validation_err => |errors| try std.testing.expectEqualStrings("Duplicate parameter name 'a'", errors[0].message),
        .ok             => return error.TestUnexpectedResult,
    }
    try std.testing.expect(registry.getMacro("pick") == null);
}

test "loadBuiltMacros: a macro with a part the parser marked broken is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var broken = try buildGreetMacro(ast_builder.AstBuilder.init(alloc));
    broken.id = .{ .err = .{ .message = "Expected a macro name", .line = 1, .column = 1, .start = 0, .end = 0 } };

    var registry = Registry.init(alloc);
    try std.testing.expectError(error.InvalidNode, loadBuiltMacros(&registry, &.{broken}));
}

test "loadMacroFile: loads a file, returns its problems, or says it can't be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var io_instance: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "good.lishmacro", .data = "double x | * :x 2 ;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.lishmacro", .data = "bad x | (+ :x 1 ;" });
    const folder = try std.Io.Dir.path.join(alloc, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });

    var registry = Registry.init(alloc);

    const good_path = try std.Io.Dir.path.join(alloc, &.{ folder, "good.lishmacro" });
    try std.testing.expectEqual(MacroFileResult{ .ok = 1 }, try loadMacroFile(io, alloc, &registry, good_path));

    const broken_path = try std.Io.Dir.path.join(alloc, &.{ folder, "broken.lishmacro" });
    switch (try loadMacroFile(io, alloc, &registry, broken_path)) {
        .validation_err => |errors| try std.testing.expectEqualStrings("Missing closing parenthesis", errors[0].message),
        .ok, .io_error  => return error.TestUnexpectedResult,
    }

    const missing_path = try std.Io.Dir.path.join(alloc, &.{ folder, "missing.lishmacro" });
    switch (try loadMacroFile(io, alloc, &registry, missing_path)) {
        .io_error            => |err| try std.testing.expectEqual(error.FileNotFound, err),
        .ok, .validation_err => return error.TestUnexpectedResult,
    }
}

test "bounds: recursion depth halts runaway macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);

    const load = try loadMacroModule(&registry, "forever | forever ;");
    try std.testing.expect(load == .ok);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.max_call_depth = 32;

    const result = try processRaw(&env, "forever", null);
    switch (result) {
        .runtime_err => |re| {
            try std.testing.expect(std.mem.find(u8, re.message, "Recursion depth") != null);
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

    const result = try processRaw(&env, "loop 1000 (+ 1 1)", null);
    switch (result) {
        .runtime_err => |re| {
            try std.testing.expect(std.mem.find(u8, re.message, "Fuel exhausted") != null);
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
            try std.testing.expect(std.mem.find(u8, re.message, "List length") != null);
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
            try std.testing.expect(std.mem.find(u8, re.message, "List length") != null);
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

    const load = try loadMacroModule(&registry, "double s | concat :s :s ;");
    try std.testing.expect(load == .ok);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.max_string_length = 100;

    const result = try processRaw(&env,
        "double (double (double (double (double (double (double (double (double (double \"x\")))))))))", null);
    switch (result) {
        .runtime_err => |re| {
            try std.testing.expect(std.mem.find(u8, re.message, "String length") != null);
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

    const load = try loadMacroModule(&registry, "countdown n | if (> :n 0) (countdown (- :n 1)) :n ;");
    try std.testing.expect(load == .ok);

    var env = Env{ .registry = &registry, .allocator = alloc };
    env.bounds.max_call_depth = 1024;

    const result = try processRaw(&env, "countdown 50", null);
    switch (result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 0), maybe_value.?.int),
        else => return error.TestUnexpectedResult,
    }
}
