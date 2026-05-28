const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");
const helpers = @import("helpers.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Allocator = std.mem.Allocator;

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    try registry.registerOperation(allocator, "map",     Operation.fromFn(mapOp));
    try registry.registerOperation(allocator, "foreach", Operation.fromFn(foreachOp));
    try registry.registerOperation(allocator, "filter",  Operation.fromFn(filterOp));
    try registry.registerOperation(allocator, "reduce",  Operation.fromFn(reduceOp));
    try registry.registerOperation(allocator, "any",     Operation.fromFn(anyOp));
    try registry.registerOperation(allocator, "all",     Operation.fromFn(allOp));
    try registry.registerOperation(allocator, "count",   Operation.fromFn(countOp));
    try registry.registerOperation(allocator, "findby",  Operation.fromFn(findbyOp));
}

fn mapOp(args: Args) ExecError!?Value {
    try args.expectCount(3);

    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const list = try args.at(1).resolveList();
    try helpers.checkListLength(args, list.len);
    const body = args.items[2];

    const results = try args.env.allocator.alloc(?Value, list.len);
    for (list, 0..) |item, i| {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(args.env.allocator, name, item);
        results[i] = try body.proc(args.env, &iter_scope);
    }
    return .{ .list = results };
}

fn foreachOp(args: Args) ExecError!?Value {
    try args.expectCount(3);

    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const list = try args.at(1).resolveList();
    const body = args.items[2];

    for (list) |item| {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(args.env.allocator, name, item);
        _ = try body.proc(args.env, &iter_scope);
    }
    return null;
}

fn filterOp(args: Args) ExecError!?Value {
    try args.expectCount(3);

    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const list      = try args.at(1).resolveList();
    const predicate = args.items[2];

    var results = std.ArrayListUnmanaged(?Value).empty;
    for (list) |item| {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(args.env.allocator, name, item);
        const result = try predicate.proc(args.env, &iter_scope);
        if (result != null) {
            try helpers.checkListLength(args, results.items.len + 1);
            try results.append(args.env.allocator, item);
        }
    }
    return .{ .list = results.items };
}

fn reduceOp(args: Args) ExecError!?Value {
    try args.expectCount(5);

    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(args.env.allocator);

    var acc_buf:  [256]u8 = undefined;
    var item_buf: [256]u8 = undefined;
    const raw_acc  = try args.at(0).resolveString(&acc_buf);
    const raw_item = try args.at(2).resolveString(&item_buf);
    const acc_name  = try args.env.allocator.dupe(u8, raw_acc);
    const item_name = try args.env.allocator.dupe(u8, raw_item);

    var accumulator = try args.items[1].proc(args.env, &iter_scope);
    const list = try args.at(3).resolveList();
    const body = args.items[4];

    for (list) |item| {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(args.env.allocator, acc_name,  accumulator);
        try iter_scope.setValue(args.env.allocator, item_name, item);
        accumulator = try body.proc(args.env, &iter_scope);
    }
    return accumulator;
}

fn anyOp(args: Args) ExecError!?Value {
    try args.expectCount(3);

    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const list      = try args.at(1).resolveList();
    const predicate = args.items[2];

    for (list) |item| {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(args.env.allocator, name, item);
        const result = try predicate.proc(args.env, &iter_scope);
        if (result != null) return val.some();
    }
    return null;
}

fn allOp(args: Args) ExecError!?Value {
    try args.expectCount(3);

    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const list      = try args.at(1).resolveList();
    const predicate = args.items[2];

    for (list) |item| {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(args.env.allocator, name, item);
        const result = try predicate.proc(args.env, &iter_scope);
        if (result == null) return null;
    }
    return val.some();
}

fn countOp(args: Args) ExecError!?Value {
    try args.expectCount(3);

    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const list      = try args.at(1).resolveList();
    const predicate = args.items[2];

    var tally: i64 = 0;
    for (list) |item| {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(args.env.allocator, name, item);
        const result = try predicate.proc(args.env, &iter_scope);
        if (result != null) tally += 1;
    }
    return .{ .int = tally };
}

fn findbyOp(args: Args) ExecError!?Value {
    try args.expectCount(3);

    var find_scope = exec.Scope{ .parent = args.scope };
    defer find_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const list = try args.at(1).resolveList();

    for (list) |item| {
        find_scope.inline_count = 0;
        try find_scope.setValue(args.env.allocator, name, item);
        const matched = try args.items[2].proc(args.env, &find_scope);
        if (matched != null) return item;
    }

    return null;
}

// ── Tests ──

const testing = @import("testing.zig");

test "higher-order: map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // map computes lengths of each string, returns a list of lengths
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (map s [\"ab\" \"cde\"] (length :s))");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "higher-order: map applies body per element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "map x [1 2 3] (* :x 2)");
    const items = result.?.list;
    try std.testing.expectEqual(@as(i64, 2), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 4), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 6), items[2].?.int);
}

test "higher-order: apply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "apply \"+\" [1 2 3]");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "higher-order: filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // filter keeps elements where (not :x) is truthy.
    // (not $some) = null (filtered out), (not $none) = some (kept), (not $some) = null (filtered out)
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (filter x [$some $none $some] (not :x))");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "higher-order: reduce sum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "reduce acc 0 x [1 2 3 4 5] (+ :acc :x)");
    try std.testing.expectEqual(@as(i64, 15), result.?.int);
}

test "higher-order: reduce with multiply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "reduce acc 1 x [2 3 4] (* :acc :x)");
    try std.testing.expectEqual(@as(i64, 24), result.?.int);
}

test "higher-order: any truthy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "any x [1 3 4] (even :x)");
    try std.testing.expect(result != null);
}

test "higher-order: any falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "any x [1 3 5] (even :x)");
    try std.testing.expect(result == null);
}

test "higher-order: all truthy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "all x [2 4 6] (even :x)");
    try std.testing.expect(result != null);
}

test "higher-order: all falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "all x [2 3 6] (even :x)");
    try std.testing.expect(result == null);
}

test "higher-order: count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "count x [1 2 3 4 5 6] (even :x)");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "findby: first match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "findby x [1 2 3 4 5] (> :x 2)");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "findby: no match returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "findby x [1 2 3] (> :x 100)");
    try std.testing.expect(result == null);
}

test "findby: empty list returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "findby x [] (> :x 0)");
    try std.testing.expect(result == null);
}

test "findby: predicate sees outer binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "let threshold 3 (findby x [1 2 3 4 5] (> :x :threshold))");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "findby: returns first non-zero in compare chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Verifies findby + isnt pattern for multi-criteria comparison
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "findby x [0 0 -1 1 0] (isnt :x 0)");
    try std.testing.expectEqual(@as(i64, -1), result.?.int);
}

test "findby: wrong arg count fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "findby x [1 2 3]");
    try std.testing.expectError(error.RuntimeError, result);
}

