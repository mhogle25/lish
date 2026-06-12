const std = @import("std");
const tok = @import("token.zig");

const Token = tok.Token;
const TokenType = tok.TokenType;

// This file is the canonical source of truth for lish's lexical rules:
// what counts as a string, a comment, an escape sequence, a token boundary.
// Several embedders re-implement these rules in their own languages because
// tree-sitter scanners are C, folio's lexer is Zig, and we don't yet have a
// shared C ABI bridge. The lexical contract those embedders are held to lives
// in src/scanner_corpus/, with the runners verifying every embedder's scanner
// agrees with this lexer.
//
// If you change tokenization here in a way that affects boundary detection
// (new sigil, new string form, new comment shape), add cases to
// src/scanner_corpus/ — embedder CI will fail until they're updated.
//
// TODO: replace the duplication with a real `extern "C"` function
// `lish_find_expression_boundary(source, terminator) -> usize` exported from
// this module. Tree-sitter scanners and folio's lexer would call into it,
// removing the scanner_corpus's job entirely. See lish-zig roadmap, "lish
// embedders" section.

pub const Lexer = struct {
    source: []const u8,
    idx: usize = 0,
    line: usize = 1,
    column: usize = 1,

    pub const State = struct {
        idx: usize,
        line: usize,
        column: usize,
    };

    pub fn getState(self: Lexer) State {
        return .{ .idx = self.idx, .line = self.line, .column = self.column };
    }

    pub fn setState(self: *Lexer, state: State) void {
        self.idx = state.idx;
        self.line = state.line;
        self.column = state.column;
    }

    pub fn nextToken(self: *Lexer) Token {
        if (self.idx >= self.source.len) {
            return .{
                .type = .eof,
                .lexeme = "",
                .start = @intCast(self.idx),
                .end = @intCast(self.idx),
                .line = @intCast(self.line),
                .column = @intCast(self.column),
            };
        }

        // Skip whitespace and comments
        while (true) {
            while (self.idx < self.source.len and isWhitespace(self.source[self.idx])) {
                switch (self.source[self.idx]) {
                    tok.CARRIAGE_RETURN => self.handleCarriageReturn(),
                    tok.NEWLINE => self.handleNewline(),
                    else => self.column += 1,
                }
                self.idx += 1;
            }

            // Check for ## comment
            if (self.idx + 1 < self.source.len and
                self.source[self.idx] == tok.COMMENT and
                self.source[self.idx + 1] == tok.COMMENT)
            {
                self.idx += 2; // skip opening ##
                self.column += 2;

                // Skip until closing ## or newline/EOF
                while (self.idx < self.source.len) {
                    if (self.source[self.idx] == tok.NEWLINE) break;
                    if (self.source[self.idx] == tok.CARRIAGE_RETURN) break;
                    if (self.idx + 1 < self.source.len and
                        self.source[self.idx] == tok.COMMENT and
                        self.source[self.idx + 1] == tok.COMMENT)
                    {
                        self.idx += 2; // skip closing ##
                        self.column += 2;
                        break;
                    }
                    self.idx += 1;
                    self.column += 1;
                }
                continue; // loop back to skip more whitespace/comments
            }

            break;
        }

        if (self.idx >= self.source.len) {
            return .{
                .type = .eof,
                .lexeme = "",
                .start = @intCast(self.idx),
                .end = @intCast(self.idx),
                .line = @intCast(self.line),
                .column = @intCast(self.column),
            };
        }

        const first = self.source[self.idx];
        const start = self.idx;

        return switch (first) {
            tok.EXPRESSION_SINGLE => self.singleCharToken(.call_expression_symbol, start),
            tok.MACRO_BRACKET => self.singleCharToken(.macro_bracket, start),
            tok.DEFERRED => self.singleCharToken(.deferred_macro_param_symbol, start),
            tok.SCOPE_THUNK => self.singleCharToken(.call_scope_thunk_symbol, start),

            tok.EXPRESSION_OPEN => self.singleCharToken(.expression_opening_bracket, start),
            tok.EXPRESSION_CLOSE => self.singleCharToken(.expression_closing_bracket, start),
            tok.LIST_OPEN => self.singleCharToken(.list_opening_bracket, start),
            tok.LIST_CLOSE => self.singleCharToken(.list_closing_bracket, start),
            tok.BLOCK_OPEN => self.singleCharToken(.block_opening_bracket, start),
            tok.BLOCK_CLOSE => self.singleCharToken(.block_closing_bracket, start),

            tok.QUOTE_DOUBLE => self.makeStringLiteralToken(tok.QUOTE_DOUBLE),
            tok.QUOTE_SINGLE => self.makeStringLiteralToken(tok.QUOTE_SINGLE),

            else => self.makeTermToken(),
        };
    }

    fn singleCharToken(self: *Lexer, token_type: TokenType, start: usize) Token {
        self.idx += 1;
        const col = self.column;
        self.column += 1;
        return .{
            .type = token_type,
            .lexeme = self.source[start..self.idx],
            .start = @intCast(start),
            .end = @intCast(self.idx),
            .line = @intCast(self.line),
            .column = @intCast(col),
        };
    }

    fn makeTermToken(self: *Lexer) Token {
        const start = self.idx;
        const starting_line = self.line;
        const starting_column = self.column;
        var invalid_escape_count: usize = 0;

        var is_number = true;
        var is_last_char_decimal = false;
        var is_last_char_negative = false;
        var decimal_point_count: usize = 0;

        while (self.idx < self.source.len) {
            const current = self.source[self.idx];

            if (isWhitespace(current) or tok.isReservedChar(current))
                break;

            is_last_char_decimal = false;
            is_last_char_negative = false;

            if (!std.ascii.isDigit(current)) {
                const is_valid_decimal = current == tok.DECIMAL_POINT and decimal_point_count == 0;
                const is_valid_negative = current == tok.NEGATIVE_SIGN and self.idx == start;

                if (is_valid_decimal) {
                    decimal_point_count += 1;
                    is_last_char_decimal = true;
                }
                if (is_valid_negative)
                    is_last_char_negative = true;

                if (!is_valid_decimal and !is_valid_negative)
                    is_number = false;
            }

            if (current == tok.BACKSLASH) {
                if (self.idx + 1 < self.source.len) {
                    if (tok.idenEscSymToChar(self.source[self.idx + 1]) == null) {
                        invalid_escape_count += 1;
                    }
                    self.idx += 1;
                    self.column += 1;
                } else {
                    invalid_escape_count += 1;
                }
            }

            self.column += 1;
            self.idx += 1;
        }

        if (is_last_char_decimal or is_last_char_negative)
            is_number = false;

        var token_type: TokenType = .identifier;

        if (is_number) {
            if (decimal_point_count == 0)
                token_type = .int;
            if (decimal_point_count == 1)
                token_type = .float;
        }

        if (self.idx - start > tok.TERM_MAX_LENGTH)
            token_type = .too_long_term;

        return .{
            .type = token_type,
            .lexeme = self.source[start..self.idx],
            .start = @intCast(start),
            .end = @intCast(self.idx),
            .line = @intCast(starting_line),
            .column = @intCast(starting_column),
            .invalid_escape_count = invalid_escape_count,
        };
    }

    fn makeStringLiteralToken(self: *Lexer, quote: u8) Token {
        // idx is at the opening quote
        if (self.idx + 1 >= self.source.len) {
            const start = self.idx;
            return .{
                .type = .unterminated_string,
                .lexeme = self.source[start..],
                .start = @intCast(start),
                .end = @intCast(self.source.len),
                .line = @intCast(self.line),
                .column = @intCast(self.column),
            };
        }

        self.idx += 1; // skip opening quote
        const start = self.idx;
        const starting_line = self.line;
        const starting_column = self.column;
        var invalid_escape_count: usize = 0;

        while (self.idx < self.source.len) {
            const current = self.source[self.idx];

            if (current == quote) {
                // Found closing quote
                const end = self.idx;
                self.idx += 1; // skip closing quote

                var token_type: TokenType = .string_literal;
                if (end - start > tok.STRING_LITERAL_MAX_LENGTH)
                    token_type = .too_long_string_literal;

                return .{
                    .type = token_type,
                    .lexeme = self.source[start..end],
                    .start = @intCast(start),
                    .end = @intCast(end),
                    .line = @intCast(starting_line),
                    .column = @intCast(starting_column),
                    .invalid_escape_count = invalid_escape_count,
                };
            }

            switch (current) {
                tok.CARRIAGE_RETURN => self.handleCarriageReturn(),
                tok.NEWLINE => self.handleNewline(),
                tok.BACKSLASH => {
                    if (self.idx + 1 < self.source.len) {
                        if (tok.escSymToChar(self.source[self.idx + 1]) == null) {
                            invalid_escape_count += 1;
                        }
                        self.idx += 1;
                        self.column += 2;
                    } else {
                        invalid_escape_count += 1;
                        self.column += 1;
                    }
                },
                else => self.column += 1,
            }

            self.idx += 1;
        }

        // Unterminated
        return .{
            .type = .unterminated_string,
            .lexeme = self.source[start..],
            .start = @intCast(start),
            .end = @intCast(self.source.len),
            .line = @intCast(starting_line),
            .column = @intCast(starting_column),
            .invalid_escape_count = invalid_escape_count,
        };
    }

    fn handleCarriageReturn(self: *Lexer) void {
        if (self.idx + 1 < self.source.len and self.source[self.idx + 1] == tok.NEWLINE) {
            self.idx += 1; // skip the \n in \r\n
        }
        self.line += 1;
        self.column = 1;
    }

    fn handleNewline(self: *Lexer) void {
        self.line += 1;
        self.column = 1;
    }
};

