const std = @import("std");

/// Nesting depth at which writeTo/format stop descending and emit `[ ... ]`.
pub const MAX_DISPLAY_DEPTH: usize = 1000;

/// The core value type for the shell language.
/// Represents one of four types: string, integer, float, or list.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    list: []const ?Value,

    pub fn isNumber(self: Value) bool {
        return self == .int or self == .float;
    }

    /// A human-readable name for this value's type, for error messages
    /// (`string`, `int`, `float`, `list`).
    pub fn typeName(self: Value) []const u8 {
        return @tagName(self);
    }

    /// The type name of an optional value, naming the absent case `none`. Use
    /// when reporting what an op received in a slot that may hold no value.
    pub fn typeNameOpt(maybe: ?Value) []const u8 {
        return if (maybe) |value| value.typeName() else NONE_ID;
    }

    pub fn getI(self: Value) error{TypeMismatch}!i64 {
        return switch (self) {
            .int   => |int_val| int_val,
            .float => |float_val| floatToInt(float_val),
            else   => error.TypeMismatch,
        };
    }

    pub fn getF(self: Value) error{TypeMismatch}!f64 {
        return switch (self) {
            .float => |float_val| float_val,
            .int   => |int_val| @floatFromInt(int_val),
            else   => error.TypeMismatch,
        };
    }

    pub fn getS(self: Value, buf: []u8) ![]const u8 {
        return switch (self) {
            .string => |str| str,
            .int    => |int_val| try std.fmt.bufPrint(buf, "{d}", .{int_val}),
            .float  => |float_val| try std.fmt.bufPrint(buf, "{d}", .{float_val}),
            .list   => {
                var writer = std.Io.Writer.fixed(buf);
                try self.format(&writer);
                return writer.buffered();
            },
        };
    }

    pub fn getL(self: Value) error{TypeMismatch}![]const ?Value {
        return switch (self) {
            .list => |items| items,
            else  => error.TypeMismatch,
        };
    }

    fn writeToDepth(self: Value, writer: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
        switch (self) {
            .string => |str| try writer.writeAll(str),
            .int    => |int_val| try writer.print("{d}", .{int_val}),
            .float  => |float_val| try writer.print("{d}", .{float_val}),
            .list   => |items| {
                if (depth >= MAX_DISPLAY_DEPTH) {
                    try writer.writeAll("[ ... ]");
                    return;
                }

                try writer.writeAll("[ ");
                for (items, 0..) |item, i| {
                    if (i > 0) {
                        try writer.writeAll(", ");
                    }

                    if (item) |inner_val| {
                        try inner_val.writeToDepth(writer, depth + 1);
                    } else {
                        try writer.writeAll(NONE_ID);
                    }
                }

                try writer.writeAll(" ]");
            },
        }
    }

    /// Deep structural equality. Scalar and flat-list comparisons never
    /// allocate; nested lists are walked with a worklist from `allocator`,
    /// so nesting depth is unbounded (no native recursion to overflow).
    pub fn eql(lhs: Value, rhs: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!bool {
        switch (shallowEql(lhs, rhs)) {
            .equal     => return true,
            .not_equal => return false,
            .descend   => {},
        }

        var pending = std.ArrayListUnmanaged(ListPair).empty;
        defer pending.deinit(allocator);

        var current: ListPair = .{ .lhs = lhs.list, .rhs = rhs.list };
        while (true) {
            for (current.lhs, current.rhs) |lhs_item, rhs_item| {
                if ((lhs_item == null) != (rhs_item == null)) return false;
                const lhs_inner = lhs_item orelse continue;

                switch (shallowEql(lhs_inner, rhs_item.?)) {
                    .equal     => {},
                    .not_equal => return false,
                    .descend   => try pending.append(allocator, .{ .lhs = lhs_inner.list, .rhs = rhs_item.?.list }),
                }
            }

            current = pending.pop() orelse return true;
        }
    }

    /// Deep-copy into `allocator` so the value outlives the arena it was produced
    /// in. Scalars pass through by value; strings and lists are copied. Nested
    /// lists are walked with a worklist, so nesting depth is unbounded.
    /// Use this to keep a result past the next session execute().
    pub fn dupe(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        switch (self) {
            .int, .float => return self,
            .string => |str| return .{ .string = try allocator.dupe(u8, str) },
            .list => {},
        }

        var pending = std.ArrayListUnmanaged(CopyTask).empty;
        defer pending.deinit(allocator);

        const root = try allocator.alloc(?Value, self.list.len);
        var current: CopyTask = .{ .source = self.list, .destination = root };
        while (true) {
            for (current.source, current.destination) |item, *slot| {
                const inner = item orelse {
                    slot.* = null;
                    continue;
                };

                switch (inner) {
                    .int, .float => slot.* = inner,
                    .string => |str| slot.* = .{ .string = try allocator.dupe(u8, str) },
                    .list => |items| {
                        const copy = try allocator.alloc(?Value, items.len);
                        slot.* = .{ .list = copy };
                        try pending.append(allocator, .{ .source = items, .destination = copy });
                    },
                }
            }

            current = pending.pop() orelse break;
        }

        return .{ .list = root };
    }

    /// Render for display. Lists nested past MAX_DISPLAY_DEPTH render as `[ ... ]`.
    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.writeToDepth(writer, 0);
    }
};

