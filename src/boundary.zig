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

/// Offset of `terminator` in `source` (which starts just past the opener), or null if unterminated. Skips strings and `##` comments.
/// A non-null `open` tracks nesting (folio's `{`/`}`); a null `open` means the first `terminator` wins (macro `;`).
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

fn skipString(source: []const u8, quote_idx: usize) usize {
    const quote = source[quote_idx];
    var idx = quote_idx + 1;
    while (idx < source.len) {
        const c = source[idx];
        if (c == tok.BACKSLASH) {
            idx += if (idx + 1 < source.len) 2 else 1;
            continue;
        }
        if (c == quote) return idx + 1;
        idx += 1;
    }
    return idx;
}

fn skipComment(source: []const u8, open_idx: usize) usize {
    var idx = open_idx + 2;
    while (idx < source.len) {
        const c = source[idx];
        if (c == tok.NEWLINE or c == tok.CARRIAGE_RETURN) return idx;
        if (c == tok.COMMENT and idx + 1 < source.len and source[idx + 1] == tok.COMMENT) {
            return idx + 2;
        }
        idx += 1;
    }
    return idx;
}
