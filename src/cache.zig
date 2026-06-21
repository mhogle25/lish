const std = @import("std");
const exec_mod = @import("exec.zig");

const Allocator = std.mem.Allocator;
const Expression = exec_mod.Expression;

/// Generic LRU cache mapping string keys to values of type V.
/// O(1) get, put, and eviction via HashMap + doubly-linked list.
pub fn LruCache(comptime V: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: []const u8 = "",
            value: V = undefined,
            prev: ?usize = null,
            next: ?usize = null,
            active: bool = false,
        };

        nodes: []Node,
        map: std.StringHashMapUnmanaged(usize),
        head: ?usize = null,
        tail: ?usize = null,
        len: usize = 0,
        capacity: usize,
        allocator: Allocator,

        pub fn init(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            std.debug.assert(capacity > 0);
            const nodes = try allocator.alloc(Node, capacity);
            @memset(nodes, Node{});
            return .{
                .nodes = nodes,
                .map = .{},
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes) |node| {
                if (node.active) {
                    self.allocator.free(node.key);
                }
            }
            self.map.deinit(self.allocator);
            self.allocator.free(self.nodes);
        }

        /// Look up a cached value by key.
        /// On hit, moves the entry to the front (most recently used).
        pub fn get(self: *Self, key: []const u8) ?V {
            const index = self.map.get(key) orelse return null;
            self.moveToFront(index);
            return self.nodes[index].value;
        }

        /// Store a value in the cache. If the cache is full, evicts
        /// the least recently used entry.
        pub fn put(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            // Update existing entry
            if (self.map.get(key)) |index| {
                self.nodes[index].value = value;
                self.moveToFront(index);
                return;
            }

            // Get a slot: either a fresh one or evict the LRU tail
            const index = if (self.len < self.capacity) blk: {
                const idx = self.len;
                self.len += 1;
                break :blk idx;
            } else blk: {
                const tail_idx = self.tail.?;
                _ = self.map.remove(self.nodes[tail_idx].key);
                self.allocator.free(self.nodes[tail_idx].key);
                self.removeFromList(tail_idx);
                self.nodes[tail_idx].active = false;
                break :blk tail_idx;
            };

            const owned_key = try self.allocator.dupe(u8, key);
            self.nodes[index] = .{
                .key = owned_key,
                .value = value,
                .active = true,
            };
            try self.map.put(self.allocator, owned_key, index);
            self.addToFront(index);
        }

        /// Remove all entries from the cache.
        pub fn clear(self: *Self) void {
            for (self.nodes[0..self.len]) |*node| {
                if (node.active) {
                    self.allocator.free(node.key);
                    node.* = .{};
                }
            }
            self.map.clearRetainingCapacity();
            self.head = null;
            self.tail = null;
            self.len = 0;
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }


        fn moveToFront(self: *Self, index: usize) void {
            if (self.head == index) return;
            self.removeFromList(index);
            self.addToFront(index);
        }

        fn addToFront(self: *Self, index: usize) void {
            self.nodes[index].prev = null;
            self.nodes[index].next = self.head;
            if (self.head) |old_head| {
                self.nodes[old_head].prev = index;
            }
            self.head = index;
            if (self.tail == null) {
                self.tail = index;
            }
        }

        fn removeFromList(self: *Self, index: usize) void {
            const node = self.nodes[index];
            if (node.prev) |prev| {
                self.nodes[prev].next = node.next;
            } else {
                self.head = node.next;
            }
            if (node.next) |next| {
                self.nodes[next].prev = node.prev;
            } else {
                self.tail = node.prev;
            }
        }
    };
}

/// LRU cache specialized for Expression values.
/// Important: cached Expressions contain pointers to Thunks. The allocator
/// used for parsing must outlive the cache (e.g. use a session-scoped arena).
pub const ExpressionCache = LruCache(Expression);


const expr_parser = @import("parser.zig");
const validation_mod = @import("validation.zig");

fn parseAndValidate(allocator: Allocator, source: []const u8) !Expression {
    const ast_root = try expr_parser.parse(allocator, source);
    const result = try validation_mod.validate(allocator, ast_root);
    return switch (result) {
        .ok => |expression| expression,
        .err => error.TestUnexpectedResult,
    };
}

