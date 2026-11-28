const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");

const Value = val.Value;
const Number = val.Number;
const Args = exec.Args;
const Env = exec.Env;
const ExecError = exec.ExecError;

pub fn getString(env: *Env, op_name: []const u8, value: Value, buf: []u8) ExecError![]const u8 {
    if (value == .list) {
        return value.sourceText(env.allocator, env.bounds.max_string_length) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StringTooLarge => env.failFmt(.string_too_large, "'{s}': list text longer than max_string_length ({?d})", .{ op_name, env.bounds.max_string_length }),
        };
    }
    return value.getS(buf) catch env.failFmt(.out_of_space, "'{s}': a {s} does not fit in the {d}-byte string buffer", .{ op_name, value.typeName(), buf.len });
}

pub fn checkListLength(env: *Env, n: usize) ExecError!void {
    if (env.bounds.max_list_length) |limit| {
        if (n > limit) {
            return env.failFmt(.invalid_argument, "List length {d} exceeds limit {d}", .{ n, limit });
        }
    }
}

pub fn lettersOf(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]?Value {
    const letters = try allocator.alloc(?Value, text.len);
    for (letters, 0..) |*letter, i| {
        letter.* = .{ .string = try allocator.dupe(u8, text[i .. i + 1]) };
    }
    return letters;
}

pub fn checkStringLength(env: *Env, n: usize) ExecError!void {
    if (env.bounds.max_string_length) |limit| {
        if (n > limit) {
            return env.failFmt(.invalid_argument, "String length {d} exceeds limit {d}", .{ n, limit });
        }
    }
}

pub fn numericFold(
    args: Args,
    int_op: *const fn (i64, i64) i64,
    float_op: *const fn (f64, f64) f64,
) ExecError!?Value {
    try args.expectMinCount(2);
    const first = try args.at(0).resolve();
    var accumulator = first.asNumber() orelse return args.env.failFmt(.type_mismatch, "Expected a number, got {s}", .{first.typeName()});

    for (1..args.count()) |i| {
        const value = try args.at(i).resolve();
        const operand = value.asNumber() orelse return args.env.failFmt(.type_mismatch, "Expected a number, got {s}", .{value.typeName()});

        accumulator = switch (Number.pair(accumulator, operand)) {
            .ints   => |both| .{ .int = int_op(both.left, both.right) },
            .floats => |both| .{ .float = float_op(both.left, both.right) },
        };
    }
    return accumulator.toValue();
}

pub fn intFold(
    args: Args,
    int_op: *const fn (i64, i64) i64,
) ExecError!?Value {
    try args.expectMinCount(2);
    var accumulator = try args.at(0).resolve();
    if (accumulator != .int) return args.env.failFmt(.type_mismatch, "Expected an integer, got {s}", .{accumulator.typeName()});

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (operand != .int) return args.env.failFmt(.type_mismatch, "Expected an integer, got {s}", .{operand.typeName()});
        accumulator = .{ .int = int_op(accumulator.int, operand.int) };
    }
    return accumulator;
}

pub fn checkedIntFold(
    args: Args,
    int_op: *const fn (i64, i64) ?i64,
) ExecError!?Value {
    try args.expectMinCount(2);
    var accumulator = try args.at(0).resolve();
    if (accumulator != .int) return args.env.failFmt(.type_mismatch, "Expected an integer, got {s}", .{accumulator.typeName()});

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (operand != .int) return args.env.failFmt(.type_mismatch, "Expected an integer, got {s}", .{operand.typeName()});
        accumulator = .{ .int = int_op(accumulator.int, operand.int) orelse return null };
    }
    return accumulator;
}

pub fn numericComparison(
    args: Args,
    int_cmp: *const fn (i64, i64) bool,
    float_cmp: *const fn (f64, f64) bool,
) ExecError!?Value {
    try args.expectMinCount(2);
    const first = try args.at(0).resolve();
    var previous = first.asNumber() orelse return args.env.failFmt(.type_mismatch, "Expected a number, got {s}", .{first.typeName()});

    for (1..args.count()) |i| {
        const value = try args.at(i).resolve();
        const current = value.asNumber() orelse return args.env.failFmt(.type_mismatch, "Expected a number, got {s}", .{value.typeName()});

        const passes = switch (Number.pair(previous, current)) {
            .ints   => |both| int_cmp(both.left, both.right),
            .floats => |both| float_cmp(both.left, both.right),
        };

        if (!passes) return null;
        previous = current;
    }
    return val.some();
}

pub fn naturalLessThan(_: void, left: ?Value, right: ?Value) bool {
    const left_value = left orelse return right != null;
    const right_value = right orelse return false;

    if (Number.pairValues(left_value, right_value)) |both| return switch (both) {
        inline else => |numbers| numbers.left < numbers.right,
    };

    if (left_value == .string and right_value == .string) {
        return std.mem.order(u8, left_value.string, right_value.string) == .lt;
    }

    return typeRank(left_value) < typeRank(right_value);
}

fn typeRank(value: Value) u8 {
    return switch (value) {
        .int, .float => 0,
        .string      => 1,
        .list        => 2,
    };
}
