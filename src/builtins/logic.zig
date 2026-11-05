const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Allocator = std.mem.Allocator;
const Param = exec.Param;

const ab_variadic = [_]Param{ .{ .name = "a" }, .{ .name = "b", .arity = .variadic } };

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "logic");
    try g.register("and", Operation.fromFn(andOp, .{
        .signature = .{ .params = &ab_variadic, .returns = .{ .one_of = &.{ .any, .none } } },
        .description = "Returns the last argument when all are truthy, else $none.",
    }));

    try g.register("or", Operation.fromFn(orOp, .{
        .signature = .{ .params = &ab_variadic, .returns = .{ .one_of = &.{ .any, .none } } },
        .description = "Returns the first truthy argument, else $none.",
    }));

    try g.register("not", Operation.fromFn(notOp, .{
        .signature = .{ .params = comptime &.{Param{ .name = "x" }}, .returns = .{ .one_of = &.{ .some, .none } } },
        .description = "Returns $some when the argument is $none, else $none.",
    }));
}

fn andOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var last: ?Value = null;
    for (0..args.count()) |i| {
        last = try args.at(i).get();
        if (last == null) return null;
    }
    return last;
}

fn orOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    for (0..args.count()) |i| {
        const result = try args.at(i).get();
        if (result != null) return result;
    }
    return null;
}

fn notOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const result = try args.at(0).get();
    return if (result != null) null else val.some();
}

const testing = @import("testing.zig");

test "logic: and short-circuits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const both_some = try testing.evalWithBuiltins(arena.allocator(), "and $some $some");
    try std.testing.expect(both_some != null);
    const first_none = try testing.evalWithBuiltins(arena.allocator(), "and $none $some");
    try std.testing.expect(first_none == null);
}

test "logic: or short-circuits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first_some = try testing.evalWithBuiltins(arena.allocator(), "or $some $none");
    try std.testing.expect(first_some != null);
    const both_none = try testing.evalWithBuiltins(arena.allocator(), "or $none $none");
    try std.testing.expect(both_none == null);
}

test "logic: not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const negated_some = try testing.evalWithBuiltins(arena.allocator(), "not $some");
    try std.testing.expect(negated_some == null);
    const negated_none = try testing.evalWithBuiltins(arena.allocator(), "not $none");
    try std.testing.expect(negated_none != null);
}
