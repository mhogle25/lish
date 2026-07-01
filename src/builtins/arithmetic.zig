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

const POWER_ID = "**";
const POWER_WRAP_ID = POWER_ID ++ "%";
const POWER_CHECKED_ID = POWER_ID ++ "?";
const BITWISE_NOT_ID = "~";

const number_fold = [_]Param{ .{ .name = "a", .type = .number }, .{ .name = "b", .type = .number, .arity = .variadic } };
const int_fold = [_]Param{ .{ .name = "a", .type = .int }, .{ .name = "b", .type = .int, .arity = .variadic } };
const shift = [_]Param{ .{ .name = "base", .type = .int }, .{ .name = "dist", .type = .int, .arity = .variadic } };

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "arithmetic");
    try g.register("+", Operation.fromFn(addOp, .{
        .signature = .{ .params = &number_fold, .returns = .number },
        .description = "Sum all arguments; integer overflow saturates to the 64-bit bounds.",
    }));

    try g.register("-", Operation.fromFn(subtractOp, .{
        .signature = .{ .params = &number_fold, .returns = .number },
        .description = "Subtract the remaining arguments from the first; integer overflow saturates.",
    }));

    try g.register("*", Operation.fromFn(multiplyOp, .{
        .signature = .{ .params = &number_fold, .returns = .number },
        .description = "Multiply all arguments; integer overflow saturates to the 64-bit bounds.",
    }));

    try g.register("/", Operation.fromFn(divideOp, .{
        .signature = .{ .params = &number_fold, .returns = .number },
        .description = "Divide the first argument by the rest; integer division truncates and division by zero yields 0.",
    }));

    try g.register("%", Operation.fromFn(moduloOp, .{
        .signature = .{ .params = &number_fold, .returns = .number },
        .description = "Modulo of the first argument by the rest; modulo by zero yields 0.",
    }));

    try g.register(POWER_ID, Operation.fromFn(powerOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "base", .type = .number }, Param{ .name = "exp", .type = .number, .arity = .variadic } }, .returns = .number },
        .description = "Raise the first argument to each subsequent power, left to right; integer overflow saturates.",
    }));

    // Overflow-explicit integer variants of `+ - * **`. The bare ops saturate on
    // overflow; these opt into wraparound (modular) or a $none-on-overflow check.
    try g.register("+%", Operation.fromFn(addWrapOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Add integers with wraparound (modular) on overflow.",
    }));

    try g.register("-%", Operation.fromFn(subtractWrapOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Subtract integers with wraparound (modular) on overflow.",
    }));

    try g.register("*%", Operation.fromFn(multiplyWrapOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Multiply integers with wraparound (modular) on overflow.",
    }));

    try g.register(POWER_WRAP_ID, Operation.fromFn(powerWrapOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Raise integers to each power with wraparound (modular) on overflow.",
    }));

    try g.register("+?", Operation.fromFn(addCheckedOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Add integers, yielding $none on overflow instead of a wrong result.",
    }));

    try g.register("-?", Operation.fromFn(subtractCheckedOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Subtract integers, yielding $none on overflow instead of a wrong result.",
    }));

    try g.register("*?", Operation.fromFn(multiplyCheckedOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Multiply integers, yielding $none on overflow instead of a wrong result.",
    }));

    try g.register(POWER_CHECKED_ID, Operation.fromFn(powerCheckedOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Raise integers to each power, yielding $none on overflow instead of a wrong result.",
    }));

    try g.register("&", Operation.fromFn(bitwiseAndOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Bitwise AND all integers.",
    }));

    try g.register("|", Operation.fromFn(bitwiseOrOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Bitwise OR all integers.",
    }));

    try g.register("^", Operation.fromFn(bitwiseXorOp, .{
        .signature = .{ .params = &int_fold, .returns = .int },
        .description = "Bitwise XOR all integers.",
    }));

    try g.register(BITWISE_NOT_ID, Operation.fromFn(bitwiseNotOp, .{
        .signature = .{ .params = comptime &.{Param{ .name = "a", .type = .int }}, .returns = .int },
        .description = "Bitwise NOT an integer.",
    }));

    try g.register("<<", Operation.fromFn(shiftLeftOp, .{
        .signature = .{ .params = &shift, .returns = .int },
        .description = "Shift an integer's bits left by any integral amount; each amount after the first further shifts the integer.",
    }));

    try g.register(">>", Operation.fromFn(shiftRightOp, .{
        .signature = .{ .params = &shift, .returns = .int },
        .description = "Shift an integer's bits right by any integral amount; each amount after the first further shifts the integer.",
    }));
}

