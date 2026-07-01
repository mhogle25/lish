const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");
const helpers = @import("helpers.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Thunk = exec.Thunk;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Param = exec.Param;
const Allocator = std.mem.Allocator;

const x_variadic = [_]Param{.{ .name = "x", .arity = .variadic }};
const start_end_step = [_]Param{ .{ .name = "start", .type = .int }, .{ .name = "end", .type = .int }, .{ .name = "step", .type = .int, .arity = .optional } };
const list_param = [_]Param{.{ .name = "list", .type = .list }};
const collection_param = [_]Param{.{ .name = "collection", .type = .collection }};
const n_collection = [_]Param{ .{ .name = "n", .type = .int }, .{ .name = "collection", .type = .collection } };

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "lists");

    // List construction / traversal
    try g.register("list", Operation.fromFn(listOp, .{
        .signature = .{ .params = &x_variadic, .returns = .list },
        .description = "Collect all arguments into a list.",
    }));

    try g.register("flat", Operation.fromFn(flatOp, .{
        .signature = .{ .params = &x_variadic, .returns = .list },
        .description = "Concatenate arguments into one list, splicing in one level of nested lists.",
    }));

    try g.register("flatten", Operation.fromFn(flattenOp, .{
        .signature = .{ .params = &x_variadic, .returns = .list },
        .description = "Concatenate arguments into one list, splicing nested lists at any depth.",
    }));

    try g.register("range", Operation.fromFn(rangeOp, .{
        .signature = .{ .params = &start_end_step, .returns = .list },
        .description = "List of integers from start to end inclusive, with an optional step.",
    }));

    try g.register("until", Operation.fromFn(untilOp, .{
        .signature = .{ .params = &start_end_step, .returns = .list },
        .description = "List of integers from start up to but excluding end, with an optional step.",
    }));

    try g.register("sort", Operation.fromFn(sortOp, .{
        .signature = .{ .params = &list_param, .returns = .list },
        .description = "Sort a list in ascending order.",
    }));

    try g.register("sortby", Operation.fromFn(sortbyOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "name", .role = .binding }, Param{ .name = "list", .type = .list }, Param{ .name = "body", .role = .body } }, .returns = .list },
        .description = "Sort a list ascending by the key the body computes for each element bound to name.",
    }));

    try g.register("sortwith", Operation.fromFn(sortwithOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "a", .role = .binding }, Param{ .name = "b", .role = .binding }, Param{ .name = "list", .type = .list }, Param{ .name = "body", .role = .body } }, .returns = .list },
        .description = "Sort a list using a comparator body that returns negative, zero, or positive for the pair bound to a and b.",
    }));

    try g.register("fillby", Operation.fromFn(fillbyOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "name", .role = .binding, .arity = .optional }, Param{ .name = "n", .type = .int }, Param{ .name = "body", .role = .body } }, .returns = .list },
        .description = "Build a list of n elements from the body; the 3-arg form binds the slot index to name.",
    }));

    // Collection access
    try g.register("length", Operation.fromFn(lengthOp, .{
        .signature = .{ .params = &collection_param, .returns = .int },
        .description = "Number of elements in a list or characters in a string.",
    }));

    try g.register("first", Operation.fromFn(firstOp, .{
        .signature = .{ .params = &collection_param, .returns = .{ .one_of = &.{ .any, .none } } },
        .description = "First element of a list, or first character of a string; else $none.",
    }));

    try g.register("last", Operation.fromFn(lastOp, .{
        .signature = .{ .params = &collection_param, .returns = .{ .one_of = &.{ .any, .none } } },
        .description = "Last element of a list, or last character of a string; else $none.",
    }));

    try g.register("rest", Operation.fromFn(restOp, .{
        .signature = .{ .params = &collection_param, .returns = .collection },
        .description = "A list without its first element, or a string without its first character.",
    }));

    try g.register("at", Operation.fromFn(atOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "index", .type = .int }, Param{ .name = "collection", .type = .collection } }, .returns = .{ .one_of = &.{ .any, .none } } },
        .description = "Element at the index in a list or string, else $none.",
    }));

    try g.register("reverse", Operation.fromFn(reverseOp, .{
        .signature = .{ .params = &collection_param, .returns = .collection },
        .description = "Reverse a list or string.",
    }));

    try g.register("take", Operation.fromFn(takeOp, .{
        .signature = .{ .params = &n_collection, .returns = .collection },
        .description = "First n elements of a list or characters of a string.",
    }));

    try g.register("drop", Operation.fromFn(dropOp, .{
        .signature = .{ .params = &n_collection, .returns = .collection },
        .description = "Collection with the first n elements or characters removed.",
    }));

    try g.register("slice", Operation.fromFn(sliceOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "start", .type = .int }, Param{ .name = "end", .type = .int }, Param{ .name = "collection", .type = .collection } }, .returns = .collection },
        .description = "Sub-range of a list or string from start up to but excluding end.",
    }));

    try g.register("zip", Operation.fromFn(zipOp, .{
        .signature = .{ .params = comptime &.{ Param{ .name = "a", .type = .list }, Param{ .name = "b", .type = .list } }, .returns = .list },
        .description = "Pair up two lists element-wise into a list of two-element lists, truncating to the shorter.",
    }));
}

