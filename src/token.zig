const std = @import("std");

pub const TokenType = enum {
    identifier,
    int,
    float,
    /// The `|` that separates a macro header from its body. Emitted only in
    /// HEADER lexer mode; in BODY mode `|` is an ordinary operator/term char.
    macro_separator,
    /// The `;` that terminates a macro body. A base wall (emitted in every mode).
    macro_break,
    call_expression_symbol,
    deferred_macro_param_symbol,
    call_scope_thunk_symbol,

    expression_opening_bracket,
    expression_closing_bracket,
    list_opening_bracket,
    list_closing_bracket,
    block_opening_bracket,
    block_closing_bracket,

    string_literal,
    eof,

    // Error tokens
    unterminated_string,
    too_long_term,
    too_long_string_literal,

    pub fn label(self: TokenType) []const u8 {
        return switch (self) {
            .identifier                  => "identifier",
            .int                         => "integer",
            .float                       => "floating-point number",
            .macro_separator             => "macro separator",
            .macro_break                 => "macro terminator",
            .call_expression_symbol      => "call expression symbol",
            .deferred_macro_param_symbol => "deferred macro param symbol",
            .call_scope_thunk_symbol     => "call scope thunk symbol",
            .expression_opening_bracket  => "opening parenthesis",
            .expression_closing_bracket  => "closing parenthesis",
            .list_opening_bracket        => "opening bracket",
            .list_closing_bracket        => "closing bracket",
            .block_opening_bracket       => "opening brace",
            .block_closing_bracket       => "closing brace",
            .string_literal              => "string literal",
            .eof                         => "end of file",
            .unterminated_string         => "unterminated string",
            .too_long_term               => "exceedingly long term",
            .too_long_string_literal     => "exceedingly long string literal",
        };
    }

    pub fn isClosing(self: TokenType) bool {
        return switch (self) {
            .expression_closing_bracket,
            .list_closing_bracket,
            .block_closing_bracket,
            => true,
            else => false,
        };
    }

    /// Returns the opener for a closer (and vice versa); null for non-bracket tokens.
    pub fn paired(self: TokenType) ?TokenType {
        return switch (self) {
            .expression_opening_bracket => .expression_closing_bracket,
            .expression_closing_bracket => .expression_opening_bracket,
            .list_opening_bracket       => .list_closing_bracket,
            .list_closing_bracket       => .list_opening_bracket,
            .block_opening_bracket      => .block_closing_bracket,
            .block_closing_bracket      => .block_opening_bracket,
            else                        => null,
        };
    }

    pub fn pairsWith(self: TokenType, other: TokenType) bool {
        return switch (self) {
            .expression_opening_bracket => other == .expression_closing_bracket,
            .expression_closing_bracket => other == .expression_opening_bracket,
            .list_opening_bracket       => other == .list_closing_bracket,
            .list_closing_bracket       => other == .list_opening_bracket,
            .block_opening_bracket      => other == .block_closing_bracket,
            .block_closing_bracket      => other == .block_opening_bracket,
            else                        => false,
        };
    }

    pub fn matchingBracket(self: TokenType) ?TokenType {
        return switch (self) {
            .expression_opening_bracket => .expression_closing_bracket,
            .expression_closing_bracket => .expression_opening_bracket,
            .list_opening_bracket       => .list_closing_bracket,
            .list_closing_bracket       => .list_opening_bracket,
            .block_opening_bracket      => .block_closing_bracket,
            .block_closing_bracket      => .block_opening_bracket,
            else => null,
        };
    }
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    start: u32,
    end: u32,
    line: u32,
    column: u32,
    invalid_escape_count: usize = 0,
    /// The delimiter of a string-literal token (`"` or `'`), or null for any
    /// other token. Lets consumers distinguish a quoted string from a bare
    /// identifier, which are otherwise indistinguishable once parsed.
    quote: ?u8 = null,

    pub fn hasInvalidEscapes(self: Token) bool {
        return self.invalid_escape_count > 0;
    }
};

