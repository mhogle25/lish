const std = @import("std");
const exec = @import("exec.zig");
const val = @import("value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Param = exec.Param;
const Allocator = std.mem.Allocator;

const x_y = [_]Param{ .{ .name = "x", .type = .number }, .{ .name = "y", .type = .number } };

pub fn registerAll(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "random");
    try g.register("?", Operation.fromFn(randInclusiveOp, .{
        .signature = .{ .params = &x_y, .returns = .number },
        .description = "Random number in the inclusive range [x, y].",
    }));

    try g.register("?<", Operation.fromFn(randExclusiveOp, .{
        .signature = .{ .params = &x_y, .returns = .number },
        .description = "Random number in the upper-exclusive range [x, y).",
    }));

    try g.register("??", Operation.fromFn(randPickOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "a" }, Param{ .name = "b", .arity = .variadic } }, .returns = .any },
        .description = "Pick one argument at random; only the chosen argument is evaluated.",
    }));
}

// Each op pulls bytes from io and converts to the needed type.

fn randomU64(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

fn randomF64(io: std.Io) f64 {
    // Use the top 53 bits of a u64 to get a uniform float in [0, 1).
    const bits = randomU64(io) >> 11;
    return @as(f64, @floatFromInt(bits)) * (1.0 / @as(f64, @floatFromInt(@as(u64, 1) << 53)));
}

fn randomIntRangeAtMost(io: std.Io, comptime T: type, at_least: T, at_most: T) T {
    // `at_most - at_least` overflows for a signed span wider than i64 max, so work
    // in the unsigned domain: bit-cast and subtract (exact since at_most >= at_least).
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    const lo: U = @bitCast(at_least);
    const span: U = @as(U, @bitCast(at_most)) -% lo;

    const range = @as(u64, span) +| 1; // inclusive count; saturates for the full 2^64 range
    const r: U = @intCast(randomU64(io) % range);

    return @bitCast(lo +% r);
}

fn randomIntRangeLessThan(io: std.Io, comptime T: type, at_least: T, less_than: T) T {
    return randomIntRangeAtMost(io, T, at_least, less_than - 1);
}

fn requireIo(args: Args) ExecError!std.Io {
    return args.env.io orelse args.env.fail(.internal, "random ops require an Io context");
}


/// `? x y`, random value in [x, y] (both inclusive).
/// For integers, both endpoints are reachable.
/// For floats, [x, y) is used internally; hitting exactly y is not representable.
fn randInclusiveOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const x = try args.at(0).resolve();
    const y = try args.at(1).resolve();
    if (!x.isNumber()) return args.env.failFmt(.type_mismatch, "'?' expects numbers, got {s}", .{x.typeName()});
    if (!y.isNumber()) return args.env.failFmt(.type_mismatch, "'?' expects numbers, got {s}", .{y.typeName()});

    const io = try requireIo(args);

    if (x == .float or y == .float) {
        const xf = x.getF() catch unreachable;
        const yf = y.getF() catch unreachable;
        if (xf > yf) return args.env.fail(.invalid_argument, "'?' expects x <= y");
        return .{ .float = xf + randomF64(io) * (yf - xf) };
    } else {
        const xi = x.getI() catch unreachable;
        const yi = y.getI() catch unreachable;
        if (xi > yi) return args.env.fail(.invalid_argument, "'?' expects x <= y");
        return .{ .int = randomIntRangeAtMost(io, i64, xi, yi) };
    }
}

/// `?< x y`, random value in [x, y) (upper-exclusive).
/// For integers, y is never returned.
/// For floats, standard [x, y) semantics.
fn randExclusiveOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const x = try args.at(0).resolve();
    const y = try args.at(1).resolve();
    if (!x.isNumber()) return args.env.failFmt(.type_mismatch, "'?<' expects numbers, got {s}", .{x.typeName()});
    if (!y.isNumber()) return args.env.failFmt(.type_mismatch, "'?<' expects numbers, got {s}", .{y.typeName()});

    const io = try requireIo(args);

    if (x == .float or y == .float) {
        const xf = x.getF() catch unreachable;
        const yf = y.getF() catch unreachable;
        if (xf >= yf) return args.env.fail(.invalid_argument, "'?<' expects x < y");
        return .{ .float = xf + randomF64(io) * (yf - xf) };
    } else {
        const xi = x.getI() catch unreachable;
        const yi = y.getI() catch unreachable;
        if (xi >= yi) return args.env.fail(.invalid_argument, "'?<' expects x < y");
        return .{ .int = randomIntRangeLessThan(io, i64, xi, yi) };
    }
}

/// `?? a b c ...`, pick one argument at random. Only the chosen argument is evaluated.
fn randPickOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const io = try requireIo(args);
    const index = randomIntRangeLessThan(io, usize, 0, args.count());
    return args.at(index).get();
}


const builtins = @import("builtins.zig");
const process = @import("process.zig");

test "?: integer inclusive range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc, .io = io };

    for (0..100) |_| {
        const result = try process.processRaw(&env, "? 1 6", null);
        const value = result.ok.?;
        try std.testing.expect(value == .int);
        try std.testing.expect(value.int >= 1 and value.int <= 6);
    }
}

test "?<: integer exclusive upper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc, .io = io };

    for (0..100) |_| {
        const result = try process.processRaw(&env, "?< 0 5", null);
        const value = result.ok.?;
        try std.testing.expect(value == .int);
        try std.testing.expect(value.int >= 0 and value.int <= 4);
    }
}

test "?: same value returns that value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc, .io = io };

    const result = try process.processRaw(&env, "? 7 7", null);
    try std.testing.expectEqual(@as(i64, 7), result.ok.?.int);
}

test "??: picks from provided values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc, .io = io };

    for (0..100) |_| {
        const result = try process.processRaw(&env, "?? 10 20 30", null);
        const value = result.ok.?.int;
        try std.testing.expect(value == 10 or value == 20 or value == 30);
    }
}

test "let: binds ? once, body sees the same roll on every reference" {
    // Without let: (- (? 0 1000000) (? 0 1000000)) is almost never 0.
    // With let:    (let r (? 0 1000000) (- :r :r)) is always 0.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc, .io = io };

    for (0..50) |_| {
        const result = try process.processRaw(&env, "let r (? 0 1000000) (- :r :r)", null);
        try std.testing.expectEqual(@as(i64, 0), result.ok.?.int);
    }
}
