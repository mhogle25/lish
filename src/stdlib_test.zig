//! Tests for stdlib macros bundled via `process.loadStdlib`.

const std = @import("std");
const testing = @import("builtins/testing.zig");

test "stdlib: kvget returns value for present key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvget [\"name\" \"alice\" \"age\" 30] \"age\"");
    try std.testing.expectEqual(@as(i64, 30), result.?.int);
}

test "stdlib: kvget returns $none for missing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvget [\"name\" \"alice\"] \"missing\"");
    try std.testing.expect(result == null);
}

test "stdlib: kvhas $some for present key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvhas [\"name\" \"alice\"] \"name\"");
    try std.testing.expect(result != null);
}

test "stdlib: kvhas $none for missing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvhas [\"name\" \"alice\"] \"missing\"");
    try std.testing.expect(result == null);
}

test "stdlib: kvkeys extracts even-indexed elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvkeys [\"name\" \"alice\" \"age\" 30]");
    const list = result.?.list;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("name", list[0].?.string);
    try std.testing.expectEqualStrings("age", list[1].?.string);
}

test "stdlib: kvvalues extracts odd-indexed elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvvalues [\"name\" \"alice\" \"age\" 30]");
    const list = result.?.list;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("alice", list[0].?.string);
    try std.testing.expectEqual(@as(i64, 30), list[1].?.int);
}

test "stdlib: kvset replaces existing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvget (kvset [\"name\" \"alice\" \"age\" 30] \"age\" 31) \"age\"");
    try std.testing.expectEqual(@as(i64, 31), result.?.int);
}

test "stdlib: kvset preserves other entries when replacing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvget (kvset [\"name\" \"alice\" \"age\" 30] \"age\" 31) \"name\"");
    try std.testing.expectEqualStrings("alice", result.?.string);
}

test "stdlib: kvset appends new key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvget (kvset [\"name\" \"alice\"] \"age\" 30) \"age\"");
    try std.testing.expectEqual(@as(i64, 30), result.?.int);
}

test "stdlib: kvmerge keeps a's bindings when b has no overlap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvget (kvmerge [\"a\" 1] [\"b\" 2]) \"a\"");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "stdlib: kvmerge b wins on conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvget (kvmerge [\"x\" 1] [\"x\" 2]) \"x\"");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "stdlib: kvmerge adds b's new keys to a" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(),
        "kvget (kvmerge [\"a\" 1] [\"b\" 2]) \"b\"");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "stdlib: kvkeys on empty list returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "kvkeys []");
    try std.testing.expectEqual(@as(usize, 0), result.?.list.len);
}

test "stdlib: pi returns ~3.14159" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "pi");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi), result.?.float, 1e-12);
}

test "stdlib: clamp within range returns v" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "clamp 5 0 10");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "stdlib: clamp above max returns hi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "clamp 15 0 10");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "stdlib: clamp below min returns lo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "clamp (- 0 5) 0 10");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "stdlib: sign positive returns 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "sign 42");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "stdlib: sign negative returns -1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "sign (- 0 5)");
    try std.testing.expectEqual(@as(i64, -1), result.?.int);
}

test "stdlib: sign zero returns 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "sign 0");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "stdlib: fill produces list of n copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "fill 4 7");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    for (items) |item| try std.testing.expectEqual(@as(i64, 7), item.?.int);
}

test "stdlib: fill zero count gives empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "fill 0 99");
    try std.testing.expectEqual(@as(usize, 0), result.?.list.len);
}

test "stdlib: square" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "square 5");
    try std.testing.expectEqual(@as(i64, 25), result.?.int);
}

test "stdlib: cube" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "cube 3");
    try std.testing.expectEqual(@as(i64, 27), result.?.int);
}

test "stdlib: negate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "negate 7");
    try std.testing.expectEqual(@as(i64, -7), result.?.int);
}

test "stdlib: lerp at t=0 returns a" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "lerp 10 20 0");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "stdlib: lerp at t=1 returns b" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "lerp 10 20 1");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "stdlib: lerp at t=0.5 returns midpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "lerp 10.0 20.0 0.5");
    try std.testing.expectApproxEqAbs(@as(f64, 15.0), result.?.float, 1e-9);
}

test "stdlib: clamp01 clamps below 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "clamp01 -0.5");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?.float, 1e-9);
}