fn isWhitespace(char: u8) bool {
    return std.ascii.isWhitespace(char);
}


test "lex simple expression" {
    var lex = Lexer{ .source = "say \"hello\" 42" };

    const t1 = lex.nextToken();
    try std.testing.expectEqual(TokenType.identifier, t1.type);
    try std.testing.expectEqualStrings("say", t1.lexeme);

    const t2 = lex.nextToken();
    try std.testing.expectEqual(TokenType.string_literal, t2.type);
    try std.testing.expectEqualStrings("hello", t2.lexeme);

    const t3 = lex.nextToken();
    try std.testing.expectEqual(TokenType.int, t3.type);
    try std.testing.expectEqualStrings("42", t3.lexeme);

    const t4 = lex.nextToken();
    try std.testing.expectEqual(TokenType.eof, t4.type);
}

test "lex brackets" {
    var lex = Lexer{ .source = "(+ [1 2] {3})" };

    try std.testing.expectEqual(TokenType.expression_opening_bracket, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.identifier, lex.nextToken().type); // +
    try std.testing.expectEqual(TokenType.list_opening_bracket, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.int, lex.nextToken().type); // 1
    try std.testing.expectEqual(TokenType.int, lex.nextToken().type); // 2
    try std.testing.expectEqual(TokenType.list_closing_bracket, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.block_opening_bracket, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.int, lex.nextToken().type); // 3
    try std.testing.expectEqual(TokenType.block_closing_bracket, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.expression_closing_bracket, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.eof, lex.nextToken().type);
}

