const std = @import("std");
const ast_mod = @import("ast.zig");
const macro_parser_mod = @import("macro_parser.zig");
const val_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const AstNode = ast_mod.AstNode;
const AstExpression = ast_mod.AstExpression;
const AstMacro = macro_parser_mod.AstMacro;
const AstMacroParam = macro_parser_mod.AstMacroParam;
const Value = val_mod.Value;

/// Fluent builder for AST nodes. Backed by an allocator (typically an arena).
/// All produced nodes are owned by that allocator.
pub const AstBuilder = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) AstBuilder {
        return .{ .allocator = allocator };
    }


    pub fn int(self: AstBuilder, value: i64) Allocator.Error!*const AstNode {
        return ast_mod.makeValueLiteral(self.allocator, ast_mod.Position.synthetic, .{ .int = value });
    }

    pub fn float(self: AstBuilder, value: f64) Allocator.Error!*const AstNode {
        return ast_mod.makeValueLiteral(self.allocator, ast_mod.Position.synthetic, .{ .float = value });
    }

    pub fn string(self: AstBuilder, value: []const u8) Allocator.Error!*const AstNode {
        return ast_mod.makeValueLiteral(self.allocator, ast_mod.Position.synthetic, .{ .string = value });
    }

    /// Produces a `:name` scope thunk.
    pub fn scope(self: AstBuilder, name: []const u8) Allocator.Error!*const AstNode {
        const id_node = try ast_mod.makeValueLiteral(self.allocator, ast_mod.Position.synthetic, .{ .string = name });
        return ast_mod.makeScopeThunk(self.allocator, ast_mod.Position.synthetic, id_node);
    }

    /// Produces a `$name` zero-argument call expression.
    pub fn call(self: AstBuilder, name: []const u8) Allocator.Error!*const AstNode {
        const id_node = try ast_mod.makeValueLiteral(self.allocator, ast_mod.Position.synthetic, .{ .string = name });
        return ast_mod.makeExpression(self.allocator, ast_mod.Position.synthetic, id_node, &.{}, null, null,
            .{ .meta_type = .single_term });
    }


    /// Start building a standard expression. Chain `.arg()`, finish with `.build()`.
    /// Use `.asTopLevel()` before `.build()` to set top-level metadata.
    pub fn expr(self: AstBuilder, id: []const u8) ExprBuilder {
        return .{
            .builder = self,
            .id = id,
            .args = .empty,
            .meta_type = .standard,
            .sticky_err = null,
        };
    }

    /// Start building a list literal (`[...]` sugar). Chain `.arg()`, finish with `.build()`.
    /// Meta type is locked to `.list_literal`.
    pub fn list(self: AstBuilder) ExprBuilder {
        return .{
            .builder = self,
            .id = ast_mod.LIST_ID,
            .args = .empty,
            .meta_type = .list_literal,
            .sticky_err = null,
        };
    }

    /// Start building a block literal (`{...}` sugar). Chain `.arg()`, finish with `.build()`.
    /// Meta type is locked to `.block_literal`.
    pub fn block(self: AstBuilder) ExprBuilder {
        return .{
            .builder = self,
            .id = ast_mod.BLOCK_ID,
            .args = .empty,
            .meta_type = .block_literal,
            .sticky_err = null,
        };
    }


    /// Start building a macro definition with the given name.
    /// Chain `.param()` / `.deferredParam()`, finish with `.body()`.
    pub fn macro(self: AstBuilder, name: []const u8) MacroBuilder {
        return .{
            .builder = self,
            .name = name,
            .params = .empty,
            .sticky_err = null,
        };
    }
};

/// Builds an expression node incrementally. Stores OOM errors and surfaces them
/// at `.build()` time, allowing uninterrupted method chaining.
pub const ExprBuilder = struct {
    builder: AstBuilder,
    id: []const u8,
    args: std.ArrayListUnmanaged(*const AstNode),
    meta_type: AstExpression.MetaType,
    sticky_err: ?Allocator.Error,

    /// Append an argument node. Returns self for chaining.
    /// If allocation fails, the error is held and returned by `.build()`.
    pub fn arg(self: *ExprBuilder, node: *const AstNode) *ExprBuilder {
        self.args.append(self.builder.allocator, node) catch |err| {
            self.sticky_err = err;
        };
        return self;
    }

    /// Override the meta type to `.top_level`. Only meaningful on `b.expr()` builders.
    /// Returns self for chaining before `.build()`.
    pub fn asTopLevel(self: *ExprBuilder) *ExprBuilder {
        self.meta_type = .top_level;
        return self;
    }

    /// Finish building the expression using the stored meta type.
    pub fn build(self: *ExprBuilder) Allocator.Error!*const AstNode {
        if (self.sticky_err) |err| return err;
        const id_node = try ast_mod.makeValueLiteral(self.builder.allocator, ast_mod.Position.synthetic, .{ .string = self.id });
        const args_slice = try self.args.toOwnedSlice(self.builder.allocator);
        return ast_mod.makeExpression(self.builder.allocator, ast_mod.Position.synthetic, id_node, args_slice, null, null,
            .{ .meta_type = self.meta_type });
    }
};

