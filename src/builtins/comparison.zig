const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");
const helpers = @import("helpers.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Param = exec.Param;
const Allocator = std.mem.Allocator;

// Ordered comparisons fold over numbers; equality (`is`/`isnt`) works on any value.
const number_variadic = [_]Param{ .{ .name = "a", .type = .number }, .{ .name = "b", .type = .number, .arity = .variadic } };
const ab_variadic = [_]Param{ .{ .name = "a" }, .{ .name = "b", .arity = .variadic } };
const ab = [_]Param{ .{ .name = "a" }, .{ .name = "b" } };

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "comparison");
    try g.register("<", Operation.fromFn(lessThanOp, .{
        .signature = .{ .params = &number_variadic, .returns = .{ .one_of = &.{ .some, .none } } },
        .description = "True when the arguments are strictly increasing.",
    }));

    try g.register("<=", Operation.fromFn(lessThanOrEqualOp, .{
        .signature = .{ .params = &number_variadic, .returns = .{ .one_of = &.{ .some, .none } } },
        .description = "True when the arguments are non-decreasing.",
    }));

    try g.register(">", Operation.fromFn(greaterThanOp, .{
        .signature = .{ .params = &number_variadic, .returns = .{ .one_of = &.{ .some, .none } } },
        .description = "True when the arguments are strictly decreasing.",
    }));

    try g.register(">=", Operation.fromFn(greaterThanOrEqualOp, .{
        .signature = .{ .params = &number_variadic, .returns = .{ .one_of = &.{ .some, .none } } },
        .description = "True when the arguments are non-increasing.",
    }));

    try g.register("is", Operation.fromFn(isOp, .{
        .signature = .{ .params = &ab_variadic, .returns = .{ .one_of = &.{ .any, .none } } },
        .description = "Equality test; returns the first value when all arguments are equal, else $none.",
    }));

    try g.register("isnt", Operation.fromFn(isntOp, .{
        .signature = .{ .params = &ab, .returns = .{ .one_of = &.{ .any, .none } } },
        .description = "Inequality test; returns the left value when the two differ, else $none.",
    }));

    try g.register("compare", Operation.fromFn(compareOp, .{
        .signature = .{ .params = comptime &.{ .{ .name = "a", .type = .{ .one_of = &.{ .number, .string } } }, .{ .name = "b", .type = .{ .one_of = &.{ .number, .string } } } }, .returns = .int },
        .description = "Three-way compare; returns -1, 0, or 1 ordering two numbers or strings.",
    }));
}

fn lessThanOp(args: Args) ExecError!?Value {
    return helpers.numericComparison(args, cmpLtInt, cmpLtFloat);
}
fn cmpLtInt(left: i64, right: i64) bool {
    return left < right;
}
fn cmpLtFloat(left: f64, right: f64) bool {
    return left < right;
}

fn lessThanOrEqualOp(args: Args) ExecError!?Value {
    return helpers.numericComparison(args, cmpLeInt, cmpLeFloat);
}
fn cmpLeInt(left: i64, right: i64) bool {
    return left <= right;
}
fn cmpLeFloat(left: f64, right: f64) bool {
    return left <= right;
}

fn greaterThanOp(args: Args) ExecError!?Value {
    return helpers.numericComparison(args, cmpGtInt, cmpGtFloat);
}
fn cmpGtInt(left: i64, right: i64) bool {
    return left > right;
}
fn cmpGtFloat(left: f64, right: f64) bool {
    return left > right;
}

fn greaterThanOrEqualOp(args: Args) ExecError!?Value {
    return helpers.numericComparison(args, cmpGeInt, cmpGeFloat);
}
fn cmpGeInt(left: i64, right: i64) bool {
    return left >= right;
}
fn cmpGeFloat(left: f64, right: f64) bool {
    return left >= right;
}

