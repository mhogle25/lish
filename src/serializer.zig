const std = @import("std");
const ast_mod = @import("ast.zig");
const macro_parser_mod = @import("macro_parser.zig");
const val_mod = @import("value.zig");
const tok = @import("token.zig");

const AstNode = ast_mod.AstNode;
const AstExpression = ast_mod.AstExpression;
const AstMacro = macro_parser_mod.AstMacro;
const Value = val_mod.Value;

pub const SerializeError = error{InvalidNode};

/// Serialize an AST node to lish source. The node is treated as a top-level
/// expression, no surrounding parens are emitted even if it contains nested
/// sub-expressions.
pub fn serializeExpression(node: *const AstNode, writer: anytype) !void {
    try serializeNode(node, writer, false);
}

/// Serialize a single macro definition to lish source.
/// Emits: |name param1 ~deferred2| body
pub fn serializeMacro(macro: AstMacro, writer: anytype) !void {
    try writer.writeByte(tok.MACRO_BRACKET);
    switch (macro.id) {
        .valid => |id_data| try writer.writeAll(id_data.name),
        .err => return SerializeError.InvalidNode,
    }
    for (macro.parameters) |param| {
        switch (param) {
            .valid => |param_data| {
                try writer.writeByte(' ');
                if (param_data.param_type == .deferred) try writer.writeByte(tok.DEFERRED);
                try writer.writeAll(param_data.id);
            },
            .err => return SerializeError.InvalidNode,
        }
    }
    try writer.writeByte(tok.MACRO_BRACKET);
    try writer.writeByte(' ');
    try serializeNode(macro.body, writer, false);
}

/// Serialize a slice of macro definitions as a .lishmacro module, one per line.
pub fn serializeMacroModule(macros: []const AstMacro, writer: anytype) !void {
    for (macros, 0..) |macro, idx| {
        if (idx > 0) try writer.writeByte(tok.NEWLINE);
        try serializeMacro(macro, writer);
    }
}


fn serializeNode(node: *const AstNode, writer: anytype, nested: bool) anyerror!void {
    switch (node.body) {
        .value_literal => |v| try serializeValue(v, writer, nested),
        .scope_thunk => |id_node| {
            try writer.writeByte(tok.SCOPE_THUNK);
            // The id_node is almost always a value_literal.string, emit it bare.
            // Fall back to full node serialization for unusual cases.
            switch (id_node.body) {
                .value_literal => |v| switch (v) {
                    .string => |name| try writer.writeAll(name),
                    else => try serializeValue(v, writer, false),
                },
                else => try serializeNode(id_node, writer, true),
            }
        },
        .expression => |expr| try serializeExprNode(expr, writer, nested),
        .err => return SerializeError.InvalidNode,
    }
}

fn serializeExprNode(expr: AstExpression, writer: anytype, nested: bool) anyerror!void {
    // $term, single-term expression, no parens regardless of nesting
    if (expr.meta.meta_type == .single_term) {
        try writer.writeByte(tok.EXPRESSION_SINGLE);
        try serializeNode(expr.id, writer, false);
        return;
    }

    // All other expression types (standard, top_level, list_literal, block_literal)
    // are serialized in desugared form. Parens are added when nested.
    if (nested) try writer.writeByte(tok.EXPRESSION_OPEN);
    try serializeNode(expr.id, writer, true);
    for (expr.args) |arg| {
        try writer.writeByte(' ');
        try serializeNode(arg, writer, true);
    }
    if (nested) try writer.writeByte(tok.EXPRESSION_CLOSE);
}

fn serializeValue(v: Value, writer: anytype, nested: bool) anyerror!void {
    switch (v) {
        .string => |str| try serializeString(str, writer),
        .int => |int_val| try writer.print("{d}", .{int_val}),
        .float => |float_val| try writer.print("{d}", .{float_val}),
        .list => |items| {
            // Desugared form: list item1 item2 ...
            // Parens needed when nested so the parser can delimit it.
            if (nested) try writer.writeByte(tok.EXPRESSION_OPEN);
            try writer.writeAll(ast_mod.LIST_ID);
            for (items) |maybe_item| {
                try writer.writeByte(' ');
                if (maybe_item) |item| {
                    try serializeValue(item, writer, true);
                } else {
                    try writer.writeByte(tok.EXPRESSION_SINGLE);
                    try writer.writeAll(val_mod.NONE_ID);
                }
            }
            if (nested) try writer.writeByte(tok.EXPRESSION_CLOSE);
        },
    }
}

