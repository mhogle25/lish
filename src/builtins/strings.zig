const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");
const helpers = @import("helpers.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Allocator = std.mem.Allocator;

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    // String
    try registry.registerOperation(allocator, "concat",  Operation.fromFn(concatOp));
    try registry.registerOperation(allocator, "join",    Operation.fromFn(joinOp));
    try registry.registerOperation(allocator, "split",   Operation.fromFn(splitOp));
    try registry.registerOperation(allocator, "trim",    Operation.fromFn(trimOp));
    try registry.registerOperation(allocator, "upper",   Operation.fromFn(upperOp));
    try registry.registerOperation(allocator, "lower",   Operation.fromFn(lowerOp));
    try registry.registerOperation(allocator, "replace", Operation.fromFn(replaceOp));
    try registry.registerOperation(allocator, "format",  Operation.fromFn(formatOp));

    // Predicates
    try registry.registerOperation(allocator, "prefix",  Operation.fromFn(prefixOp));
    try registry.registerOperation(allocator, "suffix",  Operation.fromFn(suffixOp));
    try registry.registerOperation(allocator, "in",      Operation.fromFn(inOp));
    try registry.registerOperation(allocator, "find",    Operation.fromFn(findOp));
}

fn concatOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = std.ArrayListUnmanaged(u8).empty;
    for (0..args.count()) |i| {
        const maybe_value = try args.at(i).get();
        if (maybe_value) |value| {
            var buf: [256]u8 = undefined;
            const str = value.getS(&buf);
            try helpers.checkStringLength(args, result.items.len + str.len);
            try result.appendSlice(args.env.allocator, str);
        }
    }
    return .{ .string = result.items };
}

fn joinOp(args: Args) ExecError!?Value {
    try args.expectMinCount(3);
    var sep_buf: [256]u8 = undefined;
    const separator = try args.at(0).resolveString(&sep_buf);
    const separator_owned = try args.env.allocator.dupe(u8, separator);

    var result = std.ArrayListUnmanaged(u8).empty;
    for (1..args.count()) |i| {
        if (i > 1) {
            try helpers.checkStringLength(args, result.items.len + separator_owned.len);
            try result.appendSlice(args.env.allocator, separator_owned);
        }
        const maybe_value = try args.at(i).get();
        if (maybe_value) |value| {
            var buf: [256]u8 = undefined;
            const str = value.getS(&buf);
            try helpers.checkStringLength(args, result.items.len + str.len);
            try result.appendSlice(args.env.allocator, str);
        }
    }
    return .{ .string = result.items };
}

fn splitOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    var sep_buf: [256]u8 = undefined;
    const separator = try args.at(0).resolveString(&sep_buf);
    const target = try args.at(1).resolve();
    if (target != .string) return args.env.fail("'split' expects a string as second argument");
    const string = target.string;

    const alloc = args.env.allocator;
    var parts = std.ArrayListUnmanaged(?Value).empty;

    if (separator.len == 0) {
        for (0..string.len) |i| {
            try helpers.checkListLength(args, parts.items.len + 1);
            const char = try alloc.dupe(u8, string[i .. i + 1]);
            try parts.append(alloc, .{ .string = char });
        }
    } else {
        var remaining = string;
        while (std.mem.indexOf(u8, remaining, separator)) |idx| {
            try helpers.checkListLength(args, parts.items.len + 1);
            const part = try alloc.dupe(u8, remaining[0..idx]);
            try parts.append(alloc, .{ .string = part });
            remaining = remaining[idx + separator.len ..];
        }
        try helpers.checkListLength(args, parts.items.len + 1);
        const last_part = try alloc.dupe(u8, remaining);
        try parts.append(alloc, .{ .string = last_part });
    }

    return .{ .list = parts.items };
}

fn trimOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value != .string) return args.env.fail("'trim' expects a string");
    const trimmed = std.mem.trim(u8, value.string, " \t\n\r\x0b\x0c");
    const owned = try args.env.allocator.dupe(u8, trimmed);
    return .{ .string = owned };
}

fn upperOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value != .string) return args.env.fail("'upper' expects a string");
    const result = try args.env.allocator.dupe(u8, value.string);
    for (result) |*char| {
        char.* = std.ascii.toUpper(char.*);
    }
    return .{ .string = result };
}

fn lowerOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value != .string) return args.env.fail("'lower' expects a string");
    const result = try args.env.allocator.dupe(u8, value.string);
    for (result) |*char| {
        char.* = std.ascii.toLower(char.*);
    }
    return .{ .string = result };
}

