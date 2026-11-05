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

const ab_variadic = [_]Param{ .{ .name = "a", .type = .number }, .{ .name = "b", .type = .number, .arity = .variadic } };
const x_param = [_]Param{.{ .name = "x", .type = .number }};
const n_param = [_]Param{.{ .name = "n", .type = .int }};

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "math");
    try g.register("min", Operation.fromFn(minOp, .{
        .signature = .{ .params = &ab_variadic, .returns = .number },
        .description = "Smallest of the arguments.",
    }));

    try g.register("max", Operation.fromFn(maxOp, .{
        .signature = .{ .params = &ab_variadic, .returns = .number },
        .description = "Largest of the arguments.",
    }));

    try g.register("abs", Operation.fromFn(absOp, .{
        .signature = .{ .params = &x_param, .returns = .number },
        .description = "Absolute value.",
    }));

    try g.register("floor", Operation.fromFn(floorOp, .{
        .signature = .{ .params = &x_param, .returns = .int },
        .description = "Round down to the nearest integer.",
    }));

    try g.register("ceil", Operation.fromFn(ceilOp, .{
        .signature = .{ .params = &x_param, .returns = .int },
        .description = "Round up to the nearest integer.",
    }));

    try g.register("round", Operation.fromFn(roundOp, .{
        .signature = .{ .params = &x_param, .returns = .int },
        .description = "Round to the nearest integer.",
    }));

    try g.register("even", Operation.fromFn(evenOp, .{
        .signature = .{ .params = &n_param, .returns = .{ .one_of = &.{ .some, .none } } },
        .description = "True when the integer is even.",
    }));

    try g.register("odd", Operation.fromFn(oddOp, .{
        .signature = .{ .params = &n_param, .returns = .{ .one_of = &.{ .some, .none } } },
        .description = "True when the integer is odd.",
    }));

    try g.register("sqrt", Operation.fromFn(sqrtOp, .{
        .signature = .{ .params = &x_param, .returns = .float },
        .description = "Square root.",
    }));

    try g.register("sin", Operation.fromFn(sinOp, .{
        .signature = .{ .params = &x_param, .returns = .float },
        .description = "Sine of an angle in radians.",
    }));

    try g.register("cos", Operation.fromFn(cosOp, .{
        .signature = .{ .params = &x_param, .returns = .float },
        .description = "Cosine of an angle in radians.",
    }));

    try g.register("atan2", Operation.fromFn(atan2Op, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "y", .type = .number }, Param{ .name = "x", .type = .number } }, .returns = .float },
        .description = "Arctangent of y/x, using the signs of both to choose the quadrant.",
    }));

    try g.register("log", Operation.fromFn(logOp, .{
        .signature = .{ .params = &x_param, .returns = .float },
        .description = "Natural logarithm.",
    }));

    try g.register("exp", Operation.fromFn(expOp, .{
        .signature = .{ .params = &x_param, .returns = .float },
        .description = "e raised to the given power.",
    }));
}

fn minOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = try args.at(0).resolve();
    if (!result.isNumber()) return args.env.failFmt(.type_mismatch, "'min' expects numbers, got {s}", .{result.typeName()});

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.failFmt(.type_mismatch, "'min' expects numbers, got {s}", .{operand.typeName()});

        if (result == .float or operand == .float) {
            const left = result.getF() catch unreachable;
            const right = operand.getF() catch unreachable;
            result = .{ .float = @min(left, right) };
        } else {
            const left = result.getI() catch unreachable;
            const right = operand.getI() catch unreachable;
            result = .{ .int = @min(left, right) };
        }
    }
    return result;
}

fn maxOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = try args.at(0).resolve();
    if (!result.isNumber()) return args.env.failFmt(.type_mismatch, "'max' expects numbers, got {s}", .{result.typeName()});

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.failFmt(.type_mismatch, "'max' expects numbers, got {s}", .{operand.typeName()});

        if (result == .float or operand == .float) {
            const left = result.getF() catch unreachable;
            const right = operand.getF() catch unreachable;
            result = .{ .float = @max(left, right) };
        } else {
            const left = result.getI() catch unreachable;
            const right = operand.getI() catch unreachable;
            result = .{ .int = @max(left, right) };
        }
    }
    return result;
}

