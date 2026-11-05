const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Param = exec.Param;
const Allocator = std.mem.Allocator;

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "sequencing");
    try g.register("proc", Operation.fromFn(procOp, .{
        .signature = .{ .params = comptime &.{Param{ .name = "expr", .arity = .variadic }}, .returns = .any },
        .description = "Evaluate each argument in order and return the last result.",
    }));

    try g.register("loop", Operation.fromFn(loopOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "name", .role = .binding, .arity = .optional }, Param{ .name = "n", .type = .int }, Param{ .name = "body", .role = .body } }, .returns = .none },
        .description = "Evaluate the body n times; the 3-arg form binds the iteration index to a name.",
    }));

    try g.register("while", Operation.fromFn(whileOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "cond" }, Param{ .name = "body" } }, .returns = .none },
        .description = "Evaluate the body repeatedly while the condition stays truthy.",
    }));
}

fn procOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    var result: ?Value = null;
    for (0..args.count()) |i| {
        result = try args.at(i).get();
    }
    return result;
}

fn loopOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count != 2 and count != 3) return args.env.fail(.arity_mismatch, "'loop' expects 2 or 3 arguments");

    if (count == 2) {
        const n = try args.at(0).resolveInt();
        if (n < 0) return args.env.fail(.invalid_argument, "'loop' count cannot be negative");
        var i: i64 = 0;
        while (i < n) : (i += 1) _ = try args.at(1).get();
        return null;
    }

    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const n = try args.at(1).resolveInt();
    if (n < 0) return args.env.fail(.invalid_argument, "'loop' count cannot be negative");

    const body = args.items[2];
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(args.env.allocator, name, .{ .int = i });
        _ = try body.proc(args.env, &iter_scope);
    }
    return null;
}

fn whileOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    while ((try args.at(0).get()) != null) {
        _ = try args.at(1).get();
    }
    return null;
}

const testing = @import("testing.zig");

test "sequencing: proc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "proc 1 2 3");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "block literal as proc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "proc {1 2 3}");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "loop: returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "loop 3 1");
    try std.testing.expect(result == null);
}

test "loop: zero count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "loop 0 1");
    try std.testing.expect(result == null);
}

test "loop: re-evaluates body via fillby parity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "length (fillby 4 (proc (loop 2 1) 9))");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "loop: negative count errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.RuntimeError, testing.evalWithBuiltins(arena.allocator(), "loop -1 1"));
}

test "loop: with index binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "loop i 3 :i");
    try std.testing.expect(result == null);
}

test "loop: binding accumulates via outer let" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "fillby i 4 :i");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqual(@as(i64, 0), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 1), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 2), items[2].?.int);
    try std.testing.expectEqual(@as(i64, 3), items[3].?.int);
}

test "loop: wrong arg count fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.RuntimeError, testing.evalWithBuiltins(arena.allocator(), "loop"));
    try std.testing.expectError(error.RuntimeError, testing.evalWithBuiltins(arena.allocator(), "loop x y z body"));
}

test "while: terminates when condition is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "while $none 1");
    try std.testing.expect(result == null);
}

test "while: re-evaluates condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "length (fillby 3 (proc (while $none 1) 7))");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}
