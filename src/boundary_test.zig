// Pressure tests: feed boundary values to every numeric/collection/random op.
// A safety-check trap (overflow, OOB, bad @intCast) aborts the test binary, so an
// input that traps fails the suite -- reaching the end of a sweep is the assertion.

const std = @import("std");
const exec = @import("exec.zig");
const val = @import("value.zig");
const parser = @import("parser.zig");
const validation = @import("validation.zig");
const builtins = @import("builtins.zig");
const random = @import("random.zig");

const Value = val.Value;

const MAX = "9223372036854775807"; // i64 max
const NEAR_MAX = "9223372036854775806"; // i64 max - 1
const MIN = "-9223372036854775808"; // i64 min
const NEAR_MIN = "-9223372036854775806"; // i64 min + 2

const Options = struct {
    with_random: bool = false,
    max_list_length: ?usize = null,
};

fn eval(alloc: std.mem.Allocator, io: ?std.Io, opts: Options, src: []const u8) exec.ExecError!?Value {
    var registry = exec.Registry.init(alloc);
    builtins.registerAll(&registry, alloc) catch return error.OutOfMemory;
    if (opts.with_random) random.registerAll(&registry, alloc) catch return error.OutOfMemory;

    var env = exec.Env{ .registry = &registry, .allocator = alloc, .io = io };
    env.bounds.max_list_length = opts.max_list_length;

    const ast_root = try parser.parse(alloc, src);
    const result = try validation.validate(alloc, ast_root);
    return switch (result) {
        .ok => |unit| blk: {
            const frame = try env.enterUnit(unit.unit_id, unit.site_count);
            defer env.exitUnit(frame);
            break :blk env.processExpression(unit.root, &exec.Scope.EMPTY);
        },
        .err => error.RuntimeError,
    };
}

// Each source must RETURN (a value or a graceful error), not trap. OOM is surfaced.
fn sweepNoTrap(alloc: std.mem.Allocator, io: ?std.Io, opts: Options, cases: []const []const u8) !void {
    for (cases) |src| {
        _ = eval(alloc, io, opts, src) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        };
    }
}

test "boundary sweep: arithmetic never traps at the i64 extremes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try sweepNoTrap(arena.allocator(), null, .{}, &.{
        "+ " ++ MAX ++ " " ++ MAX,
        "- " ++ MIN ++ " " ++ MAX,
        "* " ++ MIN ++ " " ++ MIN,
        "* " ++ MAX ++ " " ++ MIN,
        "** " ++ MAX ++ " " ++ MAX,
        "** " ++ MIN ++ " 3",
        "** -10 19",
        "/ " ++ MIN ++ " -1",
        "% " ++ MIN ++ " -1",
        "/ 5 0",
        "% 5 0",
        "abs " ++ MIN,
        "- 0 " ++ MIN, // negate(minInt)
        "+% " ++ MAX ++ " 1",
        "-% " ++ MIN ++ " 1",
        "*% " ++ MAX ++ " " ++ MAX,
        "**% 2 64",
        "+? " ++ MAX ++ " 1",
        "-? " ++ MIN ++ " 1",
        "*? " ++ MAX ++ " " ++ MAX,
        "**? " ++ MAX ++ " " ++ MAX,
    });
}

test "boundary sweep: math and comparison ops never trap at the extremes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try sweepNoTrap(arena.allocator(), null, .{}, &.{
        "even " ++ MIN,
        "odd " ++ MAX,
        "min " ++ MIN ++ " " ++ MAX,
        "max " ++ MIN ++ " " ++ MAX,
        "compare " ++ MIN ++ " " ++ MAX,
        "sqrt -1",
        "log 0",
        "exp 1e300",
        "int " ++ MAX,
        "float " ++ MIN,
    });
}

test "boundary sweep: shifts and bitwise never trap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try sweepNoTrap(arena.allocator(), null, .{}, &.{
        "<< 1 " ++ MAX,
        "<< 1 " ++ MIN,
        ">> " ++ MAX ++ " 1",
        "<< " ++ MIN ++ " 1",
        "<< 1 -1",
        ">> 1 " ++ MIN,
        "& " ++ MIN ++ " " ++ MAX,
        "| " ++ MIN ++ " " ++ MAX,
        "^ " ++ MIN ++ " " ++ MAX,
        "~ " ++ MIN,
    });
}

