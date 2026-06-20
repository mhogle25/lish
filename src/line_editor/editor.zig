const std = @import("std");
const posix = std.posix;
const tok = @import("../token.zig");
const highlight = @import("../highlight.zig");
const buffer_mod = @import("buffer.zig");
const renderer_mod = @import("renderer.zig");
const escape_mod = @import("escape.zig");
const history_mod = @import("history.zig");

const Allocator = std.mem.Allocator;
const LineBuffer = buffer_mod.LineBuffer;
const Renderer = renderer_mod.Renderer;
const BUFFER_SIZE = buffer_mod.BUFFER_SIZE;
const rowOf = buffer_mod.rowOf;
const colOf = buffer_mod.colOf;
const offsetAt = buffer_mod.offsetAt;
const EscapeParser = escape_mod.Parser;
const EscapeAction = escape_mod.Action;
const EscapeStep = escape_mod.Step;
const EscapeMode = escape_mod.Mode;
const History = history_mod.History;

const INDENT_WIDTH = 4;

pub const ReadLineResult = union(enum) {
    line: []const u8,
    eof,
};

/// Indent level a new line should take given the content before the cursor.
/// The level is the count of unclosed `(`/`[`/`{`, ignoring brackets inside
/// strings and comments (the highlighter classifies those). A bare top-level
/// call (head is an identifier, not a bracket) counts as one implicit level,
/// since lish's bare top-level expression is itself a call whose args on later
/// lines should indent: `proc` then a newline lands one level in.
fn structuralIndentLevel(content: []const u8) usize {
    var depth: usize = 0;
    var head: ?highlight.Category = null;
    var highlighter = highlight.Highlighter.init(content);
    while (highlighter.next()) |span| {
        if (head == null) head = span.category;
        if (span.category != .bracket) continue;
        switch (content[span.start]) {
            tok.EXPRESSION_OPEN, tok.LIST_OPEN, tok.BLOCK_OPEN => depth += 1,
            tok.EXPRESSION_CLOSE, tok.LIST_CLOSE, tok.BLOCK_CLOSE => depth -|= 1,
            else => {},
        }
    }
    if (head == .identifier) depth += 1;
    return depth;
}

/// Module-level storage so the SIGINT handler can restore the terminal.
var global_original_termios: ?posix.termios = null;
var signal_handler_installed: bool = false;


fn sigintHandler(_: posix.SIG) callconv(.c) void {
    if (global_original_termios) |original| {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
    }
    // Exit with 128 + SIGINT (2) = 130
    std.process.exit(130);
}

