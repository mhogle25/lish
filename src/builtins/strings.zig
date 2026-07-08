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

const string_param = [_]Param{.{ .name = "string", .type = .string }};
const pattern_target = [_]Param{ .{ .name = "pattern", .type = .string }, .{ .name = "target", .type = .string } };
// `needle` is a substring (string haystack) or element (list haystack), so it stays generic.
const needle_haystack = [_]Param{ .{ .name = "needle" }, .{ .name = "haystack", .type = .collection } };

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "strings");

    // String
    try g.register("concat", Operation.fromFn(concatOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "a" }, Param{ .name = "b", .arity = .variadic } }, .returns = .string },
        .description = "Concatenate all arguments into one string.",
    }));

    try g.register("join", Operation.fromFn(joinOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "separator", .type = .string }, Param{ .name = "a" }, Param{ .name = "b", .arity = .variadic } }, .returns = .string },
        .description = "Join the remaining arguments into a string separated by the first.",
    }));

    try g.register("split", Operation.fromFn(splitOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "separator", .type = .string }, Param{ .name = "string", .type = .string } }, .returns = .list },
        .description = "Split a string on a separator into a list of pieces.",
    }));

    try g.register("chars", Operation.fromFn(charsOp, .{
        .signature = .{ .params = &string_param, .returns = .list },
        .description = "Split a string into a list of its single-character strings.",
    }));

    try g.register("lines", Operation.fromFn(linesOp, .{
        .signature = .{ .params = &string_param, .returns = .list },
        .description = "Split a string into a list of its lines.",
    }));

    try g.register("trim", Operation.fromFn(trimOp, .{
        .signature = .{ .params = &string_param, .returns = .string },
        .description = "Strip leading and trailing whitespace.",
    }));

    try g.register("upper", Operation.fromFn(upperOp, .{
        .signature = .{ .params = &string_param, .returns = .string },
        .description = "Convert to uppercase.",
    }));

    try g.register("lower", Operation.fromFn(lowerOp, .{
        .signature = .{ .params = &string_param, .returns = .string },
        .description = "Convert to lowercase.",
    }));

    try g.register("replace", Operation.fromFn(replaceOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "pattern", .type = .string }, Param{ .name = "replacement", .type = .string }, Param{ .name = "target", .type = .string } }, .returns = .string },
        .description = "Replace every occurrence of a pattern with a replacement in the target string.",
    }));

    try g.register("format", Operation.fromFn(formatOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "template", .type = .string }, Param{ .name = "arg", .arity = .variadic } }, .returns = .string },
        .description = "Fill each <> placeholder in the template with the following arguments in order.",
    }));

    // Predicates
    try g.register("prefix", Operation.fromFn(prefixOp, .{
        .signature = .{ .params = &pattern_target, .returns = .{ .one_of = &.{ .string, .none } } },
        .description = "When the target starts with the pattern, returns the remainder, else $none.",
    }));

    try g.register("suffix", Operation.fromFn(suffixOp, .{
        .signature = .{ .params = &pattern_target, .returns = .{ .one_of = &.{ .string, .none } } },
        .description = "When the target ends with the pattern, returns the remainder, else $none.",
    }));

    try g.register("in", Operation.fromFn(inOp, .{
        .signature = .{ .params = &needle_haystack, .returns = .{ .one_of = &.{ .any, .none } } },
        .description = "Membership test; returns the needle when found in the string or list, else $none.",
    }));

    try g.register("find", Operation.fromFn(findOp, .{
        .signature = .{ .params = &needle_haystack, .returns = .{ .one_of = &.{ .int, .none } } },
        .description = "Index of the needle within the string or list, else $none.",
    }));
}

