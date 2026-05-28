const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;

// ── Resource bound checks ──

/// Fail if `n` exceeds env.bounds.max_list_length.
/// No-op when the bound is null (unlimited).
pub fn checkListLength(args: Args, n: usize) ExecError!void {
    if (args.env.bounds.max_list_length) |limit| {
        if (n > limit) {
            return args.env.failFmt("List length {d} exceeds limit {d}", .{ n, limit });
        }
    }
}

/// Fail if `n` (in bytes) exceeds env.bounds.max_string_length.
/// No-op when the bound is null (unlimited).
pub fn checkStringLength(args: Args, n: usize) ExecError!void {
    if (args.env.bounds.max_string_length) |limit| {
        if (n > limit) {
            return args.env.failFmt("String length {d} exceeds limit {d}", .{ n, limit });
        }
    }
}

// ── Numeric folds ──

pub fn numericFold(
    args: Args,
    int_op: *const fn (i64, i64) i64,
    float_op: *const fn (f64, f64) f64,
) ExecError!?Value {
    try args.expectMinCount(2);
    var accumulator = try args.at(0).resolve();
    if (!accumulator.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.fail("Expected a number");

        if (accumulator == .float or operand == .float) {
            const left  = accumulator.getF() catch unreachable;
            const right = operand.getF()     catch unreachable;
            accumulator = .{ .float = float_op(left, right) };
        } else {
            const left  = accumulator.getI() catch unreachable;
            const right = operand.getI()     catch unreachable;
            accumulator = .{ .int = int_op(left, right) };
        }
    }
    return accumulator;
}

pub fn numericComparison(
    args: Args,
    int_cmp: *const fn (i64, i64) bool,
    float_cmp: *const fn (f64, f64) bool,
) ExecError!?Value {
    try args.expectMinCount(2);
    var prev = try args.at(0).resolve();
    if (!prev.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const current = try args.at(i).resolve();
        if (!current.isNumber()) return args.env.fail("Expected a number");

        const passes = if (prev == .float or current == .float)
            float_cmp(prev.getF() catch unreachable, current.getF() catch unreachable)
        else
            int_cmp(prev.getI() catch unreachable, current.getI() catch unreachable);

        if (!passes) return null;
        prev = current;
    }
    return val.some();
}

// ── Natural ordering for sort ──

pub fn naturalLessThan(_: void, left: ?Value, right: ?Value) bool {
    if (left == null and right == null) return false;
    if (left == null) return true;
    if (right == null) return false;

    const lv = left.?;
    const rv = right.?;

    if (lv.isNumber() and rv.isNumber()) {
        const lf = lv.getF() catch unreachable;
        const rf = rv.getF() catch unreachable;
        return lf < rf;
    }

    if (lv == .string and rv == .string) {
        return std.mem.order(u8, lv.string, rv.string) == .lt;
    }

    // Mixed types: numbers < strings < lists
    const typeRank = struct {
        fn rank(v: Value) u8 {
            return switch (v) {
                .int, .float => 0,
                .string => 1,
                .list => 2,
            };
        }
    };
    return typeRank.rank(lv) < typeRank.rank(rv);
}
