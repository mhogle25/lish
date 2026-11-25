const std = @import("std");
const highlight = @import("../highlight.zig");

pub const PROMPT = "lish> ";

const ANSI_RESET = "\x1b[0m";

fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn writeContinuation(writer: *std.Io.Writer, prompt_width: usize) std.Io.Writer.Error!void {
    if (prompt_width == 0) return;
    try writer.splatByteAll('.', prompt_width - 1);
    try writer.writeByte(' ');
}

fn ansiFor(category: highlight.Category) []const u8 {
    return switch (category) {
        .comment    => "\x1b[2m",       // dim
        .string     => "\x1b[32m",      // green
        .number     => "\x1b[36m",      // cyan
        .identifier => "",
        .scope_ref  => "\x1b[33m",      // yellow
        .sigil      => "\x1b[35m",      // magenta
        .bracket    => "\x1b[2m",       // dim
        .macro_bar  => "\x1b[1;33m",    // bold yellow
    };
}

/// Iterator state for walking the highlight spans in step with the content
/// emission loop. Keeps the renderer single-pass.
const HighlightState = struct {
    parser: ?highlight.Highlighter = null,
    current: ?highlight.Span = null,

    fn init(content: []const u8, on: bool) HighlightState {
        if (!on) return .{};
        var parser = highlight.Highlighter.init(content);
        const first = parser.next();
        return .{ .parser = parser, .current = first };
    }

    fn advance(self: *HighlightState) void {
        if (self.parser) |*p| {
            self.current = p.next();
        }
    }

    fn enabled(self: HighlightState) bool {
        return self.parser != null;
    }

    fn firstSpanEndingAfter(self: *HighlightState, pos: usize) ?highlight.Span {
        while (self.current) |span| {
            if (span.end > pos) return span;
            self.advance();
        }
        return null;
    }
};

/// Renderer owns the terminal output side of the line editor. Takes a buffer
/// slice plus cursor offset and emits the appropriate ANSI sequences to redraw
/// the input area. Handles multi-row content with embedded `\n` by tracking
/// where the previous render left the cursor (row offset from render origin)
/// so we can navigate back before redrawing.
pub const Renderer = struct {
    stdout: *std.Io.Writer,
    prompt: []const u8 = PROMPT,
    /// Row offset (from render origin) where the cursor was last positioned.
    /// Used to navigate back to the origin before redrawing.
    prev_cursor_row: usize = 0,
    /// When true, content emission interleaves ANSI color escapes based on
    /// the highlight categorization of the source.
    highlight_enabled: bool = true,

    pub fn init(stdout: *std.Io.Writer) Renderer {
        return .{ .stdout = stdout };
    }

    pub fn render(self: *Renderer, content: []const u8, cursor: usize) void {
        self.draw(content, cursor) catch {};
        self.stdout.flush() catch {};
    }

    /// Writes the redraw straight to `stdout`. A buffered writer sends itself on
    /// when full, so no line is too long to draw.
    fn draw(self: *Renderer, content: []const u8, cursor: usize) std.Io.Writer.Error!void {
        const writer = self.stdout;

        if (self.prev_cursor_row > 0) {
            try writer.print("\x1b[{d}A", .{self.prev_cursor_row});
        }
        try writer.writeAll("\r");
        try writer.writeAll("\x1b[J");

        const prompt_width = displayWidth(self.prompt);
        try writer.writeAll(self.prompt);

        var hl_state = HighlightState.init(content, self.highlight_enabled);

        var row_count: usize = 0;
        var cursor_row: usize = 0;
        var cursor_col: usize = 0;
        var line_start: usize = 0;
        var saw_cursor: bool = false;

        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (i == cursor) {
                cursor_row = row_count;
                cursor_col = prompt_width + (i - line_start);
                saw_cursor = true;
            }
            if (content[i] == '\n') {
                try emitRange(writer, content, line_start, i, &hl_state);
                try writer.writeAll("\r\n");
                try writeContinuation(writer, prompt_width);
                row_count += 1;
                line_start = i + 1;
            }
        }
        try emitRange(writer, content, line_start, content.len, &hl_state);

        if (!saw_cursor) {
            cursor_row = row_count;
            cursor_col = prompt_width + (content.len - line_start);
        }

        const last_row = row_count;
        const rows_to_move_up = last_row - cursor_row;
        if (rows_to_move_up > 0) {
            try writer.print("\x1b[{d}A", .{rows_to_move_up});
        }
        try writer.writeAll("\r");
        if (cursor_col > 0) {
            try writer.print("\x1b[{d}C", .{cursor_col});
        }

        self.prev_cursor_row = cursor_row;
    }

    pub fn reset(self: *Renderer) void {
        self.prev_cursor_row = 0;
    }

    pub fn writeRaw(self: *Renderer, bytes: []const u8) void {
        self.stdout.writeAll(bytes) catch {};
        self.stdout.flush() catch {};
    }
};

fn emitRange(
    writer: *std.Io.Writer,
    content: []const u8,
    from: usize,
    to: usize,
    state: *HighlightState,
) std.Io.Writer.Error!void {
    if (!state.enabled()) return writer.writeAll(content[from..to]);

    var pos = from;
    while (pos < to) {
        const span = state.firstSpanEndingAfter(pos) orelse break;
        if (span.start >= to) break;

        if (span.start > pos) {
            try writer.writeAll(content[pos..span.start]);
        }

        const color = ansiFor(span.category);
        const span_end = @min(span.end, to);

        if (color.len > 0) try writer.writeAll(color);
        try writer.writeAll(content[span.start..span_end]);
        if (color.len > 0) try writer.writeAll(ANSI_RESET);

        pos = span_end;
    }

    try writer.writeAll(content[pos..to]);
}

fn renderLongHighlightedLine(writer: *std.Io.Writer) void {
    var content: [4000]u8 = undefined;
    for (&content, 0..) |*byte, index| byte.* = if (index % 2 == 0) '1' else ' ';

    var renderer = Renderer.init(writer);
    renderer.render(&content, content.len);
}

test "render draws a long highlighted line in full" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    renderLongHighlightedLine(&output.writer);

    const drawn = output.written();
    try std.testing.expectEqual(@as(usize, 2000), std.mem.count(u8, drawn, "\x1b[36m1\x1b[0m"));
    try std.testing.expect(std.mem.endsWith(u8, drawn, "\r\x1b[4006C"));
}

test "render sends the whole frame through a buffer much smaller than the frame" {
    var whole: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer whole.deinit();
    renderLongHighlightedLine(&whole.writer);

    var small_buffer: [256]u8 = undefined;
    var draining: std.Io.Writer.Discarding = .init(&small_buffer);
    renderLongHighlightedLine(&draining.writer);

    try std.testing.expectEqual(@as(u64, whole.written().len), draining.fullCount());
}
