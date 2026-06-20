const std = @import("std");
const tok = @import("token.zig");
const ast_mod = @import("ast.zig");
const lex_mod = @import("lexer.zig");
const expr_parser = @import("parser.zig");
const exec = @import("exec.zig");
const val = @import("value.zig");
const validation_mod = @import("validation.zig");

const Allocator = std.mem.Allocator;
const Token = tok.Token;
const TokenType = tok.TokenType;
const Lexer = lex_mod.Lexer;
const CommentSink = lex_mod.CommentSink;
const CommentSpan = tok.CommentSpan;
const AstNode = ast_mod.AstNode;
const Position = ast_mod.Position;


pub const AstMacroModule = struct {
    macros: []const AstMacroNode,
};

pub const AstMacroNode = union(enum) {
    macro: AstMacro,
    err: MacroError,
};

pub const AstMacro = struct {
    id: AstMacroId,
    parameters: []const AstMacroParam,
    body: *const AstNode,
    /// Docstring: the `##` comment run immediately preceding the macro's header,
    /// as a raw source slice (markers and newlines included), or "" if none.
    /// Only populated by `parseMacroModuleWithComments`; empty otherwise.
    description: []const u8 = "",
};

pub const AstMacroId = union(enum) {
    valid: MacroIdData,
    err: MacroError,
};

pub const MacroIdData = struct {
    name: []const u8,
    /// Source span of the identifier. `.synthetic` for macros built in memory
    /// (the AstBuilder) rather than parsed. Carried for tooling (the LSP).
    position: Position = .synthetic,
};

pub const AstMacroParam = union(enum) {
    valid: MacroParamData,
    err: MacroError,
};

pub const MacroParamData = struct {
    id: []const u8,
    param_type: MacroParamType,
    /// Source span of the parameter name (excluding any `~`). `.synthetic` for
    /// in-memory macros. Carried for tooling (the LSP).
    position: Position = .synthetic,
};

pub const MacroParamType = enum { value, deferred };

pub const MacroError = struct {
    message: []const u8,
    line: u32,
    column: u32,
    start: u32,
    end: u32,
};


pub fn parseMacroModule(allocator: Allocator, source: []const u8) Allocator.Error!AstMacroModule {
    var parser = MacroParser.init(allocator, source, null);
    return parser.parse();
}

/// Macro module plus the comment spans collected during parsing. For tooling
/// (the LSP); each `AstMacro.description` is also populated from its leading
/// comment run. Plain `parseMacroModule` leaves comments uncollected.
pub const MacroModuleWithComments = struct {
    module: AstMacroModule,
    comments: []const CommentSpan,
};

pub fn parseMacroModuleWithComments(allocator: Allocator, source: []const u8) Allocator.Error!MacroModuleWithComments {
    var comments: std.ArrayListUnmanaged(CommentSpan) = .empty;
    var parser = MacroParser.init(allocator, source, .{ .list = &comments, .allocator = allocator });
    const module = try parser.parse();
    return .{ .module = module, .comments = comments.items };
}


