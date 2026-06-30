const std = @import("std");
const tok = @import("token.zig");
const ast = @import("ast.zig");
const lex_mod = @import("lexer.zig");
const val = @import("value.zig");

const Allocator = std.mem.Allocator;
const Token = tok.Token;
const TokenType = tok.TokenType;
const Lexer = lex_mod.Lexer;
const AstNode = ast.AstNode;
const AstExpression = ast.AstExpression;
const AstBracketError = ast.AstBracketError;
const Value = val.Value;

const NO_PENDING_CLOSURE: i32 = -1;

/// Result from parsing via an existing lexer (used by macro parser).
pub const ParserResult = struct {
    node: *AstNode,
    lexer_state: Lexer.State,
    last_token_type: TokenType,
    /// Byte offset of the stop token (e.g. the `|` that ended a macro body). The
    /// macro parser uses it as the header position of the macro that follows.
    last_token_start: u32,
};

/// Closure tracking info for bracket matching.
const ClosureEntry = struct {
    token_type: TokenType,
    start: u32,
    end: u32,
    line: u32,
    column: u32,
};

/// Result from single-term parse operations.
const SingleTermResult = struct {
    node: *AstNode,
    saw_closing_bracket: bool = false,
    closing_match_depth: i32 = NO_PENDING_CLOSURE,
};

/// Parse a source string into an AST node.
pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error!*AstNode {
    var expression_parser = Parser.init(allocator, &.{});
    return expression_parser.get(source);
}

/// Parse result that also carries the `## comment` spans collected during
/// lexing. For tooling (the LSP); the executable path uses `parse`, which
/// discards comments.
pub const ParseWithComments = struct {
    root: *AstNode,
    comments: []const tok.CommentSpan,
};

/// Like `parse`, but also returns every comment span in source order. The
/// comment list is allocated from `allocator` alongside the AST.
pub fn parseWithComments(allocator: Allocator, source: []const u8) Allocator.Error!ParseWithComments {
    var comments: std.ArrayListUnmanaged(tok.CommentSpan) = .empty;
    var expression_parser = Parser.init(allocator, &.{});
    const root = try expression_parser.getWithComments(source, .{ .list = &comments, .allocator = allocator });
    return .{ .root = root, .comments = comments.items };
}

/// Parse using an existing lexer (for macro parser integration).
pub fn parseFromLexer(allocator: Allocator, lexer: *Lexer, eof_at: []const TokenType) Allocator.Error!ParserResult {
    var expression_parser = Parser.init(allocator, eof_at);
    return expression_parser.getFromLexer(lexer);
}