fn serializeString(str: []const u8, writer: anytype) anyerror!void {
    if (!needsQuoting(str)) {
        try writer.writeAll(str);
        return;
    }
    try writer.writeByte(tok.QUOTE_DOUBLE);
    for (str) |char| {
        switch (char) {
            tok.QUOTE_DOUBLE => try writer.writeAll("\\\""),
            tok.BACKSLASH => try writer.writeAll("\\\\"),
            tok.NEWLINE => try writer.writeAll("\\n"),
            tok.CARRIAGE_RETURN => try writer.writeAll("\\r"),
            tok.TAB => try writer.writeAll("\\t"),
            tok.BACKSPACE => try writer.writeAll("\\b"),
            tok.FORM_FEED => try writer.writeAll("\\f"),
            tok.VERTICAL_TAB => try writer.writeAll("\\v"),
            tok.NULL_CHARACTER => try writer.writeAll("\\0"),
            tok.BELL => try writer.writeAll("\\a"),
            tok.ESCAPE_CHAR => try writer.writeAll("\\e"),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte(tok.QUOTE_DOUBLE);
}

fn needsQuoting(str: []const u8) bool {
    if (str.len == 0) return true;
    for (str) |char| {
        if (std.ascii.isWhitespace(char)) return true;
        if (tok.isReservedChar(char)) return true;
    }
    return looksLikeNumber(str);
}

/// Returns true if the string would be lexed as an int or float token,
/// meaning it must be quoted to preserve its string identity.
fn looksLikeNumber(str: []const u8) bool {
    if (str.len == 0) return false;

    var idx: usize = 0;
    if (str[idx] == tok.NEGATIVE_SIGN) {
        idx += 1;
        if (idx >= str.len) return false; // lone "-" is a valid identifier
    }

    var has_dot = false;
    var digit_count: usize = 0;
    while (idx < str.len) : (idx += 1) {
        const char = str[idx];
        if (std.ascii.isDigit(char)) {
            digit_count += 1;
        } else if (char == tok.DECIMAL_POINT and !has_dot) {
            has_dot = true;
        } else {
            return false; // non-numeric character, safe bare word
        }
    }

    if (digit_count == 0) return false;
    if (str[str.len - 1] == tok.DECIMAL_POINT) return false; // trailing dot -> lexed as identifier
    return true;
}


const parser_mod = @import("parser.zig");
const Allocator = std.mem.Allocator;

fn expectSerialized(node: *const AstNode, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serializeExpression(node, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

fn expectSerializedMacro(macro: AstMacro, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serializeMacro(macro, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}


test "quoting: bare words don't need quotes" {
    try std.testing.expect(!needsQuoting("hello"));
    try std.testing.expect(!needsQuoting("+"));
    try std.testing.expect(!needsQuoting("*"));
    try std.testing.expect(!needsQuoting("my-op"));
    try std.testing.expect(!needsQuoting("snake_case"));
    try std.testing.expect(!needsQuoting("-")); // lone dash is valid identifier
    try std.testing.expect(!needsQuoting("5.")); // trailing dot -> identifier
}

test "quoting: reserved chars require quotes" {
    try std.testing.expect(needsQuoting("hello world")); // space
    try std.testing.expect(needsQuoting("a(b")); // reserved
    try std.testing.expect(needsQuoting("a:b")); // reserved
    try std.testing.expect(needsQuoting("a|b")); // reserved
    try std.testing.expect(needsQuoting("")); // empty
}

test "quoting: numbers require quotes" {
    try std.testing.expect(needsQuoting("42"));
    try std.testing.expect(needsQuoting("3.14"));
    try std.testing.expect(needsQuoting("-7"));
    try std.testing.expect(needsQuoting("-2.5"));
    try std.testing.expect(!needsQuoting("1abc")); // not a pure number
}


test "serialize: int literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .int = 42 });
    try expectSerialized(node, "42");
}

test "serialize: negative int literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .int = -7 });
    try expectSerialized(node, "-7");
}

test "serialize: float literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .float = 3.14 });
    try expectSerialized(node, "3.14");
}

test "serialize: string bare word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .string = "hello" });
    try expectSerialized(node, "hello");
}

test "serialize: string with spaces is quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .string = "hello world" });
    try expectSerialized(node, "\"hello world\"");
}

test "serialize: number-like string is quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .string = "42" });
    try expectSerialized(node, "\"42\"");
}

test "serialize: empty string is quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .string = "" });
    try expectSerialized(node, "\"\"");
}

test "serialize: string with escape chars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .string = "line1\nline2" });
    try expectSerialized(node, "\"line1\\nline2\"");
}

test "serialize: string with backslash and quote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .string = "say \"hi\"" });
    try expectSerialized(node, "\"say \\\"hi\\\"\"");
}


test "serialize: simple expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const id = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .string = "+" });
    const arg1 = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .int = 1 });
    const arg2 = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .int = 2 });
    const args = try alloc.dupe(*const AstNode, &.{ arg1, arg2 });
    const node = try ast_mod.makeExpression(alloc, ast_mod.Position.synthetic, id, args, null, null, .{ .meta_type = .top_level });
    try expectSerialized(node, "+ 1 2");
}