fn absOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => |int_val| .{ .int = if (int_val == std.math.minInt(i64)) std.math.maxInt(i64) else if (int_val < 0) -int_val else int_val },
        .float => |float_val| .{ .float = @abs(float_val) },
        else => args.env.failFmt(.type_mismatch, "'abs' expects a number, got {s}", .{value.typeName()}),
    };
}

fn floorOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = val.floatToInt(@floor(float_val)) },
        else => args.env.failFmt(.type_mismatch, "'floor' expects a number, got {s}", .{value.typeName()}),
    };
}

fn ceilOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = val.floatToInt(@ceil(float_val)) },
        else => args.env.failFmt(.type_mismatch, "'ceil' expects a number, got {s}", .{value.typeName()}),
    };
}

fn roundOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = val.floatToInt(@round(float_val)) },
        else => args.env.failFmt(.type_mismatch, "'round' expects a number, got {s}", .{value.typeName()}),
    };
}

fn evenOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    const n = value.getI() catch return args.env.failFmt(.type_mismatch, "'even' expects an integer, got {s}", .{value.typeName()});
    return val.toCondition(@mod(n, 2) == 0);
}

fn oddOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    const n = value.getI() catch return args.env.failFmt(.type_mismatch, "'odd' expects an integer, got {s}", .{value.typeName()});
    return val.toCondition(@mod(n, 2) != 0);
}

fn sqrtOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @sqrt(x) };
}

fn sinOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @sin(x) };
}

fn cosOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @cos(x) };
}

fn atan2Op(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const y = try args.at(0).resolveFloat();
    const x = try args.at(1).resolveFloat();
    return .{ .float = std.math.atan2(y, x) };
}

fn logOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @log(x) };
}

fn expOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @exp(x) };
}

const testing = @import("testing.zig");

test "math: min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "min 3 1 2");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "math: min float promotion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "min 3 1.5 2");
    try std.testing.expectEqual(@as(f64, 1.5), result.?.float);
}

test "math: max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "max 3 1 2");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "math: abs positive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "abs 5");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: abs negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "abs (- 0 5)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: abs float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "abs -3.5");
    try std.testing.expectEqual(@as(f64, 3.5), result.?.float);
}

test "math: floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "floor 3.7");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "math: floor int identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "floor 5");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: ceil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "ceil 3.2");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "math: round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "round 3.5");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "math: round down" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "round 3.4");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "math: abs of i64 min saturates to i64 max instead of wrapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "abs -9223372036854775808");
    try std.testing.expectEqual(std.math.maxInt(i64), result.?.int);
}

test "math: floor/ceil/round saturate on a non-finite float instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const floored = try testing.evalWithBuiltins(arena.allocator(), "floor (/ 1.0 0.0)");
    try std.testing.expectEqual(std.math.maxInt(i64), floored.?.int);
    const nan_rounded = try testing.evalWithBuiltins(arena.allocator(), "round (/ 0.0 0.0)");
    try std.testing.expectEqual(@as(i64, 0), nan_rounded.?.int);
}

test "math: even true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "even 4");
    try std.testing.expect(result != null);
}

test "math: even false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "even 3");
    try std.testing.expect(result == null);
}

test "math: even negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "even (- 0 4)");
    try std.testing.expect(result != null);
}

test "math: odd true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "odd 3");
    try std.testing.expect(result != null);
}

test "math: odd false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "odd 4");
    try std.testing.expect(result == null);
}

test "math: sqrt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sqrt 9");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.?.float, 1e-12);
}

test "math: sin of zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sin 0");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?.float, 1e-12);
}

test "math: cos of zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "cos 0");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.?.float, 1e-12);
}

test "math: sin of pi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sin (pi)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?.float, 1e-12);
}

test "math: atan2 quadrants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "atan2 1 0");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 2.0), result.?.float, 1e-12);
}

test "math: log natural" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "log 1");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?.float, 1e-12);
}

test "math: exp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "exp 0");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.?.float, 1e-12);
}

test "math: exp/log inverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "log (exp 2.5)");
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), result.?.float, 1e-12);
}