fn listOp(args: Args) ExecError!?Value {
    try helpers.checkListLength(args, args.count());
    const items = try args.env.allocator.alloc(?Value, args.count());
    for (0..args.count()) |i| {
        items[i] = try args.at(i).get();
    }
    return .{ .list = items };
}

fn flatOp(args: Args) ExecError!?Value {
    var result = std.ArrayListUnmanaged(?Value).empty;
    for (0..args.count()) |i| {
        const maybe_value = try args.at(i).get();
        if (maybe_value) |value| {
            if (value == .list) {
                for (value.list) |item| {
                    try helpers.checkListLength(args, result.items.len + 1);
                    try result.append(args.env.allocator, item);
                }
            } else {
                try helpers.checkListLength(args, result.items.len + 1);
                try result.append(args.env.allocator, value);
            }
        } else {
            try helpers.checkListLength(args, result.items.len + 1);
            try result.append(args.env.allocator, null);
        }
    }
    return .{ .list = result.items };
}

fn lengthOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .list => |items| .{ .int = @intCast(items.len) },
        .string => |str| .{ .int = @intCast(str.len) },
        else => args.env.failFmt(.type_mismatch, "'length' expects a list or string, got {s}", .{value.typeName()}),
    };
}

fn firstOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .list => |items| if (items.len == 0) null else items[0],
        .string => |str| if (str.len == 0) null else .{ .string = str[0..1] },
        else => args.env.failFmt(.type_mismatch, "'first' expects a list or string, got {s}", .{value.typeName()}),
    };
}

fn restOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .list => |items| if (items.len <= 1) .{ .list = &.{} } else .{ .list = items[1..] },
        .string => |str| if (str.len <= 1) .{ .string = "" } else .{ .string = str[1..] },
        else => args.env.failFmt(.type_mismatch, "'rest' expects a list or string, got {s}", .{value.typeName()}),
    };
}

fn atOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const index_value = try args.at(0).resolve();
    const index = index_value.getI() catch return args.env.failFmt(.type_mismatch, "'at' expects an integer index, got {s}", .{index_value.typeName()});
    if (index < 0) return null;
    const collection = try args.at(1).resolve();
    return switch (collection) {
        .list => |items| {
            if (index >= @as(i64, @intCast(items.len))) return null;
            return items[@intCast(index)];
        },
        .string => |str| {
            if (index >= @as(i64, @intCast(str.len))) return null;
            const idx: usize = @intCast(index);
            return .{ .string = str[idx .. idx + 1] };
        },
        else => args.env.failFmt(.type_mismatch, "'at' expects a list or string, got {s}", .{collection.typeName()}),
    };
}

fn reverseOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    const alloc = args.env.allocator;
    return switch (value) {
        .list => |items| {
            const reversed = try alloc.alloc(?Value, items.len);
            for (items, 0..) |item, i| {
                reversed[items.len - 1 - i] = item;
            }
            return .{ .list = reversed };
        },
        .string => |str| {
            const reversed = try alloc.alloc(u8, str.len);
            for (str, 0..) |char, i| {
                reversed[str.len - 1 - i] = char;
            }
            return .{ .string = reversed };
        },
        else => args.env.failFmt(.type_mismatch, "'reverse' expects a list or string, got {s}", .{value.typeName()}),
    };
}

