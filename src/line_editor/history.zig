const std = @import("std");
const buffer_mod = @import("buffer.zig");

const Allocator = std.mem.Allocator;
const LineBuffer = buffer_mod.LineBuffer;
const EditError = buffer_mod.EditError;

/// Physical ring capacity. The active `limit` (how many lines are actually
/// retained) is configurable up to this; the rest of the array stays unused.
pub const HISTORY_CAPACITY = 1024;
/// Default retained history size.
pub const DEFAULT_HISTORY_SIZE = 256;

/// Ring buffer of past input lines plus browse state. Methods that change the
/// current input take a `*LineBuffer` so History stays decoupled from the
/// editor's orchestration role.
pub const History = struct {
    entries: [HISTORY_CAPACITY]?[]const u8 = @splat(null),
    count: usize = 0,
    write_index: usize = 0,
    /// Active retained-history size (the logical ring length). Set before use.
    limit: usize = DEFAULT_HISTORY_SIZE,
    /// When browsing, index into `entries` of the currently-displayed entry.
    /// Null means not browsing.
    browse_index: ?usize = null,

    /// Backup of the in-progress line captured when browsing starts so that
    /// stepping past the newest entry restores what the user was typing.
    saved_line: std.ArrayList(u8) = .empty,

    allocator: Allocator,

    pub fn init(allocator: Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn setLimit(self: *History, n: usize) void {
        self.limit = @min(@max(n, 1), HISTORY_CAPACITY);
    }

    pub fn deinit(self: *History) void {
        for (&self.entries) |*entry| {
            if (entry.*) |slice| {
                self.allocator.free(slice);
                entry.* = null;
            }
        }
        self.count = 0;
        self.write_index = 0;
        self.saved_line.deinit(self.allocator);
    }

    /// Records `line`. If the copy can't be made, history is left exactly as it was.
    pub fn add(self: *History, line: []const u8) Allocator.Error!void {
        if (self.count > 0) {
            const last_index = if (self.write_index == 0) self.limit - 1 else self.write_index - 1;
            if (self.entries[last_index]) |last_entry| {
                if (std.mem.eql(u8, last_entry, line)) return;
            }
        }

        const copy = try self.allocator.dupe(u8, line);
        if (self.entries[self.write_index]) |old_entry| {
            self.allocator.free(old_entry);
        }
        self.entries[self.write_index] = copy;
        self.write_index = (self.write_index + 1) % self.limit;
        if (self.count < self.limit) self.count += 1;
    }

    /// Shows the next older entry. If it can't, the line and browse state stay as they were.
    pub fn up(self: *History, buffer: *LineBuffer) EditError!void {
        if (self.count == 0) return;

        const next_index = if (self.browse_index) |current|
            self.olderIndex(current) orelse return
        else
            try self.startBrowsing(buffer);

        try self.loadEntry(next_index, buffer, .end);
        self.browse_index = next_index;
    }

    fn startBrowsing(self: *History, buffer: *const LineBuffer) Allocator.Error!usize {
        self.saved_line.clearRetainingCapacity();
        try self.saved_line.appendSlice(self.allocator, buffer.slice());

        return if (self.write_index == 0) self.limit - 1 else self.write_index - 1;
    }

    fn olderIndex(self: *const History, current: usize) ?usize {
        const oldest_index = if (self.count < self.limit) 0 else self.write_index;
        if (current == oldest_index) return null;

        return if (current == 0) self.limit - 1 else current - 1;
    }

    /// Shows the next newer entry, or past the newest, the line being typed.
    /// If it can't, the line and browse state stay as they were.
    pub fn down(self: *History, buffer: *LineBuffer) EditError!void {
        const current = self.browse_index orelse return;

        const newest_index = if (self.write_index == 0) self.limit - 1 else self.write_index - 1;

        if (current == newest_index) {
            try buffer.setContent(self.saved_line.items);
            self.browse_index = null;
            return;
        }

        const next_index = (current + 1) % self.limit;
        try self.loadEntry(next_index, buffer, .start);
        self.browse_index = next_index;
    }

    pub fn endBrowse(self: *History) void {
        self.browse_index = null;
    }

    /// Where to place the cursor after loading a recalled entry. `up` lands at
    /// the end and `down` at the start so multiline navigation continues in the
    /// direction the user was already moving.
    const CursorAt = enum { start, end };

    fn loadEntry(self: *History, index: usize, buffer: *LineBuffer, cursor_at: CursorAt) EditError!void {
        const entry = self.entries[index] orelse return;
        try buffer.setContent(entry);
        buffer.cursor = switch (cursor_at) {
            .start => 0,
            .end   => buffer.length,
        };
    }
};

fn testInsertString(buffer: *LineBuffer, string: []const u8) EditError!void {
    for (string) |byte| try buffer.insertChar(byte);
}

test "history: add and navigate" {
    var buffer = LineBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    try history.add("first");
    try history.add("second");
    try history.add("third");

    try std.testing.expectEqual(@as(usize, 3), history.count);

    try history.up(&buffer);
    try std.testing.expectEqualStrings("third", buffer.slice());

    try history.up(&buffer);
    try std.testing.expectEqualStrings("second", buffer.slice());

    try history.up(&buffer);
    try std.testing.expectEqualStrings("first", buffer.slice());

    try history.down(&buffer);
    try std.testing.expectEqualStrings("second", buffer.slice());

    try history.down(&buffer);
    try std.testing.expectEqualStrings("third", buffer.slice());

    try history.down(&buffer);
    try std.testing.expectEqualStrings("", buffer.slice());
    try std.testing.expect(history.browse_index == null);
}

test "history: up lands cursor at end, down lands cursor at start" {
    var buffer = LineBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    try history.add("a\nbb");
    try history.add("ccc\ndddd");

    try history.up(&buffer);
    try std.testing.expectEqualStrings("ccc\ndddd", buffer.slice());
    try std.testing.expectEqual(buffer.length, buffer.cursor);

    try history.up(&buffer);
    try std.testing.expectEqualStrings("a\nbb", buffer.slice());
    try std.testing.expectEqual(buffer.length, buffer.cursor);

    try history.down(&buffer);
    try std.testing.expectEqualStrings("ccc\ndddd", buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
}

test "history: skip duplicates" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    try history.add("hello");
    try history.add("hello");
    try history.add("hello");

    try std.testing.expectEqual(@as(usize, 1), history.count);
}

test "history: saves current line when browsing" {
    var buffer = LineBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    try history.add("old command");
    try testInsertString(&buffer, "in progress");

    try history.up(&buffer);
    try std.testing.expectEqualStrings("old command", buffer.slice());

    try history.down(&buffer);
    try std.testing.expectEqualStrings("in progress", buffer.slice());
}

test "history: ring buffer wrapping" {
    var buffer = LineBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    for (0..DEFAULT_HISTORY_SIZE + 10) |idx| {
        var num_buf: [16]u8 = undefined;
        const num_str = std.mem.print(&num_buf, "cmd {d}", .{idx}) catch continue;
        try history.add(num_str);
    }

    try std.testing.expectEqual(@as(usize, DEFAULT_HISTORY_SIZE), history.count);

    try history.up(&buffer);
    try std.testing.expectEqualStrings("cmd 265", buffer.slice());
}

test "history: up on empty history does nothing" {
    var buffer = LineBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    try history.up(&buffer);
    try std.testing.expectEqualStrings("", buffer.slice());
    try std.testing.expect(history.browse_index == null);
}

test "history: down without browsing does nothing" {
    var buffer = LineBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    try history.add("something");
    try history.down(&buffer);
    try std.testing.expectEqualStrings("", buffer.slice());
    try std.testing.expect(history.browse_index == null);
}

test "history: a failed copy leaves history exactly as it was" {
    var buffer = LineBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var history = History.init(failing.allocator());
    defer history.deinit();
    history.setLimit(2);

    try history.add("one");
    try history.add("two");
    try std.testing.expectError(error.OutOfMemory, history.add("three"));
    try std.testing.expectError(error.OutOfMemory, history.add("four"));
    try std.testing.expectEqual(@as(usize, 2), history.count);

    try history.up(&buffer);
    try std.testing.expectEqualStrings("two", buffer.slice());
    try history.up(&buffer);
    try std.testing.expectEqualStrings("one", buffer.slice());
}

test "history: an entry longer than 4096 bytes is recalled whole" {
    var buffer = LineBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    const long_entry = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(long_entry);
    @memset(long_entry, 'x');

    try history.add(long_entry);
    try history.up(&buffer);
    try std.testing.expectEqualStrings(long_entry, buffer.slice());
}