test "lex symbols" {
    var lex = Lexer{ .source = "$foo :bar |baz| ~qux" };

    try std.testing.expectEqual(TokenType.call_expression_symbol, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.identifier, lex.nextToken().type); // foo
    try std.testing.expectEqual(TokenType.call_scope_thunk_symbol, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.identifier, lex.nextToken().type); // bar
    try std.testing.expectEqual(TokenType.macro_bracket, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.identifier, lex.nextToken().type); // baz
    try std.testing.expectEqual(TokenType.macro_bracket, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.deferred_macro_param_symbol, lex.nextToken().type);
    try std.testing.expectEqual(TokenType.identifier, lex.nextToken().type); // qux
}

test "lex numbers" {
    var lex = Lexer{ .source = "42 3.14 -7 -2.5 5. -" };

    const t1 = lex.nextToken();
    try std.testing.expectEqual(TokenType.int, t1.type);
    try std.testing.expectEqualStrings("42", t1.lexeme);

    const t2 = lex.nextToken();
    try std.testing.expectEqual(TokenType.float, t2.type);
    try std.testing.expectEqualStrings("3.14", t2.lexeme);

    const t3 = lex.nextToken();
    try std.testing.expectEqual(TokenType.int, t3.type);
    try std.testing.expectEqualStrings("-7", t3.lexeme);

    const t4 = lex.nextToken();
    try std.testing.expectEqual(TokenType.float, t4.type);
    try std.testing.expectEqualStrings("-2.5", t4.lexeme);

    // trailing decimal makes it not a number
    const t5 = lex.nextToken();
    try std.testing.expectEqual(TokenType.identifier, t5.type);
    try std.testing.expectEqualStrings("5.", t5.lexeme);

    // lone negative sign is not a number
    const t6 = lex.nextToken();
    try std.testing.expectEqual(TokenType.identifier, t6.type);
    try std.testing.expectEqualStrings("-", t6.lexeme);
}

