const std = @import("std");
const ast_mod = @import("ast.zig");
const exec_mod = @import("exec.zig");

const Allocator = std.mem.Allocator;
const AstNode = ast_mod.AstNode;
const AstExpression = ast_mod.AstExpression;
const AstBracketError = ast_mod.AstBracketError;
const Thunk = exec_mod.Thunk;
const Expression = exec_mod.Expression;
const Unit = exec_mod.Unit;

pub const ValidationError = struct {
    message: []const u8,
    line: ?usize = null,
    column: ?usize = null,
    start: ?usize = null,
    end: ?usize = null,
};

pub const ValidationErrors = struct {
    items: std.ArrayList(ValidationError) = .empty,

    pub fn add(self: *ValidationErrors, allocator: Allocator, validation_error: ValidationError) Allocator.Error!void {
        try self.items.append(allocator, validation_error);
    }

    pub fn count(self: *const ValidationErrors) usize {
        return self.items.items.len;
    }

    pub fn slice(self: *const ValidationErrors) []const ValidationError {
        return self.items.items;
    }
};

pub const ValidationResult = union(enum) {
    ok: Unit,
    err: []const ValidationError,
};

pub fn validate(allocator: Allocator, ast_root: *const AstNode) Allocator.Error!ValidationResult {
    var errors = ValidationErrors{};
    var site_counter: u32 = 0;

    const maybe_thunk = try validateStep(allocator, ast_root, &errors, &site_counter);

    if (maybe_thunk == null) {
        if (ast_root.body != .expression) {
            try errors.add(allocator, .{ .message = "Expected the root of the AST to be an expression" });
        }

        return .{ .err = errors.slice() };
    }

    const thunk = maybe_thunk.?;
    if (thunk.body != .expression) {
        try errors.add(allocator, .{ .message = "Expected the root to produce an expression thunk" });
        return .{ .err = errors.slice() };
    }

    if (errors.count() > 0) return .{ .err = errors.slice() };
    return .{ .ok = .{
        .root = thunk.body.expression,
        .unit_id = exec_mod.nextUnitId(),
        .site_count = site_counter,
    } };
}

pub fn validateStep(allocator: Allocator, node: *const AstNode, errors: *ValidationErrors, site_counter: *u32) Allocator.Error!?*const Thunk {
    return switch (node.body) {
        .value_literal => |value| {
            const thunk = try allocator.create(Thunk);

            const owned_value = switch (value) {
                .string => |s| @as(@TypeOf(value), .{ .string = try allocator.dupe(u8, s) }),
                else => value,
            };

            thunk.* = .{ .position = node.position, .body = .{ .value_literal = owned_value } };
            return thunk;
        },

        .scope_thunk => |id_node| {
            const id_thunk = try validateStep(allocator, id_node, errors, site_counter) orelse return null;
            const thunk = try allocator.create(Thunk);

            thunk.* = .{
                .position = node.position,
                .body = .{ .scope_thunk = id_thunk }
            };

            return thunk;
        },

        .expression => |expr| try validateExpression(allocator, node.position, expr, errors, site_counter),

        .err => |ast_error| {
            try errors.add(allocator, .{
                .message = ast_error.message,
                .start   = node.position.start,
                .end     = node.position.end,
            });

            return null;
        },
    };
}

fn validateExpression(
    allocator: Allocator,
    position: exec_mod.Position,
    expr: AstExpression,
    errors: *ValidationErrors,
    site_counter: *u32,
) Allocator.Error!?*const Thunk {
    const init_error_count = errors.count();

    if (expr.open_err) |open_err| {
        try addBracketError(allocator, errors, open_err);
    }

    const pre_id_error_count = errors.count();
    const id_thunk = try validateStep(allocator, expr.id, errors, site_counter);
    if (id_thunk == null and errors.count() == pre_id_error_count) {
        try errors.add(allocator, .{ .message = "An expression must have an ID" });
    }

    var valid_args = std.ArrayList(*const Thunk).empty;
    for (expr.args) |arg_node| {
        if (try validateStep(allocator, arg_node, errors, site_counter)) |arg_thunk| {
            try valid_args.append(allocator, arg_thunk);
        }
    }

    if (expr.close_err) |close_err| {
        try addBracketError(allocator, errors, close_err);
    }

    if (id_thunk == null) return null;

    if (errors.count() > init_error_count) return null;

    const site = site_counter.*;
    site_counter.* += 1;

    const thunk = try allocator.create(Thunk);
    thunk.* = .{ .position = position, .body = .{ .expression = .{
        .name = id_thunk.?,
        .args = valid_args.items,
        .site = site,
    } } };
    return thunk;
}