fn rangeOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 2 or count > 3) return args.env.fail(.arity_mismatch, "'range' expects 2 or 3 arguments");

    const start_value = try args.at(0).resolve();
    const end_value = try args.at(1).resolve();
    const start = start_value.getI() catch return args.env.fail(.type_mismatch, "'range' expects integer arguments");
    const end = end_value.getI() catch return args.env.fail(.type_mismatch, "'range' expects integer arguments");

    var step: i64 = if (start <= end) 1 else -1;
    if (count == 3) {
        const step_value = try args.at(2).resolve();
        step = step_value.getI() catch return args.env.fail(.type_mismatch, "'range' expects an integer step");
        if (step == 0) return args.env.fail(.arithmetic, "'range' step cannot be zero");
    }

    const alloc = args.env.allocator;
    var items = std.ArrayListUnmanaged(?Value).empty;

    var current = start;
    while (true) {
        const done = if (step > 0) current > end else current < end;
        if (done) break;
        try helpers.checkListLength(args, items.items.len + 1);
        try items.append(alloc, .{ .int = current });

        // Stop rather than trap when the next step would overflow past the endpoint.
        current = std.math.add(i64, current, step) catch break;
    }

    return .{ .list = items.items };
}

fn untilOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 2 or count > 3) return args.env.fail(.arity_mismatch, "'until' expects 2 or 3 arguments");

    const start_value = try args.at(0).resolve();
    const end_value = try args.at(1).resolve();
    const start = start_value.getI() catch return args.env.fail(.type_mismatch, "'until' expects integer arguments");
    const end = end_value.getI() catch return args.env.fail(.type_mismatch, "'until' expects integer arguments");

    var step: i64 = if (start <= end) 1 else -1;
    if (count == 3) {
        const step_value = try args.at(2).resolve();
        step = step_value.getI() catch return args.env.fail(.type_mismatch, "'until' expects an integer step");
        if (step == 0) return args.env.fail(.arithmetic, "'until' step cannot be zero");
    }

    const alloc = args.env.allocator;
    var items = std.ArrayListUnmanaged(?Value).empty;

    var current = start;
    while (true) {
        const done = if (step > 0) current >= end else current <= end;
        if (done) break;
        try helpers.checkListLength(args, items.items.len + 1);
        try items.append(alloc, .{ .int = current });

        // Stop rather than trap when the next step would overflow past the i64 bound.
        current = std.math.add(i64, current, step) catch break;
    }

    return .{ .list = items.items };
}

fn lastOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .list => |items| if (items.len == 0) null else items[items.len - 1],
        .string => |str| if (str.len == 0) null else .{ .string = str[str.len - 1 ..] },
        else => args.env.failFmt(.type_mismatch, "'last' expects a list or string, got {s}", .{value.typeName()}),
    };
}

fn takeOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const count_val = try args.at(0).resolve();
    const take_n = count_val.getI() catch return args.env.failFmt(.type_mismatch, "'take' expects an integer count, got {s}", .{count_val.typeName()});
    if (take_n < 0) return args.env.fail(.invalid_argument, "'take' count cannot be negative");
    const value = try args.at(1).resolve();
    const take_count: usize = @intCast(take_n);
    return switch (value) {
        .list => |items| .{ .list = items[0..@min(take_count, items.len)] },
        .string => |str| .{ .string = str[0..@min(take_count, str.len)] },
        else => args.env.failFmt(.type_mismatch, "'take' expects a list or string, got {s}", .{value.typeName()}),
    };
}

fn dropOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const count_val = try args.at(0).resolve();
    const drop_n = count_val.getI() catch return args.env.failFmt(.type_mismatch, "'drop' expects an integer count, got {s}", .{count_val.typeName()});
    if (drop_n < 0) return args.env.fail(.invalid_argument, "'drop' count cannot be negative");
    const value = try args.at(1).resolve();
    const drop_count: usize = @intCast(drop_n);
    return switch (value) {
        .list => |items| .{ .list = if (drop_count >= items.len) &.{} else items[drop_count..] },
        .string => |str| .{ .string = if (drop_count >= str.len) "" else str[drop_count..] },
        else => args.env.failFmt(.type_mismatch, "'drop' expects a list or string, got {s}", .{value.typeName()}),
    };
}

fn sliceOp(args: Args) ExecError!?Value {
    try args.expectCount(3);
    const start_i = try args.at(0).resolveInt();
    const end_i = try args.at(1).resolveInt();
    if (start_i < 0) return args.env.fail(.invalid_argument, "'slice' start cannot be negative");
    if (end_i < start_i) return args.env.fail(.invalid_argument, "'slice' end cannot be before start");
    const collection = try args.at(2).resolve();
    const start: usize = @intCast(start_i);
    const end: usize = @intCast(end_i);
    return switch (collection) {
        .list => |items| .{ .list = items[@min(start, items.len)..@min(end, items.len)] },
        .string => |str| .{ .string = str[@min(start, str.len)..@min(end, str.len)] },
        else => args.env.failFmt(.type_mismatch, "'slice' expects a list or string, got {s}", .{collection.typeName()}),
    };
}

