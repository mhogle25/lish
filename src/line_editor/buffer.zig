const std = @import("std");
const tok = @import("../token.zig");

pub const BUFFER_SIZE = 4096;

fn isWordChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isMatchedPair(open: u8, close: u8) bool {
    return (open == tok.EXPRESSION_OPEN and close == tok.EXPRESSION_CLOSE) or
        (open == tok.LIST_OPEN and close == tok.LIST_CLOSE) or
        (open == tok.BLOCK_OPEN and close == tok.BLOCK_CLOSE) or
        (open == tok.QUOTE_DOUBLE and close == tok.QUOTE_DOUBLE) or
        (open == tok.QUOTE_SINGLE and close == tok.QUOTE_SINGLE);
}

/// LineBuffer holds the editable text and cursor state. All mutating
/// operations are primitives that don't render. Rendering is owned
/// separately by the editor's Renderer. Tests can construct a LineBuffer
/// directly without any I/O attached.
pub const LineBuffer = struct {
    data:   [BUFFER_SIZE]u8 = undefined,
    length: usize           = 0,
    cursor: usize           = 0,

    pub fn slice(self: *const LineBuffer) []const u8 {
        return self.data[0..self.length];
    }

    pub fn peek(self: *const LineBuffer, pos: usize) ?u8 {
        return if (pos >= self.length) 
            null else 
            self.data[pos];
    }

    pub fn reset(self: *LineBuffer) void {
        self.length = 0;
        self.cursor = 0;
    }

    pub fn insertChar(self: *LineBuffer, byte: u8) bool {
        if (self.length >= BUFFER_SIZE) return false;

        if (self.cursor < self.length) {
            @memmove(
                self.data[self.cursor + 1 .. self.length + 1],
                self.data[self.cursor .. self.length],
            );
        }

        self.data[self.cursor] = byte;
        self.cursor += 1;
        self.length += 1;

        return true;
    }

    pub fn insertPair(self: *LineBuffer, open: u8, close: u8) bool {
        if (self.length + 2 > BUFFER_SIZE) return false;

        _ = self.insertChar(open);
        _ = self.insertChar(close);
        self.cursor -= 1;

        return true;
    }

    pub fn deleteCharBefore(self: *LineBuffer) void {
        if (self.cursor == 0) return;

        if (self.cursor < self.length) {
            @memmove(
                self.data[self.cursor - 1 .. self.length - 1],
                self.data[self.cursor .. self.length],
            );
        }

        self.cursor -= 1;
        self.length -= 1;
    }

    pub fn deleteMatchedPair(self: *LineBuffer) bool {
        if (self.cursor == 0 or self.cursor >= self.length) return false;
        const prev = self.data[self.cursor - 1];
        const next = self.data[self.cursor];

        if (!isMatchedPair(prev, next)) return false;

        if (self.cursor + 1 < self.length) {
            @memmove(
                self.data[self.cursor - 1 .. self.length - 2],
                self.data[self.cursor + 1 .. self.length],
            );
        }

        self.cursor -= 1;
        self.length -= 2;

        return true;
    }

    pub fn deleteCharAt(self: *LineBuffer) void {
        if (self.cursor >= self.length) return;

        if (self.cursor + 1 < self.length) {
            @memmove(
                self.data[self.cursor .. self.length - 1],
                self.data[self.cursor + 1 .. self.length],
            );
        }

        self.length -= 1;
    }

    pub fn cursorLeft(self: *LineBuffer) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    pub fn cursorRight(self: *LineBuffer) void {
        if (self.cursor < self.length) self.cursor += 1;
    }

    pub fn cursorToBeginning(self: *LineBuffer) void {
        self.cursor = 0;
    }

    pub fn cursorToEnd(self: *LineBuffer) void {
        self.cursor = self.length;
    }

    pub fn cursorWordRight(self: *LineBuffer) void {
        var pos = self.cursor;
        while (pos < self.length and !isWordChar(self.data[pos])) pos += 1;
        while (pos < self.length and isWordChar(self.data[pos])) pos += 1;

        self.cursor = pos;
    }

    pub fn cursorWordLeft(self: *LineBuffer) void {
        var pos = self.cursor;
        while (pos > 0 and !isWordChar(self.data[pos - 1])) pos -= 1;
        while (pos > 0 and isWordChar(self.data[pos - 1])) pos -= 1;

        self.cursor = pos;
    }

    pub fn killAll(self: *LineBuffer) void {
        self.length = 0;
        self.cursor = 0;
    }

    pub fn killToEnd(self: *LineBuffer) void {
        self.length = self.cursor;
    }

    pub fn deleteWordBefore(self: *LineBuffer) void {
        if (self.cursor == 0) return;
        
        var target = self.cursor;
        while (target > 0 and !isWordChar(self.data[target - 1])) target -= 1;
        while (target > 0 and isWordChar(self.data[target - 1])) target -= 1;

        const chars_deleted = self.cursor - target;
       
        if (chars_deleted == 0) return;
        
        if (self.cursor < self.length) {
            @memmove(
                self.data[target .. self.length - chars_deleted],
                self.data[self.cursor .. self.length],
            );
        }

        self.length -= chars_deleted;
        self.cursor = target;
    }

    pub fn setContent(self: *LineBuffer, content: []const u8) void {
        const copy_len = @min(content.len, BUFFER_SIZE);
        @memcpy(self.data[0..copy_len], content[0..copy_len]);
        self.length = copy_len;
        self.cursor = copy_len;
    }

    pub fn removeRange(self: *LineBuffer, start: usize, end: usize) void {
        if (end <= start or end > self.length) return;
        const removed = end - start;
        if (end < self.length) {
            @memmove(
                self.data[start .. self.length - removed],
                self.data[end..self.length],
            );
        }
        self.length -= removed;

        if (self.cursor >= end) {
            self.cursor -= removed;
        } 
        else 
        if (self.cursor > start) {
            self.cursor = start;
        }
    }
};