test "stdlib: clamp01 clamps above 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "clamp01 2.5");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.?.float, 1e-9);
}

test "stdlib: smoothstep at midpoint = 0.5" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "smoothstep 0.0 1.0 0.5");
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.?.float, 1e-9);
}

test "stdlib: smoothstep below edge0 = 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "smoothstep 0.0 1.0 -1.0");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?.float, 1e-9);
}

test "stdlib: smoothstep above edge1 = 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "smoothstep 0.0 1.0 2.0");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.?.float, 1e-9);
}

test "stdlib: pop drops last element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "pop [10 20 30]");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 10), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 20), items[1].?.int);
}

test "stdlib: repeatstr concatenates n copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "repeatstr \"ab\" 3");
    try std.testing.expectEqualStrings("ababab", result.?.string);
}

test "stdlib: padleft pads short string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "padleft \"42\" 5 \"0\"");
    try std.testing.expectEqualStrings("00042", result.?.string);
}

test "stdlib: padleft leaves wider string unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "padleft \"hello\" 3 \"x\"");
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "stdlib: padright pads short string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "padright \"hi\" 5 \".\"");
    try std.testing.expectEqualStrings("hi...", result.?.string);
}

test "stdlib: positive on positive number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "positive 5");
    try std.testing.expect(result != null);
}

test "stdlib: positive on zero is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "positive 0");
    try std.testing.expect(result == null);
}

test "stdlib: negative on negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "negative (- 0 3)");
    try std.testing.expect(result != null);
}

test "stdlib: zero on zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "zero 0");
    try std.testing.expect(result != null);
}

test "stdlib: zero on non-zero is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "zero 1");
    try std.testing.expect(result == null);
}

test "stdlib: between inclusive on both ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "between 0 10 5");
    try std.testing.expect(result != null);
}

test "stdlib: between outside range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "between 0 10 15");
    try std.testing.expect(result == null);
}

test "stdlib: numeric on int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "numeric 42");
    try std.testing.expect(result != null);
}

test "stdlib: numeric on float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "numeric 3.14");
    try std.testing.expect(result != null);
}

test "stdlib: numeric on string is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "numeric \"hi\"");
    try std.testing.expect(result == null);
}

test "stdlib: blank on empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "blank \"\"");
    try std.testing.expect(result != null);
}

test "stdlib: blank on whitespace-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "blank \"   \\t\\n\"");
    try std.testing.expect(result != null);
}

test "stdlib: blank on non-empty is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "blank \"hi\"");
    try std.testing.expect(result == null);
}

test "stdlib: panic raises runtime error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithStdlib(arena.allocator(), "panic \"oops\"");
    try std.testing.expectError(error.RuntimeError, result);
}

test "stdlib: ok constructs an [ok payload] Result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "ok 5");
    const list = result.?.list;
    try std.testing.expectEqualStrings("ok", list[0].?.string);
    try std.testing.expectEqual(@as(i64, 5), list[1].?.int);
}

test "stdlib: err constructs an [err payload] Result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "err \"boom\"");
    const list = result.?.list;
    try std.testing.expectEqualStrings("err", list[0].?.string);
    try std.testing.expectEqualStrings("boom", list[1].?.string);
}

test "stdlib: pass projects an ok Result to its payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "pass (ok 5)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "stdlib: pass on an err Result is $none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "pass (err \"boom\")");
    try std.testing.expect(result == null);
}

test "stdlib: fail projects an err Result to its payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "fail (err \"boom\")");
    try std.testing.expectEqualStrings("boom", result.?.string);
}

test "stdlib: fail on an ok Result is $none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "fail (ok 5)");
    try std.testing.expect(result == null);
}

test "stdlib: unwrap yields the payload of an ok Result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "unwrap (ok 42)");
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

test "stdlib: unwrap panics on an err Result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithStdlib(arena.allocator(), "unwrap (err \"kaboom\")");
    try std.testing.expectError(error.RuntimeError, result);
}

test "stdlib: given over a pass-projected ok Result binds the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "given v (pass (ok 10)) (* :v 2) 0");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "stdlib: given over a pass-projected err Result runs the else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithStdlib(arena.allocator(), "given v (pass (err \"x\")) (* :v 2) 0");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}
