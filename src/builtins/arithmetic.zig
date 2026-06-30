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
const BITWISE_NOT_ID = "~";

const number_fold = [_]Param{ .{ .name = "a", .type = .number }, .{ .name = "b", .type = .number, .arity = .variadic } };
const int_fold = [_]Param{ .{ .name = "a", .type = .int }, .{ .name = "b", .type = .int, .arity = .variadic } };
const shift = [_]Param{ .{ .name = "base", .type = .int }, .{ .name = "dist", .type = .int, .arity = .variadic } };

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "arithmetic");
    try g.register("+", Operation.fromFn(addOp, .{
        .signature = .{ .params = &number_fold, .returns = .number },
        .description = "Sum all arguments.",
    }));

    try g.register("-", Operation.fromFn(subtractOp, .{
        .signature = .{ .params = &number_fold, .returns = .number },
        .description = "Subtract the remaining arguments from the first.",
    }));

    try g.register("*", Operation.fromFn(multiplyOp, .{
        .signature = .{ .params = &number_fold, .returns = .number },
        .description = "Multiply all arguments.",
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
        .description = "Raise the first argument to each subsequent power, left to right.",
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
    return left +% right;
}

fn addFloat(left: f64, right: f64) f64 {
    return left + right;
}

fn subtractOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, subInt, subFloat);
}

fn subInt(left: i64, right: i64) i64 {
    return left -% right;
}

fn subFloat(left: f64, right: f64) f64 {
    return left - right;
}

fn multiplyOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, mulInt, mulFloat);
}

fn mulInt(left: i64, right: i64) i64 {
    return left *% right;
}

fn mulFloat(left: f64, right: f64) f64 {
    return left * right;
}

fn divideOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, divInt, divFloat);
}

fn divInt(left: i64, right: i64) i64 {
    return if (right == 0) 0 else @divTrunc(left, right);
}

fn divFloat(left: f64, right: f64) f64 {
    return left / right;
}

fn moduloOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, modInt, modFloat);
}

fn modInt(left: i64, right: i64) i64 {
    return if (right == 0) 0 else @mod(left, right);
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
            const base: f64 = @floatFromInt(accumulator.getI() catch unreachable);
            const exponent: f64 = @floatFromInt(operand.getI() catch unreachable);
            accumulator = .{ .int = @intFromFloat(std.math.pow(f64, base, exponent)) };
        }
    }

    return accumulator;
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
    if (dist < 0) return shrInt(base, -dist);
    return std.math.shl(i64, base, @as(u64, @intCast(dist)));
}

fn shrInt(base: i64, dist: i64) i64 {
    if (dist < 0) return shlInt(base, -dist);
    return std.math.shr(i64, base, @as(u64, @intCast(dist)));
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

// Bitwise `|` and `~` are not exercised here: they are unreachable in body
// position until the Track O header/body lexer mode lands (they still lex as
// the macro separator / deferred marker). Their evaluation is covered once that
// mode exists; AND/XOR/shift use ordinary operator chars and work now.

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

