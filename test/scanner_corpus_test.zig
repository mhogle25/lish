//! Runs the shared scanner-boundary corpus against lish.
//!
//! Cases come from `lish.scanner_corpus` (which @embedFiles them from
//! `src/scanner_corpus/`). Two runners share the corpus:
//!
//!   - `findMacroBreakBoundary` drives the full `Lexer`, the canonical
//!     tokenizer, on the `;` (macro-body terminator) cases.
//!   - `findExpressionBoundary` drives `lish.boundary`, the focused scanner that
//!     embedders call, on *every* case (both `;` and folio's `}`). This is what
//!     pins that shared function to the lexer's lexical rules.

const std = @import("std");
const lish = @import("lish");
const Lexer = lish.Lexer;

/// The opener that nests a given terminator: `{` for folio's `}` regions; the
/// macro `;` does not nest.
fn openFor(terminator: u8) ?u8 {
    return switch (terminator) {
        '}' => '{',
        else => null,
    };
}

/// Tokenize the source (a macro body, so BODY lexer mode) and return the byte
/// offset of the first `macro_break` (`;`) token, or null if there is none.
fn findMacroBreakBoundary(source: []const u8) ?u32 {
    var lex = Lexer{ .source = source, .mode = .body };
    while (true) {
        const t = lex.nextToken();
        switch (t.type) {
            .eof => return null,
            .macro_break => return t.start,
            else => {},
        }
    }
}

test "scanner corpus: every `;` case matches lish's lexer" {
    var break_count: usize = 0;

    for (lish.scanner_corpus.cases) |case| {
        const parsed = try lish.scanner_corpus.parse(case.text);
        if (parsed.terminator != ';') continue;
        break_count += 1;

        const found = findMacroBreakBoundary(parsed.source) orelse {
            std.debug.print("\nCASE FAILED: {s}\n  no `;` token found in source\n", .{case.name});
            return error.BoundaryNotFound;
        };
        if (found != parsed.expected_boundary) {
            std.debug.print(
                "\nCASE FAILED: {s}\n  expected boundary {d}, lexer reports {d}\n  source: {s}\n",
                .{ case.name, parsed.expected_boundary, found, parsed.source },
            );
            return error.BoundaryMismatch;
        }
    }

    try std.testing.expect(break_count > 0);
}

test "scanner corpus: findExpressionBoundary matches every case" {
    for (lish.scanner_corpus.cases) |case| {
        const parsed = try lish.scanner_corpus.parse(case.text);
        const open = openFor(parsed.terminator);

        const found = lish.findExpressionBoundary(parsed.source, open, parsed.terminator) orelse {
            std.debug.print("\nCASE FAILED: {s}\n  no boundary found\n", .{case.name});
            return error.BoundaryNotFound;
        };
        if (found != parsed.expected_boundary) {
            std.debug.print(
                "\nCASE FAILED: {s}\n  expected boundary {d}, got {d}\n  source: {s}\n",
                .{ case.name, parsed.expected_boundary, found, parsed.source },
            );
            return error.BoundaryMismatch;
        }
    }
}