test "boundary sweep: float-to-int coercion never traps on inf/nan/huge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try sweepNoTrap(arena.allocator(), null, .{}, &.{
        "int (/ 1.0 0.0)",
        "int (/ -1.0 0.0)",
        "int (/ 0.0 0.0)",
        "floor (/ 1.0 0.0)",
        "ceil (/ -1.0 0.0)",
        "round (/ 0.0 0.0)",
        "int 1e300",
        "int -1e300",
        "** 2.0 100000",
    });
}

test "boundary sweep: collection ops never trap on extreme indices or empties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try sweepNoTrap(arena.allocator(), null, .{}, &.{
        "at " ++ MAX ++ " [1 2 3]",
        "at " ++ MIN ++ " [1 2 3]",
        "at -1 [1 2 3]",
        "at " ++ MAX ++ " \"abc\"",
        "at -1 \"abc\"",
        "take " ++ MAX ++ " [1 2 3]",
        "take 0 [1 2 3]",
        "drop " ++ MAX ++ " [1 2 3]",
        "drop 0 [1 2 3]",
        "slice 0 " ++ MAX ++ " [1 2 3]",
        "slice 0 " ++ MAX ++ " \"abc\"",
        "first []",
        "last []",
        "rest []",
        "first \"\"",
        "last \"\"",
        "reverse []",
        "flatten []",
        "zip [] []",
        "zip [1 2] [3]",
        "length []",
    });
}

test "boundary sweep: range/until reach the i64 bounds without trapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Spans are kept tiny (endpoints at the boundary, not the whole range) so these
    // exercise the overflow-on-increment path without attempting a huge allocation.
    try sweepNoTrap(arena.allocator(), null, .{}, &.{
        "range " ++ NEAR_MAX ++ " " ++ MAX,
        "range 0 5",
        "range 5 0",
        "until " ++ NEAR_MAX ++ " " ++ MAX,
        "until 0 5",
        "range " ++ NEAR_MIN ++ " " ++ MIN ++ " -1",
        "until " ++ NEAR_MIN ++ " " ++ MIN ++ " -1",
    });
}

test "boundary sweep: random ops never trap at the i64 extremes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(arena.allocator(), .{});
    defer threaded.deinit();
    const io = threaded.io();
    try sweepNoTrap(arena.allocator(), io, .{ .with_random = true }, &.{
        "? " ++ MIN ++ " " ++ MAX,
        "?< " ++ MIN ++ " " ++ MAX,
        "? " ++ MIN ++ " " ++ MIN,
        "? " ++ MAX ++ " " ++ MAX,
        "?< -1 " ++ MAX,
        "? 0 " ++ MAX,
        "?< 0 " ++ MAX,
        "?? 1",
    });
}

test "range reaches the i64 boundary and yields the endpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try eval(arena.allocator(), null, .{}, "range " ++ NEAR_MAX ++ " " ++ MAX);
    try std.testing.expectEqual(@as(usize, 2), result.?.list.len);
    try std.testing.expectEqual(std.math.maxInt(i64), result.?.list[1].?.int);
}

test "an enormous range errors under a list-length bound instead of hanging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Unbounded this would try to build ~9.2e18 elements; the bound turns it into a
    // prompt RuntimeError after 1000 iterations rather than a host hang.
    try std.testing.expectError(error.RuntimeError, eval(arena.allocator(), null, .{ .max_list_length = 1000 }, "range 0 " ++ MAX));
}

test "random over the full i64 range returns an in-range value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(arena.allocator(), .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The previous code trapped here (at_most - at_least overflowed); now it must
    // return a valid i64 across many rolls.
    for (0..200) |_| {
        const result = try eval(arena.allocator(), io, .{ .with_random = true }, "? " ++ MIN ++ " " ++ MAX);
        try std.testing.expect(result.? == .int);
    }
}