pub const LineEditor = struct {
    buffer: LineBuffer = .{},

    original_termios: ?posix.termios = null,
    raw_mode_active: bool = false,
    is_terminal: bool = true,

    history: History,

    escape: EscapeParser = .{},

    /// When true, typing (, [, or { inserts the matching closing bracket
    /// and positions the cursor between the pair.
    autopair_insert: bool = true,
    /// When true, pressing backspace between a matched pair deletes both brackets.
    autopair_delete: bool = true,
    /// When true, pressing Alt+Enter with the cursor between a matched pair of
    /// brackets `()`, `[]`, or `{}` expands the pair across two lines with the
    /// cursor on an indented middle line. When false, Alt+Enter inserts the
    /// usual newline with copied indent regardless of surrounding brackets.
    bracket_expand: bool = true,
    /// Spaces inserted per Tab and per indent level.
    indent_width: usize = INDENT_WIDTH,
    /// True while a bracketed paste is in progress (between ESC[200~ and ESC[201~).
    /// Bytes received during paste are inserted literally and autopair is disabled.
    paste_mode: bool = false,

    renderer: Renderer,
    allocator: Allocator,

    pub fn init(allocator: Allocator, stdout: *std.Io.Writer) LineEditor {
        return .{
            .allocator = allocator,
            .renderer = Renderer.init(stdout),
            .history = History.init(allocator),
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.disableRawMode();
        self.history.deinit();
    }

    fn enableRawMode(self: *LineEditor) void {
        if (self.raw_mode_active or !self.is_terminal) return;

        const original = posix.tcgetattr(posix.STDIN_FILENO) catch |err| {
            if (err == error.NotATerminal) {
                self.is_terminal = false;
            }
            return;
        };

        self.original_termios = original;
        global_original_termios = original;

        if (!signal_handler_installed) {
            const act = posix.Sigaction{
                .handler = .{ .handler = &sigintHandler },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.INT, &act, null);
            signal_handler_installed = true;
        }

        var raw = original;

        // Input flags: disable CR->NL, XON/XOFF flow control
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        // Output flags: disable post-processing
        raw.oflag.OPOST = false;

        // Local flags: disable echo, canonical mode, signals, extended input
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Read returns after 1 byte, no timeout
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch return;
        self.raw_mode_active = true;

        // Enable bracketed paste so the terminal wraps pasted text in
        // ESC[200~ ... ESC[201~ markers. Lets us treat pasted content as
        // literal bytes (no autopair, no submit-on-newline).
        self.renderer.writeRaw("\x1b[?2004h");
    }

    fn disableRawMode(self: *LineEditor) void {
        if (!self.raw_mode_active) return;
        // Disable bracketed paste before restoring the terminal.
        self.renderer.writeRaw("\x1b[?2004l");
        if (self.original_termios) |original| {
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
        }
        self.raw_mode_active = false;
    }

    pub fn readLine(self: *LineEditor) ReadLineResult {
        self.buffer.reset();
        self.escape.reset();
        self.history.endBrowse();
        self.renderer.reset();

        self.enableRawMode();
        defer self.disableRawMode();

        if (!self.is_terminal) {
            return self.readLineFallback();
        }

        // Initial render writes the prompt and positions cursor.
        self.renderer.render(self.buffer.slice(), self.buffer.cursor);

        while (true) {
            var byte_buf: [1]u8 = undefined;
            const bytes_read = posix.read(posix.STDIN_FILENO, &byte_buf) catch {
                return .eof;
            };

            if (bytes_read == 0) {
                return .eof;
            }

            const byte = byte_buf[0];

            switch (self.processInput(byte)) {
                .continue_reading => continue,
                .submit_line => {
                    // Position cursor past the last rendered row so the
                    // following "\r\n" lands below the (possibly multi-row)
                    // input rather than overwriting it.
                    self.renderer.render(self.buffer.slice(), self.buffer.length);
                    self.renderer.writeRaw("\r\n");
                    self.renderer.reset();
                    const line = self.buffer.data[0..self.buffer.length];
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len > 0) {
                        self.history.add(trimmed);
                    }
                    return .{ .line = line };
                },
                .cancel_line => {
                    // Same approach as submit: park cursor past the rendered
                    // area before writing "^C" so multi-row input isn't
                    // overwritten by the cancel marker.
                    self.renderer.render(self.buffer.slice(), self.buffer.length);
                    self.renderer.writeRaw("^C\r\n");
                    self.renderer.reset();
                    self.buffer.reset();
                    self.history.endBrowse();
                    self.paste_mode = false;
                    self.renderer.render(self.buffer.slice(), self.buffer.cursor);
                },
                .eof_signal => {
                    if (self.buffer.length == 0) {
                        self.renderer.writeRaw("\r\n");
                        self.renderer.reset();
                        return .eof;
                    }
                    // Non-empty line: delete forward
                    self.buffer.deleteCharAt();
                    self.renderer.render(self.buffer.slice(), self.buffer.cursor);
                },
            }
        }
    }

    /// Fallback for piped/non-terminal input, reads line byte-by-byte in cooked mode.
    fn readLineFallback(self: *LineEditor) ReadLineResult {
        var pos: usize = 0;
        while (pos < self.buffer.data.len) {
            const bytes_read = posix.read(posix.STDIN_FILENO, self.buffer.data[pos..][0..1]) catch return .eof;
            if (bytes_read == 0) {
                return if (pos > 0) .{ .line = self.buffer.data[0..pos] } else .eof;
            }
            if (self.buffer.data[pos] == '\n') {
                return .{ .line = self.buffer.data[0..pos] };
            }
            pos += 1;
        }
        return .{ .line = self.buffer.data[0..pos] };
    }

    const InputResult = enum {
        continue_reading,
        submit_line,
        cancel_line,
        eof_signal,
    };

    fn processInput(self: *LineEditor, byte: u8) InputResult {
        // Capture buffer state so we can render once at the end if anything
        // changed. Mutations done by dispatchByte don't render themselves;
        // this single check covers them.
        const initial_length = self.buffer.length;
        const initial_cursor = self.buffer.cursor;

        const result = self.dispatchByte(byte);

        if (result == .continue_reading and
            (self.buffer.length != initial_length or self.buffer.cursor != initial_cursor))
        {
            self.renderer.render(self.buffer.slice(), self.buffer.cursor);
        }
        return result;
    }

    fn dispatchByte(self: *LineEditor, byte: u8) InputResult {
        switch (self.escape.process(byte)) {
            .not_escape => {},
            .consumed => return .continue_reading,
            .action => |action| {
                self.handleEscapeAction(action);
                return .continue_reading;
            },
        }

        // During bracketed paste, every non-escape byte is literal content.
        // No autopair, no submit-on-Enter, no command bindings.
        if (self.paste_mode) {
            _ = self.buffer.insertChar(byte);
            return .continue_reading;
        }

        switch (byte) {
            '\r', '\n' => return .submit_line,
            0x03 => return .cancel_line, // Ctrl+C
            0x04 => return .eof_signal, // Ctrl+D
            0x01 => self.buffer.cursorToBeginning(), // Ctrl+A
            0x05 => self.buffer.cursorToEnd(),       // Ctrl+E
            0x0b => self.buffer.killToEnd(),         // Ctrl+K
            0x15 => self.buffer.killAll(),           // Ctrl+U
            0x17 => self.buffer.deleteWordBefore(),  // Ctrl+W
            0x0c => self.handleClearScreen(),        // Ctrl+L
            0x7f, 0x08 => self.handleDeleteBackward(),
            0x09 => self.insertTab(),                // Tab
            0x10 => self.history.up(&self.buffer),                // Ctrl+P
            0x0e => self.history.down(&self.buffer),              // Ctrl+N

            tok.EXPRESSION_OPEN  => self.handleOpenBracket(tok.EXPRESSION_OPEN, tok.EXPRESSION_CLOSE),
            tok.EXPRESSION_CLOSE => self.handleCloseBracket(tok.EXPRESSION_CLOSE),
            tok.LIST_OPEN        => self.handleOpenBracket(tok.LIST_OPEN, tok.LIST_CLOSE),
            tok.LIST_CLOSE       => self.handleCloseBracket(tok.LIST_CLOSE),
            tok.BLOCK_OPEN       => self.handleOpenBracket(tok.BLOCK_OPEN, tok.BLOCK_CLOSE),
            tok.BLOCK_CLOSE      => self.handleCloseBracket(tok.BLOCK_CLOSE),
            tok.QUOTE_DOUBLE     => self.handleQuote(tok.QUOTE_DOUBLE),
            tok.QUOTE_SINGLE     => self.handleQuote(tok.QUOTE_SINGLE),

            else => {
                if (byte >= 0x20 and byte < 0x7f) {
                    _ = self.buffer.insertChar(byte);
                }
                // Other control bytes are ignored.
            },
        }
        return .continue_reading;
    }


    fn handleEscapeAction(self: *LineEditor, action: EscapeAction) void {
        switch (action) {
            .move_up         => self.handleUpKey(),
            .move_down       => self.handleDownKey(),
            .move_right      => self.buffer.cursorRight(),
            .move_left       => self.buffer.cursorLeft(),
            .move_word_right => self.buffer.cursorWordRight(),
            .move_word_left  => self.buffer.cursorWordLeft(),
            .home            => self.buffer.cursorToBeginning(),
            .end             => self.buffer.cursorToEnd(),
            .delete_forward  => self.buffer.deleteCharAt(),
            .insert_newline  => self.insertNewlineWithIndent(),
            .dedent          => self.dedentCurrentLine(),
            .paste_start     => self.paste_mode = true,
            .paste_end       => self.paste_mode = false,
        }
    }

    // Policy helpers: encode autopair behavior and explicit render needs.
    // None of these call renderer.render; processInput's render-on-change
    // covers buffer mutations; handleClearScreen is the one exception that
    // explicitly renders (clearing the screen doesn't change buffer state).

    fn handleOpenBracket(self: *LineEditor, open: u8, close: u8) void {
        if (self.autopair_insert) {
            if (!self.buffer.insertPair(open, close)) {
                _ = self.buffer.insertChar(open);
            }
        } else {
            _ = self.buffer.insertChar(open);
        }
    }

    fn handleCloseBracket(self: *LineEditor, close: u8) void {
        if (self.autopair_insert) {
            if (self.buffer.peek(self.buffer.cursor)) |c| {
                if (c == close) {
                    self.buffer.cursorRight();
                    return;
                }
            }
        }
        _ = self.buffer.insertChar(close);
    }

    fn handleQuote(self: *LineEditor, quote: u8) void {
        if (!self.autopair_insert) {
            _ = self.buffer.insertChar(quote);
            return;
        }
        if (self.buffer.peek(self.buffer.cursor)) |c| {
            if (c == quote) {
                self.buffer.cursorRight();
                return;
            }
        }
        if (!self.buffer.insertPair(quote, quote)) {
            _ = self.buffer.insertChar(quote);
        }
    }

    fn handleDeleteBackward(self: *LineEditor) void {
        if (self.buffer.cursor == 0) return;
        if (self.bracket_expand and self.collapseExpandedPairIfApplicable()) return;
        if (self.autopair_delete and self.buffer.deleteMatchedPair()) return;
        self.buffer.deleteCharBefore();
    }

    /// Inverse of `expandPairAcrossLines`: if the cursor sits on a
    /// whitespace-only line between an open bracket (last char of the previous
    /// line) and its matching close bracket (first char of the next line),
    /// collapse the three lines back into `<open><close>` with the cursor
    /// between them. Returns true on collapse.
    fn collapseExpandedPairIfApplicable(self: *LineEditor) bool {
        var line_start = self.buffer.cursor;
        while (line_start > 0 and self.buffer.data[line_start - 1] != '\n') : (line_start -= 1) {}

        var line_end = self.buffer.cursor;
        while (line_end < self.buffer.length and self.buffer.data[line_end] != '\n') : (line_end += 1) {}

        // Current line must consist only of whitespace.
        var i = line_start;
        while (i < line_end) : (i += 1) {
            const c = self.buffer.data[i];
            if (c != ' ' and c != '\t') return false;
        }

        // Must have a previous line ending in an open bracket and a next line
        // whose first non-whitespace character is the matching close bracket.
        // The close may be preceded by indentation when the pair is nested
        // (the open is always the previous line's last char, so it needs no
        // such skip).
        if (line_start < 2) return false;
        if (line_end >= self.buffer.length) return false;

        const open = self.buffer.data[line_start - 2];

        var close_pos = line_end + 1;
        while (close_pos < self.buffer.length and
            (self.buffer.data[close_pos] == ' ' or self.buffer.data[close_pos] == '\t')) : (close_pos += 1)
        {}
        if (close_pos >= self.buffer.length) return false;

        const close = self.buffer.data[close_pos];
        const matches = switch (open) {
            tok.EXPRESSION_OPEN => close == tok.EXPRESSION_CLOSE,
            tok.LIST_OPEN => close == tok.LIST_CLOSE,
            tok.BLOCK_OPEN => close == tok.BLOCK_CLOSE,
            else => false,
        };
        if (!matches) return false;

        // Splice out [line_start - 1, close_pos): the prev `\n`, the whitespace
        // line, the trailing `\n`, and the close line's leading indent, leaving
        // `<open><close>` with the cursor between them.
        const delete_from = line_start - 1;
        const delete_to = close_pos;
        const delete_len = delete_to - delete_from;

        var j = delete_to;
        while (j < self.buffer.length) : (j += 1) {
            self.buffer.data[j - delete_len] = self.buffer.data[j];
        }
        self.buffer.length -= delete_len;
        self.buffer.cursor = delete_from;
        return true;
    }

    fn handleClearScreen(self: *LineEditor) void {
        self.renderer.writeRaw("\x1b[2J\x1b[H");
        self.renderer.reset();
        self.renderer.render(self.buffer.slice(), self.buffer.cursor);
    }

    /// Up arrow: move cursor up one row within the buffer; if already on row 0,
    /// fall through to history navigation.
    fn handleUpKey(self: *LineEditor) void {
        const content = self.buffer.slice();
        const cur_row = rowOf(content, self.buffer.cursor);
        if (cur_row == 0) {
            self.history.up(&self.buffer);
            return;
        }
        const cur_col = colOf(content, self.buffer.cursor);
        self.buffer.cursor = offsetAt(content, cur_row - 1, cur_col);
    }

    /// Down arrow: move cursor down one row within the buffer; if already on
    /// the last row, fall through to history navigation.
    fn handleDownKey(self: *LineEditor) void {
        const content = self.buffer.slice();
        const cur_row = rowOf(content, self.buffer.cursor);
        const last_row = rowOf(content, content.len);
        if (cur_row >= last_row) {
            self.history.down(&self.buffer);
            return;
        }
        const cur_col = colOf(content, self.buffer.cursor);
        self.buffer.cursor = offsetAt(content, cur_row + 1, cur_col);
    }

    /// Tab: insert `indent_width` spaces at the cursor.
    fn insertTab(self: *LineEditor) void {
        var i: usize = 0;
        while (i < self.indent_width) : (i += 1) {
            if (!self.buffer.insertChar(' ')) break;
        }
    }

    /// Shift+Tab: remove up to `indent_width` leading spaces from the current
    /// logical line.
    fn dedentCurrentLine(self: *LineEditor) void {
        var line_start = self.buffer.cursor;
        while (line_start > 0 and self.buffer.data[line_start - 1] != '\n') : (line_start -= 1) {}

        var leading_spaces: usize = 0;
        while (leading_spaces < self.indent_width and line_start + leading_spaces < self.buffer.length and self.buffer.data[line_start + leading_spaces] == ' ') : (leading_spaces += 1) {}

        if (leading_spaces == 0) return;
        self.buffer.removeRange(line_start, line_start + leading_spaces);
    }

    /// Alt+Enter: insert a `\n`, then indent the new line to its structural
    /// depth (see `structuralIndentLevel`).
    ///
    /// Special case when `bracket_expand` is set: if the cursor sits between
    /// a matched pair of paired brackets (`()`, `[]`, or `{}`), expand the
    /// pair across two lines and position the cursor on the indented middle.
    fn insertNewlineWithIndent(self: *LineEditor) void {
        const level = structuralIndentLevel(self.buffer.data[0..self.buffer.cursor]);

        if (self.bracket_expand and self.cursorInsideMatchedPair()) {
            self.expandPairAcrossLines(level);
            return;
        }

        if (!self.buffer.insertChar('\n')) return;
        self.insertIndent(level);
    }

    /// Insert `level` indent units worth of spaces at the cursor. Stops early
    /// if the buffer fills.
    fn insertIndent(self: *LineEditor, level: usize) void {
        var i: usize = 0;
        while (i < level * self.indent_width) : (i += 1) {
            if (!self.buffer.insertChar(' ')) return;
        }
    }

    /// True when the byte at the cursor is a closing bracket whose matching
    /// opener sits immediately before the cursor, i.e., the cursor is at
    /// `(|)`, `[|]`, or `{|}`. Quotes are deliberately excluded; lish strings
    /// can't span lines so expanding `"|"` would create invalid syntax.
    fn cursorInsideMatchedPair(self: *LineEditor) bool {
        if (self.buffer.cursor == 0) return false;
        if (self.buffer.cursor >= self.buffer.length) return false;
        const before = self.buffer.data[self.buffer.cursor - 1];
        const at = self.buffer.data[self.buffer.cursor];
        return switch (before) {
            tok.EXPRESSION_OPEN => at == tok.EXPRESSION_CLOSE,
            tok.LIST_OPEN => at == tok.LIST_CLOSE,
            tok.BLOCK_OPEN => at == tok.BLOCK_CLOSE,
            else => false,
        };
    }

    /// Expand `(|)` (or equivalent) into:
    ///     (
    ///         |
    ///     )
    /// where `indent` is the leading whitespace of the current logical line
    /// and the cursor lands on the middle (indented) line.
    fn expandPairAcrossLines(self: *LineEditor, level: usize) void {
        // `level` already counts the open bracket before the cursor, so the
        // middle line sits at `level` and the close aligns with the open's line.
        if (!self.buffer.insertChar('\n')) return;
        self.insertIndent(level);

        // Remember the cursor position (the middle indented line), then
        // insert the closing newline + indent and restore.
        const cursor_after_middle = self.buffer.cursor;

        if (!self.buffer.insertChar('\n')) return;
        self.insertIndent(level -| 1);

        self.buffer.cursor = cursor_after_middle;
    }



    // Helpers for testing: expose internal state without needing a terminal

    var test_discard_buf: [256]u8 = undefined;
    var test_discarding: std.Io.Writer.Discarding = .init(&test_discard_buf);

    fn testInit() LineEditor {
        return .{
            .allocator = std.testing.allocator,
            .renderer = Renderer.init(&test_discarding.writer),
            .history = History.init(std.testing.allocator),
            .is_terminal = false,
        };
    }

    fn testInsertString(self: *LineEditor, string: []const u8) void {
        for (string) |byte| {
            _ = self.buffer.insertChar(byte);
        }
    }

    fn getLineSlice(self: *const LineEditor) []const u8 {
        return self.buffer.data[0..self.buffer.length];
    }
};


