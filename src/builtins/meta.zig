const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Expression = exec.Expression;
const Thunk = exec.Thunk;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Allocator = std.mem.Allocator;

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    try registry.registerOperation(allocator, "apply", Operation.fromFn(applyOp));
    try registry.registerOperation(allocator, "known", Operation.fromFn(knownOp));
    try registry.registerOperation(allocator, "ops",   Operation.fromFn(opsOp));
}

inline fn makeExpression(id: exec.ExpressionId, arg_buf: []const *const Thunk) Expression {
    return .{ .id = id, .args = arg_buf };
}

fn applyOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const id_value = try args.at(0).resolve();
    const list = try args.at(1).resolveList();

    // Variable-length arg list: must heap-allocate the thunk slice.
    const alloc = args.env.allocator;
    var id_thunk = Thunk{ .value_literal = id_value };
    const id = if (id_value == .string)
        args.env.registry.resolveId(id_value.string) orelse exec.ExpressionId{ .dynamic = &id_thunk }
    else
        exec.ExpressionId{ .dynamic = &id_thunk };
    const thunks = try alloc.alloc(*const Thunk, list.len);
    for (list, 0..) |item, i| {
        thunks[i] = try exec.makeValueLiteral(alloc, item);
    }

    const expression = makeExpression(id, thunks);
    return args.env.processExpression(expression, args.scope);
}

fn knownOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).get() orelse return null;
    if (value != .string) return null;
    if (value.string.len == 0) return null;
    if (args.env.registry.resolveId(value.string) == null) return null;
    return value;
}

fn opsOp(args: Args) ExecError!?Value {
    try args.expectCount(0);

    const alloc = args.env.allocator;
    const registry = args.env.registry;

    var names = std.ArrayListUnmanaged(?Value).empty;
    try names.ensureTotalCapacity(alloc, registry.operations.count() + registry.macros.count());

    var op_iter = registry.operations.keyIterator();
    while (op_iter.next()) |key| {
        const owned = try alloc.dupe(u8, key.*);
        names.appendAssumeCapacity(.{ .string = owned });
    }

    var macro_iter = registry.macros.keyIterator();
    while (macro_iter.next()) |key| {
        const owned = try alloc.dupe(u8, key.*);
        names.appendAssumeCapacity(.{ .string = owned });
    }

    return .{ .list = names.items };
}

// ── Tests ──

const testing = @import("testing.zig");

test "known: built-in op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "known \"+\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("+", result.?.string);
}

test "known: unregistered name returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "known \"nonexistent-op-xyz\"");
    try std.testing.expect(result == null);
}

test "known: non-string arg returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "known 42");
    try std.testing.expect(result == null);
}

test "known: null arg returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "known $none");
    try std.testing.expect(result == null);
}

test "known: empty string returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "known \"\"");
    try std.testing.expect(result == null);
}

test "known: chains with or for fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "apply (or (known \"missing\") \"+\") [10 20]");
    try std.testing.expectEqual(@as(i64, 30), result.?.int);
}

test "ops: returns a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "ops");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .list);
    try std.testing.expect(result.?.list.len > 0);
}

test "ops: contains known built-ins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Use `in` to check membership of "+" in the list of op names.
    const has_plus = try testing.evalWithBuiltins(arena.allocator(), "in \"+\" (ops)");
    try std.testing.expect(has_plus != null);
    const has_map = try testing.evalWithBuiltins(arena.allocator(), "in \"map\" (ops)");
    try std.testing.expect(has_map != null);
    const has_let = try testing.evalWithBuiltins(arena.allocator(), "in \"let\" (ops)");
    try std.testing.expect(has_let != null);
}

test "ops: missing name not in list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const missing = try testing.evalWithBuiltins(arena.allocator(), "in \"nonexistent-xyz\" (ops)");
    try std.testing.expect(missing == null);
}

test "ops: accepts no arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "ops 5");
    try std.testing.expectError(error.RuntimeError, result);
}

test "ops: includes registered macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parser = @import("../parser.zig");
    const validation = @import("../validation.zig");
    const process = @import("../process.zig");
    const builtins = @import("../builtins.zig");

    var registry = Registry.init(alloc);
    builtins.registerAll(&registry, alloc) catch return error.OutOfMemory;

    const macro_load = try process.loadMacroModule(&registry, "|triple x| * :x 3");
    try std.testing.expect(macro_load == .ok);

    var env = testing.makeTestEnv(alloc, &registry);
    const scope = exec.Scope.EMPTY;

    const ast_root = try parser.parse(alloc, "in \"triple\" (ops)");
    const validated = try validation.validate(alloc, ast_root);

    const result = switch (validated) {
        .ok => |expression| try env.processExpression(expression, &scope),
        .err => return error.RuntimeError,
    };
    try std.testing.expect(result != null);
}

test "known: registered macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parser = @import("../parser.zig");
    const validation = @import("../validation.zig");
    const process = @import("../process.zig");
    const builtins = @import("../builtins.zig");

    var registry = Registry.init(alloc);
    builtins.registerAll(&registry, alloc) catch return error.OutOfMemory;

    // Define a macro and load it into the registry
    const macro_load = try process.loadMacroModule(&registry, "|double x| * :x 2");
    try std.testing.expect(macro_load == .ok);

    var env = testing.makeTestEnv(alloc, &registry);
    const scope = exec.Scope.EMPTY;

    const ast_root = try parser.parse(alloc, "known \"double\"");
    const validated = try validation.validate(alloc, ast_root);

    const result = switch (validated) {
        .ok => |expression| try env.processExpression(expression, &scope),
        .err => return error.RuntimeError,
    };

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("double", result.?.string);
}