fn addOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, addInt, addFloat);
}

fn addInt(left: i64, right: i64) i64 {
    return left +| right;
}

fn addFloat(left: f64, right: f64) f64 {
    return left + right;
}

fn addWrapOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, addWrapInt);
}

fn addWrapInt(left: i64, right: i64) i64 {
    return left +% right;
}

fn addCheckedOp(args: Args) ExecError!?Value {
    return helpers.checkedIntFold(args, addCheckedInt);
}

fn addCheckedInt(left: i64, right: i64) ?i64 {
    return std.math.add(i64, left, right) catch null;
}

fn subtractOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, subInt, subFloat);
}

fn subInt(left: i64, right: i64) i64 {
    return left -| right;
}

fn subFloat(left: f64, right: f64) f64 {
    return left - right;
}

fn subtractWrapOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, subWrapInt);
}

fn subWrapInt(left: i64, right: i64) i64 {
    return left -% right;
}

fn subtractCheckedOp(args: Args) ExecError!?Value {
    return helpers.checkedIntFold(args, subCheckedInt);
}

fn subCheckedInt(left: i64, right: i64) ?i64 {
    return std.math.sub(i64, left, right) catch null;
}

fn multiplyOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, mulInt, mulFloat);
}

fn mulInt(left: i64, right: i64) i64 {
    return left *| right;
}

fn mulFloat(left: f64, right: f64) f64 {
    return left * right;
}

fn multiplyWrapOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, mulWrapInt);
}

fn mulWrapInt(left: i64, right: i64) i64 {
    return left *% right;
}

fn multiplyCheckedOp(args: Args) ExecError!?Value {
    return helpers.checkedIntFold(args, mulCheckedInt);
}

fn mulCheckedInt(left: i64, right: i64) ?i64 {
    return std.math.mul(i64, left, right) catch null;
}

fn divideOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, divInt, divFloat);
}

fn divInt(left: i64, right: i64) i64 {
    if (right == 0) return 0;
    // minInt / -1 is the one overflowing division (+2^63 doesn't fit); saturate it.
    if (left == std.math.minInt(i64) and right == -1) return std.math.maxInt(i64);
    return @divTrunc(left, right);
}

fn divFloat(left: f64, right: f64) f64 {
    return left / right;
}

fn moduloOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, modInt, modFloat);
}

fn modInt(left: i64, right: i64) i64 {
    if (right == 0) return 0;
    // x mod 1 or -1 is always 0; guarding -1 also avoids the minInt/-1 divide overflow.
    if (right == -1) return 0;
    return @mod(left, right);
}

fn modFloat(left: f64, right: f64) f64 {
    return @mod(left, right);
}

fn powerOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var accumulator = try args.at(0).resolve();
    if (!accumulator.isNumber()) return args.env.failFmt(.type_mismatch, "'{s}' expects numbers, got {s}", .{ POWER_ID, accumulator.typeName() });

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.failFmt(.type_mismatch, "'{s}' expects numbers, got {s}", .{ POWER_ID, operand.typeName() });

        if (accumulator == .float or operand == .float) {
            const base = accumulator.getF() catch unreachable;
            const exponent = operand.getF() catch unreachable;
            accumulator = .{ .float = std.math.pow(f64, base, exponent) };
        } else {
            accumulator = .{ .int = intPowSat(accumulator.int, operand.int) };
        }
    }

    return accumulator;
}