fn expectAction(expected: EscapeAction, step: EscapeStep) !void {
    try std.testing.expect(step == .action);
    try std.testing.expectEqual(expected, step.action);
}

test "escape parser: arrow keys" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Up arrow: ESC [ A
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(EscapeMode.escape, editor.escape.mode);
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try std.testing.expectEqual(EscapeMode.csi, editor.escape.mode);
    try expectAction(.move_up, editor.escape.process('A'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);

    // Down arrow: ESC [ B
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try expectAction(.move_down, editor.escape.process('B'));

    // Right arrow: ESC [ C
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try expectAction(.move_right, editor.escape.process('C'));

    // Left arrow: ESC [ D
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try expectAction(.move_left, editor.escape.process('D'));
}

test "escape parser: home and end" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Home: ESC [ H
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try expectAction(.home, editor.escape.process('H'));

    // End: ESC [ F
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try expectAction(.end, editor.escape.process('F'));
}

test "escape parser: delete key" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Delete: ESC [ 3 ~
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('3'));
    try std.testing.expectEqual(EscapeMode.csi, editor.escape.mode);
    try expectAction(.delete_forward, editor.escape.process('~'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}

test "escape parser: unknown CSI param sequence" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // ESC [ 5 ~, not mapped, should be consumed without action
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('5'));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('~'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}

test "escape parser: Alt+Left and Alt+Right (ESC b / ESC f)" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // ESC b, Alt+Left
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try expectAction(.move_word_left, editor.escape.process('b'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);

    // ESC f, Alt+Right
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try expectAction(.move_word_right, editor.escape.process('f'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}

test "escape parser: Alt+Enter (ESC \\r / ESC \\n)" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // ESC \r, Alt+Enter
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try expectAction(.insert_newline, editor.escape.process('\r'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);

    // ESC \n, also Alt+Enter (some terminals)
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try expectAction(.insert_newline, editor.escape.process('\n'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}

test "Alt+Enter indents a bare top-level call one level" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // `foo` is a bare top-level call head, so the next line indents one level.
    editor.testInsertString("foo");
    editor.insertNewlineWithIndent();
    try std.testing.expectEqualStrings("foo\n    ", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 8), editor.buffer.cursor);
}

test "Alt+Enter on a bare proc keeps body steps at one level" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("proc (step1)");
    editor.insertNewlineWithIndent();
    try std.testing.expectEqualStrings("proc (step1)\n    ", editor.buffer.slice());
}

test "Alt+Enter adds a level for each unclosed bracket" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Bare call (+1) plus one unclosed `(` => level 2 => 8 spaces.
    editor.testInsertString("proc (let");
    editor.insertNewlineWithIndent();
    try std.testing.expectEqualStrings("proc (let\n        ", editor.buffer.slice());
}

test "Alt+Enter at line start inserts just newline (no indent)" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("    foo");
    editor.buffer.cursor = 0;
    editor.insertNewlineWithIndent();
    try std.testing.expectEqualStrings("\n    foo", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 1), editor.buffer.cursor);
}