fn replaceOp(args: Args) ExecError!?Value {
    try args.expectCount(3);
    const pattern_val = try args.at(0).resolve();
    const replacement_val = try args.at(1).resolve();
    const target_val = try args.at(2).resolve();
    if (pattern_val != .string or replacement_val != .string or target_val != .string)
        return args.env.fail("'replace' expects string arguments");

    const pattern = pattern_val.string;
    const replacement = replacement_val.string;
    const target = target_val.string;
    const alloc = args.env.allocator;

    if (pattern.len == 0) return .{ .string = target };

    var result = std.ArrayListUnmanaged(u8).empty;
    var remaining = target;
    while (std.mem.indexOf(u8, remaining, pattern)) |idx| {
        try helpers.checkStringLength(args, result.items.len + idx + replacement.len);
        try result.appendSlice(alloc, remaining[0..idx]);
        try result.appendSlice(alloc, replacement);
        remaining = remaining[idx + pattern.len ..];
    }
    try helpers.checkStringLength(args, result.items.len + remaining.len);
    try result.appendSlice(alloc, remaining);
    return .{ .string = result.items };
}

fn formatOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const template_val = try args.at(0).resolve();
    if (template_val != .string) return args.env.fail("'format' expects a string template as first argument");

    const template = template_val.string;
    const alloc = args.env.allocator;
    var result = std.ArrayListUnmanaged(u8).empty;

    var remaining = template;
    var arg_index: usize = 1;
    while (std.mem.indexOf(u8, remaining, "<>")) |idx| {
        try helpers.checkStringLength(args, result.items.len + idx);
        try result.appendSlice(alloc, remaining[0..idx]);
        if (arg_index < args.count()) {
            const arg_val = try args.at(arg_index).get();
            if (arg_val) |value| {
                var buf: [256]u8 = undefined;
                const str = value.getS(&buf);
                try helpers.checkStringLength(args, result.items.len + str.len);
                try result.appendSlice(alloc, str);
            }
            arg_index += 1;
        }
        remaining = remaining[idx + 2 ..];
    }
    try helpers.checkStringLength(args, result.items.len + remaining.len);
    try result.appendSlice(alloc, remaining);
    return .{ .string = result.items };
}

// ── Predicates ──

fn prefixOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    var pattern_buf: [256]u8 = undefined;
    const pattern = try args.at(0).resolveString(&pattern_buf);
    const pattern_len = pattern.len;
    var target_buf: [256]u8 = undefined;
    const target = try args.at(1).resolveString(&target_buf);
    if (!std.mem.startsWith(u8, target, pattern)) return null;
    const remainder = try args.env.allocator.dupe(u8, target[pattern_len..]);
    return .{ .string = remainder };
}

fn suffixOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    var pattern_buf: [256]u8 = undefined;
    const pattern = try args.at(0).resolveString(&pattern_buf);
    const pattern_len = pattern.len;
    var target_buf: [256]u8 = undefined;
    const target = try args.at(1).resolveString(&target_buf);
    if (!std.mem.endsWith(u8, target, pattern)) return null;
    const remainder = try args.env.allocator.dupe(u8, target[0 .. target.len - pattern_len]);
    return .{ .string = remainder };
}

fn inOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const needle = try args.at(0).resolve();
    const haystack = try args.at(1).resolve();
    return switch (haystack) {
        .string => |haystack_str| {
            var needle_buf: [256]u8 = undefined;
            const needle_str = needle.getS(&needle_buf);
            if (std.mem.indexOf(u8, haystack_str, needle_str) != null) return needle;
            return null;
        },
        .list => |items| {
            for (items) |item| {
                if (item != null and needle.eql(item.?)) return needle;
            }
            return null;
        },
        else => args.env.fail("'in' expects a string or list as second argument"),
    };
}

fn findOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const needle = try args.at(0).resolve();
    const haystack = try args.at(1).resolve();
    return switch (haystack) {
        .string => |haystack_str| {
            var needle_buf: [256]u8 = undefined;
            const needle_str = needle.getS(&needle_buf);
            const index = std.mem.indexOf(u8, haystack_str, needle_str) orelse return null;
            return .{ .int = @intCast(index) };
        },
        .list => |items| {
            for (items, 0..) |item, i| {
                if (item != null and needle.eql(item.?)) return .{ .int = @intCast(i) };
            }
            return null;
        },
        else => args.env.fail("'find' expects a string or list as second argument"),
    };
}

