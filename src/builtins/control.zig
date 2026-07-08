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
    const g = registry.group(allocator, "control");
    try g.register("if", Operation.fromFn(ifElseOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "cond" }, Param{ .name = "then" }, Param{ .name = "else", .arity = .optional } }, .returns = .any },
        .description = "If the condition is truthy yield the then-branch, else the optional else-branch (or $none).",
    }));

    try g.register("when", Operation.fromFn(whenOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "cond" }, Param{ .name = "result", .arity = .variadic } }, .returns = .any },
        .description = "Returns the result of the first truthy condition in condition/result pairs, else $none.",
    }));

    try g.register("match", Operation.fromFn(matchOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "target" }, Param{ .name = "pattern" }, Param{ .name = "result", .arity = .variadic }, Param{ .name = "default", .arity = .optional } }, .returns = .any },
        .description = "Returns the result whose pattern equals the target in pattern/result pairs, else the optional trailing default (or $none).",
    }));

    try g.register("panic", Operation.fromFn(panicOp, .{
        .signature = .{ .params = comptime &.{Param{ .name = "message", .type = .string }}, .returns = .none },
        .description = "Raise a runtime error with the message; never returns.",
    }));
}

fn ifElseOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count != 2 and count != 3) return args.env.fail(.arity_mismatch, "'if' expects 2 or 3 arguments");

    const condition = try args.at(0).get();

    if (count == 2) {
        return if (condition != null) try args.at(1).get() else null;
    }

    return if (condition != null) try args.at(1).get() else try args.at(2).get();
}

fn whenOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 2 or count % 2 != 0) {
        return args.env.fail(.arity_mismatch, "'when' expects an even number of arguments (condition/result pairs)");
    }

    var i: usize = 0;
    while (i < count) : (i += 2) {
        const condition = try args.at(i).get();
        if (condition != null) {
            return args.at(i + 1).get();
        }
    }

    return null;
}

fn matchOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 3) {
        return args.env.fail(.arity_mismatch, "'match' expects a target plus at least one pattern/result pair");
    }

    // After the target, an even number of arguments are pattern/result pairs;
    // an odd remainder means the final argument is the no-match default.
    const has_default = (count - 1) % 2 == 1;
    const pairs_end = if (has_default) count - 1 else count;

    const target = try args.at(0).get();

    var i: usize = 1;
    while (i < pairs_end) : (i += 2) {
        const pattern = try args.at(i).get();

        const matches = if (target == null and pattern == null)
            true
        else if (target != null and pattern != null)
            try target.?.eql(pattern.?, args.env.allocator)
        else
            false;

        if (matches) {
            return args.at(i + 1).get();
        }
    }

    return if (has_default) args.at(count - 1).get() else null;
}

fn panicOp(args: Args) ExecError!?Value {
    if (args.count() != 1) return args.env.fail(.arity_mismatch, "'panic' expects 1 argument");
    var msg_buf: [512]u8 = undefined;
    const message = try args.at(0).resolveString(&msg_buf);
    return args.env.failFmt(.user, "{s}", .{message});
}


const testing = @import("testing.zig");

test "control flow: if-then" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const truthy = try testing.evalWithBuiltins(arena.allocator(), "if $some 42");
    try std.testing.expectEqual(@as(i64, 42), truthy.?.int);
    const falsy = try testing.evalWithBuiltins(arena.allocator(), "if $none 42");
    try std.testing.expect(falsy == null);
}

test "control flow: if-then-else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const truthy = try testing.evalWithBuiltins(arena.allocator(), "if $some 1 2");
    try std.testing.expectEqual(@as(i64, 1), truthy.?.int);
    const falsy = try testing.evalWithBuiltins(arena.allocator(), "if $none 1 2");
    try std.testing.expectEqual(@as(i64, 2), falsy.?.int);
}

test "control flow: when" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // First condition is false (none), second is true (some) -> returns 2
    const result = try testing.evalWithBuiltins(arena.allocator(), "when $none 1 $some 2");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "control flow: match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "match 2 1 10 2 20 3 30");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "control flow: match returns a matched arm's result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "match 2 1 10 2 20 99");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "control flow: match preserves a matched arm whose result is $none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The arm for 2 legitimately yields $none; the trailing default must NOT shadow it.
    const result = try testing.evalWithBuiltins(arena.allocator(), "match 2 1 10 2 $none 99");
    try std.testing.expect(result == null);
}

test "control flow: match returns the trailing default on a miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "match 7 1 10 2 20 99");
    try std.testing.expectEqual(@as(i64, 99), result.?.int);
}

test "control flow: match without a default yields $none on a miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "match 7 1 10 2 20");
    try std.testing.expect(result == null);
}

test "control flow: panic raises a runtime error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "panic \"boom\"");
    try std.testing.expectError(error.RuntimeError, result);
}

test "control flow: panic stringifies a non-string argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "panic 42");
    try std.testing.expectError(error.RuntimeError, result);
}