test "serialize: nested expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Inner: + 1 2
    const inner_id = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .string = "+" });
    const inner_args = try alloc.dupe(*const AstNode, &.{
        try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .int = 1 }),
        try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .int = 2 }),
    });
    const inner = try ast_mod.makeExpression(alloc, ast_mod.Position.synthetic, inner_id, inner_args, null, null, .{ .meta_type = .standard });

    // Outer: + <inner> 3
    const outer_id = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .string = "+" });
    const outer_args = try alloc.dupe(*const AstNode, &.{
        inner,
        try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .int = 3 }),
    });
    const outer = try ast_mod.makeExpression(alloc, ast_mod.Position.synthetic, outer_id, outer_args, null, null, .{ .meta_type = .top_level });
    try expectSerialized(outer, "+ (+ 1 2) 3");
}

test "serialize: scope thunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const id_node = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .string = "x" });
    const node = try ast_mod.makeScopeThunk(alloc, ast_mod.Position.synthetic, id_node);
    try expectSerialized(node, ":x");
}

test "serialize: single term" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const id = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .string = val_mod.NONE_ID });
    const node = try ast_mod.makeExpression(alloc, ast_mod.Position.synthetic, id, &.{}, null, null, .{ .meta_type = .single_term });
    try expectSerialized(node, "$none");
}

test "serialize: expression with scope thunk arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const id = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .string = "*" });
    const scope_id = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .string = "x" });
    const scope = try ast_mod.makeScopeThunk(alloc, ast_mod.Position.synthetic, scope_id);
    const args = try alloc.dupe(*const AstNode, &.{ scope, try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .int = 2 }) });
    const node = try ast_mod.makeExpression(alloc, ast_mod.Position.synthetic, id, args, null, null, .{ .meta_type = .top_level });
    try expectSerialized(node, "* :x 2");
}

test "serialize: list value literal at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const items = [_]?Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } };
    const node = try ast_mod.makeValueLiteral(arena.allocator(), ast_mod.Position.synthetic, .{ .list = &items });
    try expectSerialized(node, "list 1 2 3");
}

test "serialize: list value literal nested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // length (list 1 2 3)
    const items = [_]?Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } };
    const list_node = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .list = &items });
    const id = try ast_mod.makeValueLiteral(alloc, ast_mod.Position.synthetic, .{ .string = "length" });
    const args = try alloc.dupe(*const AstNode, &.{list_node});
    const node = try ast_mod.makeExpression(alloc, ast_mod.Position.synthetic, id, args, null, null, .{ .meta_type = .top_level });
    try expectSerialized(node, "length (list 1 2 3)");
}


test "serialize: simple macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try macro_parser_mod.parseMacroModule(alloc, "|double x| * :x 2");
    const macro = switch (module.macros[0]) {
        .macro => |m| m,
        .err => return error.TestUnexpectedResult,
    };
    try expectSerializedMacro(macro, "|double x| * :x 2");
}

test "serialize: macro with deferred param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try macro_parser_mod.parseMacroModule(alloc, "|do-twice ~action| proc :action :action");
    const macro = switch (module.macros[0]) {
        .macro => |m| m,
        .err => return error.TestUnexpectedResult,
    };
    try expectSerializedMacro(macro, "|do-twice ~action| proc :action :action");
}

test "serialize: macro with no params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try macro_parser_mod.parseMacroModule(alloc, "|greet| say hello");
    const macro = switch (module.macros[0]) {
        .macro => |m| m,
        .err => return error.TestUnexpectedResult,
    };
    try expectSerializedMacro(macro, "|greet| say hello");
}

test "serialize: macro module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "|double x| * :x 2\n|triple x| * :x 3";
    const module = try macro_parser_mod.parseMacroModule(alloc, source);

    var macros_buf: [8]AstMacro = undefined;
    var macro_count: usize = 0;
    for (module.macros) |node| {
        switch (node) {
            .macro => |m| {
                macros_buf[macro_count] = m;
                macro_count += 1;
            },
            .err => return error.TestUnexpectedResult,
        }
    }

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serializeMacroModule(macros_buf[0..macro_count], &writer);
    try std.testing.expectEqualStrings(
        "|double x| * :x 2\n|triple x| * :x 3",
        writer.buffered(),
    );
}


test "round-trip: expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try parser_mod.parse(alloc, "+ 1 2");
    try expectSerialized(node, "+ 1 2");
}

test "round-trip: nested expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try parser_mod.parse(alloc, "+ (+ 1 2) 3");
    try expectSerialized(node, "+ (+ 1 2) 3");
}

test "round-trip: expression with string and scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try parser_mod.parse(alloc, "concat \"hello \" :name");
    try expectSerialized(node, "concat \"hello \" :name");
}

test "round-trip: macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try macro_parser_mod.parseMacroModule(alloc, "|greet name| say (concat \"hello \" :name)");
    const macro = switch (module.macros[0]) {
        .macro => |m| m,
        .err => return error.TestUnexpectedResult,
    };
    try expectSerializedMacro(macro, "|greet name| say (concat \"hello \" :name)");
}