/// Byte span of a `##` comment in source. The lexer discards comments from the
/// token stream; tooling that wants them (the LSP) collects spans into a sink
/// (see `lexer.CommentSink`). `start` is the opening `#`; `end` is one past the
/// comment's last byte.
pub const CommentSpan = struct {
    start: u32,
    end: u32,
};


// Source of truth for cross-language constants.
//
// `tools/gen.zig` reflects over the integer constants below and emits the
// mirrors non-Zig consumers vendor in:
//
//   generated/constants.js   (used by the tree-sitter grammar JS)
//   generated/constants.h    (used by external C scanners)
//
// Printable values (0x20..0x7E) become source-character literals; values >= 256
// become numeric limits. Control characters (the escape targets below) are not
// mirrored here. After changing a constant, run `zig build gen`; consumers pull
// the regenerated files via their own sync step (see tree-sitter-lish).
pub const EXPRESSION_SINGLE = '$';
pub const SCOPE_THUNK = ':';
pub const EXPRESSION_OPEN = '(';
pub const EXPRESSION_CLOSE = ')';
pub const LIST_OPEN = '[';
pub const LIST_CLOSE = ']';
pub const BLOCK_OPEN = '{';
pub const BLOCK_CLOSE = '}';
pub const QUOTE_DOUBLE = '"';
pub const QUOTE_SINGLE = '\'';
pub const PIPE = '|';
pub const TILDE = '~';
pub const SEMICOLON = ';';
pub const DECIMAL_POINT = '.';
pub const NEGATIVE_SIGN = '-';
pub const COMMENT = '#';
pub const BACKSLASH = '\\';
pub const CARRIAGE_RETURN = '\r';
pub const NEWLINE = '\n';
pub const TAB = '\t';
pub const BACKSPACE = 0x08;
pub const FORM_FEED = 0x0C;
pub const VERTICAL_TAB = 0x0B;
pub const NULL_CHARACTER = 0x00;
pub const BELL = 0x07;
pub const ESCAPE_CHAR = 0x1B;

pub const TERM_MAX_LENGTH = 256;
pub const STRING_LITERAL_MAX_LENGTH = 32 * 1024;
pub const MAX_EXPRESSION_NESTING = 256;
pub const MAX_PARAMETER_COUNT = 2048;

/// The base walls: characters that end a term in EVERY lexer mode, because they
/// are structural inside an expression (`:x`/`$some` attach to the next token,
/// brackets/quotes bound things, `;` terminates a macro body). `|` and `~` are
/// deliberately NOT here: they are structural only in a macro HEADER (see
/// `isHeaderWall`); in a body they are ordinary operator/term chars, so a host
/// may register ops named `|`/`~` (bitwise OR/NOT). This set is also what the
/// serializer's `needsQuoting` reads, so a bare `|`/`~` round-trips as an op.
pub fn isReservedChar(char: u8) bool {
    return switch (char) {
        EXPRESSION_SINGLE,
        SCOPE_THUNK,
        EXPRESSION_OPEN,
        EXPRESSION_CLOSE,
        LIST_OPEN,
        LIST_CLOSE,
        BLOCK_OPEN,
        BLOCK_CLOSE,
        QUOTE_DOUBLE,
        QUOTE_SINGLE,
        SEMICOLON,
        => true,
        else => false,
    };
}

/// The walls in a macro HEADER: the base walls plus `|` (header/body separator)
/// and `~` (deferred-param marker). The lexer applies this in HEADER mode so
/// `~cond` splits into `~` + `cond` and the `|` ends the header.
pub fn isHeaderWall(char: u8) bool {
    return isReservedChar(char) or char == PIPE or char == TILDE;
}

/// Standard escape sequences for string literals.
pub fn escSymToChar(symbol: u8) ?u8 {
    return switch (symbol) {
        'r' => CARRIAGE_RETURN,
        'n' => NEWLINE,
        't' => TAB,
        'b' => BACKSPACE,
        'f' => FORM_FEED,
        'v' => VERTICAL_TAB,
        '0' => NULL_CHARACTER,
        'a' => BELL,
        'e' => ESCAPE_CHAR,
        BACKSLASH => BACKSLASH,
        QUOTE_DOUBLE => QUOTE_DOUBLE,
        QUOTE_SINGLE => QUOTE_SINGLE,
        else => null,
    };
}

