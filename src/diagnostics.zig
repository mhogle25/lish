//! Writes an error as `name:line:column: message`, then the source line with
//! `^^^` under the part that failed. Scripts, the REPL and the macro and config
//! loaders all report through here, and so can embedders.

const std = @import("std");
const exec = @import("exec.zig");
const validation = @import("validation.zig");

const Position = exec.Position;
const RuntimeErr = exec.RuntimeErr;
const ErrorStep = exec.ErrorStep;
const Macro = exec.Macro;
const ValidationError = validation.ValidationError;

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
    first_line: usize = 1,
};

pub const Source = struct {
    /// null for text typed at the REPL.
    name: ?[]const u8,
    text: []const u8,
    first_line: usize = 1,
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
    const location = if (report.span) |span| locateFrom(report.source, span.start, report.first_line) else null;

    if (color) try writer.writeAll(RED);
    try writeLocation(writer, report.name, location);
    if (report.name != null or location != null) try writer.writeByte(' ');
    try writer.writeAll(report.message);
    if (color) try writer.writeAll(RESET);
    try writer.writeByte('\n');

    try writeMarkedLine(writer, report.source, report.span, color);
}

/// A runtime error: where it ended up in the text that was run, then each macro it
/// passed through on the way out, from that call inward to where it failed.
pub fn writeRuntimeReport(writer: *std.Io.Writer, source: Source, problem: RuntimeErr, color: bool) std.Io.Writer.Error!void {
    const in_run_text = problem.macro == null;
    try writeReport(writer, .{
        .name = if (in_run_text) source.name else null,
        .source = textOf(problem.macro, source.text),
        .span = problem.position,
        .message = problem.message,
        .first_line = if (in_run_text) source.first_line else 1,
    }, color);

    var remaining = problem.steps.len;
    while (remaining > 0) : (remaining -= 1) {
        try writeStep(writer, source, problem.steps[remaining - 1], color);
    }
    if (problem.steps_incomplete) try writer.writeAll("(some steps couldn't be recorded)\n");
}

/// A problem found before anything ran.
pub fn writeValidationReport(writer: *std.Io.Writer, source: Source, problem: ValidationError, color: bool) std.Io.Writer.Error!void {
    const span: ?Position = if (problem.start) |start|
        .{ .start = @intCast(start), .end = @intCast(problem.end orelse start) }
    else
        null;
    try writeReport(writer, .{
        .name = source.name,
        .source = source.text,
        .span = span,
        .message = problem.message,
        .first_line = source.first_line,
    }, color);
}

fn writeStep(writer: *std.Io.Writer, source: Source, step: ErrorStep, color: bool) std.Io.Writer.Error!void {
    if (step.macro) |macro| {
        try writer.print("in macro {s}:\n", .{macro.id});
    } else {
        try writer.writeAll("back in ");
        const location = if (step.position) |span| locateFrom(source.text, span.start, source.first_line) else null;
        try writeLocation(writer, source.name, location);
        try writer.writeByte('\n');
    }
    try writeMarkedLine(writer, textOf(step.macro, source.text), step.position, color);
    if (step.repeats > 0) try writer.print("[previous step repeated {d} more times]\n", .{step.repeats});
}

fn locateFrom(text: []const u8, offset: usize, first_line: usize) Location {
    const within = locate(text, offset);
    return .{ .line = within.line + first_line - 1, .column = within.column };
}

/// The text a position is in: its macro's, or the text that was run.
fn textOf(macro: ?*const Macro, run_text: []const u8) []const u8 {
    const owner = macro orelse return run_text;
    return owner.text;
}

/// `name:line:column:`, leaving out whichever part isn't known.
fn writeLocation(writer: *std.Io.Writer, name: ?[]const u8, location: ?Location) std.Io.Writer.Error!void {
    if (name) |file| try writer.print("{s}:", .{file});
    if (location) |where| try writer.print("{d}:{d}:", .{ where.line, where.column });
}

/// The line holding `span`, without its own indentation, with `^` under the span.
fn writeMarkedLine(writer: *std.Io.Writer, source: []const u8, span: ?Position, color: bool) std.Io.Writer.Error!void {
    const marked = span orelse return;
    const start = @min(marked.start, source.len);

    const line_start = lineStart(source, start);
    const line_end = lineEnd(source, start);
    const shown_start = @min(start, line_start + leadingWhitespace(source[line_start..line_end]));
    const marked_end = @max(start, @min(marked.end, line_end));

    try writer.writeAll(SOURCE_INDENT);
    try writer.writeAll(source[shown_start..line_end]);
    try writer.writeByte('\n');

    try writer.writeAll(SOURCE_INDENT);
    try writePadding(writer, source[shown_start..start]);
    if (color) try writer.writeAll(RED);
    try writer.splatByteAll(MARKER, @max(1, characterCount(source[start..marked_end])));
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
    const accented = "\u{e9}";
    try expectReport(.{
        .name = null,
        .source = "say \"" ++ accented ++ "\" (nosuchop 4)",
        .span = .{ .start = 9, .end = 21 },
        .message = "Unknown operation or macro: 'nosuchop'",
    }, false, "1:9: Unknown operation or macro: 'nosuchop'\n" ++
        "  say \"" ++ accented ++ "\" (nosuchop 4)\n" ++
        "          ^^^^^^^^^^^^\n");
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

fn testMacro(id: []const u8, text: []const u8) Macro {
    return .{ .id = id, .text = text, .parameters = &.{}, .body = undefined, .body_position = .synthetic };
}

fn spanOf(text: []const u8, piece: []const u8) Position {
    const start: u32 = @intCast(std.mem.indexOf(u8, text, piece).?);
    return .{ .start = start, .end = start + @as(u32, @intCast(piece.len)) };
}

fn expectRuntimeReport(name: ?[]const u8, run_text: []const u8, problem: RuntimeErr, expected: []const u8) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRuntimeReport(&output.writer, .{ .name = name, .text = run_text }, problem, false);
    try std.testing.expectEqualStrings(expected, output.written());
}