pub const Parser = struct {
    allocator: Allocator,
    eof_at: []const TokenType,
    lexer: Lexer = .{ .source = "" },
    token: Token = .{
        .type = .eof,
        .lexeme = "",
        .start = 0,
        .end = 0,
        .line = 1,
        .column = 1,
    },

    node_stack: std.ArrayListUnmanaged(*AstNode) = .empty,
    closure_stack: [tok.MAX_EXPRESSION_NESTING]ClosureEntry = undefined,
    closure_stack_count: usize = 0,
    pending_closure_depth: i32 = NO_PENDING_CLOSURE,
    string_buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: Allocator, eof_at: []const TokenType) Parser {
        return .{
            .allocator = allocator,
            .eof_at = eof_at,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.node_stack.deinit(self.allocator);
        self.string_buf.deinit(self.allocator);
    }

    pub fn get(self: *Parser, source: []const u8) Allocator.Error!*AstNode {
        self.lexer = .{ .source = source };
        self.token = self.lexer.nextToken();
        return self.topLevelExpression(1);
    }

    /// Same as `get`, but with a comment sink attached before the first token
    /// so leading comments are captured too.
    pub fn getWithComments(self: *Parser, source: []const u8, sink: lex_mod.CommentSink) Allocator.Error!*AstNode {
        self.lexer = .{ .source = source, .comment_sink = sink };
        self.token = self.lexer.nextToken();
        return self.topLevelExpression(1);
    }

    pub fn getFromLexer(self: *Parser, lexer: *Lexer) Allocator.Error!ParserResult {
        self.lexer = lexer.*;
        self.token = self.lexer.nextToken();
        const node = try self.topLevelExpression(1);

        return .{
            .node = node,
            .lexer_state = self.lexer.getState(),
            .last_token_type = self.token.type,
            .last_token_start = self.token.start,
        };
    }


    fn topLevelExpression(self: *Parser, nested_count: usize) Allocator.Error!*AstNode {
        if (nested_count > tok.MAX_EXPRESSION_NESTING)
            return self.expressionNestingErr();

        const thunk_count = try self.handleTopLevel(nested_count);

        if (thunk_count < 1) {
            return ast.makeExpression(
                self.allocator,
                .{ .start = 0, .end = self.token.end },
                try self.syntaxErr("An expression must have an ID"),
                &.{},
                null,
                null,
                .{ .meta_type = .top_level },
            );
        }

        const args = try self.popNodes(thunk_count - 1);
        const id = self.stackPop();

        return ast.makeExpression(self.allocator, .{ .start = 0, .end = self.token.end }, id, args, null, null, .{ .meta_type = .top_level });
    }

    fn expression(self: *Parser, nested_count: usize) Allocator.Error!*AstNode {
        if (nested_count > tok.MAX_EXPRESSION_NESTING)
            return self.expressionNestingErr();

        const closure = try self.handleClosure(nested_count);

        if (closure.expr_count < 1) {
            return ast.makeExpression(
                self.allocator,
                closure.position,
                try self.syntaxErr("An expression must have an ID"),
                &.{},
                closure.open_err,
                closure.close_err,
                .{ .meta_type = .standard },
            );
        }

        const args = try self.popNodes(closure.expr_count - 1);
        const id = self.stackPop();

        return ast.makeExpression(self.allocator, closure.position, id, args, closure.open_err, closure.close_err, .{ .meta_type = .standard });
    }

    fn listLiteral(self: *Parser, nested_count: usize) Allocator.Error!*AstNode {
        if (nested_count > tok.MAX_EXPRESSION_NESTING)
            return self.expressionNestingErr();

        const closure = try self.handleClosure(nested_count);
        const args = try self.popNodes(closure.expr_count);
        const id = try ast.makeValueLiteral(self.allocator, closure.position, .{ .string = ast.LIST_ID });

        return ast.makeExpression(self.allocator, closure.position, id, args, closure.open_err, closure.close_err, .{ .meta_type = .list_literal });
    }

    fn block(self: *Parser, nested_count: usize) Allocator.Error!*AstNode {
        if (nested_count > tok.MAX_EXPRESSION_NESTING)
            return self.expressionNestingErr();

        const closure = try self.handleClosure(nested_count);
        const args = try self.popNodes(closure.expr_count);
        const id = try ast.makeValueLiteral(self.allocator, closure.position, .{ .string = ast.BLOCK_ID });

        return ast.makeExpression(self.allocator, closure.position, id, args, closure.open_err, closure.close_err, .{ .meta_type = .block_literal });
    }

    fn singleTermExpression(self: *Parser, nested_count: usize) Allocator.Error!SingleTermResult {
        const symbol_token = self.token;
        self.token = self.lexer.nextToken();

        if (nested_count > tok.MAX_EXPRESSION_NESTING)
            return self.singleTermNestingErr();

        const term = try self.makeSingleTermNode(nested_count);
        const expr = try ast.makeExpression(
            self.allocator,
            .{ .start = symbol_token.start, .end = term.node.position.end },
            term.node,
            &.{},
            null,
            null,
            .{ .meta_type = .single_term },
        );

        return .{
            .node = expr,
            .saw_closing_bracket = term.saw_closing_bracket,
            .closing_match_depth = term.closing_match_depth,
        };
    }

    fn scopeThunk(self: *Parser, nested_count: usize) Allocator.Error!SingleTermResult {
        const symbol_token = self.token;
        self.token = self.lexer.nextToken();

        if (nested_count > tok.MAX_EXPRESSION_NESTING)
            return self.singleTermNestingErr();

        const term = try self.makeSingleTermNode(nested_count);
        const node = try ast.makeScopeThunk(self.allocator, .{ .start = symbol_token.start, .end = term.node.position.end }, term.node);

        return .{
            .node = node,
            .saw_closing_bracket = term.saw_closing_bracket,
            .closing_match_depth = term.closing_match_depth,
        };
    }


    fn identifierLiteral(self: *Parser) Allocator.Error!*AstNode {
        return self.textLiteral(tok.idenEscSymToChar);
    }

    fn stringLiteral(self: *Parser) Allocator.Error!*AstNode {
        return self.textLiteral(tok.escSymToChar);
    }

    fn textLiteral(self: *Parser, converter: *const fn (u8) ?u8) Allocator.Error!*AstNode {
        if (self.token.hasInvalidEscapes()) {
            return ast.makeSyntaxErr(
                self.allocator,
                .{ .start = self.token.start, .end = self.token.end },
                "Encountered a literal with invalid escape sequences",
            );
        }

        self.string_buf.clearRetainingCapacity();
        const lexeme = self.token.lexeme;
        var i: usize = 0;
        while (i < lexeme.len) {
            var current_char = lexeme[i];
            if (current_char == tok.BACKSLASH and i + 1 < lexeme.len) {
                if (converter(lexeme[i + 1])) |escaped| {
                    current_char = escaped;
                    i += 1;
                }
            }

            try self.string_buf.append(self.allocator, current_char);
            i += 1;
        }

        const owned = try self.allocator.dupe(u8, self.string_buf.items);

        const node = try ast.makeValueLiteral(self.allocator, .{ .start = self.token.start, .end = self.token.end }, .{ .string = owned });
        node.quote = self.token.quote; // the delimiter for a string literal, null for an identifier
        return node;
    }

    fn intLiteral(self: *Parser) Allocator.Error!*AstNode {
        const parsed_int = std.fmt.parseInt(i64, self.token.lexeme, 10) catch {
            return self.logicalErr("An unexpected numeric token was encountered");
        };

        return ast.makeValueLiteral(self.allocator, .{ .start = self.token.start, .end = self.token.end }, .{ .int = parsed_int });
    }

    fn floatLiteral(self: *Parser) Allocator.Error!*AstNode {
        const parsed_float = std.fmt.parseFloat(f64, self.token.lexeme) catch {
            return self.logicalErr("An unexpected numeric token was encountered");
        };

        return ast.makeValueLiteral(self.allocator, .{ .start = self.token.start, .end = self.token.end }, .{ .float = parsed_float });
    }


    fn handleTopLevel(self: *Parser, nested_count_start: usize) Allocator.Error!usize {
        var expr_count: usize = 0;
        var nested_count = nested_count_start;

        while (!self.isEof()) {
            if (expr_count > tok.MAX_PARAMETER_COUNT) {
                try self.stackPush(try self.syntaxErr("Parameter count threshold reached"));
                expr_count += 1;
                break;
            }

            const node: *AstNode = switch (self.token.type) {
                .unterminated_string => try self.syntaxErr("Missing closing quotation mark"),
                .too_long_term => try self.syntaxErr("The term was too long"),
                .too_long_string_literal => try self.syntaxErr("The string literal was too long"),
                .deferred_macro_param_symbol => try self.syntaxErr("Invalid use of a deferred modifier"),
                .macro_separator => try self.syntaxErr("Invalid use of a macro separator"),
                .macro_break => try self.syntaxErr("Invalid use of a macro terminator"),
                .identifier => try self.identifierLiteral(),
                .int => try self.intLiteral(),
                .float => try self.floatLiteral(),
                .string_literal => try self.stringLiteral(),
                .call_expression_symbol => blk: {
                    nested_count += 1;
                    const term_result = try self.singleTermExpression(nested_count);
                    break :blk term_result.node;
                },
                .call_scope_thunk_symbol => blk: {
                    nested_count += 1;
                    const thunk_result = try self.scopeThunk(nested_count);
                    break :blk thunk_result.node;
                },
                .expression_opening_bracket => blk: {
                    nested_count += 1;
                    break :blk try self.expression(nested_count);
                },
                .list_opening_bracket => blk: {
                    nested_count += 1;
                    break :blk try self.listLiteral(nested_count);
                },
                .block_opening_bracket => blk: {
                    nested_count += 1;
                    break :blk try self.block(nested_count);
                },
                .expression_closing_bracket,
                .list_closing_bracket,
                .block_closing_bracket,
                => try self.syntaxErrFmt("Unexpected {s} at top-level", self.token.type.label()),
                else => try self.logicalErr("An unknown token was encountered within the expression"),
            };

            try self.stackPush(node);
            expr_count += 1;
            self.token = self.lexer.nextToken();
        }

        return expr_count;
    }


    const ClosureInfo = struct {
        expr_count: usize,
        open_err: ?AstBracketError,
        close_err: ?AstBracketError,
        position: ast.Position,
    };

    fn handleClosure(self: *Parser, nested_count_start: usize) Allocator.Error!ClosureInfo {
        const opening_token = self.token;
        const bracket_depth: i32 = @intCast(self.closure_stack_count);
        self.closure_stack_count += 1;

        self.closure_stack[@intCast(bracket_depth)] = .{
            .token_type = self.token.type,
            .start = self.token.start,
            .end = self.token.end,
            .line = self.token.line,
            .column = self.token.column,
        };
        self.token = self.lexer.nextToken();

        var expr_count: usize = 0;
        var open_err: ?AstBracketError = null;
        var close_err: ?AstBracketError = null;
        var nested_count = nested_count_start;

        while (true) {
            if ((self.pending_closure_depth >= 0 and self.pending_closure_depth < bracket_depth) or self.isEof()) {
                open_err = try self.missingCloseErr(opening_token);
                return self.finishClosure(opening_token, expr_count, open_err, close_err);
            }

            if (expr_count > tok.MAX_PARAMETER_COUNT) {
                try self.stackPush(try self.syntaxErr("Parameter count threshold reached"));
                expr_count += 1;
                return self.finishClosure(opening_token, expr_count, open_err, close_err);
            }

            switch (self.token.type) {
                .unterminated_string => {
                    try self.stackPush(try self.syntaxErr("Missing closing quotation mark"));
                    expr_count += 1;
                },
                .too_long_term => {
                    try self.stackPush(try self.syntaxErr("The term was too long"));
                    expr_count += 1;
                },
                .too_long_string_literal => {
                    try self.stackPush(try self.syntaxErr("The string literal was too long"));
                    expr_count += 1;
                },
                .deferred_macro_param_symbol => {
                    try self.stackPush(try self.syntaxErr("Invalid use of a deferred modifier"));
                    expr_count += 1;
                },
                .macro_separator => {
                    try self.stackPush(try self.syntaxErr("Invalid use of a macro separator"));
                    expr_count += 1;
                },
                .macro_break => {
                    try self.stackPush(try self.syntaxErr("Invalid use of a macro terminator"));
                    expr_count += 1;
                },
                .identifier => {
                    try self.stackPush(try self.identifierLiteral());
                    expr_count += 1;
                },
                .int => {
                    try self.stackPush(try self.intLiteral());
                    expr_count += 1;
                },
                .float => {
                    try self.stackPush(try self.floatLiteral());
                    expr_count += 1;
                },
                .string_literal => {
                    try self.stackPush(try self.stringLiteral());
                    expr_count += 1;
                },
                .call_expression_symbol => {
                    nested_count += 1;
                    const term = try self.singleTermExpression(nested_count);
                    try self.stackPush(term.node);
                    expr_count += 1;
                    if (try self.tryHandleClosureSingleTermClosing(term, opening_token, &open_err, &close_err))
                        return self.finishClosure(opening_token, expr_count, open_err, close_err);
                },
                .call_scope_thunk_symbol => {
                    nested_count += 1;
                    const term = try self.scopeThunk(nested_count);
                    try self.stackPush(term.node);
                    expr_count += 1;
                    if (try self.tryHandleClosureSingleTermClosing(term, opening_token, &open_err, &close_err))
                        return self.finishClosure(opening_token, expr_count, open_err, close_err);
                },
                .expression_opening_bracket => {
                    nested_count += 1;
                    try self.stackPush(try self.expression(nested_count));
                    expr_count += 1;
                },
                .list_opening_bracket => {
                    nested_count += 1;
                    try self.stackPush(try self.listLiteral(nested_count));
                    expr_count += 1;
                },
                .block_opening_bracket => {
                    nested_count += 1;
                    try self.stackPush(try self.block(nested_count));
                    expr_count += 1;
                },
                .expression_closing_bracket,
                .list_closing_bracket,
                .block_closing_bracket,
                => {
                    const match_depth = self.findMatchingDepth(self.token.type);

                    if (match_depth == bracket_depth) {
                        if (self.pending_closure_depth == bracket_depth)
                            self.pending_closure_depth = NO_PENDING_CLOSURE;
                        return self.finishClosure(opening_token, expr_count, open_err, close_err);
                    }

                    if (match_depth != NO_PENDING_CLOSURE) {
                        self.pending_closure_depth = match_depth;
                        open_err = try self.missingCloseErr(opening_token);
                        return self.finishClosure(opening_token, expr_count, open_err, close_err);
                    }

                    open_err = .{
                        .message  = try self.bracketMsg("Missing {s}", opening_token.type.paired().?),
                        .position = .{ .start = opening_token.start, .end = opening_token.end },
                    };
                    close_err = .{
                        .message  = try self.bracketMsg("Unexpected {s}", self.token.type),
                        .position = .{ .start = self.token.start, .end = self.token.end },
                    };
                    return self.finishClosure(opening_token, expr_count, open_err, close_err);
                },
                else => {
                    try self.stackPush(try self.logicalErr("An unknown token was encountered within the closure"));
                    expr_count += 1;
                },
            }

            if (self.pending_closure_depth >= 0) {
                if (self.pending_closure_depth < bracket_depth) {
                    open_err = try self.missingCloseErr(opening_token);
                    return self.finishClosure(opening_token, expr_count, open_err, close_err);
                }

                if (self.pending_closure_depth == bracket_depth) {
                    self.pending_closure_depth = NO_PENDING_CLOSURE;
                    return self.finishClosure(opening_token, expr_count, open_err, close_err);
                }
            }

            self.token = self.lexer.nextToken();
        }
    }

    fn findMatchingDepth(self: *const Parser, closing_type: TokenType) i32 {
        var i: i32 = @as(i32, @intCast(self.closure_stack_count)) - 1;
        while (i >= 0) : (i -= 1) {
            if (self.closure_stack[@intCast(i)].token_type.pairsWith(closing_type))
                return i;
        }

        return NO_PENDING_CLOSURE;
    }

    fn finishClosure(self: *Parser, opening_token: Token, expr_count: usize, open_err: ?AstBracketError, close_err: ?AstBracketError) ClosureInfo {
        if (self.closure_stack_count > 0)
            self.closure_stack_count -= 1;

        return .{
            .expr_count = expr_count,
            .open_err = open_err,
            .close_err = close_err,
            .position = .{ .start = opening_token.start, .end = self.token.end },
        };
    }

    fn tryHandleClosureSingleTermClosing(
        self: *Parser,
        result: SingleTermResult,
        opening_token: Token,
        open_err: *?AstBracketError,
        close_err: *?AstBracketError,
    ) Allocator.Error!bool {
        if (!result.saw_closing_bracket)
            return false;

        if (result.closing_match_depth == NO_PENDING_CLOSURE) {
            open_err.* = .{
                .message  = try self.bracketMsg("Missing {s}", opening_token.type.paired().?),
                .position = .{ .start = opening_token.start, .end = opening_token.end },
            };

            close_err.* = .{
                .message  = try self.bracketMsg("Unexpected {s}", self.token.type),
                .position = .{ .start = self.token.start, .end = self.token.end },
            };

            return true;
        }

        self.pending_closure_depth = result.closing_match_depth;
        return false;
    }


    fn makeSingleTermNode(self: *Parser, nested_count_start: usize) Allocator.Error!SingleTermResult {
        var nested_count = nested_count_start;
        return switch (self.token.type) {
            .unterminated_string => singleTermResult(try self.syntaxErr("Missing closing quotation mark")),
            .too_long_term => singleTermResult(try self.syntaxErr("The term was too long")),
            .too_long_string_literal => singleTermResult(try self.syntaxErr("The string literal was too long")),
            .deferred_macro_param_symbol => singleTermResult(try self.syntaxErr("Invalid use of a deferred modifier")),
            .macro_separator => singleTermResult(try self.syntaxErr("Invalid use of a macro separator")),
            .macro_break => singleTermResult(try self.syntaxErr("Invalid use of a macro terminator")),
            .eof => singleTermResult(try self.syntaxErr("Expected a term but got the end of the input")),
            .identifier => singleTermResult(try self.identifierLiteral()),
            .int => singleTermResult(try self.intLiteral()),
            .float => singleTermResult(try self.floatLiteral()),
            .string_literal => singleTermResult(try self.stringLiteral()),
            .call_expression_symbol => blk: {
                nested_count += 1;
                break :blk try self.singleTermExpression(nested_count);
            },

            .call_scope_thunk_symbol => blk: {
                nested_count += 1;
                break :blk try self.scopeThunk(nested_count);
            },

            .expression_opening_bracket => blk: {
                nested_count += 1;
                break :blk singleTermResult(try self.expression(nested_count));
            },

            .list_opening_bracket => blk: {
                nested_count += 1;
                break :blk singleTermResult(try self.listLiteral(nested_count));
            },

            .block_opening_bracket => blk: {
                nested_count += 1;
                break :blk singleTermResult(try self.block(nested_count));
            },

            .expression_closing_bracket,
            .list_closing_bracket,
            .block_closing_bracket,
            => .{
                .node = try self.syntaxErrFmt("Expected a term but got a {s}", self.token.type.label()),
                .saw_closing_bracket = true,
                .closing_match_depth = self.findMatchingDepth(self.token.type),
            },
        };
    }

    fn singleTermNestingErr(self: *Parser) Allocator.Error!SingleTermResult {
        const saw_closing = self.token.type.isClosing();
        const match_depth = if (saw_closing) self.findMatchingDepth(self.token.type) else NO_PENDING_CLOSURE;

        return .{
            .node = try self.expressionNestingErr(),
            .saw_closing_bracket = saw_closing,
            .closing_match_depth = match_depth,
        };
    }


    fn isEof(self: *const Parser) bool {
        if (self.token.type == .eof) return true;

        for (self.eof_at) |eof_type| {
            if (self.token.type == eof_type) {
                if (self.token.type.isClosing() and
                    self.closure_stack_count > 0 and
                    self.findMatchingDepth(self.token.type) > -1)
                {
                    continue;
                }

                return true;
            }
        }

        return false;
    }


    fn stackPush(self: *Parser, node: *AstNode) Allocator.Error!void {
        return self.node_stack.append(self.allocator, node);
    }

    fn stackPop(self: *Parser) *AstNode {
        return self.node_stack.pop().?;
    }

    fn popNodes(self: *Parser, count: usize) Allocator.Error![]const *const AstNode {
        if (count == 0) return &.{};

        const args = try self.allocator.alloc(*const AstNode, count);
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            args[i] = self.stackPop();
        }

        return args;
    }


    fn syntaxErr(self: *Parser, message: []const u8) Allocator.Error!*AstNode {
        return ast.makeSyntaxErr(self.allocator, .{ .start = self.token.start, .end = self.token.end }, message);
    }

    fn syntaxErrFmt(self: *Parser, comptime fmt: []const u8, arg: []const u8) Allocator.Error!*AstNode {
        const message = try std.fmt.allocPrint(self.allocator, fmt, .{arg});
        return ast.makeSyntaxErr(self.allocator, .{ .start = self.token.start, .end = self.token.end }, message);
    }

    fn logicalErr(self: *Parser, message: []const u8) Allocator.Error!*AstNode {
        return ast.makeLogicalErr(self.allocator, .{ .start = self.token.start, .end = self.token.end }, message);
    }

    fn expressionNestingErr(self: *Parser) Allocator.Error!*AstNode {
        return self.syntaxErr("Expression nesting threshold reached");
    }

    fn bracketMsg(self: *Parser, comptime fmt: []const u8, token_type: TokenType) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.allocator, fmt, .{token_type.label()});
    }

    fn missingCloseErr(self: *Parser, opening_token: Token) Allocator.Error!AstBracketError {
        return .{
            .message  = try self.bracketMsg("Missing {s}", opening_token.type.paired().?),
            .position = .{ .start = opening_token.start, .end = opening_token.end },
        };
    }
};

