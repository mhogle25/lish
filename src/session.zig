const std = @import("std");
const exec_mod = @import("exec.zig");
const process_mod = @import("process.zig");
const validation_mod = @import("validation.zig");

const Allocator = std.mem.Allocator;
const Registry = exec_mod.Registry;
const Env = exec_mod.Env;
const Scope = exec_mod.Scope;
const ExpressionCache = process_mod.ExpressionCache;
const ProcessResult = process_mod.ProcessResult;
const MacroLoadResult = process_mod.MacroLoadResult;
const MacroDirResult = process_mod.MacroDirResult;
const RegistryFragment = process_mod.RegistryFragment;
const ValidationError = validation_mod.ValidationError;

/// When transient runtime values (the eval arena) are reclaimed.
pub const EvalReset = enum {
    /// Reset before every execute(): a result is valid only until the next
    /// execute(). Bounded memory, no caller effort. The default.
    per_execute,
    /// Never reset automatically: results stay valid until the caller calls
    /// resetEval(). Lets a batch of results be combined without per-value dupe(),
    /// at the cost of the caller managing reclamation.
    manual,
};

pub const SessionConfig = struct {
    io: std.Io,
    fragments: []const RegistryFragment = &.{},
    macro_paths: []const []const u8 = &.{},
    expression_cache_capacity: usize = 256,
    stdout: ?*std.Io.Writer = null,
    stderr: ?*std.Io.Writer = null,
    bounds: exec_mod.Bounds = .{},
    eval_reset: EvalReset = .per_execute,
};

pub const Session = struct {
    io: std.Io,
    registry: Registry,
    env: Env,
    expression_cache: ExpressionCache,
    parse_arena: std.heap.ArenaAllocator, // persistent: cached parses
    eval_arena: std.heap.ArenaAllocator, // transient: reset each execute()
    eval_reset: EvalReset,
    session_allocator: Allocator,

    pub fn init(allocator: Allocator, config: SessionConfig) !Session {
        var registry = Registry.init(allocator);
        try process_mod.loadFragments(&registry, allocator, config.fragments);

        var expression_cache = try ExpressionCache.init(allocator, config.expression_cache_capacity);
        errdefer expression_cache.deinit();

        var session = Session{
            .io = config.io,
            .registry = registry,
            .env = .{
                .registry = undefined, // set in execute() via self pointer
                .allocator = undefined, // set in execute() via self.arena
                .io = config.io,
                .stdout = config.stdout,
                .stderr = config.stderr,
                .bounds = config.bounds,
            },
            .expression_cache = expression_cache,
            .parse_arena = std.heap.ArenaAllocator.init(allocator),
            .eval_arena = std.heap.ArenaAllocator.init(allocator),
            .eval_reset = config.eval_reset,
            .session_allocator = allocator,
        };

        // Load macros from configured paths, each may be a file or directory.
        for (config.macro_paths) |macro_path| {
            var maybe_dir = std.Io.Dir.cwd().openDir(config.io, macro_path, .{}) catch null;
            if (maybe_dir) |*dir| {
                dir.close(config.io);
                const result = try process_mod.loadMacroDir(config.io, allocator, &session.registry, macro_path);
                result.deinit(allocator);
            } else {
                _ = try process_mod.loadMacroFile(config.io, allocator, &session.registry, macro_path);
            }
        }

        return session;
    }

    pub fn deinit(self: *Session) void {
        self.expression_cache.deinit();
        self.parse_arena.deinit();
        self.eval_arena.deinit();
        self.registry.deinit(self.session_allocator);
    }

    /// Execute one input. The returned value is valid until the next execute().
    pub fn execute(self: *Session, input: []const u8) Allocator.Error!ProcessResult {
        self.prepareEnv();
        return process_mod.processRawCached(&self.env, self.parse_arena.allocator(), &self.expression_cache, input, null);
    }

    /// Execute with a provided scope. Result valid until the next execute().
    pub fn executeWithScope(self: *Session, input: []const u8, scope: *const Scope) Allocator.Error!ProcessResult {
        self.prepareEnv();
        return process_mod.processRawCached(&self.env, self.parse_arena.allocator(), &self.expression_cache, input, scope);
    }

    fn prepareEnv(self: *Session) void {
        if (self.eval_reset == .per_execute) {
            _ = self.eval_arena.reset(.retain_capacity); // reclaim the previous execution's transients
        }
        self.env.registry = &self.registry;
        self.env.allocator = self.eval_arena.allocator();
        self.env.runtime_error = null;
        self.env.call_depth = 0;
        self.env.fuel_remaining = self.env.bounds.fuel;
    }

    /// Load macro files from a directory.
    pub fn loadMacroDir(self: *Session, dir_path: []const u8) !MacroDirResult {
        return process_mod.loadMacroDir(self.io, self.session_allocator, &self.registry, dir_path);
    }

    /// Load a single macro file.
    pub fn loadMacroFile(self: *Session, file_path: []const u8) !MacroLoadResult {
        return process_mod.loadMacroFile(self.io, self.session_allocator, &self.registry, file_path);
    }

    /// Clear the expression cache.
    pub fn clearCache(self: *Session) void {
        self.expression_cache.clear();
    }

    /// Reclaim transient runtime values (the eval arena). Automatic in the default
    /// per_execute mode; call this explicitly under .manual when done with a batch.
    pub fn resetEval(self: *Session) void {
        _ = self.eval_arena.reset(.retain_capacity);
    }

    /// Clear the cache and reset the parse arena (cached parses). Transient runtime
    /// values live in the eval arena; reclaim those with resetEval().
    pub fn resetArena(self: *Session) void {
        self.expression_cache.clear();
        _ = self.parse_arena.reset(.retain_capacity);
    }
};