test "diagnostics: a runtime error shows your call, then each macro inward to where it failed" {
    const clamp01 = testMacro("clamp01", "clamp01 v | clamp :v 0 1 ;");
    const clamp = testMacro("clamp", "clamp v lo hi |\n   min :hi (max :lo :v) ;");
    const run_text = "list 1\n  (clamp01 \"a\")\n";

    const steps = [_]ErrorStep{
        .{ .macro = &clamp, .position = spanOf(clamp.text, "(max :lo :v)") },
        .{ .macro = &clamp01, .position = spanOf(clamp01.text, "clamp :v 0 1") },
    };
    try expectRuntimeReport("backup.lish", run_text, .{
        .category = .type_mismatch,
        .message = "'max' expects numbers, got string",
        .position = spanOf(run_text, "(clamp01 \"a\")"),
        .steps = &steps,
    },
        \\backup.lish:2:3: 'max' expects numbers, got string
        \\  (clamp01 "a")
        \\  ^^^^^^^^^^^^^
        \\in macro clamp01:
        \\  clamp01 v | clamp :v 0 1 ;
        \\              ^^^^^^^^^^^^
        \\in macro clamp:
        \\  min :hi (max :lo :v) ;
        \\          ^^^^^^^^^^^^
        \\
    );
}

test "diagnostics: stepping back into your text, repeats, and lost steps are each one line" {
    const twice = testMacro("twice", "twice ~x | list :x :x ;");
    const run_text = "(twice (nosuchop))";

    const steps = [_]ErrorStep{
        .{ .macro = null, .position = spanOf(run_text, "(nosuchop)") },
        .{ .macro = &twice, .position = spanOf(twice.text, ":x"), .repeats = 2 },
    };
    try expectRuntimeReport(null, run_text, .{
        .category = .unknown_op,
        .message = "Unknown operation or macro: 'nosuchop'",
        .position = spanOf(run_text, run_text),
        .steps = &steps,
        .steps_incomplete = true,
    },
        \\1:1: Unknown operation or macro: 'nosuchop'
        \\  (twice (nosuchop))
        \\  ^^^^^^^^^^^^^^^^^^
        \\in macro twice:
        \\  twice ~x | list :x :x ;
        \\                  ^^
        \\[previous step repeated 2 more times]
        \\back in 1:8:
        \\  (twice (nosuchop))
        \\         ^^^^^^^^^^
        \\(some steps couldn't be recorded)
        \\
    );
}

test "diagnostics: a validation problem is reported at its span, or by name alone without one" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const source = "list 1\n  (say (+ 4 5)";
    try writeValidationReport(&output.writer, .{ .name = "backup.lish", .text = source }, .{ .message = "Missing closing parenthesis", .start = 9, .end = 10 }, false);
    try writeValidationReport(&output.writer, .{ .name = "backup.lish", .text = source }, .{ .message = "Macro body must be an expression" }, false);
    try std.testing.expectEqualStrings(
        \\backup.lish:2:3: Missing closing parenthesis
        \\  (say (+ 4 5)
        \\  ^
        \\backup.lish: Macro body must be an expression
        \\
    , output.written());
}

test "diagnostics: text that starts partway through its input counts lines from there" {
    const twice = testMacro("twice", "twice ~x | list :x :x ;");
    const command = "list 1\n  (twice (nosuchop))";

    const steps = [_]ErrorStep{
        .{ .macro = null, .position = spanOf(command, "(nosuchop)") },
        .{ .macro = &twice, .position = spanOf(twice.text, ":x") },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRuntimeReport(&output.writer, .{ .name = "<stdin>", .text = command, .first_line = 1204 }, .{
        .category = .unknown_op,
        .message = "Unknown operation or macro: 'nosuchop'",
        .position = spanOf(command, "(twice (nosuchop))"),
        .steps = &steps,
    }, false);
    try std.testing.expectEqualStrings(
        \\<stdin>:1205:3: Unknown operation or macro: 'nosuchop'
        \\  (twice (nosuchop))
        \\  ^^^^^^^^^^^^^^^^^^
        \\in macro twice:
        \\  twice ~x | list :x :x ;
        \\                  ^^
        \\back in <stdin>:1205:10:
        \\  (twice (nosuchop))
        \\         ^^^^^^^^^^
        \\
    , output.written());
}