fn addBracketError(allocator: Allocator, errors: *ValidationErrors, bracket_error: AstBracketError) Allocator.Error!void {
    try errors.add(allocator, .{
        .message = bracket_error.message,
        .start   = bracket_error.position.start,
        .end     = bracket_error.position.end,
    });
}

const parser = @import("parser.zig");
const ast = ast_mod;
const val = @import("value.zig");

test "validate simple expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ast_root = try parser.parse(alloc, "say \"hello\"");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => |unit| {
            const expression = unit.root;
            try std.testing.expect(expression.name.body == .value_literal);
            try std.testing.expectEqualStrings("say", expression.name.body.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 1), expression.args.len);
        },
        .err => |errors| {
            std.debug.print("Unexpected validation errors:\n", .{});
            for (errors) |validation_error| {
                std.debug.print("  {s}\n", .{validation_error.message});
            }
            return error.TestUnexpectedResult;
        },
    }
}

test "validate nested expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ast_root = try parser.parse(alloc, "add (add 1 2) 3");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => |unit| {
            const expression = unit.root;
            try std.testing.expectEqualStrings("add", expression.name.body.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 2), expression.args.len);
            try std.testing.expect(expression.args[0].body == .expression);
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "validate scope thunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ast_root = try parser.parse(alloc, "say :myVar");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => |unit| {
            const expression = unit.root;
            try std.testing.expectEqualStrings("say", expression.name.body.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 1), expression.args.len);
            try std.testing.expect(expression.args[0].body == .scope_thunk);
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "validate empty input produces errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ast_root = try parser.parse(alloc, "");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |errors| {
            try std.testing.expect(errors.len > 0);
        },
    }
}

test "validate accumulates multiple errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const err_node_1 = try ast.makeSyntaxErr(alloc, .{ .start = 0, .end = 5 }, "first error");
    const err_node_2 = try ast.makeSyntaxErr(alloc, .{ .start = 5, .end = 10 }, "second error");

    const expr_node = try ast.makeExpression(
        alloc,
        ast.Position.synthetic,
        err_node_1,
        &.{err_node_2},
        null,
        null,
        .{ .meta_type = .top_level },
    );

    const result = try validate(alloc, expr_node);

    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |errors| {
            try std.testing.expect(errors.len >= 2);
        },
    }
}

test "validate with bracket errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const id_node = try ast.makeValueLiteral(alloc, ast.Position.synthetic, .{ .string = "say" });

    const expr_node = try ast.makeExpression(
        alloc,
        ast.Position.synthetic,
        id_node,
        &.{},
        .{
            .message  = "Missing closing parenthesis",
            .position = .{ .start = 0, .end = 1 },
        },
        null,
        .{ .meta_type = .standard },
    );

    const result = try validate(alloc, expr_node);

    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |errors| {
            try std.testing.expect(errors.len >= 1);
            try std.testing.expectEqualStrings("Missing closing parenthesis", errors[0].message);
        },
    }
}

test "validate end-to-end with execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = exec_mod.Registry.init(alloc);
    try registry.registerOperation(alloc, "echo", exec_mod.Operation.fromFn(testEchoOp, .{
        .signature = .{ .params = comptime &.{exec_mod.Param{ .name = "x" }}, .returns = .any },
        .description = "Test op: return its argument unchanged.",
    }));

    var env = exec_mod.Env{ .registry = &registry, .allocator = alloc };
    const scope = exec_mod.Scope.EMPTY;

    const ast_root = try parser.parse(alloc, "echo 42");
    const validation_result = try validate(alloc, ast_root);

    switch (validation_result) {
        .ok => |unit| {
            const expression = unit.root;
            const exec_result = try env.processExpression(expression, &scope);
            try std.testing.expectEqual(@as(i64, 42), exec_result.?.int);
        },
        .err => return error.TestUnexpectedResult,
    }
}

fn testEchoOp(args: exec_mod.Args) exec_mod.ExecError!?val.Value {
    return args.at(0).get();
}

test "validate list literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ast_root = try parser.parse(alloc, "say [1 2 3]");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => |unit| {
            const expression = unit.root;
            try std.testing.expectEqualStrings("say", expression.name.body.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 1), expression.args.len);

            const list_expr = expression.args[0].body.expression;
            try std.testing.expectEqualStrings("list", list_expr.name.body.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 3), list_expr.args.len);
        },
        .err => return error.TestUnexpectedResult,
    }
}