fn powerWrapOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, intPowWrap);
}

fn powerCheckedOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var accumulator = try args.at(0).resolve();
    if (accumulator != .int) return args.env.failFmt(.type_mismatch, "'{s}' expects integers, got {s}", .{ POWER_CHECKED_ID, accumulator.typeName() });

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (operand != .int) return args.env.failFmt(.type_mismatch, "'{s}' expects integers, got {s}", .{ POWER_CHECKED_ID, operand.typeName() });
        accumulator = .{ .int = intPowChecked(accumulator.int, operand.int) orelse return null };
    }

    return accumulator;
}

// Negative exponent: |base^exp| < 1 for |base| > 1, so it truncates to 0 (like `/`);
// base 1/-1 are their own reciprocals. Shared by all integer power paths.
fn intPowNegExp(base: i64, exp: i64) i64 {
    return switch (base) {
        1 => 1,
        -1 => if (@mod(exp, 2) == 0) 1 else -1,
        else => 0,
    };
}

// Exact integer exponentiation by squaring; null on i64 overflow. The direct i64
// multiply avoids the f64 round-trip, which loses precision past 2^53 and traps.
fn intPowChecked(base: i64, exp: i64) ?i64 {
    if (exp < 0) return intPowNegExp(base, exp);

    var result: i64 = 1;
    var b = base;
    var e = exp;

    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result = std.math.mul(i64, result, b) catch return null;
        if (e > 1) b = std.math.mul(i64, b, b) catch return null;
    }

    return result;
}

// On overflow, pin to the i64 bound matching the result's sign.
fn intPowSat(base: i64, exp: i64) i64 {
    return intPowChecked(base, exp) orelse
        if (base < 0 and @mod(exp, 2) != 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

// Exponentiation modulo 2^64 (wraps), mirroring `*%`; not arbitrary `a^b mod m`.
fn intPowWrap(base: i64, exp: i64) i64 {
    if (exp < 0) return intPowNegExp(base, exp);

    var result: i64 = 1;
    var b = base;
    var e = exp;

    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result *%= b;
        if (e > 1) b *%= b;
    }

    return result;
}

fn bitwiseAndOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, andInt);
}

fn andInt(left: i64, right: i64) i64 {
    return left & right;
}

fn bitwiseOrOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, orInt);
}

fn orInt(left: i64, right: i64) i64 {
    return left | right;
}

fn bitwiseXorOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, xorInt);
}

fn xorInt(left: i64, right: i64) i64 {
    return left ^ right;
}

fn bitwiseNotOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const operand = try args.at(0).resolve();
    if (operand != .int) return args.env.failFmt(.type_mismatch, "'{s}' expects an integer, got {s}", .{ BITWISE_NOT_ID, operand.typeName() });
    return Value{ .int = ~operand.int };
}

fn shiftLeftOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, shlInt);
}

fn shiftRightOp(args: Args) ExecError!?Value {
    return helpers.intFold(args, shrInt);
}

// A negative distance shifts the opposite direction (symmetric); a distance at
// or beyond the bit width saturates to 0 (via std.math.shl/shr).
fn shlInt(base: i64, dist: i64) i64 {
    if (dist < 0) return std.math.shr(i64, base, shiftAmount(dist));
    return std.math.shl(i64, base, shiftAmount(dist));
}

fn shrInt(base: i64, dist: i64) i64 {
    if (dist < 0) return std.math.shl(i64, base, shiftAmount(dist));
    return std.math.shr(i64, base, shiftAmount(dist));
}

// |dist| as u64; `-dist` would overflow on minInt, so negate in the u64 domain.
fn shiftAmount(dist: i64) u64 {
    const bits: u64 = @bitCast(dist);
    return if (dist < 0) ~bits +% 1 else bits;
}


const testing = @import("testing.zig");