test "cache: basic put and get" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    const expression = try parseAndValidate(alloc, "+ 1 2");
    try cache.put("+ 1 2", expression);

    const cached = cache.get("+ 1 2");
    try std.testing.expect(cached != null);
    try std.testing.expectEqualStrings("+", cached.?.name.body.value_literal.?.string);
}

test "cache: miss returns null" {
    var cache = try ExpressionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    try std.testing.expect(cache.get("nonexistent") == null);
}

test "cache: update existing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    const expr1 = try parseAndValidate(alloc, "+ 1 2");
    const expr2 = try parseAndValidate(alloc, "* 3 4");

    try cache.put("key", expr1);
    try cache.put("key", expr2);

    try std.testing.expectEqual(@as(usize, 1), cache.count());

    const cached = cache.get("key").?;
    try std.testing.expectEqualStrings("*", cached.name.body.value_literal.?.string);
}

test "cache: evicts least recently used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put("a", try parseAndValidate(alloc, "+ 1 2"));
    try cache.put("b", try parseAndValidate(alloc, "+ 3 4"));
    try cache.put("c", try parseAndValidate(alloc, "+ 5 6"));

    // Cache is full (capacity 3). Inserting "d" should evict "a" (LRU).
    try cache.put("d", try parseAndValidate(alloc, "+ 7 8"));

    try std.testing.expect(cache.get("a") == null);
    try std.testing.expect(cache.get("b") != null);
    try std.testing.expect(cache.get("c") != null);
    try std.testing.expect(cache.get("d") != null);
}

test "cache: access refreshes LRU order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put("a", try parseAndValidate(alloc, "+ 1 2"));
    try cache.put("b", try parseAndValidate(alloc, "+ 3 4"));
    try cache.put("c", try parseAndValidate(alloc, "+ 5 6"));

    // Access "a" to refresh it, now "b" is the LRU
    _ = cache.get("a");

    try cache.put("d", try parseAndValidate(alloc, "+ 7 8"));

    try std.testing.expect(cache.get("a") != null);
    try std.testing.expect(cache.get("b") == null);
    try std.testing.expect(cache.get("c") != null);
    try std.testing.expect(cache.get("d") != null);
}

test "cache: clear empties the cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put("a", try parseAndValidate(alloc, "+ 1 2"));
    try cache.put("b", try parseAndValidate(alloc, "+ 3 4"));

    try std.testing.expectEqual(@as(usize, 2), cache.count());

    cache.clear();

    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expect(cache.get("a") == null);
    try std.testing.expect(cache.get("b") == null);
}

test "cache: refill after clear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    try cache.put("a", try parseAndValidate(alloc, "+ 1 2"));
    try cache.put("b", try parseAndValidate(alloc, "+ 3 4"));
    cache.clear();

    try cache.put("c", try parseAndValidate(alloc, "+ 5 6"));
    try cache.put("d", try parseAndValidate(alloc, "+ 7 8"));

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expect(cache.get("c") != null);
    try std.testing.expect(cache.get("d") != null);
}

test "cache: repeated evictions cycle correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    const expression = try parseAndValidate(alloc, "+ 1 2");

    // Fill and evict several rounds
    try cache.put("a", expression);
    try cache.put("b", expression);
    try cache.put("c", expression); // evicts "a"
    try cache.put("d", expression); // evicts "b"
    try cache.put("e", expression); // evicts "c"

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expect(cache.get("a") == null);
    try std.testing.expect(cache.get("b") == null);
    try std.testing.expect(cache.get("c") == null);
    try std.testing.expect(cache.get("d") != null);
    try std.testing.expect(cache.get("e") != null);
}

test "cache: generic with simple values" {
    var cache = try LruCache(i32).init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put("one", 1);
    try cache.put("two", 2);
    try cache.put("three", 3);

    try std.testing.expectEqual(@as(i32, 1), cache.get("one").?);
    try std.testing.expectEqual(@as(i32, 2), cache.get("two").?);
    try std.testing.expectEqual(@as(i32, 3), cache.get("three").?);

    // Evict LRU ("one" was accessed most recently due to get above, "two" next, so
    // after the gets above the order is: three(head), two, one(tail)
    // Wait, gets move to front, so after get("one"), get("two"), get("three"):
    // order is three(head), two, one(tail)
    try cache.put("four", 4); // evicts "one" (tail)

    try std.testing.expect(cache.get("one") == null);
    try std.testing.expectEqual(@as(i32, 2), cache.get("two").?);
}