/// One shallow comparison step for eql: scalars and strings settle immediately;
/// two lists of equal length need their elements walked.
const ShallowEql = enum { equal, not_equal, descend };

fn shallowEql(lhs: Value, rhs: Value) ShallowEql {
    const Tag = std.meta.Tag(Value);
    const lhs_tag: Tag = lhs;
    const rhs_tag: Tag = rhs;
    if (lhs_tag != rhs_tag) return .not_equal;

    return switch (lhs) {
        .string => |lhs_str| if (std.mem.eql(u8, lhs_str, rhs.string)) .equal else .not_equal,
        .int    => |lhs_int| if (lhs_int == rhs.int) .equal else .not_equal,
        .float  => |lhs_float| if (lhs_float == rhs.float) .equal else .not_equal,
        .list   => |lhs_items| if (lhs_items.len == rhs.list.len) .descend else .not_equal,
    };
}

const ListPair = struct {
    lhs: []const ?Value,
    rhs: []const ?Value,
};

const CopyTask = struct {
    source:      []const ?Value,
    destination: []?Value,
};

/// The string identifier for the null/absent value in lish.
pub const NONE_ID = "none";

/// Truthy/falsy convention: "some" is truthy, null is falsy.
pub const SOME: Value = .{ .string = "some" };
pub const NONE: ?Value = null;

pub fn some() ?Value {
    return SOME;
}

pub fn toCondition(condition: bool) ?Value {
    return if (condition) some() else NONE;
}

/// Saturating f64 -> i64: NaN -> 0, out-of-range clamps to the i64 bounds. A raw
/// `@intFromFloat` would trap on those, and a coercion must never abort the host.
pub fn floatToInt(float_val: f64) i64 {
    if (std.math.isNan(float_val)) return 0;

    const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
    if (float_val >= max_f) return std.math.maxInt(i64);
    if (float_val <= min_f) return std.math.minInt(i64);

    return @intFromFloat(float_val);
}

