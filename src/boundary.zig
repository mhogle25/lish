//! Finds where an embedded lish expression ends.
//!
//! Hosts that splice lish into their own syntax need the same answer: given the
//! text right after an opening delimiter, where is the terminator that closes
//! it, skipping any terminator that sits inside a string, a comment, or a
//! nested bracket pair? folio's `{...}` regions and the macro grammar's
//! `| body ;` bodies both ask this. This is the single place that answers it.
//!
//! It mirrors `lexer.zig`'s string and comment rules exactly; the corpus in
//! `src/scanner_corpus/` pins the two together so they can't drift.
//!
//! Streaming embedders (tree-sitter external scanners) can't call this; they
//! receive input one codepoint at a time and have no buffer to pass. They keep
//! their own scan, held to the same corpus.

const std = @import("std");
const tok = @import("token.zig");

/// Offset of the expression-terminating `terminator` in `source`, or null if
/// the source ends first (unterminated).
///
/// `source` begins just after the opening delimiter. When `open` is non-null,
/// nesting is tracked: each `open` raises the depth and each `terminator` lowers
/// it, so the boundary is the `terminator` seen at depth 0 (folio's `{`/`}`).
/// When `open` is null the terminator does not nest, so the first
/// unquoted/uncommented `terminator` is the boundary (the macro body `;`).
///
/// Strings (`"`/`'`, with `\` escapes) and `##` comments are skipped, so a
/// terminator inside them counts as content.
pub fn findExpressionBoundary(source: []const u8, open: ?u8, terminator: u8) ?usize {
    var idx: usize = 0;
    var depth: usize = 0;
    while (idx < source.len) {
        const c = source[idx];

        if (c == tok.QUOTE_DOUBLE or c == tok.QUOTE_SINGLE) {
            idx = skipString(source, idx);
            continue;
        }
        if (c == tok.COMMENT and idx + 1 < source.len and source[idx + 1] == tok.COMMENT) {
            idx = skipComment(source, idx);
            continue;
        }
        if (c == terminator) {
            if (depth == 0) return idx;
            depth -= 1;
        } else if (open != null and c == open.?) {
            depth += 1;
        }
        idx += 1;
    }
    return null;
}

/// Skip a string literal whose opening quote is at `quote_idx`. Returns the
/// offset just past the closing quote, or `source.len` if unterminated.
/// Mirrors the BACKSLASH handling in `lexer.zig`'s string scanner.
fn skipString(source: []const u8, quote_idx: usize) usize {
    const quote = source[quote_idx];
    var idx = quote_idx + 1; // past the opening quote
    while (idx < source.len) {
        const c = source[idx];
        if (c == tok.BACKSLASH) {
            idx += if (idx + 1 < source.len) 2 else 1; // skip the escaped char too
            continue;
        }
        if (c == quote) return idx + 1; // past the closing quote
        idx += 1;
    }
    return idx; // unterminated: consumed to EOF
}

/// Skip a `##` comment whose opener is at `open_idx`. Comments end at the next
/// `##` (inline form, consumed) or at a newline/EOF (to-EOL form, left in
/// place). Mirrors `lexer.zig`'s comment skipping.
fn skipComment(source: []const u8, open_idx: usize) usize {
    var idx = open_idx + 2; // past the opening ##
    while (idx < source.len) {
        const c = source[idx];
        if (c == tok.NEWLINE or c == tok.CARRIAGE_RETURN) return idx;
        if (c == tok.COMMENT and idx + 1 < source.len and source[idx + 1] == tok.COMMENT) {
            return idx + 2; // past the closing ##
        }
        idx += 1;
    }
    return idx; // EOF
}