/// Escape sequences for identifiers: standard escapes plus every wall char (the
/// base walls AND the header-only `|`/`~`), so a header term can name a literal
/// `|`/`~`/`;` via `\|`/`\~`/`\;`.
pub fn idenEscSymToChar(symbol: u8) ?u8 {
    return if (isHeaderWall(symbol))
        symbol
    else
        escSymToChar(symbol);
}


test "token type pairing" {
    try std.testing.expect(TokenType.expression_opening_bracket.pairsWith(.expression_closing_bracket));
    try std.testing.expect(TokenType.list_opening_bracket.pairsWith(.list_closing_bracket));
    try std.testing.expect(TokenType.block_opening_bracket.pairsWith(.block_closing_bracket));
    try std.testing.expect(!TokenType.expression_opening_bracket.pairsWith(.list_closing_bracket));
}

test "reserved chars" {
    try std.testing.expect(isReservedChar('$'));
    try std.testing.expect(isReservedChar('('));
    try std.testing.expect(isReservedChar(')'));
    try std.testing.expect(!isReservedChar('a'));
    try std.testing.expect(!isReservedChar(' '));
}

test "base walls exclude pipe/tilde, include semicolon" {
    // `|` and `~` are body operators, not base walls.
    try std.testing.expect(!isReservedChar(PIPE));
    try std.testing.expect(!isReservedChar(TILDE));
    // `;` terminates a macro body in every mode.
    try std.testing.expect(isReservedChar(SEMICOLON));
}

test "header walls add pipe and tilde" {
    try std.testing.expect(isHeaderWall(PIPE));
    try std.testing.expect(isHeaderWall(TILDE));
    try std.testing.expect(isHeaderWall(SEMICOLON));
    // Every base wall is also a header wall.
    try std.testing.expect(isHeaderWall('$'));
    try std.testing.expect(isHeaderWall(':'));
    try std.testing.expect(!isHeaderWall('a'));
}

test "header-wall chars are identifier-escapable" {
    try std.testing.expectEqual(@as(u8, PIPE), idenEscSymToChar(PIPE).?);
    try std.testing.expectEqual(@as(u8, TILDE), idenEscSymToChar(TILDE).?);
    try std.testing.expectEqual(@as(u8, SEMICOLON), idenEscSymToChar(SEMICOLON).?);
}

test "escape sequences" {
    try std.testing.expectEqual(@as(u8, '\n'), escSymToChar('n').?);
    try std.testing.expectEqual(@as(u8, '\r'), escSymToChar('r').?);
    try std.testing.expectEqual(@as(u8, '\t'), escSymToChar('t').?);
    try std.testing.expectEqual(@as(u8, BACKSPACE), escSymToChar('b').?);
    try std.testing.expectEqual(@as(u8, FORM_FEED), escSymToChar('f').?);
    try std.testing.expectEqual(@as(u8, VERTICAL_TAB), escSymToChar('v').?);
    try std.testing.expectEqual(@as(u8, NULL_CHARACTER), escSymToChar('0').?);
    try std.testing.expectEqual(@as(u8, BELL), escSymToChar('a').?);
    try std.testing.expectEqual(@as(u8, ESCAPE_CHAR), escSymToChar('e').?);
    try std.testing.expectEqual(@as(u8, '\\'), escSymToChar('\\').?);
    try std.testing.expectEqual(@as(u8, '"'), escSymToChar('"').?);
    try std.testing.expectEqual(@as(u8, '\''), escSymToChar('\'').?);
    try std.testing.expect(escSymToChar('x') == null);
    // Identifier escapes include reserved chars
    try std.testing.expectEqual(@as(u8, '$'), idenEscSymToChar('$').?);
    try std.testing.expectEqual(@as(u8, '('), idenEscSymToChar('(').?);
}
