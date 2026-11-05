const std = @import("std");
const buffer_mod = @import("buffer.zig");
const highlight = @import("../highlight.zig");

const BUFFER_SIZE = buffer_mod.BUFFER_SIZE;

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
        var state: HighlightState = .{ .parser = highlight.Highlighter.init(content) };
        state.current = state.parser.?.next();
        return state;
    }

    fn advance(self: *HighlightState) void {
        if (self.parser) |*p| {
            self.current = p.next();
        }
    }

    fn enabled(self: HighlightState) bool {
        return self.parser != null;
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
        var buf: [BUFFER_SIZE + 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        if (self.prev_cursor_row > 0) {
            writer.print("\x1b[{d}A", .{self.prev_cursor_row}) catch return;
        }
        writer.writeAll("\r") catch return;
        writer.writeAll("\x1b[J") catch return;

        const prompt_width = displayWidth(self.prompt);
        writer.writeAll(self.prompt) catch return;

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
                emitRange(&writer, content, line_start, i, &hl_state);
                writer.writeAll("\r\n") catch return;
                writeContinuation(&writer, prompt_width) catch return;
                row_count += 1;
                line_start = i + 1;
            }
        }
        emitRange(&writer, content, line_start, content.len, &hl_state);

        if (!saw_cursor) {
            cursor_row = row_count;
            cursor_col = prompt_width + (content.len - line_start);
        }

        const last_row = row_count;
        const rows_to_move_up = last_row - cursor_row;
        if (rows_to_move_up > 0) {
            writer.print("\x1b[{d}A", .{rows_to_move_up}) catch return;
        }
        writer.writeAll("\r") catch return;
        if (cursor_col > 0) {
            writer.print("\x1b[{d}C", .{cursor_col}) catch return;
        }

        self.prev_cursor_row = cursor_row;

        self.stdout.writeAll(writer.buffered()) catch {};
        self.stdout.flush() catch {};
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
) void {
    if (!state.enabled()) {
        writer.writeAll(content[from..to]) catch return;
        return;
    }

    var pos = from;
    while (pos < to) {
        while (state.current != null and state.current.?.end <= pos) {
            state.advance();
        }

        if (state.current == null or state.current.?.start >= to) {
            writer.writeAll(content[pos..to]) catch return;
            return;
        }

        const span = state.current.?;
        if (span.start > pos) {
            writer.writeAll(content[pos..span.start]) catch return;
        }

        const color = ansiFor(span.category);
        const span_end = @min(span.end, to);

        if (color.len > 0) writer.writeAll(color) catch return;
        writer.writeAll(content[span.start..span_end]) catch return;
        if (color.len > 0) writer.writeAll(ANSI_RESET) catch return;

        pos = span_end;
    }
}
