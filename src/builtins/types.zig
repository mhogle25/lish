const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");
const tok = @import("../token.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Param = exec.Param;
const Allocator = std.mem.Allocator;

const x_param = [_]Param{Param.value("x")};

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "types");
    try g.register("type", Operation.fromFn(typeOp, .{
        .signature = .{ .params = &x_param, .returns = "string" },
        .description = "Name of a value's type: int, float, string, list, or none.",
    }));

    try g.register("int", Operation.fromFn(intOp, .{
        .signature = .{ .params = &x_param, .returns = "int" },
        .description = "Convert a number or string to an integer.",
    }));

    try g.register("float", Operation.fromFn(floatOp, .{
        .signature = .{ .params = &x_param, .returns = "float" },
        .description = "Convert a number or string to a float.",
    }));

    try g.register("string", Operation.fromFn(stringOp, .{
        .signature = .{ .params = &x_param, .returns = "string" },
        .description = "Render a value as its plain text form.",
    }));

    try g.register("inspect", Operation.fromFn(inspectOp, .{
        .signature = .{ .params = &x_param, .returns = "string" },
        .description = "Debug representation of a value with quoted strings and list sugar; for logs and the REPL, not round-trip.",
    }));
}

fn intOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(float_val) },
        .string => |str| {
            const parsed = std.fmt.parseInt(i64, str, 10) catch return null;
            return .{ .int = parsed };
        },
        .list => null,
    };
}

fn floatOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .float => value,
        .int => |int_val| .{ .float = @floatFromInt(int_val) },
        .string => |str| {
            const parsed = std.fmt.parseFloat(f64, str) catch return null;
            return .{ .float = parsed };
        },
        .list => null,
    };
}

fn stringOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .string => value,
        .int, .float, .list => {
            var buf: [256]u8 = undefined;
            const str = value.getS(&buf);
            const owned = try args.env.allocator.dupe(u8, str);
            return .{ .string = owned };
        },
    };
}

/// Debug representation of any value. Distinct from `string` which gives
/// value-as-text:
///   strings -> "quoted" with escapes
///   lists   -> [a b c] (sub-expression sugar; not a top-level form)
///   none    -> $none
///   ints/floats -> same as `string`
///
/// Intended for logs and REPL inspection, not programmatic round-trip.
/// For AST -> source -> AST use the `serializer` module.
fn inspectOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    writeInspect(&writer, maybe_value) catch return args.env.fail(.string_too_large, "'inspect' output exceeded buffer");

    const owned = try args.env.allocator.dupe(u8, writer.buffered());
    return .{ .string = owned };
}

fn writeInspect(writer: *std.Io.Writer, maybe_value: ?Value) !void {
    const value = maybe_value orelse {
        try writer.writeAll("$none");
        return;
    };
    switch (value) {
        .string => |s| try writeQuoted(writer, s),
        .int => |n| try writer.print("{d}", .{n}),
        .float => |x| try writer.print("{d}", .{x}),
        .list => |items| {
            try writer.writeByte(tok.LIST_OPEN);
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try writeInspect(writer, item);
            }
            try writer.writeByte(tok.LIST_CLOSE);
        },
    }
}

fn writeQuoted(writer: *std.Io.Writer, s: []const u8) !void {
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

fn typeOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return .{ .string = switch (value) {
        .int => "int",
        .float => "float",
        .string => "string",
        .list => "list",
    } };
}


const testing = @import("testing.zig");

test "type conversion: int from float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "int 3.14");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "type conversion: int from string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "int \"42\"");
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

test "type conversion: int from invalid string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "int \"hello\"");
    try std.testing.expect(result == null);
}

test "type conversion: int from none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "int $none");
    try std.testing.expect(result == null);
}

test "type conversion: float from int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "float 5");
    try std.testing.expectEqual(@as(f64, 5.0), result.?.float);
}

test "type conversion: float from string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "float \"3.14\"");
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.?.float, 0.001);
}

test "type conversion: string from int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "string 42");
    try std.testing.expectEqualStrings("42", result.?.string);
}

test "type conversion: string from none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "string $none");
    try std.testing.expect(result == null);
}

test "type inspection: int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type 42");
    try std.testing.expectEqualStrings("int", result.?.string);
}

test "type inspection: float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type 3.14");
    try std.testing.expectEqualStrings("float", result.?.string);
}

test "type inspection: string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type \"hello\"");
    try std.testing.expectEqualStrings("string", result.?.string);
}

test "type inspection: list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type [1 2]");
    try std.testing.expectEqualStrings("list", result.?.string);
}

test "type inspection: none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type $none");
    try std.testing.expect(result == null);
}

test "inspect: int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "inspect 42");
    try std.testing.expectEqualStrings("42", result.?.string);
}

test "inspect: string gets quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "inspect \"hello\"");
    try std.testing.expectEqualStrings("\"hello\"", result.?.string);
}

test "inspect: string with newline escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "inspect \"a\\nb\"");
    try std.testing.expectEqualStrings("\"a\\nb\"", result.?.string);
}

test "inspect: string with embedded quote escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "inspect \"a\\\"b\"");
    try std.testing.expectEqualStrings("\"a\\\"b\"", result.?.string);
}

test "inspect: list uses lish syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "inspect [1 2 3]");
    try std.testing.expectEqualStrings("[1 2 3]", result.?.string);
}

test "inspect: nested list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "inspect [\"a\" 1 [2 3]]");
    try std.testing.expectEqualStrings("[\"a\" 1 [2 3]]", result.?.string);
}

test "inspect: none renders as $none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "inspect $none");
    try std.testing.expectEqualStrings("$none", result.?.string);
}

test "inspect: empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "inspect []");
    try std.testing.expectEqualStrings("[]", result.?.string);
}

test "inspect: wrong arity fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "inspect 1 2");
    try std.testing.expectError(error.RuntimeError, result);
}

