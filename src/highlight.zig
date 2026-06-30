//! Source token categorization for syntax highlighting.
//!
//! The `Highlighter` walks a source string and emits non-overlapping `Span`s,
//! each tagged with a `Category`. Whitespace is silently skipped; only
//! semantically meaningful regions produce spans.
//!
//! This is independent of the parser's `Lexer` because highlighting has
//! different needs: comments produce spans (the lexer skips them), and the
//! highlighter is forgiving about malformed input (no errors, just best-effort
//! categorization) since it runs on every keystroke.

const std = @import("std");
const tok = @import("token.zig");

pub const Category = enum {
    comment,
    string,
    number,
    identifier,
    scope_ref,
    sigil,
    bracket,
    macro_bar,
};

pub const Span = struct {
    category: Category,
    start:    u32,
    end:      u32,
};

/// Header/body zone, mirroring the lexer (see lexer.Mode). In a header `|`/`~`
/// are macro structure; in a body they are ordinary operators. A `.lish` file
/// and the REPL are always `.body`; a `.lishmacro` file starts `.header`.
pub const Mode = enum { header, body };

pub const Highlighter = struct {
    source: []const u8,
    pos:    usize = 0,
    /// Current zone. Flips to `.body` at the header/body `|` and back to
    /// `.header` at the `;` terminator.
    mode: Mode = .body,
    /// True if the last emitted span was a `:` sigil. The next identifier
    /// becomes a `scope_ref` instead of a generic identifier.
    after_scope_thunk: bool = false,

    pub fn init(source: []const u8) Highlighter {
        return .{ .source = source };
    }

    /// Start highlighting in a specific zone. A `.lishmacro` document starts in
    /// `.header`; a plain expression / REPL line uses `init` (`.body`).
    pub fn initMode(source: []const u8, mode: Mode) Highlighter {
        return .{ .source = source, .mode = mode };
    }

    pub fn next(self: *Highlighter) ?Span {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];

            if (isWhitespace(c)) {
                self.pos += 1;
                continue;
            }

            const start: u32 = @intCast(self.pos);

            // ## ... (to newline or matching ##).
            if (c == tok.COMMENT and self.pos + 1 < self.source.len and self.source[self.pos + 1] == tok.COMMENT) {
                self.scanComment();
                self.after_scope_thunk = false;
                return .{ .category = .comment, .start = start, .end = @intCast(self.pos) };
            }

            // String literal.
            if (c == tok.QUOTE_DOUBLE or c == tok.QUOTE_SINGLE) {
                self.scanString(c);
                self.after_scope_thunk = false;
                return .{ .category = .string, .start = start, .end = @intCast(self.pos) };
            }

            // Number: positive digit run, or `-` followed by a digit.
            if (isDigit(c) or (c == tok.NEGATIVE_SIGN and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))) {
                self.scanNumber();
                self.after_scope_thunk = false;
                return .{ .category = .number, .start = start, .end = @intCast(self.pos) };
            }

            // Bracket.
            if (isBracket(c)) {
                self.pos += 1;
                self.after_scope_thunk = false;
                return .{ .category = .bracket, .start = start, .end = @intCast(self.pos) };
            }

            // `;` terminates a macro body in every zone; the next header begins.
            if (c == tok.SEMICOLON) {
                self.pos += 1;
                self.mode = .header;
                self.after_scope_thunk = false;
                return .{ .category = .macro_bar, .start = start, .end = @intCast(self.pos) };
            }

            // `|` separates header from body ONLY in a header; in a body it is a
            // bitwise operator (falls through to the identifier scan below).
            if (c == tok.PIPE and self.mode == .header) {
                self.pos += 1;
                self.mode = .body;
                self.after_scope_thunk = false;
                return .{ .category = .macro_bar, .start = start, .end = @intCast(self.pos) };
            }

            // `~` is the deferred-param marker ONLY in a header; in a body it is a
            // bitwise operator (falls through to the identifier scan below).
            if (c == tok.TILDE and self.mode == .header) {
                self.pos += 1;
                self.after_scope_thunk = false;
                return .{ .category = .sigil, .start = start, .end = @intCast(self.pos) };
            }

            // Sigils: $ : (reserved in every zone). The `:` flips a flag so the
            // next identifier becomes a scope_ref.
            if (c == tok.EXPRESSION_SINGLE or c == tok.SCOPE_THUNK) {
                self.pos += 1;
                self.after_scope_thunk = (c == tok.SCOPE_THUNK);
                return .{ .category = .sigil, .start = start, .end = @intCast(self.pos) };
            }

            // Identifier (default).
            const was_scope_ref = self.after_scope_thunk;
            self.scanIdentifier();
            self.after_scope_thunk = false;

            return .{
                .category = if (was_scope_ref) .scope_ref else .identifier,
                .start    = start,
                .end      = @intCast(self.pos),
            };
        }
        return null;
    }

    fn scanComment(self: *Highlighter) void {
        // Skip the opening `##`.
        self.pos += 2;
        // Comments end at newline, EOF, or matching `##`.
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];

            if (c == tok.NEWLINE or c == tok.CARRIAGE_RETURN) break;
            
            if (c == tok.COMMENT and self.pos + 1 < self.source.len and self.source[self.pos + 1] == tok.COMMENT) {
                self.pos += 2;
                return;
            }

            self.pos += 1;
        }
    }

    fn scanString(self: *Highlighter, quote: u8) void {
        self.pos += 1; // opening quote
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];

            if (c == tok.BACKSLASH and self.pos + 1 < self.source.len) {
                self.pos += 2;
                continue;
            }

            if (c == quote) {
                self.pos += 1;
                return;
            }

            if (c == tok.NEWLINE) return; // unterminated string ends at newline
                                          //
            self.pos += 1;
        }
    }

    fn scanNumber(self: *Highlighter) void {
        if (self.source[self.pos] == tok.NEGATIVE_SIGN) self.pos += 1;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];

            if (!isDigit(c) and c != tok.DECIMAL_POINT) break;

            self.pos += 1;
        }
    }

    fn scanIdentifier(self: *Highlighter) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];

            // Base walls always end a term; `|`/`~` end one only in a header
            // (in a body they are part of an operator term, e.g. `~5`, `a|b`).
            if (isWhitespace(c)
                or isBracket(c)
                or c == tok.EXPRESSION_SINGLE
                or c == tok.SCOPE_THUNK
                or c == tok.SEMICOLON
                or c == tok.QUOTE_DOUBLE
                or c == tok.QUOTE_SINGLE
                or (self.mode == .header and (c == tok.PIPE or c == tok.TILDE))) break;

            self.pos += 1;
        }
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isBracket(c: u8) bool {
    return c == tok.EXPRESSION_OPEN 
        or c == tok.EXPRESSION_CLOSE 
        or c == tok.LIST_OPEN 
        or c == tok.LIST_CLOSE 
        or c == tok.BLOCK_OPEN 
        or c == tok.BLOCK_CLOSE;
}


