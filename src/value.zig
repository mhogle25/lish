const std = @import("std");
const tok = @import("token.zig");

/// Nesting depth at which format stops descending and emits `[ ... ]`.
pub const MAX_DISPLAY_DEPTH: usize = 1000;

/// What format writes in place of a list nested past MAX_DISPLAY_DEPTH.
const TRUNCATED_LIST_SOURCE = std.fmt.comptimePrint("{c} ... {c}", .{ tok.LIST_OPEN, tok.LIST_CLOSE });

/// The printer's choice of gap between list items; when reading, any whitespace works.
const LIST_ITEM_SEPARATOR = ' ';

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

    pub fn asNumber(self: Value) ?Number {
        return switch (self) {
            .int           => |int_val| .{ .int = int_val },
            .float         => |float_val| .{ .float = float_val },
            .string, .list => null,
        };
    }

    pub fn typeName(self: Value) []const u8 {
        return @tagName(self);
    }

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
            .int    => |int_val| try std.mem.print(buf, "{d}", .{int_val}),
            .float  => |float_val| try std.mem.print(buf, "{d}", .{float_val}),
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

    pub fn sourceText(self: Value, allocator: std.mem.Allocator, max_length: ?usize) error{ OutOfMemory, StringTooLarge }![]const u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();

        var mode = SourceTextMode.init(allocator, &out, max_length);
        defer mode.deinit();

        writeSource(SourceTextMode, &mode, self, &out.writer) catch |err| switch (err) {
            error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
            error.StringTooLarge                 => return error.StringTooLarge,
        };
        return out.toOwnedSlice();
    }

    pub fn eql(lhs: Value, rhs: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!bool {
        switch (shallowEql(lhs, rhs)) {
            .equal     => return true,
            .not_equal => return false,
            .descend   => {},
        }

        var pending = std.ArrayList(ListPair).empty;
        defer pending.deinit(allocator);

        var current: ListPair = .{ .lhs = lhs.list, .rhs = rhs.list };
        while (true) {
            for (current.lhs, current.rhs) |lhs_item, rhs_item| {
                const lhs_inner = lhs_item orelse {
                    if (rhs_item != null) return false;
                    continue;
                };
                const rhs_inner = rhs_item orelse return false;

                switch (shallowEql(lhs_inner, rhs_inner)) {
                    .equal     => {},
                    .not_equal => return false,
                    .descend   => try pending.append(allocator, .{ .lhs = lhs_inner.list, .rhs = rhs_inner.list }),
                }
            }

            current = pending.pop() orelse return true;
        }
    }

    pub fn dupe(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        switch (self) {
            .int, .float => return self,
            .string => |str| return .{ .string = try allocator.dupe(u8, str) },
            .list => {},
        }

        var pending = std.ArrayList(CopyTask).empty;
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

    pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var mode = FormatMode.init();
        return writeSource(FormatMode, &mode, self, writer);
    }
};