fn isOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    const values = try args.getAll();
    const first = values[0];
    for (values[1..]) |other| {
        if (first == null and other == null) continue;
        if (first == null or other == null) return null;
        if (!(try first.?.eql(other.?, args.env.allocator))) return null;
    }
    return first orelse val.some();
}

fn isntOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const left = try args.at(0).get();
    const right = try args.at(1).get();

    if (left == null and right == null) return null;
    if (left != null and right != null and try left.?.eql(right.?, args.env.allocator)) return null;
    return left orelse val.some();
}

fn compareOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const left = try args.at(0).resolve();
    const right = try args.at(1).resolve();

    if (left.isNumber() and right.isNumber()) {
        const left_f = left.getF() catch unreachable;
        const right_f = right.getF() catch unreachable;
        const result: i64 = if (left_f < right_f) -1 else if (left_f > right_f) @as(i64, 1) else 0;
        return .{ .int = result };
    }

    if (left == .string and right == .string) {
        const order = std.mem.order(u8, left.string, right.string);
        const result: i64 = switch (order) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
        return .{ .int = result };
    }

    return null;
}


const testing = @import("testing.zig");

test "comparison: less than" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const truthy = try testing.evalWithBuiltins(arena.allocator(), "< 1 2");
    try std.testing.expect(truthy != null);
    const falsy = try testing.evalWithBuiltins(arena.allocator(), "< 2 1");
    try std.testing.expect(falsy == null);
}

test "comparison: chained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ascending = try testing.evalWithBuiltins(arena.allocator(), "< 1 2 3");
    try std.testing.expect(ascending != null);
    const not_ascending = try testing.evalWithBuiltins(arena.allocator(), "< 1 3 2");
    try std.testing.expect(not_ascending == null);
}

test "comparison: is and isnt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const equal = try testing.evalWithBuiltins(arena.allocator(), "is 5 5");
    try std.testing.expect(equal != null);
    const not_equal = try testing.evalWithBuiltins(arena.allocator(), "is 5 6");
    try std.testing.expect(not_equal == null);
    const different = try testing.evalWithBuiltins(arena.allocator(), "isnt 5 6");
    try std.testing.expect(different != null);
}

test "comparison: isnt returns left value when truthy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const left_int = try testing.evalWithBuiltins(arena.allocator(), "isnt 5 6");
    try std.testing.expectEqual(@as(i64, 5), left_int.?.int);
    const left_zero = try testing.evalWithBuiltins(arena.allocator(), "isnt 0 1");
    try std.testing.expectEqual(@as(i64, 0), left_zero.?.int);
    const equal = try testing.evalWithBuiltins(arena.allocator(), "isnt 5 5");
    try std.testing.expect(equal == null);
    const left_null = try testing.evalWithBuiltins(arena.allocator(), "isnt $none 5");
    try std.testing.expect(left_null != null);
}

test "comparison: compare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const less = try testing.evalWithBuiltins(arena.allocator(), "compare 1 2");
    try std.testing.expectEqual(@as(i64, -1), less.?.int);
    const greater = try testing.evalWithBuiltins(arena.allocator(), "compare 2 1");
    try std.testing.expectEqual(@as(i64, 1), greater.?.int);
    const equal = try testing.evalWithBuiltins(arena.allocator(), "compare 5 5");
    try std.testing.expectEqual(@as(i64, 0), equal.?.int);
}

test "comparison: compare incompatible types returns none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "compare 1 \"hello\"");
    try std.testing.expect(result == null);
}

test "comparison: is compares deeply nested values without native recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Chains this deep overflow the native stack if the compare recurses.
    const equal = try testing.evalWithBuiltins(arena.allocator(), "is (fold acc 0 x 50000 (list :acc)) (fold acc 0 x 50000 (list :acc))");
    try std.testing.expect(equal != null);

    const differs = try testing.evalWithBuiltins(arena.allocator(), "is (fold acc 0 x 50000 (list :acc)) (fold acc 1 x 50000 (list :acc))");
    try std.testing.expect(differs == null);
}