test "lex unterminated string" {
    var lex = Lexer{ .source = "\"hello" };
    const t = lex.nextToken();
    try std.testing.expectEqual(TokenType.unterminated_string, t.type);
}

test "lex string with escapes" {
    var lex = Lexer{ .source = "\"hello\\nworld\"" };
    const t = lex.nextToken();
    try std.testing.expectEqual(TokenType.string_literal, t.type);
    // Lexeme includes the raw escape sequence, not the resolved char
    try std.testing.expectEqualStrings("hello\\nworld", t.lexeme);
    try std.testing.expectEqual(@as(usize, 0), t.invalid_escape_count);
}

test "lex string with escaped quotes" {
    var lex = Lexer{ .source = "\"say \\\"hi\\\"\"" };
    const t = lex.nextToken();
    try std.testing.expectEqual(TokenType.string_literal, t.type);
    try std.testing.expectEqualStrings("say \\\"hi\\\"", t.lexeme);
    try std.testing.expectEqual(@as(usize, 0), t.invalid_escape_count);
}

test "lex single-quoted string with escaped single quote" {
    var lex = Lexer{ .source = "'it\\'s alive'" };
    const t = lex.nextToken();
    try std.testing.expectEqual(TokenType.string_literal, t.type);
    try std.testing.expectEqualStrings("it\\'s alive", t.lexeme);
    try std.testing.expectEqual(@as(usize, 0), t.invalid_escape_count);
}

test "lex string with invalid escape" {
    var lex = Lexer{ .source = "\"hello\\xworld\"" };
    const t = lex.nextToken();
    try std.testing.expectEqual(TokenType.string_literal, t.type);
    try std.testing.expectEqual(@as(usize, 1), t.invalid_escape_count);
}

test "lex tracks line and column" {
    var lex = Lexer{ .source = "a\nb c" };

    const t1 = lex.nextToken();
    try std.testing.expectEqual(@as(usize, 1), t1.line);
    try std.testing.expectEqual(@as(usize, 1), t1.column);

    const t2 = lex.nextToken();
    try std.testing.expectEqual(@as(usize, 2), t2.line);
    try std.testing.expectEqual(@as(usize, 1), t2.column);

    const t3 = lex.nextToken();
    try std.testing.expectEqual(@as(usize, 2), t3.line);
    try std.testing.expectEqual(@as(usize, 3), t3.column);
}

test "lex empty input" {
    var lex = Lexer{ .source = "" };
    try std.testing.expectEqual(TokenType.eof, lex.nextToken().type);
}

test "lex whitespace only" {
    var lex = Lexer{ .source = "   \t\n  " };
    try std.testing.expectEqual(TokenType.eof, lex.nextToken().type);
}

test "lex comment: line comment produces no tokens" {
    var lex = Lexer{ .source = "## line comment" };
    try std.testing.expectEqual(TokenType.eof, lex.nextToken().type);
}

test "lex comment: inline comment" {
    var lex = Lexer{ .source = "+ 1 ## inline ## 2" };

    const t1 = lex.nextToken();
    try std.testing.expectEqual(TokenType.identifier, t1.type);
    try std.testing.expectEqualStrings("+", t1.lexeme);

    const t2 = lex.nextToken();
    try std.testing.expectEqual(TokenType.int, t2.type);
    try std.testing.expectEqualStrings("1", t2.lexeme);

    const t3 = lex.nextToken();
    try std.testing.expectEqual(TokenType.int, t3.type);
    try std.testing.expectEqualStrings("2", t3.lexeme);

    try std.testing.expectEqual(TokenType.eof, lex.nextToken().type);
}

test "lex comment: ## inside string literal is not a comment" {
    var lex = Lexer{ .source = "\"string with ## in it\"" };
    const token = lex.nextToken();
    try std.testing.expectEqual(TokenType.string_literal, token.type);
    try std.testing.expectEqualStrings("string with ## in it", token.lexeme);
}

test "lex comment: single # in term is valid identifier" {
    var lex = Lexer{ .source = "#hello" };
    const token = lex.nextToken();
    try std.testing.expectEqual(TokenType.identifier, token.type);
    try std.testing.expectEqualStrings("#hello", token.lexeme);
}