// Row/col helpers

pub fn rowOf(content: []const u8, offset: usize) usize {
    var row: usize = 0;
    const limit = @min(offset, content.len);
    var i: usize = 0;

    while (i < limit) : (i += 1) {
        if (content[i] == '\n') row += 1;
    }

    return row;
}

pub fn colOf(content: []const u8, offset: usize) usize {
    var last_newline: ?usize = null;
    const limit = @min(offset, content.len);

    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (content[i] == '\n') last_newline = i;
    }

    return if (last_newline) |ln| offset - ln - 1 else offset;
}

pub fn offsetAt(content: []const u8, row: usize, col: usize) usize {
    var current_row: usize = 0;
    var row_start: usize = 0;

    var i: usize = 0;
    while (i < content.len and current_row < row) : (i += 1) {
        if (content[i] == '\n') {
            current_row += 1;
            row_start = i + 1;
        }
    }

    if (current_row < row) return content.len;

    var row_end: usize = row_start;
    while (row_end < content.len and content[row_end] != '\n') : (row_end += 1) {}

    return row_start + @min(col, row_end - row_start);
}

fn testInsertString(buffer: *LineBuffer, string: []const u8) void {
    for (string) |byte| {
        _ = buffer.insertChar(byte);
    }
}

test "line buffer: insert characters" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello");
    try std.testing.expectEqualStrings("hello", buffer.slice());
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);
    try std.testing.expectEqual(@as(usize, 5), buffer.length);
}

test "line buffer: insert in middle" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hllo");
    buffer.cursor = 1;
    _ = buffer.insertChar('e');
    try std.testing.expectEqualStrings("hello", buffer.slice());
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
}

test "line buffer: delete backward" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello");
    buffer.deleteCharBefore();
    try std.testing.expectEqualStrings("hell", buffer.slice());
    try std.testing.expectEqual(@as(usize, 4), buffer.cursor);
}

test "line buffer: delete backward in middle" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello");
    buffer.cursor = 3;
    buffer.deleteCharBefore();
    try std.testing.expectEqualStrings("helo", buffer.slice());
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
}

test "line buffer: delete matched pair in middle keeps the text after it" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "ab");
    buffer.cursor = 1;
    _ = buffer.insertPair(tok.EXPRESSION_OPEN, tok.EXPRESSION_CLOSE);

    try std.testing.expect(buffer.deleteMatchedPair());
    try std.testing.expectEqualStrings("ab", buffer.slice());
    try std.testing.expectEqual(@as(usize, 1), buffer.cursor);
}

test "line buffer: delete backward at beginning does nothing" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello");
    buffer.cursor = 0;
    buffer.deleteCharBefore();
    try std.testing.expectEqualStrings("hello", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
}

test "line buffer: delete forward" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello");
    buffer.cursor = 2;
    buffer.deleteCharAt();
    try std.testing.expectEqualStrings("helo", buffer.slice());
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
}

test "line buffer: delete forward at end does nothing" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello");
    buffer.deleteCharAt();
    try std.testing.expectEqualStrings("hello", buffer.slice());
}