/// Builds a macro definition incrementally.
pub const MacroBuilder = struct {
    builder: AstBuilder,
    name: []const u8,
    params: std.ArrayListUnmanaged(AstMacroParam),
    sticky_err: ?Allocator.Error,

    /// Append a value parameter (`:name` in macro body). Returns self for chaining.
    pub fn param(self: *MacroBuilder, name: []const u8) *MacroBuilder {
        self.params.append(self.builder.allocator, .{ .valid = .{
            .id = name,
            .param_type = .value,
        } }) catch |err| {
            self.sticky_err = err;
        };
        return self;
    }

    /// Append a deferred parameter (`~name` in macro definition). Returns self for chaining.
    pub fn deferredParam(self: *MacroBuilder, name: []const u8) *MacroBuilder {
        self.params.append(self.builder.allocator, .{ .valid = .{
            .id = name,
            .param_type = .deferred,
        } }) catch |err| {
            self.sticky_err = err;
        };
        return self;
    }

    /// Finish building by providing the body expression node. Returns the completed AstMacro.
    pub fn body(self: *MacroBuilder, body_node: *const AstNode) Allocator.Error!AstMacro {
        if (self.sticky_err) |err| return err;
        const params_slice = try self.params.toOwnedSlice(self.builder.allocator);
        return AstMacro{
            .id = .{ .valid = .{ .name = self.name } },
            .parameters = params_slice,
            .body = body_node,
        };
    }
};


const serializer_mod = @import("serializer.zig");

fn expectExpr(node: *const AstNode, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serializer_mod.serializeExpression(node, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

fn expectMacro(macro_def: AstMacro, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serializer_mod.serializeMacro(macro_def, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "builder: leaf nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    try expectExpr(try b.int(42), "42");
    try expectExpr(try b.float(3.14), "3.14");
    try expectExpr(try b.string("hello"), "hello");
    try expectExpr(try b.string("hello world"), "\"hello world\"");
    try expectExpr(try b.scope("x"), ":x");
    try expectExpr(try b.call("none"), "$none");
}

test "builder: call vs string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    try expectExpr(try b.call("some"), "$some");
    try expectExpr(try b.string("some"), "some");
}

test "builder: simple expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var eb = b.expr("+");
    const node = try eb.arg(try b.int(1)).arg(try b.int(2)).build();
    try expectExpr(node, "+ 1 2");
}

test "builder: nested expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    // + (+ 1 2) 3
    var inner = b.expr("+");
    const inner_node = try inner.arg(try b.int(1)).arg(try b.int(2)).build();

    var outer = b.expr("+");
    const root = try outer.arg(inner_node).arg(try b.int(3)).build();
    try expectExpr(root, "+ (+ 1 2) 3");
}

test "builder: scope thunk arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var eb = b.expr("*");
    const node = try eb.arg(try b.scope("x")).arg(try b.int(2)).build();
    try expectExpr(node, "* :x 2");
}

test "builder: asTopLevel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var eb = b.expr("+");
    const node = try eb.arg(try b.int(1)).asTopLevel().build();
    try std.testing.expectEqual(
        AstExpression.MetaType.top_level,
        node.body.expression.meta.meta_type,
    );
}

test "builder: list literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var lb = b.list();
    const node = try lb.arg(try b.int(1)).arg(try b.int(2)).arg(try b.int(3)).build();
    try std.testing.expectEqual(AstExpression.MetaType.list_literal, node.body.expression.meta.meta_type);
    try expectExpr(node, "list 1 2 3");
}

test "builder: block literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var say1 = b.expr("say");
    var say2 = b.expr("say");
    var bb = b.block();
    const node = try bb
        .arg(try say1.arg(try b.string("hello")).build())
        .arg(try say2.arg(try b.string("world")).build())
        .build();
    try std.testing.expectEqual(AstExpression.MetaType.block_literal, node.body.expression.meta.meta_type);
    try expectExpr(node, "proc (say hello) (say world)");
}

test "builder: list vs expr list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    // b.list() -> .list_literal
    var lb = b.list();
    const list_node = try lb.arg(try b.int(1)).build();
    try std.testing.expectEqual(AstExpression.MetaType.list_literal, list_node.body.expression.meta.meta_type);

    // b.expr("list") -> .standard
    var eb = b.expr("list");
    const expr_node = try eb.arg(try b.int(1)).build();
    try std.testing.expectEqual(AstExpression.MetaType.standard, expr_node.body.expression.meta.meta_type);
}

test "builder: macro with value param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var body_eb = b.expr("*");
    const body_node = try body_eb.arg(try b.scope("x")).arg(try b.int(2)).build();

    var mb = b.macro("double");
    const macro_def = try mb.param("x").body(body_node);
    try expectMacro(macro_def, "|double x| * :x 2");
}

test "builder: macro with deferred param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var body_eb = b.expr("proc");
    const body_node = try body_eb
        .arg(try b.scope("action"))
        .arg(try b.scope("action"))
        .build();

    var mb = b.macro("do-twice");
    const macro_def = try mb.deferredParam("action").body(body_node);
    try expectMacro(macro_def, "|do-twice ~action| proc :action :action");
}

test "builder: macro with no params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var body_eb = b.expr("say");
    const body_node = try body_eb.arg(try b.string("hello")).build();

    var mb = b.macro("greet");
    const macro_def = try mb.body(body_node);
    try expectMacro(macro_def, "|greet| say hello");
}

test "builder: complex macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var concat_eb = b.expr("concat");
    const concat_node = try concat_eb
        .arg(try b.string("hello "))
        .arg(try b.scope("name"))
        .build();

    var say_eb = b.expr("say");
    const say_node = try say_eb.arg(concat_node).build();

    var mb = b.macro("greet");
    const macro_def = try mb.param("name").body(say_node);
    try expectMacro(macro_def, "|greet name| say (concat \"hello \" :name)");
}