fn singleTermResult(node: *AstNode) SingleTermResult {
    return .{ .node = node };
}


test "parse simple identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const node = try parse(arena.allocator(), "hello");

    try std.testing.expect(node.body == .expression);
    const expr = node.body.expression;
    try std.testing.expect(expr.id.body == .value_literal);
    try std.testing.expectEqualStrings("hello", expr.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 0), expr.args.len);
}

test "parse top-level expression with args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const node = try parse(arena.allocator(), "say \"hello\" 42");

    try std.testing.expect(node.body == .expression);
    const expr = node.body.expression;
    try std.testing.expectEqualStrings("say", expr.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 2), expr.args.len);
    try std.testing.expectEqualStrings("hello", expr.args[0].body.value_literal.string);
    try std.testing.expectEqual(@as(i64, 42), expr.args[1].body.value_literal.int);
}

test "parse parenthesized sub-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // At top level, parens create a sub-expression that becomes the ID
    const node = try parse(arena.allocator(), "(+ 1 2)");

    try std.testing.expect(node.body == .expression);
    const top = node.body.expression;
    try std.testing.expect(top.id.body == .expression);
    const sub = top.id.body.expression;
    try std.testing.expectEqualStrings("+", sub.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 2), sub.args.len);
}

test "parse nested expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const node = try parse(arena.allocator(), "+ (+ 1 2) 3");

    try std.testing.expect(node.body == .expression);
    const top = node.body.expression;
    try std.testing.expectEqualStrings("+", top.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 2), top.args.len);

    try std.testing.expect(top.args[0].body == .expression);
    const sub = top.args[0].body.expression;
    try std.testing.expectEqualStrings("+", sub.id.body.value_literal.string);
    try std.testing.expectEqual(@as(i64, 1), sub.args[0].body.value_literal.int);
    try std.testing.expectEqual(@as(i64, 2), sub.args[1].body.value_literal.int);

    try std.testing.expectEqual(@as(i64, 3), top.args[1].body.value_literal.int);
}

