//! Exposes the shared scanner-boundary corpus as a comptime const so any
//! embedder linking against the lish module can run its own scanner against
//! the same set of cases.
//!
//! The case files live in `test/scanner_corpus/` and the README there
//! documents the file format + the contract. Use `parse(case.text)` to
//! decode each case's header into a `Parsed` struct, then point your scanner
//! at `Parsed.source` and assert the result equals `Parsed.expected_boundary`.

const std = @import("std");

pub const Case = struct {
    name: []const u8,
    text: []const u8,
};

pub const Parsed = struct {
    terminator: u8,
    expected_boundary: u32,
    source: []const u8,
};

/// Decode the header of a `.case` file. Returns `error.MalformedCase` if any
/// required field is missing or unparseable. The returned `source` is a slice
/// of `text` — no allocations.
pub fn parse(text: []const u8) !Parsed {
    var terminator: ?u8 = null;
    var expected: ?u32 = null;

    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "---")) break;
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            const key = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            if (std.mem.eql(u8, key, "terminator")) {
                if (value.len != 1) return error.MalformedCase;
                terminator = value[0];
            } else if (std.mem.eql(u8, key, "boundary")) {
                expected = try std.fmt.parseInt(u32, value, 10);
            }
        }
    }

    if (terminator == null or expected == null) return error.MalformedCase;

    var source = rest;
    if (source.len > 0 and source[source.len - 1] == '\n') {
        source = source[0 .. source.len - 1];
    }

    return .{
        .terminator = terminator.?,
        .expected_boundary = expected.?,
        .source = source,
    };
}

/// All corpus cases, embedded at compile time. To add a case: drop the
/// `.case` file in `test/scanner_corpus/` and append an entry here.
pub const cases = [_]Case{
    .{ .name = "01_simple_pipe.case",                 .text = @embedFile("scanner_corpus/01_simple_pipe.case") },
    .{ .name = "02_pipe_in_double_string.case",       .text = @embedFile("scanner_corpus/02_pipe_in_double_string.case") },
    .{ .name = "03_pipe_in_single_string.case",       .text = @embedFile("scanner_corpus/03_pipe_in_single_string.case") },
    .{ .name = "04_pipe_in_inline_comment.case",      .text = @embedFile("scanner_corpus/04_pipe_in_inline_comment.case") },
    .{ .name = "05_pipe_in_eol_comment.case",         .text = @embedFile("scanner_corpus/05_pipe_in_eol_comment.case") },
    .{ .name = "06_escaped_quote_in_string.case",     .text = @embedFile("scanner_corpus/06_escaped_quote_in_string.case") },
    .{ .name = "07_brace_in_double_string.case",      .text = @embedFile("scanner_corpus/07_brace_in_double_string.case") },
    .{ .name = "08_brace_in_inline_comment.case",     .text = @embedFile("scanner_corpus/08_brace_in_inline_comment.case") },
    .{ .name = "09_open_brace_in_inline_comment.case", .text = @embedFile("scanner_corpus/09_open_brace_in_inline_comment.case") },
    .{ .name = "10_nested_braces_in_lish.case",       .text = @embedFile("scanner_corpus/10_nested_braces_in_lish.case") },
    .{ .name = "11_empty_string_before_terminator.case", .text = @embedFile("scanner_corpus/11_empty_string_before_terminator.case") },
    .{ .name = "12_escaped_backslash_in_string.case",  .text = @embedFile("scanner_corpus/12_escaped_backslash_in_string.case") },
    .{ .name = "13_string_immediately_terminates.case", .text = @embedFile("scanner_corpus/13_string_immediately_terminates.case") },
    .{ .name = "14_leading_comment_then_content.case", .text = @embedFile("scanner_corpus/14_leading_comment_then_content.case") },
    .{ .name = "15_string_with_pipe_in_middle.case",   .text = @embedFile("scanner_corpus/15_string_with_pipe_in_middle.case") },
};

test "parse: minimal case" {
    const text =
        \\terminator: |
        \\boundary: 8
        \\---
        \\do-thing|next
        \\
    ;
    const p = try parse(text);
    try std.testing.expectEqual(@as(u8, '|'), p.terminator);
    try std.testing.expectEqual(@as(u32, 8), p.expected_boundary);
    try std.testing.expectEqualStrings("do-thing|next", p.source);
}