test "Alt+Enter with only whitespace before the cursor adds no indent" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("    foo");
    editor.buffer.cursor = 2; // Amid the leading whitespace: no call head yet.
    editor.insertNewlineWithIndent();
    try std.testing.expectEqualStrings("  \n  foo", editor.buffer.slice());
}

test "escape parser: Shift+Tab (ESC [ Z)" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try expectAction(.dedent, editor.escape.process('Z'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}

test "Tab inserts INDENT_WIDTH spaces at cursor" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("foo");
    editor.insertTab();
    var expected_buf: [16]u8 = undefined;
    var len: usize = 3;
    @memcpy(expected_buf[0..3], "foo");
    var i: usize = 0;
    while (i < INDENT_WIDTH) : (i += 1) {
        expected_buf[len] = ' ';
        len += 1;
    }
    try std.testing.expectEqualStrings(expected_buf[0..len], editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 3 + INDENT_WIDTH), editor.buffer.cursor);
}

test "Shift+Tab removes leading spaces from current line" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Start with INDENT_WIDTH * 2 leading spaces; one dedent should leave INDENT_WIDTH.
    var leading_buf: [32]u8 = undefined;
    var total: usize = 0;
    while (total < INDENT_WIDTH * 2) : (total += 1) {
        leading_buf[total] = ' ';
    }
    @memcpy(leading_buf[total..][0..3], "foo");
    editor.testInsertString(leading_buf[0 .. total + 3]);
    editor.dedentCurrentLine();

    var expected: [32]u8 = undefined;
    var elen: usize = 0;
    while (elen < INDENT_WIDTH) : (elen += 1) {
        expected[elen] = ' ';
    }
    @memcpy(expected[elen..][0..3], "foo");
    try std.testing.expectEqualStrings(expected[0 .. elen + 3], editor.buffer.slice());
}