const builtins = @import("builtins.zig");

test "session: basic execute" {
    var session = try Session.init(std.testing.allocator, .{
        .io = std.Io.failing,
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    const result = try session.execute("+ 1 2");
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "session: multiple executions reuse cache" {
    var session = try Session.init(std.testing.allocator, .{
        .io = std.Io.failing,
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    // First execution, cache miss
    const result1 = try session.execute("+ 10 20");
    switch (result1) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 30), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }

    // Second execution, cache hit
    const result2 = try session.execute("+ 10 20");
    switch (result2) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 30), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 1), session.expression_cache.count());
}

test "session: runtime error does not break subsequent executions" {
    var session = try Session.init(std.testing.allocator, .{
        .io = std.Io.failing,
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    // Trigger a runtime error
    const bad_result = try session.execute("nonexistent 1 2");
    switch (bad_result) {
        .runtime_err => {},
        else => return error.TestUnexpectedResult,
    }

    // Should still work fine after error
    const good_result = try session.execute("+ 1 2");
    switch (good_result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int),
        else => return error.TestUnexpectedResult,
    }
}

test "session: clear cache" {
    var session = try Session.init(std.testing.allocator, .{
        .io = std.Io.failing,
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    _ = try session.execute("+ 1 2");
    try std.testing.expectEqual(@as(usize, 1), session.expression_cache.count());

    session.clearCache();
    try std.testing.expectEqual(@as(usize, 0), session.expression_cache.count());
}

test "session: eval arena is reclaimed across executions" {
    var session = try Session.init(std.testing.allocator, .{
        .io = std.Io.failing,
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    // A list-producing expression allocates transient values on every run.
    _ = try session.execute("range 0 500");
    const baseline = session.eval_arena.queryCapacity();

    for (0..100) |_| _ = try session.execute("range 0 500");
    // Each execute resets the eval arena, so 100 more runs don't grow it.
    try std.testing.expectEqual(baseline, session.eval_arena.queryCapacity());
}

test "session: manual eval reset keeps results alive across executions" {
    var session = try Session.init(std.testing.allocator, .{
        .io = std.Io.failing,
        .fragments = &.{&builtins.registerAll},
        .eval_reset = .manual,
    });
    defer session.deinit();

    const first = (try session.execute("range 0 3")).ok.?;
    const second = (try session.execute("range 10 13")).ok.?;

    // No reset happened between the two executes, so the first list is still valid.
    try std.testing.expectEqual(@as(i64, 0), (try first.getL())[0].?.int);
    try std.testing.expectEqual(@as(i64, 10), (try second.getL())[0].?.int);

    // resetEval retains capacity but reclaims contents; the next execute reuses it.
    session.resetEval();
    const after = (try session.execute("range 0 3")).ok.?;
    try std.testing.expectEqual(@as(i64, 0), (try after.getL())[0].?.int);
}
