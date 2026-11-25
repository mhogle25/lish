//! Writes an error as `name:line:column: message`, then the source line with
//! `^^^` under the part that failed. Scripts, the REPL and the macro and config
//! loaders all report through here, and so can embedders.

const std = @import("std");
const exec = @import("exec.zig");

const Position = exec.Position;

const RED = "\x1b[31m";
const RESET = "\x1b[0m";
const SOURCE_INDENT = "  ";
const MARKER = '^';

pub const Report = struct {
    /// The file the text came from, or null for text typed at the REPL.
    name: ?[]const u8,
    /// The text the error came from.
    source: []const u8,
    /// Which bytes of `source` failed, if known.
    span: ?Position,
    message: []const u8,
};

/// Line and column of a byte offset, both counted from 1. The column counts
/// characters, not bytes.
pub const Location = struct {
    line: usize,
    column: usize,
};

pub fn locate(source: []const u8, offset: usize) Location {
    const before = source[0..@min(offset, source.len)];
    const line_start = lineStart(source, before.len);
    return .{
        .line = std.mem.count(u8, before, "\n") + 1,
        .column = characterCount(before[line_start..]) + 1,
    };
}

pub fn writeReport(writer: *std.Io.Writer, report: Report, color: bool) std.Io.Writer.Error!void {
    const span = report.span orelse return writeHeadline(writer, report, null, color);

    const start = @min(span.start, report.source.len);
    try writeHeadline(writer, report, locate(report.source, start), color);

    // The line is shown without its own indentation; the column still counts it.
    const line_start = lineStart(report.source, start);
    const line_end = lineEnd(report.source, start);
    const shown_start = @min(start, line_start + leadingWhitespace(report.source[line_start..line_end]));
    const marked_end = @max(start, @min(span.end, line_end));

    try writer.writeAll(SOURCE_INDENT);
    try writer.writeAll(report.source[shown_start..line_end]);
    try writer.writeByte('\n');

    try writer.writeAll(SOURCE_INDENT);
    try writePadding(writer, report.source[shown_start..start]);
    if (color) try writer.writeAll(RED);
    try writer.splatByteAll(MARKER, @max(1, characterCount(report.source[start..marked_end])));
    if (color) try writer.writeAll(RESET);
    try writer.writeByte('\n');
}

fn writeHeadline(writer: *std.Io.Writer, report: Report, location: ?Location, color: bool) std.Io.Writer.Error!void {
    if (color) try writer.writeAll(RED);
    if (report.name) |name| try writer.print("{s}:", .{name});
    if (location) |where| try writer.print("{d}:{d}:", .{ where.line, where.column });
    if (report.name != null or location != null) try writer.writeByte(' ');
    try writer.writeAll(report.message);
    if (color) try writer.writeAll(RESET);
    try writer.writeByte('\n');
}

/// One space per character before the failing part, keeping tabs as tabs so the
/// marker lines up however wide the terminal draws a tab.
fn writePadding(writer: *std.Io.Writer, before: []const u8) std.Io.Writer.Error!void {
    for (before) |byte| {
        if (byte == '\t') {
            try writer.writeByte('\t');
        } else if (!isContinuationByte(byte)) {
            try writer.writeByte(' ');
        }
    }
}

fn leadingWhitespace(line: []const u8) usize {
    for (line, 0..) |byte, index| {
        if (byte != ' ' and byte != '\t') return index;
    }
    return line.len;
}

fn lineStart(source: []const u8, offset: usize) usize {
    const newline = std.mem.lastIndexOfScalar(u8, source[0..offset], '\n') orelse return 0;
    return newline + 1;
}

/// Where the line holding `offset` ends, not counting a `\r` before its `\n`.
fn lineEnd(source: []const u8, offset: usize) usize {
    const end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
    if (end > offset and source[end - 1] == '\r') return end - 1;
    return end;
}

/// UTF-8 characters in `text`: every byte except the continuation bytes of a
/// multi-byte character.
fn characterCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (!isContinuationByte(byte)) count += 1;
    }
    return count;
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

fn expectReport(report: Report, color: bool, expected: []const u8) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeReport(&output.writer, report, color);
    try std.testing.expectEqualStrings(expected, output.written());
}

test "diagnostics: names the file, line and column, and marks the failing part" {
    try expectReport(.{
        .name = "backup.lish",
        .source = "list 1\n  (+ 2 3)\n  (nosuchop 4)\n",
        .span = .{ .start = 19, .end = 31 },
        .message = "Unknown operation or macro: 'nosuchop'",
    }, false,
        \\backup.lish:3:3: Unknown operation or macro: 'nosuchop'
        \\  (nosuchop 4)
        \\  ^^^^^^^^^^^^
        \\
    );
}