test "Shift+Tab on line with no leading spaces is a no-op" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("foo");
    editor.dedentCurrentLine();
    try std.testing.expectEqualStrings("foo", editor.buffer.slice());
}

test "Shift+Tab dedents the current line in a multi-line buffer" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    var head: [64]u8 = undefined;
    @memcpy(head[0..4], "foo\n");
    var pos: usize = 4;
    var i: usize = 0;
    while (i < INDENT_WIDTH * 2) : (i += 1) {
        head[pos] = ' ';
        pos += 1;
    }
    @memcpy(head[pos..][0..3], "bar");
    editor.testInsertString(head[0 .. pos + 3]);

    editor.dedentCurrentLine();

    var expected: [64]u8 = undefined;
    @memcpy(expected[0..4], "foo\n");
    var epos: usize = 4;
    var j: usize = 0;
    while (j < INDENT_WIDTH) : (j += 1) {
        expected[epos] = ' ';
        epos += 1;
    }
    @memcpy(expected[epos..][0..3], "bar");
    try std.testing.expectEqualStrings(expected[0 .. epos + 3], editor.buffer.slice());
}

test "Alt+Enter inside `(|)` expands the pair across two lines" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("()");
    editor.buffer.cursor = 1; // between ( and )
    editor.insertNewlineWithIndent();

    // Expected: `(\n    \n)` with cursor on the indented middle line.
    var expected: [16]u8 = undefined;
    var len: usize = 0;
    expected[len] = '(';     len += 1;
    expected[len] = '\n';    len += 1;
    var i: usize = 0;
    while (i < INDENT_WIDTH) : (i += 1) { expected[len] = ' '; len += 1; }
    const middle_cursor = len;
    expected[len] = '\n';    len += 1;
    expected[len] = ')';     len += 1;

    try std.testing.expectEqualStrings(expected[0..len], editor.buffer.slice());
    try std.testing.expectEqual(middle_cursor, editor.buffer.cursor);
}