fn concatOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = std.ArrayListUnmanaged(u8).empty;
    for (0..args.count()) |i| {
        const maybe_value = try args.at(i).get();
        if (maybe_value) |value| {
            var buf: [256]u8 = undefined;
            const str = try helpers.getString(args.env, "concat", value, &buf);
            try helpers.checkStringLength(args.env, result.items.len + str.len);
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
            try helpers.checkStringLength(args.env, result.items.len + separator_owned.len);
            try result.appendSlice(args.env.allocator, separator_owned);
        }
        const maybe_value = try args.at(i).get();
        if (maybe_value) |value| {
            var buf: [256]u8 = undefined;
            const str = try helpers.getString(args.env, "join", value, &buf);

            try helpers.checkStringLength(args.env, result.items.len + str.len);
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
    if (target != .string) return args.env.failFmt(.type_mismatch, "'split' expects a string as second argument, got {s}", .{target.typeName()});
    const string = target.string;

    const alloc = args.env.allocator;
    var parts = std.ArrayListUnmanaged(?Value).empty;

    if (separator.len == 0) {
        for (0..string.len) |i| {
            try helpers.checkListLength(args.env, parts.items.len + 1);
            const char = try alloc.dupe(u8, string[i .. i + 1]);
            try parts.append(alloc, .{ .string = char });
        }
    } else {
        var remaining = string;
        while (std.mem.indexOf(u8, remaining, separator)) |idx| {
            try helpers.checkListLength(args.env, parts.items.len + 1);
            const part = try alloc.dupe(u8, remaining[0..idx]);
            try parts.append(alloc, .{ .string = part });
            remaining = remaining[idx + separator.len ..];
        }
        try helpers.checkListLength(args.env, parts.items.len + 1);
        const last_part = try alloc.dupe(u8, remaining);
        try parts.append(alloc, .{ .string = last_part });
    }

    return .{ .list = parts.items };
}

fn charsOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value != .string) return args.env.failFmt(.type_mismatch, "'chars' expects a string, got {s}", .{value.typeName()});
    const string = value.string;

    const alloc = args.env.allocator;
    var parts = std.ArrayListUnmanaged(?Value).empty;
    for (0..string.len) |i| {
        try helpers.checkListLength(args.env, parts.items.len + 1);
        const char = try alloc.dupe(u8, string[i .. i + 1]);
        try parts.append(alloc, .{ .string = char });
    }
    return .{ .list = parts.items };
}

fn linesOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value != .string) return args.env.failFmt(.type_mismatch, "'lines' expects a string, got {s}", .{value.typeName()});
    const string = value.string;

    const alloc = args.env.allocator;
    var parts = std.ArrayListUnmanaged(?Value).empty;

    var remaining = string;
    while (std.mem.indexOfScalar(u8, remaining, '\n')) |idx| {
        try helpers.checkListLength(args.env, parts.items.len + 1);
        // Strip trailing \r so CRLF input produces clean lines.
        const raw = remaining[0..idx];
        const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        const part = try alloc.dupe(u8, trimmed);
        try parts.append(alloc, .{ .string = part });
        remaining = remaining[idx + 1 ..];
    }
    // Emit the final segment only if non-empty so a trailing newline doesn't
    // produce a phantom empty line.
    if (remaining.len > 0) {
        try helpers.checkListLength(args.env, parts.items.len + 1);
        const trimmed = if (remaining[remaining.len - 1] == '\r') remaining[0 .. remaining.len - 1] else remaining;
        const part = try alloc.dupe(u8, trimmed);
        try parts.append(alloc, .{ .string = part });
    }
    return .{ .list = parts.items };
}

fn trimOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value != .string) return args.env.failFmt(.type_mismatch, "'trim' expects a string, got {s}", .{value.typeName()});
    const trimmed = std.mem.trim(u8, value.string, " \t\n\r\x0b\x0c");
    const owned = try args.env.allocator.dupe(u8, trimmed);
    return .{ .string = owned };
}

fn upperOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value != .string) return args.env.failFmt(.type_mismatch, "'upper' expects a string, got {s}", .{value.typeName()});
    const result = try args.env.allocator.dupe(u8, value.string);
    for (result) |*char| {
        char.* = std.ascii.toUpper(char.*);
    }
    return .{ .string = result };
}

fn lowerOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value != .string) return args.env.failFmt(.type_mismatch, "'lower' expects a string, got {s}", .{value.typeName()});
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
        return args.env.failFmt(.type_mismatch, "'replace' expects string arguments (pattern, replacement, target), got {s}, {s}, {s}", .{ pattern_val.typeName(), replacement_val.typeName(), target_val.typeName() });

    const pattern = pattern_val.string;
    const replacement = replacement_val.string;
    const target = target_val.string;
    const alloc = args.env.allocator;

    if (pattern.len == 0) return .{ .string = target };

    var result = std.ArrayListUnmanaged(u8).empty;
    var remaining = target;
    while (std.mem.indexOf(u8, remaining, pattern)) |idx| {
        try helpers.checkStringLength(args.env, result.items.len + idx + replacement.len);
        try result.appendSlice(alloc, remaining[0..idx]);
        try result.appendSlice(alloc, replacement);
        remaining = remaining[idx + pattern.len ..];
    }
    try helpers.checkStringLength(args.env, result.items.len + remaining.len);
    try result.appendSlice(alloc, remaining);
    return .{ .string = result.items };
}