const MacroParser = struct {
    allocator: Allocator,
    lexer: Lexer,
    token: Token,
    state: State,

    current_id: ?AstMacroId = null,
    parameters: std.ArrayListUnmanaged(AstMacroParam) = .empty,
    macros: std.ArrayListUnmanaged(AstMacroNode) = .empty,
    id_set: std.StringHashMapUnmanaged(void) = .{},
    string_buf: std.ArrayListUnmanaged(u8) = .empty,

    /// Comment sink shared with the lexer (and sub-parsers). When set, each
    /// macro's leading comment run becomes its `description`.
    comment_sink: ?CommentSink = null,
    /// Byte offset of the current macro's opening `|`, used to find its docstring.
    header_start: u32 = 0,

    const State = enum { init, in_params, past_id, deferred_param };

    const EOF_TOKEN: Token = .{
        .type = .eof,
        .lexeme = "",
        .start = 0,
        .end = 0,
        .line = 0,
        .column = 0,
    };

    fn init(allocator: Allocator, source: []const u8, comment_sink: ?CommentSink) MacroParser {
        var lexer = Lexer{ .source = source, .comment_sink = comment_sink };
        const first_token = lexer.nextToken();

        return .{
            .allocator = allocator,
            .lexer = lexer,
            .token = first_token,
            .state = .init,
            .comment_sink = comment_sink,
        };
    }

    fn parse(self: *MacroParser) Allocator.Error!AstMacroModule {
        while (self.token.type != .eof) {
            switch (self.state) {
                .init => self.handleInit(),
                .in_params => try self.handleInParams(),
                .past_id => try self.handlePastId(),
                .deferred_param => try self.handleDeferredParam(),
            }
        }

        return .{ .macros = self.macros.items };
    }


    fn handleInit(self: *MacroParser) void {
        if (self.token.type == .macro_bracket) {
            self.header_start = self.token.start;
            self.state = .in_params;
            self.token = self.lexer.nextToken();
        } else {
            // Unexpected token outside a macro definition, skip
            self.token = self.lexer.nextToken();
        }
    }

    fn handleInParams(self: *MacroParser) Allocator.Error!void {
        if (isTerm(self.token.type)) {
            // First term is the macro identifier
            const id_position: Position = .{ .start = self.token.start, .end = self.token.end };
            const identifier = try self.processIdentifier();

            if (identifier) |id_str| {
                if (self.id_set.contains(id_str)) {
                    self.current_id = .{ .err = self.errorAtToken("Duplicate macro identifier") };
                } else {
                    try self.id_set.put(self.allocator, id_str, {});
                    self.current_id = .{ .valid = .{ .name = id_str, .position = id_position } };
                }
            } else {
                self.current_id = .{ .err = self.errorAtToken("Invalid escape sequences in macro identifier") };
            }

            self.state = .past_id;
            self.token = self.lexer.nextToken();
        } 
        else 
        if (self.token.type == .macro_bracket) {
            // Missing ID, still parse the body
            self.current_id = .{ .err = self.errorAtToken("Macro is missing an identifier") };
            try self.parseMacroBody();
        } 
        else {
            self.token = self.lexer.nextToken();
        }
    }

    fn handlePastId(self: *MacroParser) Allocator.Error!void {
        if (isTerm(self.token.type)) {
            // Value parameter
            const param_position: Position = .{ .start = self.token.start, .end = self.token.end };
            const identifier = try self.processIdentifier();

            if (identifier) |param_id| {
                try self.parameters.append(self.allocator, .{
                    .valid = .{ .id = param_id, .param_type = .value, .position = param_position },
                });
            } else {
                try self.parameters.append(self.allocator, .{
                    .err = self.errorAtToken("Invalid escape sequences in parameter name"),
                });
            }

            self.token = self.lexer.nextToken();
        }
        else
        if (self.token.type == .deferred_macro_param_symbol) {
            self.state = .deferred_param;
            self.token = self.lexer.nextToken();
        } 
        else 
        if (self.token.type == .macro_bracket) {
            try self.parseMacroBody();
        } 
        else {
            try self.parameters.append(self.allocator, .{
                .err = self.errorAtToken("Unexpected token in macro parameters"),
            });
            self.token = self.lexer.nextToken();
        }
    }

    fn handleDeferredParam(self: *MacroParser) Allocator.Error!void {
        if (isTerm(self.token.type)) {
            // Deferred parameter
            const param_position: Position = .{ .start = self.token.start, .end = self.token.end };
            const identifier = try self.processIdentifier();
            if (identifier) |param_id| {
                try self.parameters.append(self.allocator, .{
                    .valid = .{ .id = param_id, .param_type = .deferred, .position = param_position },
                });
            } else {
                try self.parameters.append(self.allocator, .{
                    .err = self.errorAtToken("Invalid escape sequences in parameter name"),
                });
            }
            self.state = .past_id;
            self.token = self.lexer.nextToken();
        } 
        else 
        if (self.token.type == .macro_bracket) {
            // Missing deferred param name
            try self.parameters.append(self.allocator, .{
                .err = self.errorAtToken("Missing parameter name for deferred argument"),
            });
            try self.parseMacroBody();
        } 
        else {
            try self.parameters.append(self.allocator, .{
                .err = self.errorAtToken("Expected parameter name after '~'"),
            });
            self.state = .past_id;
            self.token = self.lexer.nextToken();
        }
    }


    fn parseMacroBody(self: *MacroParser) Allocator.Error!void {
        const result = try expr_parser.parseFromLexer(
            self.allocator,
            &self.lexer,
            &.{.macro_bracket},
        );

        // Build macro node
        try self.finishMacro(result.node);

        // Restore lexer position to where the expression parser stopped
        self.lexer.setState(result.lexer_state);

        if (result.last_token_type == .macro_bracket) {
            // The `|` that ended this body opens the next macro's header.
            self.header_start = result.last_token_start;
            self.state = .in_params;
            self.token = self.lexer.nextToken();
        } else {
            // End of input
            self.token = EOF_TOKEN;
        }
    }

    fn finishMacro(self: *MacroParser, body: *const AstNode) Allocator.Error!void {
        if (self.current_id) |id| {
            const macro = AstMacro{
                .id = id,
                .parameters = try self.allocator.dupe(AstMacroParam, self.parameters.items),
                .body = body,
                .description = self.docstringBefore(self.header_start),
            };
            try self.macros.append(self.allocator, .{ .macro = macro });
        } else {
            try self.macros.append(self.allocator, .{
                .err = .{
                    .message = "Macro is missing an identifier",
                    .line = self.token.line,
                    .column = self.token.column,
                    .start = self.token.start,
                    .end = self.token.end,
                },
            });
        }

        // Reset for next macro
        self.current_id = null;
        self.parameters.clearRetainingCapacity();
    }

    /// The macro's docstring: the maximal run of comments ending immediately
    /// before `header_start`, where every gap (comment-to-comment and
    /// last-comment-to-header) is whitespace only. Returned as a raw source
    /// slice, or "" if there's no sink or no adjacent comment.
    fn docstringBefore(self: *MacroParser, header_start: u32) []const u8 {
        const sink = self.comment_sink orelse return "";
        const items = sink.list.items;
        const source = self.lexer.source;

        // Comments are appended in source order; skip any that start at or after
        // the header (they belong to a later macro, already collected).
        var run_end = items.len;
        while (run_end > 0 and items[run_end - 1].start >= header_start) run_end -= 1;
        if (run_end == 0) return "";
        run_end -= 1;

        // The nearest comment must be adjacent to the header to be its docstring.
        if (!isAdjacentGap(source[items[run_end].end..header_start])) return "";

        // Extend the run backward across adjacent comments.
        var run_start = run_end;
        while (run_start > 0 and isAdjacentGap(source[items[run_start - 1].end..items[run_start].start]))
            run_start -= 1;

        return source[items[run_start].start..items[run_end].end];
    }


    fn processIdentifier(self: *MacroParser) Allocator.Error!?[]const u8 {
        if (self.token.hasInvalidEscapes()) return null;

        self.string_buf.clearRetainingCapacity();
        const lexeme = self.token.lexeme;

        var i: usize = 0;
        while (i < lexeme.len) {
            var current_char = lexeme[i];
            if (current_char == tok.BACKSLASH and i + 1 < lexeme.len) {
                if (tok.idenEscSymToChar(lexeme[i + 1])) |escaped| {
                    current_char = escaped;
                    i += 1;
                }
            }

            try self.string_buf.append(self.allocator, current_char);
            i += 1;
        }

        return try self.allocator.dupe(u8, self.string_buf.items);
    }

    fn errorAtToken(self: *const MacroParser, message: []const u8) MacroError {
        return .{
            .message = message,
            .line = self.token.line,
            .column = self.token.column,
            .start = self.token.start,
            .end = self.token.end,
        };
    }

    fn isTerm(token_type: TokenType) bool {
        return switch (token_type) {
            .identifier, .int, .float, .string_literal => true,
            else => false,
        };
    }
};