test "Alt+Enter inside `[|]` also expands" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("[]");
    editor.buffer.cursor = 1;
    editor.insertNewlineWithIndent();

    try std.testing.expect(std.mem.indexOfScalar(u8, editor.buffer.slice(), tok.LIST_OPEN) == 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, editor.buffer.slice(), tok.LIST_CLOSE) != null);
    try std.testing.expect(editor.buffer.cursor > 1);
    try std.testing.expect(editor.buffer.cursor < editor.buffer.length);
}

test "Alt+Enter outside paired brackets indents structurally, not by copying" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Not inside a pair: no expand. The new line indents to its structural
    // level (bare call => 1), regardless of the current line's own indent.
    editor.testInsertString("  foo");
    editor.insertNewlineWithIndent();
    try std.testing.expectEqualStrings("  foo\n    ", editor.buffer.slice());
}

test "Alt+Enter inside `\"|\"` does NOT expand (strings are single-line)" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("\"\"");
    editor.buffer.cursor = 1;
    editor.insertNewlineWithIndent();
    // Should be plain newline behavior: `"\n"` ; quotes themselves don't expand.
    try std.testing.expectEqualStrings("\"\n\"", editor.buffer.slice());
}

test "Backspace on indented middle line of expanded pair collapses it" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("()");
    editor.buffer.cursor = 1;
    editor.insertNewlineWithIndent();
    // We're now at `(\n    |\n)`. Hit backspace.
    editor.handleDeleteBackward();
    try std.testing.expectEqualStrings("()", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 1), editor.buffer.cursor);
}