test "parse list literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const node = try parse(arena.allocator(), "say [1 2 3]");

    try std.testing.expect(node.body == .expression);
    const top = node.body.expression;
    try std.testing.expectEqualStrings("say", top.id.body.value_literal.string);

    const list_expr = top.args[0].body.expression;
    try std.testing.expectEqualStrings(ast.LIST_ID, list_expr.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 3), list_expr.args.len);
}

test "parse block literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const node = try parse(arena.allocator(), "do {(say 1) (say 2)}");

    try std.testing.expect(node.body == .expression);
    const top = node.body.expression;

    const block_expr = top.args[0].body.expression;
    try std.testing.expectEqualStrings(ast.BLOCK_ID, block_expr.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 2), block_expr.args.len);
}

test "parse single-term expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const node = try parse(arena.allocator(), "say $hello");

    try std.testing.expect(node.body == .expression);
    const top = node.body.expression;
    try std.testing.expectEqual(@as(usize, 1), top.args.len);

    const single = top.args[0].body.expression;
    try std.testing.expectEqualStrings("hello", single.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 0), single.args.len);
    try std.testing.expectEqual(AstExpression.MetaType.single_term, single.meta.meta_type);
}

test "parse scope thunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const node = try parse(arena.allocator(), "say :myVar");

    try std.testing.expect(node.body == .expression);
    const top = node.body.expression;
    try std.testing.expectEqual(@as(usize, 1), top.args.len);

    try std.testing.expect(top.args[0].body == .scope_thunk);
    const thunk_id = top.args[0].body.scope_thunk;
    try std.testing.expectEqualStrings("myVar", thunk_id.body.value_literal.string);
}