// ── Tests ──

const testing = @import("testing.zig");

test "string: concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "concat \"hello\" \" \" \"world\"");
    try std.testing.expectEqualStrings("hello world", result.?.string);
}

test "string: join" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "join \",\" \"a\" \"b\" \"c\"");
    try std.testing.expectEqualStrings("a,b,c", result.?.string);
}

test "string predicate: prefix returns remainder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "prefix \"hel\" \"hello\"");
    try std.testing.expectEqualStrings("lo", result.?.string);
}

test "string predicate: prefix full match returns empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "prefix \"hello\" \"hello\"");
    try std.testing.expectEqualStrings("", result.?.string);
}

test "string predicate: prefix falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "prefix \"xyz\" \"hello\"");
    try std.testing.expect(result == null);
}

test "string predicate: suffix returns remainder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "suffix \"llo\" \"hello\"");
    try std.testing.expectEqualStrings("he", result.?.string);
}

test "string predicate: suffix full match returns empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "suffix \"hello\" \"hello\"");
    try std.testing.expectEqualStrings("", result.?.string);
}

test "string predicate: suffix falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "suffix \"xyz\" \"hello\"");
    try std.testing.expect(result == null);
}

test "string predicate: in string returns needle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "in \"ell\" \"hello\"");
    try std.testing.expectEqualStrings("ell", result.?.string);
}

test "string predicate: in string falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "in \"xyz\" \"hello\"");
    try std.testing.expect(result == null);
}

test "string predicate: in list returns needle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "in 2 [1 2 3]");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "string predicate: in list falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "in 5 [1 2 3]");
    try std.testing.expect(result == null);
}

test "string: at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "at 0 \"hello\"");
    try std.testing.expectEqualStrings("h", result.?.string);
}

test "string: at out of bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "at 10 \"hello\"");
    try std.testing.expect(result == null);
}

test "string: first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first \"hello\"");
    try std.testing.expectEqualStrings("h", result.?.string);
}

test "string: first empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first \"\"");
    try std.testing.expect(result == null);
}

test "string: rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "rest \"hello\"");
    try std.testing.expectEqualStrings("ello", result.?.string);
}

test "string: rest single char" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "rest \"h\"");
    try std.testing.expectEqualStrings("", result.?.string);
}

test "string: reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "reverse \"hello\"");
    try std.testing.expectEqualStrings("olleh", result.?.string);
}

test "string: split basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "split \",\" \"a,b,c\"");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("a", items[0].?.string);
    try std.testing.expectEqualStrings("b", items[1].?.string);
    try std.testing.expectEqualStrings("c", items[2].?.string);
}

test "string: split no match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "split \",\" \"hello\"");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("hello", items[0].?.string);
}

test "string: split empty separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "split \"\" \"abc\"");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("a", items[0].?.string);
    try std.testing.expectEqualStrings("b", items[1].?.string);
    try std.testing.expectEqualStrings("c", items[2].?.string);
}

test "string: trim whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "trim \"  hello  \"");
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "string: trim no whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "trim \"hello\"");
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "string: upper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "upper \"hello\"");
    try std.testing.expectEqualStrings("HELLO", result.?.string);
}

test "string: lower" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "lower \"HELLO\"");
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "string: replace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "replace \"o\" \"0\" \"hello world\"");
    try std.testing.expectEqualStrings("hell0 w0rld", result.?.string);
}

test "string: replace no match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "replace \"x\" \"y\" \"hello\"");
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "string: format basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "format \"hello, <>!\" \"world\"");
    try std.testing.expectEqualStrings("hello, world!", result.?.string);
}

test "string: format multiple args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "format \"<> + <> = <>\" 1 2 3");
    try std.testing.expectEqualStrings("1 + 2 = 3", result.?.string);
}

test "string: format missing arg leaves placeholder empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "format \"a<>b\"");
    try std.testing.expectEqualStrings("ab", result.?.string);
}

test "find: substring match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "find \"world\" \"hello world\"");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "find: substring miss returns none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "find \"zzz\" \"hello\"");
    try std.testing.expect(result == null);
}

test "find: list element match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "find 30 [10 20 30 40]");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "find: list element miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "find 99 [10 20 30]");
    try std.testing.expect(result == null);
}

test "find: first index when duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "find 5 [1 5 5 5]");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