test "diagnostics: text typed at the REPL has no file name" {
    try expectReport(.{
        .name = null,
        .source = "nosuchop 1",
        .span = .{ .start = 0, .end = 10 },
        .message = "Unknown operation or macro: 'nosuchop'",
    }, false,
        \\1:1: Unknown operation or macro: 'nosuchop'
        \\  nosuchop 1
        \\  ^^^^^^^^^^
        \\
    );
}

test "diagnostics: a span that runs onto later lines is marked to the end of its first line" {
    try expectReport(.{
        .name = "backup.lish",
        .source = "say (concat\n  \"a\")",
        .span = .{ .start = 4, .end = 18 },
        .message = "Expected at least 2 argument(s) but got 1",
    }, false,
        \\backup.lish:1:5: Expected at least 2 argument(s) but got 1
        \\  say (concat
        \\      ^^^^^^^
        \\
    );
}

test "diagnostics: an empty span at the end of the text gets one marker" {
    try expectReport(.{
        .name = null,
        .source = "say (+ 1",
        .span = .{ .start = 8, .end = 8 },
        .message = "Missing closing parenthesis",
    }, false,
        \\1:9: Missing closing parenthesis
        \\  say (+ 1
        \\          ^
        \\
    );
}

test "diagnostics: the line's own indentation is dropped, but the column still counts it" {
    try expectReport(.{
        .name = null,
        .source = "say 1\n        (nosuchop 4)",
        .span = .{ .start = 14, .end = 26 },
        .message = "Unknown operation or macro: 'nosuchop'",
    }, false,
        \\2:9: Unknown operation or macro: 'nosuchop'
        \\  (nosuchop 4)
        \\  ^^^^^^^^^^^^
        \\
    );
}

test "diagnostics: a tab inside the line is kept in the marker so it lines up" {
    try expectReport(.{
        .name = null,
        .source = "\tsay\t(nosuchop 4)",
        .span = .{ .start = 5, .end = 17 },
        .message = "Unknown operation or macro: 'nosuchop'",
    }, false, "1:6: Unknown operation or macro: 'nosuchop'\n" ++
        "  say\t(nosuchop 4)\n" ++
        "     \t^^^^^^^^^^^^\n");
}

test "diagnostics: the column counts characters, not bytes" {
    try expectReport(.{
        .name = null,
        .source = "say \"é\" (nosuchop 4)",
        .span = .{ .start = 9, .end = 21 },
        .message = "Unknown operation or macro: 'nosuchop'",
    }, false,
        \\1:9: Unknown operation or macro: 'nosuchop'
        \\  say "é" (nosuchop 4)
        \\          ^^^^^^^^^^^^
        \\
    );
}

test "diagnostics: a Windows line ending isn't shown as part of the line" {
    try expectReport(.{
        .name = "backup.lish",
        .source = "say 1\r\n(nosuchop 4)\r\n",
        .span = .{ .start = 7, .end = 19 },
        .message = "Unknown operation or macro: 'nosuchop'",
    }, false,
        \\backup.lish:2:1: Unknown operation or macro: 'nosuchop'
        \\  (nosuchop 4)
        \\  ^^^^^^^^^^^^
        \\
    );
}

test "diagnostics: an error with no span is just the name and message" {
    const report: Report = .{ .name = "backup.lish", .source = "say 1", .span = null, .message = "Memory budget exhausted" };
    try expectReport(report, false, "backup.lish: Memory budget exhausted\n");

    var at_repl = report;
    at_repl.name = null;
    try expectReport(at_repl, false, "Memory budget exhausted\n");
}

test "diagnostics: colour wraps the first line and the marker, never the source line" {
    try expectReport(.{
        .name = null,
        .source = "nosuchop 1",
        .span = .{ .start = 0, .end = 8 },
        .message = "Unknown operation or macro: 'nosuchop'",
    }, true, RED ++ "1:1: Unknown operation or macro: 'nosuchop'" ++ RESET ++ "\n" ++
        "  nosuchop 1\n" ++
        "  " ++ RED ++ "^^^^^^^^" ++ RESET ++ "\n");
}

test "diagnostics: locate counts lines and characters from 1" {
    try std.testing.expectEqual(Location{ .line = 1, .column = 1 }, locate("abc", 0));
    try std.testing.expectEqual(Location{ .line = 2, .column = 3 }, locate("ab\ncde", 5));
    try std.testing.expectEqual(Location{ .line = 2, .column = 1 }, locate("ab\n", 99));
}