const testing = std.testing;

fn expectSpans(source: []const u8, expected: []const Span) !void {
    var hl = Highlighter.init(source);

    for (expected) |exp| {
        const got = hl.next() orelse return error.TestExpectedSpan;
        try testing.expectEqual(exp.category, got.category);
        try testing.expectEqual(exp.start, got.start);
        try testing.expectEqual(exp.end, got.end);
    }

    try testing.expect(hl.next() == null);
}

test "highlight: number" {
    try expectSpans("42", &.{
        .{ .category = .number, .start = 0, .end = 2 },
    });
}

test "highlight: negative number" {
    try expectSpans("-17", &.{
        .{ .category = .number, .start = 0, .end = 3 },
    });
}

test "highlight: float" {
    try expectSpans("3.14", &.{
        .{ .category = .number, .start = 0, .end = 4 },
    });
}

test "highlight: string" {
    try expectSpans("\"hello\"", &.{
        .{ .category = .string, .start = 0, .end = 7 },
    });
}

test "highlight: string with escape" {
    try expectSpans("\"a\\nb\"", &.{
        .{ .category = .string, .start = 0, .end = 6 },
    });
}

test "highlight: identifier" {
    try expectSpans("hello", &.{
        .{ .category = .identifier, .start = 0, .end = 5 },
    });
}

test "highlight: scope ref" {
    try expectSpans(":hp", &.{
        .{ .category = .sigil, .start = 0, .end = 1 },
        .{ .category = .scope_ref, .start = 1, .end = 3 },
    });
}