/// True when `slice` (the gap between a comment and what follows) is whitespace
/// only AND spans at most one line break, i.e. they are on adjacent lines. A
/// blank line (two line breaks) detaches the comment, so it is not a docstring.
fn isAdjacentGap(slice: []const u8) bool {
    var newlines: usize = 0;
    for (slice) |c| switch (c) {
        '\n' => {
            newlines += 1;
            if (newlines > 1) return false;
        },
        ' ', '\t', '\r' => {},
        else => return false,
    };
    return true;
}


pub const MacroValidationResult = union(enum) {
    ok: []const exec.Macro,
    err: []const validation_mod.ValidationError,
};

pub fn validateMacroModule(allocator: Allocator, module: AstMacroModule) Allocator.Error!MacroValidationResult {
    var errors = validation_mod.ValidationErrors{};
    var valid_macros = std.ArrayListUnmanaged(exec.Macro).empty;

    for (module.macros) |macro_node| {
        switch (macro_node) {
            .macro => |macro| {
                if (try validateMacro(allocator, macro, &errors)) |valid| {
                    try valid_macros.append(allocator, valid);
                }
            },
            .err => |macro_error| {
                try errors.add(allocator, macroErrToValidationErr(macro_error));
            },
        }
    }

    if (errors.count() > 0) {
        return .{ .err = errors.slice() };
    }
    return .{ .ok = valid_macros.items };
}