/// The type vocabulary an operation declares in its `Signature` (parameter
/// types and return type), authored as structured data instead of free-form
/// strings. `render` is the single source of truth for how each form is
/// spelled, so the conventions can't drift op-to-op.
///
/// The concrete forms mirror `Value` (`string`/`int`/`float`/`list`); `number`
/// is the `int|float` shorthand; `collection` is the `string|list` (iterable)
/// shorthand; `any` is any present value; `some`/`none` are the `$some`/`$none`
/// sentinels; `literal` is one concrete string value (e.g. `"ortho"`); `one_of`
/// is an arbitrary union, and since it carries `literal` members too, a union
/// can mix generic types with literals (`string|"ortho"`).
///
/// This is a description vocabulary for signatures, NOT a runtime type system:
/// nothing here is enforced; it guides the programmer and feeds tooling.
pub const LishType = union(enum) {
    any,
    string,
    int,
    float,
    list,
    number,
    collection,
    some,
    none,
    // TODO: `literal` is string-only. Add numeric literals (int/float, e.g. `3`,
    // `3.555`) when a concrete "must be 0|1|2"-style op appears: either sibling
    // variants (`int_literal: i64`, `float_literal: f64`) or by promoting
    // `literal` to a typed union. Render numbers bare (unquoted) so they read as
    // values distinct from the quoted strings.
    literal: []const u8,
    // TODO: list shapes (element type, e.g. `list of int`; or tuple shapes like
    // `[int, string]`) when an op needs them. `list` stays generic until then.
    one_of: []const LishType,

    /// A union of generic members plus string literals, so a signature can DERIVE
    /// its literal-set from the op's own source (e.g. `StaticStringMap.keys()`).
    pub fn oneOf(comptime types: []const LishType, comptime names: []const []const u8) LishType {
        return .{ .one_of = comptime blk: {
            var members: [types.len + names.len]LishType = undefined;
            for (types, 0..) |t, i| members[i] = t;
            for (names, 0..) |name, i| members[types.len + i] = .{ .literal = name };
            const frozen = members;
            break :blk &frozen;
        } };
    }

    /// Spell the type in display form. The ONLY place type names are written,
    /// so changing a convention (e.g. the `$` sentinel sigil) is a one-line edit.
    pub fn render(self: LishType, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .some => try writer.writeAll("$some"),
            .none => try writer.writeAll("$none"),
            .literal => |value_str| {
                try writer.writeByte('"');
                try writer.writeAll(value_str);
                try writer.writeByte('"');
            },
            .one_of => |members| for (members, 0..) |member, i| {
                if (i > 0) try writer.writeByte('|');
                try member.render(writer);
            },
            else => try writer.writeAll(@tagName(self)),
        }
    }
};

test "LishType.render spells a union mixing generic types and quoted literals" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const t = LishType{ .one_of = &.{ .number, .{ .literal = "slow" }, .{ .literal = "fast" }, .none } };
    try t.render(&writer);
    try std.testing.expectEqualStrings("number|\"slow\"|\"fast\"|$none", writer.buffered());
}

test "LishType.oneOf derives literal members from a name list" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const t = LishType.oneOf(&.{.number}, &.{ "slow", "fast" });
    try t.render(&writer);
    try std.testing.expectEqualStrings("number|\"slow\"|\"fast\"", writer.buffered());
}

test "value int" {
    const val: Value = .{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), try val.getI());
    try std.testing.expectEqual(@as(f64, 42.0), try val.getF());
}

test "value float" {
    const val: Value = .{ .float = 3.14 };
    try std.testing.expectEqual(@as(f64, 3.14), try val.getF());
    try std.testing.expectEqual(@as(i64, 3), try val.getI());
}

test "value string" {
    const val: Value = .{ .string = "hello" };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try val.getS(&buf));
    try std.testing.expectError(error.TypeMismatch, val.getI());
}

test "value list" {
    const items = [_]?Value{
        .{ .int = 1 },
        .{ .int = 2 },
        null,
    };
    const val: Value = .{ .list = &items };
    const list = try val.getL();
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(i64, 1), list[0].?.int);
    try std.testing.expectEqual(@as(i64, 2), list[1].?.int);
    try std.testing.expect(list[2] == null);
}

test "value equality" {
    const first: Value = .{ .int = 5 };
    const same: Value = .{ .int = 5 };
    const different: Value = .{ .int = 6 };
    const different_type: Value = .{ .string = "5" };

    try std.testing.expect(try first.eql(same, std.testing.allocator));
    try std.testing.expect(!(try first.eql(different, std.testing.allocator)));
    try std.testing.expect(!(try first.eql(different_type, std.testing.allocator)));
}

test "condition" {
    try std.testing.expect(toCondition(true) != null);
    try std.testing.expect(toCondition(false) == null);
}