test "highlight: brackets" {
    try expectSpans("()[]{}", &.{
        .{ .category = .bracket, .start = 0, .end = 1 },
        .{ .category = .bracket, .start = 1, .end = 2 },
        .{ .category = .bracket, .start = 2, .end = 3 },
        .{ .category = .bracket, .start = 3, .end = 4 },
        .{ .category = .bracket, .start = 4, .end = 5 },
        .{ .category = .bracket, .start = 5, .end = 6 },
    });
}

test "highlight: comment to newline" {
    try expectSpans("## hi\n42", &.{
        .{ .category = .comment, .start = 0, .end = 5 },
        .{ .category = .number, .start = 6, .end = 8 },
    });
}

test "highlight: block comment" {
    try expectSpans("## inline ## 42", &.{
        .{ .category = .comment, .start = 0, .end = 12 },
        .{ .category = .number, .start = 13, .end = 15 },
    });
}

fn expectSpansMode(source: []const u8, mode: Mode, expected: []const Span) !void {
    var hl = Highlighter.initMode(source, mode);
    for (expected) |exp| {
        const got = hl.next() orelse return error.TestExpectedSpan;
        try testing.expectEqual(exp.category, got.category);
        try testing.expectEqual(exp.start, got.start);
        try testing.expectEqual(exp.end, got.end);
    }
    try testing.expect(hl.next() == null);
}

test "highlight: macro header then body then terminator" {
    // `double x | * :x 2 ;` in header mode: name + param, `|` macro_bar flips to
    // body where `*` is an operator identifier, and `;` is the terminator.
    try expectSpansMode("double x | :x ;", .header, &.{
        .{ .category = .identifier, .start = 0, .end = 6 }, // double
        .{ .category = .identifier, .start = 7, .end = 8 }, // x
        .{ .category = .macro_bar, .start = 9, .end = 10 }, // |
        .{ .category = .sigil, .start = 11, .end = 12 }, // :
        .{ .category = .scope_ref, .start = 12, .end = 13 }, // x
        .{ .category = .macro_bar, .start = 14, .end = 15 }, // ;
    });
}

test "highlight: deferred marker is a sigil in a header" {
    try expectSpansMode("run ~body |", .header, &.{
        .{ .category = .identifier, .start = 0, .end = 3 }, // run
        .{ .category = .sigil, .start = 4, .end = 5 }, // ~
        .{ .category = .identifier, .start = 5, .end = 9 }, // body
        .{ .category = .macro_bar, .start = 10, .end = 11 }, // |
    });
}

test "highlight: body-mode | and ~ are operator identifiers" {
    // Default (body) mode: `|`/`~` are part of operator terms, not structure.
    try expectSpans("| :a", &.{
        .{ .category = .identifier, .start = 0, .end = 1 }, // | operator
        .{ .category = .sigil, .start = 2, .end = 3 }, // :
        .{ .category = .scope_ref, .start = 3, .end = 4 }, // a
    });

    try expectSpans("~5", &.{
        .{ .category = .identifier, .start = 0, .end = 2 }, // ~5 is one term
    });
}

test "highlight: simple expression" {
    try expectSpans("(when (< :hp 10) [flee])", &.{
        .{ .category = .bracket, .start = 0, .end = 1 },
        .{ .category = .identifier, .start = 1, .end = 5 },
        .{ .category = .bracket, .start = 6, .end = 7 },
        .{ .category = .identifier, .start = 7, .end = 8 },
        .{ .category = .sigil, .start = 9, .end = 10 },
        .{ .category = .scope_ref, .start = 10, .end = 12 },
        .{ .category = .number, .start = 13, .end = 15 },
        .{ .category = .bracket, .start = 15, .end = 16 },
        .{ .category = .bracket, .start = 17, .end = 18 },
        .{ .category = .identifier, .start = 18, .end = 22 },
        .{ .category = .bracket, .start = 22, .end = 23 },
        .{ .category = .bracket, .start = 23, .end = 24 },
    });
}

test "highlight: empty string" {
    var hl = Highlighter.init("");
    try testing.expect(hl.next() == null);
}

test "highlight: whitespace only" {
    var hl = Highlighter.init("   \n\t  ");
    try testing.expect(hl.next() == null);
}