fn zipOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const left = try args.at(0).resolveList();
    const right = try args.at(1).resolveList();

    const alloc = args.env.allocator;
    const len = @min(left.len, right.len);
    try helpers.checkListLength(args, len);
    const pairs = try alloc.alloc(?Value, len);
    for (0..len) |i| {
        const pair = try alloc.alloc(?Value, 2);
        pair[0] = left[i];
        pair[1] = right[i];
        pairs[i] = .{ .list = pair };
    }
    return .{ .list = pairs };
}

fn flattenInto(maybe_value: ?Value, result: *std.ArrayListUnmanaged(?Value), alloc: Allocator) Allocator.Error!void {
    const value = maybe_value orelse {
        try result.append(alloc, null);
        return;
    };
    if (value != .list) {
        try result.append(alloc, value);
        return;
    }
    for (value.list) |item| {
        try flattenInto(item, result, alloc);
    }
}

fn flattenOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    var result = std.ArrayListUnmanaged(?Value).empty;
    for (0..args.count()) |i| {
        const maybe_value = try args.at(i).get();
        try flattenInto(maybe_value, &result, args.env.allocator);
        try helpers.checkListLength(args, result.items.len);
    }
    return .{ .list = result.items };
}

fn sortOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const list = try args.at(0).resolveList();
    try helpers.checkListLength(args, list.len);
    const alloc = args.env.allocator;
    const sorted = try alloc.dupe(?Value, list);
    std.sort.pdq(?Value, sorted, {}, helpers.naturalLessThan);
    return .{ .list = sorted };
}

fn sortbyOp(args: Args) ExecError!?Value {
    try args.expectCount(3);

    var sort_scope = exec.Scope{ .parent = args.scope };
    defer sort_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    const list = try args.at(1).resolveList();
    try helpers.checkListLength(args, list.len);
    const body = args.items[2];
    const alloc = args.env.allocator;

    // Extract keys: evaluate body once per element with name bound.
    const keys = try alloc.alloc(?Value, list.len);
    for (list, 0..) |item, i| {
        sort_scope.inline_count = 0;
        try sort_scope.setValue(alloc, name, item);
        keys[i] = try body.proc(args.env, &sort_scope);
    }

    // Sort indices by their associated keys.
    const indices = try alloc.alloc(usize, list.len);
    for (indices, 0..) |*idx, i| idx.* = i;
    const KeyCtx = struct { keys: []const ?Value };
    std.sort.pdq(usize, indices, KeyCtx{ .keys = keys }, struct {
        fn lessThan(ctx: KeyCtx, a: usize, b: usize) bool {
            return helpers.naturalLessThan({}, ctx.keys[a], ctx.keys[b]);
        }
    }.lessThan);

    // Reorder original list using sorted index permutation.
    const sorted = try alloc.alloc(?Value, list.len);
    for (sorted, 0..) |*slot, i| slot.* = list[indices[i]];

    return .{ .list = sorted };
}

const SortWithContext = struct {
    env:        *exec.Env,
    scope:      *exec.Scope,
    a_name:     []const u8,
    b_name:     []const u8,
    body:       *const Thunk,
    sticky_err: ?ExecError,
};

fn sortwithLessThan(ctx: *SortWithContext, left: ?Value, right: ?Value) bool {
    if (ctx.sticky_err != null) return false;

    ctx.scope.inline_count = 0;
    ctx.scope.setValue(ctx.env.allocator, ctx.a_name, left) catch |err| {
        ctx.sticky_err = err;
        return false;
    };
    ctx.scope.setValue(ctx.env.allocator, ctx.b_name, right) catch |err| {
        ctx.sticky_err = err;
        return false;
    };

    const result = ctx.body.proc(ctx.env, ctx.scope) catch |err| {
        ctx.sticky_err = err;
        return false;
    };

    if (result) |value| {
        if (value == .int) return value.int < 0;
        if (value == .float) return value.float < 0;
    }
    return false;
}