test "Backspace collapses expanded pair in the middle of larger content" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("say (");
    editor.testInsertString(")");
    editor.buffer.cursor = 5; // between ( and )
    editor.insertNewlineWithIndent();
    editor.handleDeleteBackward();
    try std.testing.expectEqualStrings("say ()", editor.buffer.slice());
    try std.testing.expectEqual(@as(usize, 5), editor.buffer.cursor);
}

test "Backspace collapses a nested (indented) expanded pair" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Build an outer expanded pair, then expand an inner pair on the indented
    // middle line so the inner close bracket is itself indented.
    editor.testInsertString("()");
    editor.buffer.cursor = 1;
    editor.insertNewlineWithIndent(); // `(\n    |\n)`
    editor.testInsertString("()");
    editor.buffer.cursor -= 1; // between the inner ( and )
    editor.insertNewlineWithIndent(); // inner pair expands at indent INDENT_WIDTH

    // The inner close bracket now sits behind INDENT_WIDTH spaces. Backspace on
    // the inner whitespace line must still collapse it to `()`.
    editor.handleDeleteBackward();

    // Expected: outer pair preserved, inner collapsed to `()`:
    //     (\n<indent>()\n)
    var expected: [32]u8 = undefined;
    var len: usize = 0;
    expected[len] = '(';  len += 1;
    expected[len] = '\n'; len += 1;
    var i: usize = 0;
    while (i < INDENT_WIDTH) : (i += 1) { expected[len] = ' '; len += 1; }
    const inner_cursor = len + 1; // between the inner ( and )
    expected[len] = '(';  len += 1;
    expected[len] = ')';  len += 1;
    expected[len] = '\n'; len += 1;
    expected[len] = ')';  len += 1;

    try std.testing.expectEqualStrings(expected[0..len], editor.buffer.slice());
    try std.testing.expectEqual(inner_cursor, editor.buffer.cursor);
}

test "Backspace does NOT collapse if the indented line has content" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("()");
    editor.buffer.cursor = 1;
    editor.insertNewlineWithIndent();
    editor.testInsertString("x"); // now `(\n    x|\n)`
    editor.handleDeleteBackward(); // should just delete the 'x'
    var expected: [16]u8 = undefined;
    var len: usize = 0;
    expected[len] = '('; len += 1;
    expected[len] = '\n'; len += 1;
    var i: usize = 0;
    while (i < INDENT_WIDTH) : (i += 1) { expected[len] = ' '; len += 1; }
    expected[len] = '\n'; len += 1;
    expected[len] = ')'; len += 1;
    try std.testing.expectEqualStrings(expected[0..len], editor.buffer.slice());
}

test "Backspace collapse disabled when bracket_expand is off" {
    var editor = LineEditor.testInit();
    defer editor.deinit();
    editor.bracket_expand = true;

    editor.testInsertString("()");
    editor.buffer.cursor = 1;
    editor.insertNewlineWithIndent();
    // Now turn off bracket_expand; backspace should fall through to autopair-delete or plain.
    editor.bracket_expand = false;
    editor.handleDeleteBackward();
    // bracket_expand off + autopair_delete on: the autopair_delete won't fire here
    // because we're on a whitespace line, not directly between matched brackets.
    // We should get plain backspace: one space deleted.
    var expected: [16]u8 = undefined;
    var len: usize = 0;
    expected[len] = '('; len += 1;
    expected[len] = '\n'; len += 1;
    var i: usize = 0;
    while (i < INDENT_WIDTH - 1) : (i += 1) { expected[len] = ' '; len += 1; }
    expected[len] = '\n'; len += 1;
    expected[len] = ')'; len += 1;
    try std.testing.expectEqualStrings(expected[0..len], editor.buffer.slice());
}

test "Alt+Enter inside `(|)` with bracket_expand disabled still indents" {
    var editor = LineEditor.testInit();
    defer editor.deinit();
    editor.bracket_expand = false;

    // No pair-expansion (no close line), but the new line still indents one
    // level for the unclosed `(`.
    editor.testInsertString("()");
    editor.buffer.cursor = 1;
    editor.insertNewlineWithIndent();
    try std.testing.expectEqualStrings("(\n    )", editor.buffer.slice());
}

test "Up arrow on row 0 falls through to history" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.history.add("prev cmd");
    editor.testInsertString("current");
    editor.handleUpKey();
    try std.testing.expectEqualStrings("prev cmd", editor.buffer.slice());
}

test "Up arrow on row > 0 moves cursor up within buffer" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("abc\ndefgh");
    // Cursor at end (position 9), on row 1 at col 5.
    editor.handleUpKey();
    // Target row 0, col 5. Row 0 = "abc" so col clamps to 3 -> offset 3.
    try std.testing.expectEqual(@as(usize, 3), editor.buffer.cursor);
}

test "Down arrow on last row falls through to history" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.history.add("first");
    editor.history.add("second");
    editor.testInsertString("current");
    // Cursor on row 0 (only row). Need to start history browse first via Up.
    editor.handleUpKey();   // history-up to "second"
    editor.handleDownKey(); // history-down back to "current" (saved)
    try std.testing.expectEqualStrings("current", editor.buffer.slice());
}