test "arithmetic: add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "+ 1 2 3");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "arithmetic: subtract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "- 10 3");
    try std.testing.expectEqual(@as(i64, 7), result.?.int);
}

test "arithmetic: multiply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "* 4 5");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "arithmetic: divide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "/ 10 3");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "arithmetic: float promotion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "+ 1 2.5");
    try std.testing.expectEqual(@as(f64, 3.5), result.?.float);
}

test "arithmetic: power" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "** 2 10");
    try std.testing.expectEqual(@as(i64, 1024), result.?.int);
}

test "arithmetic: power computes exact large integers (no f64 precision loss)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 15^15 = 437893890380859375; the old f64 round-trip returned ...859392.
    const result = try testing.evalWithBuiltins(arena.allocator(), "** 15 15");
    try std.testing.expectEqual(@as(i64, 437893890380859375), result.?.int);
}

test "arithmetic: power overflow saturates to i64 max instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 16^16 exceeds the i64 range; the default `**` pins to maxInt (no crash, no wrap).
    const result = try testing.evalWithBuiltins(arena.allocator(), "** 16 16");
    try std.testing.expectEqual(std.math.maxInt(i64), result.?.int);
}

test "arithmetic: power saturates to i64 min for a negative overflowing result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // (-10)^19 overflows negative (base < 0, odd exponent) -> pins to minInt.
    const result = try testing.evalWithBuiltins(arena.allocator(), "** -10 19");
    try std.testing.expectEqual(std.math.minInt(i64), result.?.int);
}

test "arithmetic: power negative exponent truncates toward zero (integer path)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const zero = try testing.evalWithBuiltins(arena.allocator(), "** 2 -1");
    try std.testing.expectEqual(@as(i64, 0), zero.?.int);
    const one = try testing.evalWithBuiltins(arena.allocator(), "** 1 -5");
    try std.testing.expectEqual(@as(i64, 1), one.?.int);
    const neg = try testing.evalWithBuiltins(arena.allocator(), "** -1 -3");
    try std.testing.expectEqual(@as(i64, -1), neg.?.int);
}

test "arithmetic: power of zero to a negative exponent is lenient zero, not a crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Old code: pow(0, -1) -> inf -> @intFromFloat trap. Now: lenient 0.
    const result = try testing.evalWithBuiltins(arena.allocator(), "** 0 -1");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "arithmetic: float power still uses floating point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "** 2.0 10");
    try std.testing.expectEqual(@as(f64, 1024.0), result.?.float);
}

test "arithmetic: default add/subtract saturate at the i64 bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const hi = try testing.evalWithBuiltins(arena.allocator(), "+ 9223372036854775807 1");
    try std.testing.expectEqual(std.math.maxInt(i64), hi.?.int);
    // Nuclear-Gandhi underflow: pinned at minInt, not wrapped to a huge positive.
    const lo = try testing.evalWithBuiltins(arena.allocator(), "- -9223372036854775808 1");
    try std.testing.expectEqual(std.math.minInt(i64), lo.?.int);
}

test "arithmetic: default multiply saturates toward the true result's sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "* 5000000000 -5000000000");
    try std.testing.expectEqual(std.math.minInt(i64), result.?.int);
}

test "arithmetic: wrapping ops wrap around instead of saturating" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // maxInt +% 1 wraps to minInt; contrast with the saturating `+`.
    const result = try testing.evalWithBuiltins(arena.allocator(), "+% 9223372036854775807 1");
    try std.testing.expectEqual(std.math.minInt(i64), result.?.int);
}

test "arithmetic: wrapping ops fold variadically and stay int-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const folded = try testing.evalWithBuiltins(arena.allocator(), "*% 2 3 4");
    try std.testing.expectEqual(@as(i64, 24), folded.?.int);
    try std.testing.expectError(error.RuntimeError, testing.evalWithBuiltins(arena.allocator(), "+% 1 1.5"));
}