fn sortwithOp(args: Args) ExecError!?Value {
    try args.expectCount(4);

    var sort_scope = exec.Scope{ .parent = args.scope };
    defer sort_scope.deinit(args.env.allocator);

    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const raw_a  = try args.at(0).resolveString(&a_buf);
    const raw_b  = try args.at(1).resolveString(&b_buf);
    const a_name = try args.env.allocator.dupe(u8, raw_a);
    const b_name = try args.env.allocator.dupe(u8, raw_b);

    const list = try args.at(2).resolveList();
    try helpers.checkListLength(args, list.len);

    const sorted = try args.env.allocator.dupe(?Value, list);
    var ctx = SortWithContext{
        .env        = args.env,
        .scope      = &sort_scope,
        .a_name     = a_name,
        .b_name     = b_name,
        .body       = args.items[3],
        .sticky_err = null,
    };

    std.sort.pdq(?Value, sorted, &ctx, sortwithLessThan);

    if (ctx.sticky_err) |err| return err;
    return .{ .list = sorted };
}

fn fillbyOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count != 2 and count != 3) return args.env.fail(.arity_mismatch, "'fillby' expects 2 or 3 arguments");

    const alloc = args.env.allocator;

    if (count == 2) {
        const n_value = try args.at(0).resolve();
        const n = n_value.getI() catch return args.env.failFmt(.type_mismatch, "'fillby' expects an integer count, got {s}", .{n_value.typeName()});
        if (n < 0) return args.env.fail(.invalid_argument, "'fillby' count cannot be negative");

        try helpers.checkListLength(args, @intCast(n));
        const items = try alloc.alloc(?Value, @intCast(n));
        for (items) |*slot| slot.* = try args.at(1).get();
        return .{ .list = items };
    }

    // 3-arg form: name, count, body, name is bound to the slot index per iteration.
    var iter_scope = exec.Scope{ .parent = args.scope };
    defer iter_scope.deinit(alloc);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try alloc.dupe(u8, raw_name);

    const n_value = try args.at(1).resolve();
    const n = n_value.getI() catch return args.env.failFmt(.type_mismatch, "'fillby' expects an integer count, got {s}", .{n_value.typeName()});
    if (n < 0) return args.env.fail(.invalid_argument, "'fillby' count cannot be negative");

    try helpers.checkListLength(args, @intCast(n));
    const body  = args.items[2];
    const items = try alloc.alloc(?Value, @intCast(n));
    for (items, 0..) |*slot, idx| {
        iter_scope.inline_count = 0;
        try iter_scope.setValue(alloc, name, .{ .int = @intCast(idx) });
        slot.* = try body.proc(args.env, &iter_scope);
    }
    return .{ .list = items };
}


const testing = @import("testing.zig");

test "list: construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "list 1 2 3");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 2), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 3), items[2].?.int);
}

test "list: length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length [1 2 3]");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "list: flat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "flat 1 [2 3] 4");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 4), items.len);
}

test "list: first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first [10 20 30]");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "list: first on empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first []");
    try std.testing.expect(result == null);
}

test "list: rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (rest [10 20 30])");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "list: rest on single element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (rest [10])");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "list: rest on empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (rest [])");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "list: at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "at 1 [10 20 30]");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "list: at out of bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "at 5 [10 20 30]");
    try std.testing.expect(result == null);
}

test "list: at negative index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "at (- 0 1) [10 20 30]");
    try std.testing.expect(result == null);
}

test "list: reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first (reverse [10 20 30])");
    try std.testing.expectEqual(@as(i64, 30), result.?.int);
}

test "list: range inclusive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (range 1 5)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "list: range with step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "at 2 (range 0 10 3)");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "list: range descending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first (range 5 1)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "list: range start > end returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (range 5 1 1)");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "list: until exclusive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (until 1 5)");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "list: until same start and end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (until 5 5)");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "collection: last list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "last [10 20 30]");
    try std.testing.expectEqual(@as(i64, 30), result.?.int);
}

test "collection: last empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "last []");
    try std.testing.expect(result == null);
}

test "collection: last string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "last \"hello\"");
    try std.testing.expectEqualStrings("o", result.?.string);
}

test "collection: take" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (take 2 [10 20 30])");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "collection: take more than length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (take 10 [1 2 3])");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "collection: drop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first (drop 2 [10 20 30])");
    try std.testing.expectEqual(@as(i64, 30), result.?.int);
}