test "Down arrow on row < last_row moves cursor down within buffer" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("abcde\nfg");
    editor.buffer.cursor = 3; // Row 0, col 3.
    editor.handleDownKey();
    // Target row 1, col 3. Row 1 = "fg" so col clamps to 2 -> offset 6 + 2 = 8.
    try std.testing.expectEqual(@as(usize, 8), editor.buffer.cursor);
}

test "escape parser: bracketed paste start (ESC [ 200 ~) and end (ESC [ 201 ~)" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // ESC [ 200 ~ -> paste_start
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('2'));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('0'));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('0'));
    try expectAction(.paste_start, editor.escape.process('~'));

    // ESC [ 201 ~ -> paste_end
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('2'));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('0'));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('1'));
    try expectAction(.paste_end, editor.escape.process('~'));
}

test "bracketed paste: literal newlines, no autopair, no submit" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Simulate ESC[200~ to enter paste mode.
    _ = editor.processInput(0x1b);
    _ = editor.processInput('[');
    _ = editor.processInput('2');
    _ = editor.processInput('0');
    _ = editor.processInput('0');
    _ = editor.processInput('~');
    try std.testing.expect(editor.paste_mode);

    // Paste "(foo\nbar)". The `\n` should be literal (no submit), `(` should
    // not autopair, `)` should not autopair-skip.
    for ("(foo\nbar)") |byte| {
        const result = editor.processInput(byte);
        try std.testing.expectEqual(LineEditor.InputResult.continue_reading, result);
    }
    try std.testing.expectEqualStrings("(foo\nbar)", editor.buffer.slice());

    // Exit paste mode.
    _ = editor.processInput(0x1b);
    _ = editor.processInput('[');
    _ = editor.processInput('2');
    _ = editor.processInput('0');
    _ = editor.processInput('1');
    _ = editor.processInput('~');
    try std.testing.expect(!editor.paste_mode);
}

test "Ctrl+P always navigates history regardless of cursor position" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.history.add("prev");
    editor.testInsertString("abc\ndef");
    // Cursor on row 1; Up arrow would move within buffer.
    // Ctrl+P should still hit history.
    _ = editor.processInput(0x10);
    try std.testing.expectEqualStrings("prev", editor.buffer.slice());
}

test "escape parser: Alt+Left and Alt+Right (xterm ESC [ 1 ; 3 D/C)" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // ESC [ 1 ; 3 D, Alt+Left
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('1'));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(';'));
    try std.testing.expectEqual(EscapeMode.csi, editor.escape.mode);
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('3'));
    try expectAction(.move_word_left, editor.escape.process('D'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);

    // ESC [ 1 ; 3 C, Alt+Right
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('['));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('1'));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(';'));
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('3'));
    try expectAction(.move_word_right, editor.escape.process('C'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}

test "escape parser: incomplete escape resets on non-bracket" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // ESC followed by non-'[' should reset to ground
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process(0x1b));
    try std.testing.expectEqual(EscapeMode.escape, editor.escape.mode);
    try std.testing.expectEqual(escape_mod.Step.consumed, editor.escape.process('x'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}

test "escape parser: ground state passes ordinary bytes through" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // 'a' in ground state is not part of a sequence, caller must handle it.
    try std.testing.expectEqual(EscapeStep.not_escape, editor.escape.process('a'));
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}

test "processInput: unknown CSI terminator does not leak into the line" {
    // Regression: ESC[Z used to land on 'Z' in ground state and get inserted as
    // text. processEscape now returns .consumed for the unknown terminator so
    // processInput skips the regular-byte branch.
    var editor = LineEditor.testInit();
    defer editor.deinit();

    _ = editor.processInput(0x1b);
    _ = editor.processInput('[');
    _ = editor.processInput('Z');

    try std.testing.expectEqualStrings("", editor.getLineSlice());
    try std.testing.expectEqual(EscapeMode.ground, editor.escape.mode);
}



test "processInput: printable characters" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    try std.testing.expectEqual(LineEditor.InputResult.continue_reading, editor.processInput('a'));
    try std.testing.expectEqualStrings("a", editor.getLineSlice());

    try std.testing.expectEqual(LineEditor.InputResult.continue_reading, editor.processInput('b'));
    try std.testing.expectEqualStrings("ab", editor.getLineSlice());
}

test "processInput: submit on enter" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    try std.testing.expectEqual(LineEditor.InputResult.submit_line, editor.processInput('\r'));
}

test "processInput: ctrl+c cancels line" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    try std.testing.expectEqual(LineEditor.InputResult.cancel_line, editor.processInput(0x03));
}

test "processInput: ctrl+d on empty sends eof" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    try std.testing.expectEqual(LineEditor.InputResult.eof_signal, editor.processInput(0x04));
}

test "processInput: backspace deletes backward" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("abc");
    try std.testing.expectEqual(LineEditor.InputResult.continue_reading, editor.processInput(0x7f));
    try std.testing.expectEqualStrings("ab", editor.getLineSlice());
}