test "line buffer: cursor movement" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello");
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);

    buffer.cursorLeft();
    try std.testing.expectEqual(@as(usize, 4), buffer.cursor);

    buffer.cursorRight();
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);

    buffer.cursorRight();
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);

    buffer.cursorToBeginning();
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);

    buffer.cursorLeft();
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);

    buffer.cursorToEnd();
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);
}

test "line buffer: move cursor word right" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello world foo");
    buffer.cursor = 0;

    buffer.cursorWordRight();
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);

    buffer.cursorWordRight();
    try std.testing.expectEqual(@as(usize, 11), buffer.cursor);

    buffer.cursorWordRight();
    try std.testing.expectEqual(@as(usize, 15), buffer.cursor);

    buffer.cursorWordRight();
    try std.testing.expectEqual(@as(usize, 15), buffer.cursor);
}

test "line buffer: move cursor word left" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello world foo");

    buffer.cursorWordLeft();
    try std.testing.expectEqual(@as(usize, 12), buffer.cursor);

    buffer.cursorWordLeft();
    try std.testing.expectEqual(@as(usize, 6), buffer.cursor);

    buffer.cursorWordLeft();
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);

    buffer.cursorWordLeft();
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
}

test "line buffer: kill all" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello world");
    buffer.killAll();
    try std.testing.expectEqualStrings("", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
}

test "line buffer: kill to end" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello world");
    buffer.cursor = 5;
    buffer.killToEnd();
    try std.testing.expectEqualStrings("hello", buffer.slice());
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);
}

test "line buffer: delete word backward" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello world");
    buffer.deleteWordBefore();
    try std.testing.expectEqualStrings("hello ", buffer.slice());
    try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
}

test "line buffer: delete word backward in middle keeps the text after it" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello world");
    buffer.cursor = 5;
    buffer.deleteWordBefore();
    try std.testing.expectEqualStrings(" world", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
}

test "line buffer: delete word backward with trailing spaces" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello   ");
    buffer.deleteWordBefore();
    try std.testing.expectEqualStrings("", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
}

test "line buffer: delete word backward stops at punctuation in path" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "~/.config/foo");
    buffer.deleteWordBefore();
    try std.testing.expectEqualStrings("~/.config/", buffer.slice());

    buffer.deleteWordBefore();
    try std.testing.expectEqualStrings("~/.", buffer.slice());
}

test "line buffer: move cursor word right stops at punctuation in path" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "~/.config/foo");
    buffer.cursor = 0;

    buffer.cursorWordRight();
    try std.testing.expectEqual(@as(usize, 9), buffer.cursor);

    buffer.cursorWordRight();
    try std.testing.expectEqual(@as(usize, 13), buffer.cursor);
}

test "line buffer: delete word backward at beginning does nothing" {
    var buffer = LineBuffer{};
    testInsertString(&buffer, "hello");
    buffer.cursor = 0;
    buffer.deleteWordBefore();
    try std.testing.expectEqualStrings("hello", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
}

test "rowOf: counts newlines before offset" {
    try std.testing.expectEqual(@as(usize, 0), rowOf("abc", 2));
    try std.testing.expectEqual(@as(usize, 0), rowOf("abc\ndef", 2));
    try std.testing.expectEqual(@as(usize, 1), rowOf("abc\ndef", 4));
    try std.testing.expectEqual(@as(usize, 1), rowOf("abc\ndef", 7));
    try std.testing.expectEqual(@as(usize, 2), rowOf("a\nb\nc", 4));
}

test "colOf: bytes since last newline" {
    try std.testing.expectEqual(@as(usize, 0), colOf("abc", 0));
    try std.testing.expectEqual(@as(usize, 2), colOf("abc", 2));
    try std.testing.expectEqual(@as(usize, 0), colOf("abc\ndef", 4));
    try std.testing.expectEqual(@as(usize, 2), colOf("abc\ndef", 6));
    try std.testing.expectEqual(@as(usize, 3), colOf("abc\ndef", 7));
}

test "offsetAt: round-trip with rowOf/colOf" {
    const content = "abc\ndefg\nhi";
    var offset: usize = 0;
    while (offset <= content.len) : (offset += 1) {
        const row = rowOf(content, offset);
        const col = colOf(content, offset);
        try std.testing.expectEqual(offset, offsetAt(content, row, col));
    }
}

test "offsetAt: clamps col to row length" {
    const content = "abc\nde";
    try std.testing.expectEqual(@as(usize, 3), offsetAt(content, 0, 100));
    try std.testing.expectEqual(@as(usize, 6), offsetAt(content, 1, 100));
}

test "offsetAt: row beyond buffer returns content.len" {
    const content = "abc";
    try std.testing.expectEqual(@as(usize, 3), offsetAt(content, 5, 0));
}