fn validateMacro(
    allocator: Allocator,
    macro: AstMacro,
    errors: *validation_mod.ValidationErrors,
) Allocator.Error!?exec.Macro {
    const init_error_count = errors.count();

    // Validate ID
    const id = switch (macro.id) {
        .valid => |id_data| id_data.name,
        .err => |macro_error| {
            try errors.add(allocator, macroErrToValidationErr(macro_error));
            return null;
        },
    };

    // Validate parameters
    var valid_params = std.ArrayListUnmanaged(exec.MacroParameter).empty;
    for (macro.parameters) |param_node| {
        switch (param_node) {
            .valid => |param| {
                try valid_params.append(allocator, .{
                    .id = param.id,
                    .param_type = switch (param.param_type) {
                        .value => .value,
                        .deferred => .deferred,
                    },
                });
            },

            .err => |macro_error| {
                try errors.add(allocator, macroErrToValidationErr(macro_error));
            },
        }
    }

    // Validate body expression (reuse expression validation)
    const body_thunk = try validation_mod.validateStep(allocator, macro.body, errors) orelse return null;
    if (body_thunk.body != .expression) {
        try errors.add(allocator, .{ .message = "Macro body must be an expression" });
        return null;
    }

    if (errors.count() > init_error_count) return null;

    return .{
        .id = id,
        .parameters = valid_params.items,
        .body = body_thunk.body.expression,
    };
}

fn macroErrToValidationErr(macro_error: MacroError) validation_mod.ValidationError {
    return .{
        .message = macro_error.message,
        .line = macro_error.line,
        .column = macro_error.column,
        .start = macro_error.start,
        .end = macro_error.end,
    };
}


const builtins = @import("builtins.zig");

test "parse single macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try parseMacroModule(alloc, "| double x | * :x 2");

    try std.testing.expectEqual(@as(usize, 1), module.macros.len);
    const macro = module.macros[0].macro;
    try std.testing.expectEqualStrings("double", macro.id.valid.name);
    try std.testing.expectEqual(@as(usize, 1), macro.parameters.len);
    try std.testing.expectEqualStrings("x", macro.parameters[0].valid.id);
    try std.testing.expect(macro.parameters[0].valid.param_type == .value);
}

test "parse multiple macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try parseMacroModule(alloc, "| double x | * :x 2 | triple x | * :x 3");

    try std.testing.expectEqual(@as(usize, 2), module.macros.len);
    try std.testing.expectEqualStrings("double", module.macros[0].macro.id.valid.name);
    try std.testing.expectEqualStrings("triple", module.macros[1].macro.id.valid.name);
}

test "parse macro with deferred parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try parseMacroModule(alloc, "| run-if cond ~body | if :cond :body");

    try std.testing.expectEqual(@as(usize, 1), module.macros.len);
    const macro = module.macros[0].macro;
    try std.testing.expectEqual(@as(usize, 2), macro.parameters.len);
    try std.testing.expect(macro.parameters[0].valid.param_type == .value);
    try std.testing.expect(macro.parameters[1].valid.param_type == .deferred);
    try std.testing.expectEqualStrings("cond", macro.parameters[0].valid.id);
    try std.testing.expectEqualStrings("body", macro.parameters[1].valid.id);
}

test "parse macro with no parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try parseMacroModule(alloc, "| get-zero | + 0 0");

    try std.testing.expectEqual(@as(usize, 1), module.macros.len);
    try std.testing.expectEqual(@as(usize, 0), module.macros[0].macro.parameters.len);
}

test "duplicate macro id produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try parseMacroModule(alloc, "| foo x | + :x 1 | foo y | + :y 2");

    try std.testing.expectEqual(@as(usize, 2), module.macros.len);
    // Second macro should have an error ID
    try std.testing.expect(module.macros[1].macro.id == .err);
}

