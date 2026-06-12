//! Runs the shared scanner-boundary corpus against lish-zig's own lexer.
//!
//! Cases come from `lish.scanner_corpus` (which @embedFiles them from
//! `test/scanner_corpus/`). lish-zig only knows about the `|` terminator
//! (its job is finding macro-body boundaries). Other terminators (`}` for
//! folio's `{...}` regions, etc.) are exercised by their owning embedders'
//! own runners against the same module.

const std = @import("std");
const lish = @import("lish");
const Lexer = lish.Lexer;

/// Tokenize the source and return the byte offset of the first `macro_bracket`
/// (`|`) token. Returns null if the source contains no such token.
fn findPipeBoundary(source: []const u8) ?u32 {
    var lex = Lexer{ .source = source };
    while (true) {
        const t = lex.nextToken();
        switch (t.type) {
            .eof => return null,
            .macro_bracket => return t.start,
            else => {},
        }
    }
}

test "scanner corpus: every `|` case matches lish-zig's lexer" {
    var pipe_count: usize = 0;

    for (lish.scanner_corpus.cases) |case| {
        const parsed = try lish.scanner_corpus.parse(case.text);
        if (parsed.terminator != '|') continue;
        pipe_count += 1;

        const found = findPipeBoundary(parsed.source) orelse {
            std.debug.print("\nCASE FAILED: {s}\n  no `|` token found in source\n", .{case.name});
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

    try std.testing.expect(pipe_count > 0);
}