test "arithmetic: checked ops return the value, or $none on overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ok = try testing.evalWithBuiltins(arena.allocator(), "+? 1 2");
    try std.testing.expectEqual(@as(i64, 3), ok.?.int);
    const overflow = try testing.evalWithBuiltins(arena.allocator(), "*? 5000000000 5000000000");
    try std.testing.expect(overflow == null);
}

test "arithmetic: checked overflow composes with or (panic derivable the same way)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "or (+? 9223372036854775807 1) -1");
    try std.testing.expectEqual(@as(i64, -1), result.?.int);
}

test "arithmetic: checked power returns the value, or $none on overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ok = try testing.evalWithBuiltins(arena.allocator(), "**? 2 10");
    try std.testing.expectEqual(@as(i64, 1024), ok.?.int);
    const overflow = try testing.evalWithBuiltins(arena.allocator(), "**? 16 16");
    try std.testing.expect(overflow == null);
}

test "arithmetic: wrapping power multiplies modulo 2^64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // In range: exact (2^10 = 1024).
    const small = try testing.evalWithBuiltins(arena.allocator(), "**% 2 10");
    try std.testing.expectEqual(@as(i64, 1024), small.?.int);
    // 2^64 wraps to 0 (mod 2^64); the saturating `**` would pin to maxInt instead.
    const wrapped = try testing.evalWithBuiltins(arena.allocator(), "**% 2 64");
    try std.testing.expectEqual(@as(i64, 0), wrapped.?.int);
}

test "arithmetic: minInt divided or modded by -1 does not trap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const divided = try testing.evalWithBuiltins(arena.allocator(), "/ -9223372036854775808 -1");
    try std.testing.expectEqual(std.math.maxInt(i64), divided.?.int);
    const modded = try testing.evalWithBuiltins(arena.allocator(), "% -9223372036854775808 -1");
    try std.testing.expectEqual(@as(i64, 0), modded.?.int);
}

test "bitwise: or (reachable as a body operator post Track O)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 1100 | 1010 = 1110
    const result = try testing.evalWithBuiltins(arena.allocator(), "| 12 10");
    try std.testing.expectEqual(@as(i64, 14), result.?.int);
}

test "bitwise: not (reachable as a body operator post Track O)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ~5 = -6 in two's complement.
    const result = try testing.evalWithBuiltins(arena.allocator(), "~ 5");
    try std.testing.expectEqual(@as(i64, -6), result.?.int);
}

test "bitwise: and" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "& 12 10");
    try std.testing.expectEqual(@as(i64, 8), result.?.int);
}

test "bitwise: and folds variadically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 14 & 12 & 10 = 1110 & 1100 & 1010 = 1000
    const result = try testing.evalWithBuiltins(arena.allocator(), "& 14 12 10");
    try std.testing.expectEqual(@as(i64, 8), result.?.int);
}

test "bitwise: xor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "^ 6 3");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "bitwise: xor folds variadically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "^ 6 3 5");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "bitwise: shift left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "<< 1 4");
    try std.testing.expectEqual(@as(i64, 16), result.?.int);
}

test "bitwise: shift left chains each distance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ((1 << 2) << 3) = 4 << 3 = 32
    const result = try testing.evalWithBuiltins(arena.allocator(), "<< 1 2 3");
    try std.testing.expectEqual(@as(i64, 32), result.?.int);
}

test "bitwise: shift right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), ">> 256 2");
    try std.testing.expectEqual(@as(i64, 64), result.?.int);
}

test "bitwise: shift right chains each distance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ((1024 >> 2) >> 3) = 256 >> 3 = 32
    const result = try testing.evalWithBuiltins(arena.allocator(), ">> 1024 2 3");
    try std.testing.expectEqual(@as(i64, 32), result.?.int);
}

test "bitwise: negative shift reverses direction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "<< 64 -2");
    try std.testing.expectEqual(@as(i64, 16), result.?.int);
}

test "bitwise: type mismatch on non-integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.RuntimeError, testing.evalWithBuiltins(arena.allocator(), "& 12 1.5"));
}