test "floatToInt saturates and never traps on non-finite or out-of-range input" {
    // In range: ordinary truncation toward zero.
    try std.testing.expectEqual(@as(i64, 3), floatToInt(3.7));
    try std.testing.expectEqual(@as(i64, -3), floatToInt(-3.7));
    // Non-finite and out-of-range saturate instead of a @intFromFloat trap.
    try std.testing.expectEqual(std.math.maxInt(i64), floatToInt(std.math.inf(f64)));
    try std.testing.expectEqual(std.math.minInt(i64), floatToInt(-std.math.inf(f64)));
    try std.testing.expectEqual(std.math.maxInt(i64), floatToInt(1e300));
    try std.testing.expectEqual(std.math.minInt(i64), floatToInt(-1e300));
    try std.testing.expectEqual(@as(i64, 0), floatToInt(std.math.nan(f64)));
}

test "value dupe survives its source arena" {
    // Build a string + nested list in a scratch arena that we then throw away.
    var source = std.heap.ArenaAllocator.init(std.testing.allocator);
    const scratch = source.allocator();

    const inner = try scratch.alloc(?Value, 2);
    inner[0] = .{ .string = try scratch.dupe(u8, "hi") };
    inner[1] = null;
    const original: Value = .{ .list = &[_]?Value{
        .{ .string = try scratch.dupe(u8, "keep me") },
        .{ .int = 7 },
        .{ .list = inner },
    } };

    const kept = try original.dupe(std.testing.allocator);
    defer freeValue(std.testing.allocator, kept);

    source.deinit(); // the original's backing memory is now gone

    const items = try kept.getL();
    try std.testing.expectEqualStrings("keep me", items[0].?.string);
    try std.testing.expectEqual(@as(i64, 7), items[1].?.int);
    const nested = try items[2].?.getL();
    try std.testing.expectEqualStrings("hi", nested[0].?.string);
    try std.testing.expect(nested[1] == null);
}

/// Recursively free a value produced by `dupe` (test helper: a real host would
/// use an arena and free it in one shot).
fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .string => |str| allocator.free(str),
        .list => |items| {
            for (items) |item| if (item) |inner| freeValue(allocator, inner);
            allocator.free(items);
        },
        .int, .float => {},
    }
}

test "value: eql and dupe handle deep nesting without native recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A chain this deep overflows the native stack if any walk recurses.
    const depth = 100_000;
    var left: Value = .{ .int = 7 };
    var right: Value = .{ .int = 7 };
    var other: Value = .{ .int = 8 };
    for (0..depth) |_| {
        left = try wrapInList(alloc, left);
        right = try wrapInList(alloc, right);
        other = try wrapInList(alloc, other);
    }

    try std.testing.expect(try left.eql(right, alloc));
    try std.testing.expect(!(try left.eql(other, alloc)));

    const copy = try left.dupe(alloc);
    try std.testing.expect(try left.eql(copy, alloc));
}

test "value: format truncates lists past MAX_DISPLAY_DEPTH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var shallow: Value = .{ .int = 7 };
    for (0..MAX_DISPLAY_DEPTH - 1) |_| shallow = try wrapInList(alloc, shallow);

    var deep: Value = .{ .int = 7 };
    for (0..MAX_DISPLAY_DEPTH + 5) |_| deep = try wrapInList(alloc, deep);

    var shallow_buf: [8 * 1024]u8 = undefined;
    var shallow_writer = std.Io.Writer.fixed(&shallow_buf);
    try shallow.format(&shallow_writer);
    try std.testing.expect(std.mem.indexOf(u8, shallow_writer.buffered(), "7") != null);
    try std.testing.expect(std.mem.indexOf(u8, shallow_writer.buffered(), "[ ... ]") == null);

    var deep_buf: [8 * 1024]u8 = undefined;
    var deep_writer = std.Io.Writer.fixed(&deep_buf);
    try deep.format(&deep_writer);
    try std.testing.expect(std.mem.indexOf(u8, deep_writer.buffered(), "[ ... ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, deep_writer.buffered(), "7") == null);
}

fn wrapInList(allocator: std.mem.Allocator, value: Value) !Value {
    const items = try allocator.alloc(?Value, 1);
    items[0] = value;
    return .{ .list = items };
}