test "validate macro module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const module = try parseMacroModule(alloc, "| double x | * :x 2");
    const result = try validateMacroModule(alloc, module);

    switch (result) {
        .ok => |macros| {
            try std.testing.expectEqual(@as(usize, 1), macros.len);
            try std.testing.expectEqualStrings("double", macros[0].id);
            try std.testing.expectEqual(@as(usize, 1), macros[0].parameters.len);
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "validate and execute macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Parse and validate the macro module
    const module = try parseMacroModule(alloc, "| double x | * :x 2");
    const macro_result = try validateMacroModule(alloc, module);
    const macros = switch (macro_result) {
        .ok => |valid_macros| valid_macros,
        .err => return error.TestUnexpectedResult,
    };

    // Set up registry with builtins + the macro
    var registry = exec.Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    for (macros) |*macro| {
        try registry.registerMacro(macro.id, macro);
    }

    // Parse and validate an expression that calls the macro
    const ast_root = try expr_parser.parse(alloc, "double 21");
    const expr_result = try validation_mod.validate(alloc, ast_root);
    const expression = switch (expr_result) {
        .ok => |expr| expr,
        .err => return error.TestUnexpectedResult,
    };

    // Execute
    var env = exec.Env{ .registry = &registry, .allocator = alloc };
    const scope = exec.Scope.EMPTY;
    const value = try env.processExpression(expression, &scope);

    try std.testing.expectEqual(@as(i64, 42), value.?.int);
}

test "end-to-end: macro with deferred parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Macro: |do-twice ~action| proc :action :action
    const module = try parseMacroModule(alloc, "| do-twice ~action | proc :action :action");
    const macro_result = try validateMacroModule(alloc, module);
    const macros = switch (macro_result) {
        .ok => |valid_macros| valid_macros,
        .err => return error.TestUnexpectedResult,
    };

    var registry = exec.Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    for (macros) |*macro| {
        try registry.registerMacro(macro.id, macro);
    }

    // do-twice 42 -> evaluates 42 twice, returns last = 42
    const ast_root = try expr_parser.parse(alloc, "do-twice 42");
    const expr_result = try validation_mod.validate(alloc, ast_root);
    const expression = switch (expr_result) {
        .ok => |expr| expr,
        .err => return error.TestUnexpectedResult,
    };

    var env = exec.Env{ .registry = &registry, .allocator = alloc };
    const scope = exec.Scope.EMPTY;
    const value = try env.processExpression(expression, &scope);

    try std.testing.expectEqual(@as(i64, 42), value.?.int);
}

test "end-to-end: multiple macros in module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "| double x | * :x 2 | quadruple x | double (double :x)";
    const module = try parseMacroModule(alloc, source);
    const macro_result = try validateMacroModule(alloc, module);
    const macros = switch (macro_result) {
        .ok => |valid_macros| valid_macros,
        .err => return error.TestUnexpectedResult,
    };

    var registry = exec.Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    for (macros) |*macro| {
        try registry.registerMacro(macro.id, macro);
    }

    // quadruple 3 -> double(double(3)) -> double(6) -> 12
    const ast_root = try expr_parser.parse(alloc, "quadruple 3");
    const expr_result = try validation_mod.validate(alloc, ast_root);
    const expression = switch (expr_result) {
        .ok => |expr| expr,
        .err => return error.TestUnexpectedResult,
    };

    var env = exec.Env{ .registry = &registry, .allocator = alloc };
    const scope = exec.Scope.EMPTY;
    const value = try env.processExpression(expression, &scope);

    try std.testing.expectEqual(@as(i64, 12), value.?.int);
}

test "docstring: leading comment run attaches to the macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "## doubles its arg\n## (second line)\n| double x | * :x 2";
    const result = try parseMacroModuleWithComments(a, source);

    try std.testing.expectEqual(@as(usize, 1), result.module.macros.len);
    const m = result.module.macros[0].macro;
    try std.testing.expectEqualStrings("double", m.id.valid.name);
    try std.testing.expectEqualStrings("## doubles its arg\n## (second line)", m.description);
    try std.testing.expectEqual(@as(usize, 2), result.comments.len);
}

test "docstring: a blank line detaches the comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "## just a note\n\n| double x | * :x 2";
    const result = try parseMacroModuleWithComments(a, source);

    const m = result.module.macros[0].macro;
    try std.testing.expectEqualStrings("", m.description);
}

test "docstring: each macro gets its own (second enters via body-stop path)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        "## first\n| double x | * :x 2\n## second\n| quad x | double (double :x)";
    const result = try parseMacroModuleWithComments(a, source);

    try std.testing.expectEqual(@as(usize, 2), result.module.macros.len);
    try std.testing.expectEqualStrings("## first", result.module.macros[0].macro.description);
    try std.testing.expectEqualStrings("## second", result.module.macros[1].macro.description);
}