pub fn optionalEql(lhs: ?Value, rhs: ?Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!bool {
    const left  = lhs orelse return rhs == null;
    const right = rhs orelse return false;
    return left.eql(right, allocator);
}

/// A value that can only be an int or a float, so turning it into a float can't fail.
pub const Number = union(enum) {
    int: i64,
    float: f64,

    pub fn toFloat(self: Number) f64 {
        return switch (self) {
            .int   => |int_val| @floatFromInt(int_val),
            .float => |float_val| float_val,
        };
    }

    pub fn toValue(self: Number) Value {
        return switch (self) {
            .int   => |int_val| .{ .int = int_val },
            .float => |float_val| .{ .float = float_val },
        };
    }

    /// The one rule for mixing numbers: two ints stay ints; a float on either side makes both floats.
    pub fn pair(left: Number, right: Number) NumberPair {
        return switch (left) {
            .int => |left_int| switch (right) {
                .int   => |right_int| .{ .ints = .{ .left = left_int, .right = right_int } },
                .float => |right_float| .{ .floats = .{ .left = @floatFromInt(left_int), .right = right_float } },
            },
            .float => |left_float| .{ .floats = .{ .left = left_float, .right = right.toFloat() } },
        };
    }

    /// Pairs two values when both are numbers; nothing otherwise.
    pub fn pairValues(left: Value, right: Value) ?NumberPair {
        const left_number  = left.asNumber() orelse return null;
        const right_number = right.asNumber() orelse return null;
        return pair(left_number, right_number);
    }
};

pub const NumberPair = union(enum) {
    ints:   struct { left: i64, right: i64 },
    floats: struct { left: f64, right: f64 },
};

fn writeSource(comptime Mode: type, mode: *Mode, value: Value, writer: *std.Io.Writer) Mode.Error!void {
    try writeValue(Mode, mode, value, writer);
    try mode.checkLength();

    while (mode.top()) |frame| {
        if (frame.index == frame.items.len) {
            try writer.writeByte(tok.LIST_CLOSE);
            mode.pop();
            try mode.checkLength();
            continue;
        }

        if (frame.index > 0) try writer.writeByte(LIST_ITEM_SEPARATOR);
        const item = frame.items[frame.index];
        frame.index += 1;

        if (item) |inner| {
            try writeValue(Mode, mode, inner, writer);
        } else {
            try writer.writeAll(NONE_SOURCE);
        }
        try mode.checkLength();
    }
}

fn writeValue(comptime Mode: type, mode: *Mode, value: Value, writer: *std.Io.Writer) Mode.Error!void {
    switch (value) {
        .string => |text| try writeQuotedString(writer, text),
        .int    => |number| try writer.print("{d}", .{number}),
        .float  => |number| try writer.print("{d}", .{number}),
        .list   => |items| {
            if (!try mode.enter(items)) return writer.writeAll(TRUNCATED_LIST_SOURCE);
            try writer.writeByte(tok.LIST_OPEN);
        },
    }
}

fn writeQuotedString(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte(tok.QUOTE_DOUBLE);
    for (s) |c| {
        switch (c) {
            tok.QUOTE_DOUBLE    => try writer.writeAll("\\\""),
            tok.BACKSLASH       => try writer.writeAll("\\\\"),
            tok.NEWLINE         => try writer.writeAll("\\n"),
            tok.CARRIAGE_RETURN => try writer.writeAll("\\r"),
            tok.TAB             => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte(tok.QUOTE_DOUBLE);
}

const SourceFrame = struct {
    items: []const ?Value,
    index: usize = 0,
};

const FormatMode = struct {
    const Error = std.Io.Writer.Error;

    frames: [MAX_DISPLAY_DEPTH]SourceFrame = undefined,
    len:    usize                          = 0,

    fn init() FormatMode {
        return .{};
    }

    fn enter(self: *FormatMode, items: []const ?Value) Error!bool {
        if (self.len == self.frames.len) return false;
        self.frames[self.len] = .{ .items = items };
        self.len += 1;
        return true;
    }

    fn top(self: *FormatMode) ?*SourceFrame {
        if (self.len == 0) return null;
        return &self.frames[self.len - 1];
    }

    fn pop(self: *FormatMode) void {
        self.len -= 1;
    }

    fn checkLength(_: *FormatMode) Error!void {}
};

const SourceTextMode = struct {
    const Error = std.Io.Writer.Error || error{ OutOfMemory, StringTooLarge };

    frames:     std.ArrayList(SourceFrame) = .empty,
    allocator:  std.mem.Allocator,
    out:        *std.Io.Writer.Allocating,
    max_length: ?usize,

    fn init(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating, max_length: ?usize) SourceTextMode {
        return .{ .allocator = allocator, .out = out, .max_length = max_length };
    }

    fn deinit(self: *SourceTextMode) void {
        self.frames.deinit(self.allocator);
    }

    fn enter(self: *SourceTextMode, items: []const ?Value) Error!bool {
        try self.frames.append(self.allocator, .{ .items = items });
        return true;
    }

    fn top(self: *SourceTextMode) ?*SourceFrame {
        if (self.frames.items.len == 0) return null;
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn pop(self: *SourceTextMode) void {
        self.frames.shrinkRetainingCapacity(self.frames.items.len - 1);
    }

    fn checkLength(self: *SourceTextMode) Error!void {
        const limit = self.max_length orelse return;
        if (self.out.written().len > limit) return error.StringTooLarge;
    }
};

/// One shallow eql step: scalars settle; equal-length lists need their elements walked.
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

/// Source spelling of the absent value (`$none`).
pub const NONE_SOURCE = std.fmt.comptimePrint("{c}{s}", .{ tok.EXPRESSION_SINGLE, NONE_ID });

/// Truthy/falsy convention: "some" is truthy, null is falsy.
pub const SOME: Value = .{ .string = "some" };
pub const NONE: ?Value = null;

pub fn some() ?Value {
    return SOME;
}

pub fn toCondition(condition: bool) ?Value {
    return if (condition) some() else NONE;
}

pub fn floatToInt(float_val: f64) i64 {
    if (std.math.isNan(float_val)) return 0;

    const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
    if (float_val >= max_f) return std.math.maxInt(i64);
    if (float_val <= min_f) return std.math.minInt(i64);

    return @trunc(float_val);
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
    // TODO: numeric literals (int/float, rendered bare) when a "must be 0|1|2"-style op appears
    literal: []const u8,
    // TODO: element/tuple shapes (`list of int`, `[int, string]`) when an op needs them
    one_of: []const LishType,

    pub fn oneOf(comptime types: []const LishType, comptime names: []const []const u8) LishType {
        return .{ .one_of = comptime blk: {
            var members: [types.len + names.len]LishType = undefined;
            for (types, 0..) |t, i| members[i] = t;
            for (names, 0..) |name, i| members[types.len + i] = .{ .literal = name };
            const frozen = members;
            break :blk &frozen;
        } };
    }

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
    try std.testing.expectEqual(@as(i64, 3), floatToInt(3.7));
    try std.testing.expectEqual(@as(i64, -3), floatToInt(-3.7));
    try std.testing.expectEqual(std.math.maxInt(i64), floatToInt(std.math.inf(f64)));
    try std.testing.expectEqual(std.math.minInt(i64), floatToInt(-std.math.inf(f64)));
    try std.testing.expectEqual(std.math.maxInt(i64), floatToInt(1e300));
    try std.testing.expectEqual(std.math.minInt(i64), floatToInt(-1e300));
    try std.testing.expectEqual(@as(i64, 0), floatToInt(std.math.nan(f64)));
}

test "value: asNumber accepts only ints and floats, and toValue gives the same value back" {
    const items = [_]?Value{.{ .int = 1 }};
    try std.testing.expectEqual(Number{ .int = 7 }, (Value{ .int = 7 }).asNumber().?);
    try std.testing.expectEqual(Number{ .float = 2.5 }, (Value{ .float = 2.5 }).asNumber().?);
    try std.testing.expect((Value{ .string = "7" }).asNumber() == null);
    try std.testing.expect((Value{ .list = &items }).asNumber() == null);

    try std.testing.expectEqual(Value{ .int = 7 }, (Number{ .int = 7 }).toValue());
    try std.testing.expectEqual(Value{ .float = 2.5 }, (Number{ .float = 2.5 }).toValue());
}

test "value: Number.pair keeps two ints as ints and makes both floats when either is a float" {
    const one: Number = .{ .int = 1 };
    const two: Number = .{ .int = 2 };
    const one_and_a_half: Number = .{ .float = 1.5 };
    const two_and_a_half: Number = .{ .float = 2.5 };

    try std.testing.expectEqual(NumberPair{ .ints = .{ .left = 1, .right = 2 } }, Number.pair(one, two));
    try std.testing.expectEqual(NumberPair{ .floats = .{ .left = 1.0, .right = 2.5 } }, Number.pair(one, two_and_a_half));
    try std.testing.expectEqual(NumberPair{ .floats = .{ .left = 1.5, .right = 2.0 } }, Number.pair(one_and_a_half, two));
    try std.testing.expectEqual(NumberPair{ .floats = .{ .left = 1.5, .right = 2.5 } }, Number.pair(one_and_a_half, two_and_a_half));
}

test "value: Number.pair keeps ints past 2^53 exact, where floats would make them equal" {
    const larger: Number = .{ .int = 9007199254740993 };
    const smaller: Number = .{ .int = 9007199254740992 };
    try std.testing.expectEqual(larger.toFloat(), smaller.toFloat());
    try std.testing.expectEqual(NumberPair{ .ints = .{ .left = 9007199254740993, .right = 9007199254740992 } }, Number.pair(larger, smaller));
}

test "value: Number.pairValues pairs two numbers and gives nothing when either is not a number" {
    const one: Value = .{ .int = 1 };
    const two_and_a_half: Value = .{ .float = 2.5 };
    const word: Value = .{ .string = "2" };

    try std.testing.expectEqual(NumberPair{ .floats = .{ .left = 1.0, .right = 2.5 } }, Number.pairValues(one, two_and_a_half).?);
    try std.testing.expect(Number.pairValues(one, word) == null);
    try std.testing.expect(Number.pairValues(word, one) == null);
}

test "value dupe survives its source arena" {
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

    source.deinit();

    const items = try kept.getL();
    try std.testing.expectEqualStrings("keep me", items[0].?.string);
    try std.testing.expectEqual(@as(i64, 7), items[1].?.int);
    const nested = try items[2].?.getL();
    try std.testing.expectEqualStrings("hi", nested[0].?.string);
    try std.testing.expect(nested[1] == null);
}

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
    try std.testing.expect(std.mem.find(u8, shallow_writer.buffered(), "7") != null);
    try std.testing.expect(std.mem.find(u8, shallow_writer.buffered(), "[ ... ]") == null);

    var deep_buf: [8 * 1024]u8 = undefined;
    var deep_writer = std.Io.Writer.fixed(&deep_buf);
    try deep.format(&deep_writer);
    try std.testing.expect(std.mem.find(u8, deep_writer.buffered(), "[ ... ]") != null);
    try std.testing.expect(std.mem.find(u8, deep_writer.buffered(), "7") == null);
}

fn wrapInList(allocator: std.mem.Allocator, value: Value) !Value {
    const items = try allocator.alloc(?Value, 1);
    items[0] = value;
    return .{ .list = items };
}

test "value: format renders source style with quoting and $none" {
    const items = [_]?Value{ .{ .int = 1 }, .{ .string = "a b" }, null };
    const value: Value = .{ .list = &items };

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try value.format(&writer);
    try std.testing.expectEqualStrings("[1 \"a b\" $none]", writer.buffered());

    var string_buf: [64]u8 = undefined;
    var string_writer = std.Io.Writer.fixed(&string_buf);
    try (Value{ .string = "quote \" and \\ and\n" }).format(&string_writer);
    try std.testing.expectEqualStrings("\"quote \\\" and \\\\ and\\n\"", string_writer.buffered());
}

test "value: sourceText matches format and is depth-unbounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]?Value{ .{ .int = 1 }, .{ .string = "a" }, null };
    const small: Value = .{ .list = &items };
    try std.testing.expectEqualStrings("[1 \"a\" $none]", try small.sourceText(alloc, null));

    var deep: Value = .{ .int = 7 };
    for (0..100_000) |_| deep = try wrapInList(alloc, deep);
    const text = try deep.sourceText(alloc, null);
    try std.testing.expectEqual(@as(usize, 200_001), text.len);
    try std.testing.expectEqual(@as(u8, '7'), text[100_000]);

    try std.testing.expectError(error.StringTooLarge, deep.sourceText(alloc, 10));
}

test "value: sourceText enforces the length limit partway through a nested list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const left  = [_]?Value{ .{ .int = 1 }, .{ .int = 2 } };
    const right = [_]?Value{ .{ .int = 3 }, .{ .int = 4 } };
    const outer = [_]?Value{ .{ .list = &left }, .{ .list = &right } };
    const value: Value = .{ .list = &outer };

    const expected = "[[1 2] [3 4]]";
    try std.testing.expectEqualStrings(expected, try value.sourceText(alloc, expected.len));
    try std.testing.expectError(error.StringTooLarge, value.sourceText(alloc, expected.len - 1));

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try value.format(&writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "value: format and sourceText write a lone scalar the same way" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const values = [_]Value{ .{ .int = 5 }, .{ .float = 2.5 }, .{ .string = "a \"b\"" } };
    for (values) |value| {
        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try value.format(&writer);
        try std.testing.expectEqualStrings(writer.buffered(), try value.sourceText(alloc, null));
    }
}