test "collection: drop more than length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (drop 10 [1 2 3])");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "collection: zip equal length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (zip [1 2 3] [4 5 6])");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "collection: zip truncates to shorter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (zip [1 2] [4 5 6 7])");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "collection: zip pair contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "at 0 (at 0 (zip [10 20] [30 40]))");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "collection: flatten deep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (flatten [[1 2] [3 [4 5]]])");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "collection: flatten variadic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (flatten [1 2] [3 4])");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "collection: flatten vs flat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // flat is shallow, inner list [4 5] stays as a list element
    const flat_result = try testing.evalWithBuiltins(arena.allocator(), "length (flat [1 2] [3 [4 5]])");
    try std.testing.expectEqual(@as(i64, 4), flat_result.?.int);
    // flatten is deep, recurses into [4 5]
    const flatten_result = try testing.evalWithBuiltins(arena.allocator(), "length (flatten [1 2] [3 [4 5]])");
    try std.testing.expectEqual(@as(i64, 5), flatten_result.?.int);
}

test "collection: sort integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first (sort [3 1 2])");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "collection: sort strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "first (sort [\"banana\" \"apple\" \"cherry\"])");
    try std.testing.expectEqualStrings("apple", result.?.string);
}

test "sortby: key-based ascending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Sort by the value itself (identity key), natural ascending order.
    const result = try testing.evalWithBuiltins(arena.allocator(), "sortby x [3 1 2] :x");
    const items = result.?.list;
    try std.testing.expectEqual(@as(i64, 1), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 2), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 3), items[2].?.int);
}

test "sortby: by computed key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Sort by negation: yields descending order of originals.
    const result = try testing.evalWithBuiltins(arena.allocator(), "sortby x [1 3 2] (- 0 :x)");
    const items = result.?.list;
    try std.testing.expectEqual(@as(i64, 3), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 2), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 1), items[2].?.int);
}

test "sortby: empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sortby x [] :x");
    try std.testing.expectEqual(@as(usize, 0), result.?.list.len);
}

test "sortby: wrong arg count fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "sortby x [1 2 3]");
    try std.testing.expectError(error.RuntimeError, result);
}

test "sortwith: ascending via compare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "sortwith a b [3 1 4 1 5 9 2 6] (compare :a :b)");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 8), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 1), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 9), items[7].?.int);
}

test "sortwith: descending via reversed compare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "sortwith a b [3 1 2] (compare :b :a)");
    const items = result.?.list;
    try std.testing.expectEqual(@as(i64, 3), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 2), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 1), items[2].?.int);
}

test "sortwith: multi-criteria via or-chain with isnt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // List of [rank, name] pairs encoded as nested lists; sort by rank, then by name.
    // Using primitive ints for both criteria. Pairs as ints: tens digit = rank, units = name.
    // 21 (rank=2,name=1), 13 (rank=1,name=3), 11 (rank=1,name=1), 22 (rank=2,name=2)
    // Sort by tens then units: 11, 13, 21, 22
    const result = try testing.evalWithBuiltins(arena.allocator(),
        \\sortwith a b [21 13 11 22]
        \\    (or (isnt (compare (/ :a 10) (/ :b 10)) 0)
        \\        (compare (% :a 10) (% :b 10)))
    );
    const items = result.?.list;
    try std.testing.expectEqual(@as(i64, 11), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 13), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 21), items[2].?.int);
    try std.testing.expectEqual(@as(i64, 22), items[3].?.int);
}

test "sortwith: empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "sortwith a b [] (compare :a :b)");
    try std.testing.expectEqual(@as(usize, 0), result.?.list.len);
}

test "sortwith: wrong arg count fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "sortwith a b [1 2 3]");
    try std.testing.expectError(error.RuntimeError, result);
}

test "list: fillby length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "fillby 5 42");
    try std.testing.expectEqual(@as(usize, 5), result.?.list.len);
}

test "fillby: with index binding produces squares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "fillby i 5 (* :i :i)");
    const items = result.?.list;
    try std.testing.expectEqual(@as(i64, 0), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 1), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 4), items[2].?.int);
    try std.testing.expectEqual(@as(i64, 9), items[3].?.int);
    try std.testing.expectEqual(@as(i64, 16), items[4].?.int);
}

test "slice: list middle range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (slice 1 4 [10 20 30 40 50])");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "slice: string range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "slice 0 5 \"hello world\"");
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "slice: clamps end past length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "slice 2 99 \"abcdef\"");
    try std.testing.expectEqualStrings("cdef", result.?.string);
}

test "slice: empty when start equals end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "length (slice 2 2 [1 2 3])");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "slice: end before start errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.RuntimeError, testing.evalWithBuiltins(arena.allocator(), "slice 5 2 [1 2 3 4 5]"));
}