test "parse empty input produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const node = try parse(arena.allocator(), "");
    try std.testing.expect(node.body == .expression);
    try std.testing.expect(node.body.expression.id.body == .err);
}

test "parse with eof_at stops at macro terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Body parses in BODY mode and stops at `;` (the macro body terminator).
    var lexer = Lexer{ .source = "+ 1 2 ;next" };
    const result = try parseFromLexer(arena.allocator(), &lexer, &.{.macro_break});

    try std.testing.expect(result.node.body == .expression);
    const expr = result.node.body.expression;
    try std.testing.expectEqualStrings("+", expr.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 2), expr.args.len);
    try std.testing.expectEqual(TokenType.macro_break, result.last_token_type);
}

test "body mode parses | and ~ as operator terms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `| :a :b` is the bitwise-or op applied to two scope refs (no macro here).
    const node = try parse(arena.allocator(), "| :a :b");
    try std.testing.expect(node.body == .expression);
    const expr = node.body.expression;
    try std.testing.expectEqualStrings("|", expr.id.body.value_literal.string);
    try std.testing.expectEqual(@as(usize, 2), expr.args.len);
}

test "parseWithComments returns comment spans and a valid root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "## doc\n(+ 1 2) ## trailing";
    const result = try parseWithComments(a, source);

    try std.testing.expect(result.root.body == .expression);
    try std.testing.expectEqual(@as(usize, 2), result.comments.len);
    try std.testing.expectEqualStrings("## doc", source[result.comments[0].start..result.comments[0].end]);
    try std.testing.expectEqualStrings("## trailing", source[result.comments[1].start..result.comments[1].end]);
}

test "quote field distinguishes a string literal from a bare identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Bare identifier: same value payload, but no quote.
    const id_root = try parse(a, "foo");
    const id_node = id_root.body.expression.id;
    try std.testing.expectEqualStrings("foo", id_node.body.value_literal.string);
    try std.testing.expectEqual(@as(?u8, null), id_node.quote);

    // Quoted string: identical value payload, but the quote records the delimiter.
    const str_root = try parse(a, "\"foo\"");
    const str_node = str_root.body.expression.id;
    try std.testing.expectEqualStrings("foo", str_node.body.value_literal.string);
    try std.testing.expectEqual(@as(?u8, '"'), str_node.quote);
}