fn formatOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const template_val = try args.at(0).resolve();
    if (template_val != .string) return args.env.failFmt(.type_mismatch, "'format' expects a string template as first argument, got {s}", .{template_val.typeName()});

    const template = template_val.string;
    const alloc = args.env.allocator;
    var result = std.ArrayListUnmanaged(u8).empty;

    var remaining = template;
    var arg_index: usize = 1;
    while (std.mem.indexOf(u8, remaining, "<>")) |idx| {
        try helpers.checkStringLength(args.env, result.items.len + idx);
        try result.appendSlice(alloc, remaining[0..idx]);
        if (arg_index < args.count()) {
            const arg_val = try args.at(arg_index).get();
            if (arg_val) |value| {
                var buf: [256]u8 = undefined;
                const str = try helpers.getString(args.env, "format", value, &buf);

                try helpers.checkStringLength(args.env, result.items.len + str.len);
                try result.appendSlice(alloc, str);
            }
            arg_index += 1;
        }
        remaining = remaining[idx + 2 ..];
    }
    try helpers.checkStringLength(args.env, result.items.len + remaining.len);
    try result.appendSlice(alloc, remaining);
    return .{ .string = result.items };
}


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
            const needle_str = try helpers.getString(args.env, "in", needle, &needle_buf);

            if (std.mem.indexOf(u8, haystack_str, needle_str) != null) return needle;
            return null;
        },
        .list => |items| {
            for (items) |item| {
                if (item != null and try needle.eql(item.?, args.env.allocator)) return needle;
            }
            return null;
        },
        else => args.env.failFmt(.type_mismatch, "'in' expects a string or list as second argument, got {s}", .{haystack.typeName()}),
    };
}

fn findOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const needle = try args.at(0).resolve();
    const haystack = try args.at(1).resolve();
    return switch (haystack) {
        .string => |haystack_str| {
            var needle_buf: [256]u8 = undefined;
            const needle_str = try helpers.getString(args.env, "find", needle, &needle_buf);
            const index = std.mem.indexOf(u8, haystack_str, needle_str) orelse return null;
            return .{ .int = @intCast(index) };
        },
        .list => |items| {
            for (items, 0..) |item, i| {
                if (item != null and try needle.eql(item.?, args.env.allocator)) return .{ .int = @intCast(i) };
            }
            return null;
        },
        else => args.env.failFmt(.type_mismatch, "'find' expects a string or list as second argument, got {s}", .{haystack.typeName()}),
    };
}


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

test "string: chars splits to single-char strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "chars \"abc\"");
    const list = result.?.list;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("a", list[0].?.string);
    try std.testing.expectEqualStrings("b", list[1].?.string);
    try std.testing.expectEqualStrings("c", list[2].?.string);
}

test "string: chars on empty string returns empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "chars \"\"");
    try std.testing.expectEqual(@as(usize, 0), result.?.list.len);
}

test "string: lines splits on newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "lines \"a\\nb\\nc\"");
    const list = result.?.list;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("a", list[0].?.string);
    try std.testing.expectEqualStrings("b", list[1].?.string);
    try std.testing.expectEqualStrings("c", list[2].?.string);
}

test "string: lines strips trailing CR (CRLF input)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "lines \"a\\r\\nb\\r\\nc\"");
    const list = result.?.list;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("a", list[0].?.string);
    try std.testing.expectEqualStrings("b", list[1].?.string);
    try std.testing.expectEqualStrings("c", list[2].?.string);
}

test "string: lines on empty string returns empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "lines \"\"");
    try std.testing.expectEqual(@as(usize, 0), result.?.list.len);
}

test "string: lines with trailing newline doesn't produce phantom empty line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "lines \"a\\nb\\n\"");
    const list = result.?.list;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a", list[0].?.string);
    try std.testing.expectEqualStrings("b", list[1].?.string);
}

test "string: chars wrong arity fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "chars \"a\" \"b\"");
    try std.testing.expectError(error.RuntimeError, result);
}

test "string: lines on non-string fails with type_mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "lines 42");
    try std.testing.expectError(error.RuntimeError, result);
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

