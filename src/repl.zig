const std = @import("std");
const exec_mod = @import("exec.zig");
const value_mod = @import("value.zig");
const builtins_mod = @import("builtins.zig");
const process_mod = @import("process.zig");
const session_mod = @import("session.zig");
const line_editor_mod = @import("line_editor.zig");

const Allocator = std.mem.Allocator;
const LineEditor = line_editor_mod.LineEditor;

const op_autopair_insert   = "autopair-insert";
const op_autopair_delete   = "autopair-delete";
const op_bracket_expand    = "bracket-expand";
const op_highlight         = "highlight";
const op_max_call_depth    = "max-call-depth";
const op_fuel              = "fuel";
const op_max_list_length   = "max-list-length";
const op_max_string_length = "max-string-length";
const op_indent_width      = "indent-width";
const op_history_size      = "history-size";
const op_prompt            = "prompt";

const Param = exec_mod.Param;
const on_off = [_]Param{.{ .name = "on", .arity = .optional }};
const n_off = [_]Param{.{ .name = "n", .type = .{ .one_of = &.{ .int, .none } } }};

/// Write a result value in the canonical `=> <value>` form, strings quoted to
/// disambiguate them from other types. The caller frames it (the trailing
/// newline, and the REPL's dim ANSI). Shared by the REPL and the `lish <file>`
/// runner so they stay consistent.
pub fn writeResult(writer: *std.Io.Writer, value: value_mod.Value) std.Io.Writer.Error!void {
    try writer.writeAll("=> ");
    switch (value) {
        .string => |str| try writer.print("\"{s}\"", .{str}),
        else => try value.writeTo(writer),
    }
}

/// Maximum size of the REPL config file read from `~/.config/lish/config`.
const CONFIG_FILE_MAX_SIZE = 64 * 1024;

pub const ReplConfig = struct {
    autopair_insert: bool = true,
    autopair_delete: bool = true,
    bracket_expand: bool = true,
    highlight: bool = true,
    /// Spaces per Tab / indent level. Mirrors the editor default.
    indent_width: usize = 4,
    /// Lines of command history retained. Mirrors the history default.
    history_size: usize = 256,
    /// Input prompt, or null to use the editor's default. Owned.
    prompt: ?[]const u8 = null,
    macro_dirs: std.ArrayListUnmanaged([]const u8) = .empty,
    bounds: exec_mod.Bounds = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator) ReplConfig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReplConfig) void {
        for (self.macro_dirs.items) |path| self.allocator.free(path);
        self.macro_dirs.deinit(self.allocator);
        if (self.prompt) |prompt| self.allocator.free(prompt);
    }
};

fn autopairInsertOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    switch (args.count()) {
        0 => config.autopair_insert = true,
        1 => config.autopair_insert = (try args.at(0).get()) != null,
        else => return args.env.fail(.arity_mismatch, op_autopair_insert ++ " takes 0 or 1 argument"),
    }

    return null;
}

fn autopairDeleteOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    switch (args.count()) {
        0 => config.autopair_delete = true,
        1 => config.autopair_delete = (try args.at(0).get()) != null,
        else => return args.env.fail(.arity_mismatch, op_autopair_delete ++ " takes 0 or 1 argument"),
    }

    return null;
}

fn bracketExpandOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    switch (args.count()) {
        0 => config.bracket_expand = true,
        1 => config.bracket_expand = (try args.at(0).get()) != null,
        else => return args.env.fail(.arity_mismatch, op_bracket_expand ++ " takes 0 or 1 argument"),
    }

    return null;
}

fn highlightOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    switch (args.count()) {
        0 => config.highlight = true,
        1 => config.highlight = (try args.at(0).get()) != null,
        else => return args.env.fail(.arity_mismatch, op_highlight ++ " takes 0 or 1 argument"),
    }

    return null;
}

fn maxCallDepthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try args.single();
    const n = try value.resolveInt();
    if (n < 1) return args.env.fail(.invalid_argument, op_max_call_depth ++ " must be a positive integer");

    config.bounds.max_call_depth = @intCast(n);

    return null;
}

fn fuelOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get();
    if (value == null) {
        config.bounds.fuel = null;
        return null;
    }

    const n = value.?.getI() catch return args.env.failFmt(.type_mismatch, "{s} expects an integer or $off, got {s}", .{ op_fuel, value.?.typeName() });

    if (n < 1) return args.env.fail(.invalid_argument, op_fuel ++ " must be a positive integer");

    config.bounds.fuel = @intCast(n);

    return null;
}

fn maxListLengthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get();
    if (value == null) {
        config.bounds.max_list_length = null;
        return null;
    }

    const n = value.?.getI() catch return args.env.failFmt(.type_mismatch, "{s} expects an integer or $off, got {s}", .{ op_max_list_length, value.?.typeName() });

    if (n < 1) return args.env.fail(.invalid_argument, op_max_list_length ++ " must be a positive integer");

    config.bounds.max_list_length = @intCast(n);

    return null;
}

fn maxStringLengthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get();
    if (value == null) {
        config.bounds.max_string_length = null;
        return null;
    }

    const n = value.?.getI() catch return args.env.failFmt(.type_mismatch, "{s} expects an integer or $off, got {s}", .{ op_max_string_length, value.?.typeName() });

    if (n < 1) return args.env.fail(.invalid_argument, op_max_string_length ++ " must be a positive integer");

    config.bounds.max_string_length = @intCast(n);

    return null;
}

fn macrosOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try (try args.single()).resolveString(&path_buf);
    const owned = config.allocator.dupe(u8, path) catch return error.OutOfMemory;

    config.macro_dirs.append(config.allocator, owned) catch {
        config.allocator.free(owned);
        return error.OutOfMemory;
    };

    return null;
}

fn indentWidthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const n = try (try args.single()).resolveInt();
    if (n < 1) return args.env.fail(.invalid_argument, op_indent_width ++ " must be a positive integer");
    config.indent_width = @intCast(n);
    return null;
}

fn historySizeOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const n = try (try args.single()).resolveInt();
    if (n < 1) return args.env.fail(.invalid_argument, op_history_size ++ " must be a positive integer");
    config.history_size = @intCast(n);
    return null;
}

fn promptOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    var buf: [256]u8 = undefined;
    const text = try (try args.single()).resolveString(&buf);
    const owned = config.allocator.dupe(u8, text) catch return error.OutOfMemory;
    if (config.prompt) |old| config.allocator.free(old);
    config.prompt = owned;
    return null;
}

const CONFIG_FILE_NAME = "config" ++ process_mod.LISH_EXTENSION;

fn configFilePath(environ: std.process.Environ, allocator: Allocator) ?[]const u8 {
    return 
        if (environ.getPosix("XDG_CONFIG_HOME")) |xdg| std.fs.path.join(allocator, &.{ xdg, "lish", CONFIG_FILE_NAME }) catch null else
        if (environ.getPosix("HOME"))            |home| std.fs.path.join(allocator, &.{ home, ".config", "lish", CONFIG_FILE_NAME }) catch null else 
        null;
}

/// Commented starter written by `--init-config`.
pub const STARTER_CONFIG =
    \\## lish REPL config. Evaluated once at startup.
    \\## Settings are ops; wrap several in `proc`. Booleans take $on / $off.
    \\
    \\proc
    \\  (indent-width 4)
    \\  (history-size 1000)
    \\  (prompt "> ")
    \\  (autopair-insert $on)
    \\  (bracket-expand $on)
    \\  (highlight $on)
    \\
;

pub const InitConfigResult = struct {
    /// Absolute config path; caller frees.
    path: []const u8,
    /// True if newly written, false if it already existed.
    created: bool,
};

/// Write the starter config to the standard path if absent. Returns the path and
/// whether it was created, or null if no config location can be determined.
pub fn initConfig(io: std.Io, environ: std.process.Environ, allocator: Allocator) !?InitConfigResult {
    const path = configFilePath(environ, allocator) orelse return null;
    errdefer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
            try cwd.writeFile(io, .{ .sub_path = path, .data = STARTER_CONFIG });
            return .{ .path = path, .created = true };
        },
        else => return err,
    };
    return .{ .path = path, .created = false };
}

/// Register the REPL config ops (and `on`/`off` macros) into `registry`, bound
/// to `config`. A reusable fragment so tooling can introspect them.
pub fn registerConfigOps(registry: *exec_mod.Registry, config: *ReplConfig, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "repl-config");
    try g.register(op_autopair_insert, exec_mod.Operation.fromBoundFn(ReplConfig, autopairInsertOp, config, .{
        .signature = .{ .params = &on_off, .returns = .none },
        .description = "REPL config: insert the matching closer when you type an opening bracket or quote.",
    }));

    try g.register(op_autopair_delete, exec_mod.Operation.fromBoundFn(ReplConfig, autopairDeleteOp, config, .{
        .signature = .{ .params = &on_off, .returns = .none },
        .description = "REPL config: delete the matching closer when you backspace an opening bracket.",
    }));

    try g.register(op_bracket_expand, exec_mod.Operation.fromBoundFn(ReplConfig, bracketExpandOp, config, .{
        .signature = .{ .params = &on_off, .returns = .none },
        .description = "REPL config: Alt+Enter inside a bracket pair expands it across lines; backspace collapses it.",
    }));

    try g.register(op_highlight, exec_mod.Operation.fromBoundFn(ReplConfig, highlightOp, config, .{
        .signature = .{ .params = &on_off, .returns = .none },
        .description = "REPL config: syntax highlighting of the input line.",
    }));

    try g.register(op_max_call_depth, exec_mod.Operation.fromBoundFn(ReplConfig, maxCallDepthOp, config, .{
        .signature = .{ .params = comptime &.{Param{ .name = "n" }}, .returns = .none },
        .description = "REPL config: maximum operation call-stack depth before recursion is stopped.",
    }));

    try g.register(op_fuel, exec_mod.Operation.fromBoundFn(ReplConfig, fuelOp, config, .{
        .signature = .{ .params = &n_off, .returns = .none },
        .description = "REPL config: maximum evaluation steps per expression, or $off to disable.",
    }));

    try g.register(op_max_list_length, exec_mod.Operation.fromBoundFn(ReplConfig, maxListLengthOp, config, .{
        .signature = .{ .params = &n_off, .returns = .none },
        .description = "REPL config: maximum list length, or $off to disable.",
    }));

    try g.register(op_max_string_length, exec_mod.Operation.fromBoundFn(ReplConfig, maxStringLengthOp, config, .{
        .signature = .{ .params = &n_off, .returns = .none },
        .description = "REPL config: maximum string length, or $off to disable.",
    }));

    try g.register("macros", exec_mod.Operation.fromBoundFn(ReplConfig, macrosOp, config, .{
        .signature = .{ .params = comptime &.{Param{ .name = "path" }}, .returns = .none },
        .description = "REPL config: add a directory to load macro modules from.",
    }));

    try g.register(op_indent_width, exec_mod.Operation.fromBoundFn(ReplConfig, indentWidthOp, config, .{
        .signature = .{ .params = comptime &.{Param{ .name = "n" }}, .returns = .none },
        .description = "REPL config: spaces per Tab / indent level.",
    }));

    try g.register(op_history_size, exec_mod.Operation.fromBoundFn(ReplConfig, historySizeOp, config, .{
        .signature = .{ .params = comptime &.{Param{ .name = "n" }}, .returns = .none },
        .description = "REPL config: lines of command history to retain.",
    }));

    try g.register(op_prompt, exec_mod.Operation.fromBoundFn(ReplConfig, promptOp, config, .{
        .signature = .{ .params = comptime &.{Param{ .name = "text" }}, .returns = .none },
        .description = "REPL config: the input prompt string.",
    }));

    _ = try process_mod.loadMacroModule(registry,
        \\on | $some ;
        \\off | $none ;
    );
}

pub fn loadConfig(io: std.Io, environ: std.process.Environ, config: *ReplConfig, allocator: Allocator) void {
    const path = configFilePath(environ, allocator) orelse return;
    defer allocator.free(path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(CONFIG_FILE_MAX_SIZE)) catch return;
    defer allocator.free(source);

    applyConfig(config, source, allocator);
}

/// Register the config ops against a throwaway registry and evaluate `source`
/// (config file contents) to populate `config`. Errors are swallowed: a broken
/// line just leaves the corresponding default in place.
fn applyConfig(config: *ReplConfig, source: []const u8, allocator: Allocator) void {
    // The registry, parse, and eval are throwaway; only values copied into
    // `config` (via config.allocator) outlive this call.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var registry = exec_mod.Registry.init(scratch);
    builtins_mod.registerCore(&registry, scratch) catch return;
    registerConfigOps(&registry, config, scratch) catch return;

    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return;

    var env = exec_mod.Env{ .registry = &registry, .allocator = scratch };
    _ = process_mod.processRaw(&env, trimmed, null) catch {};
}

pub fn runRepl(
    session: *session_mod.Session,
    editor: *LineEditor,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) void {
    while (true) {
        switch (editor.readLine()) {
            .eof => break,
            .line => |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;

                if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
                    break;
                }

                if (std.mem.eql(u8, trimmed, "clear")) {
                    stdout.print("\x1b[2J\x1b[H", .{}) catch {};
                    continue;
                }

                const result = session.execute(trimmed) catch |err| {
                    stderr.print("Error: {}\n", .{err}) catch {};
                    continue;
                };

                switch (result) {
                    .ok => |maybe_value| {
                        if (maybe_value) |value| {
                            stdout.writeAll("\x1b[2m") catch {};
                            writeResult(stdout, value) catch {};
                            stdout.writeAll("\x1b[0m\n") catch {};
                        }
                    },
                    .validation_err => |errors| {
                        for (errors) |validation_error| {
                            stderr.print("\x1b[31mValidation error: {s}\x1b[0m\n", .{validation_error.message}) catch {};
                        }
                    },
                    .runtime_err => |re| {
                        stderr.print("\x1b[31mRuntime error: {s}\x1b[0m\n", .{re.message}) catch {};
                    },
                }
            },
        }
    }
}


const testing = std.testing;

test "applyConfig sets indent-width, history-size, and prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    applyConfig(&config, "proc (indent-width 2) (history-size 500) (prompt \"# \")", arena.allocator());

    try testing.expectEqual(@as(usize, 2), config.indent_width);
    try testing.expectEqual(@as(usize, 500), config.history_size);
    try testing.expectEqualStrings("# ", config.prompt.?);
}

test "applyConfig applies the shipped starter config (comments + multiline)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    applyConfig(&config, STARTER_CONFIG, arena.allocator());

    try testing.expectEqual(@as(usize, 4), config.indent_width);
    try testing.expectEqual(@as(usize, 1000), config.history_size);
    try testing.expectEqualStrings("> ", config.prompt.?);
}

test "applyConfig leaves defaults when a setting is invalid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    // indent-width 0 is rejected; the default stays.
    applyConfig(&config, "indent-width 0", arena.allocator());
    try testing.expectEqual(@as(usize, 4), config.indent_width);
}

test "applyConfig with an empty source keeps every default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    applyConfig(&config, "   \n  ", arena.allocator());
    try testing.expectEqual(@as(usize, 4), config.indent_width);
    try testing.expectEqual(@as(usize, 256), config.history_size);
    try testing.expect(config.prompt == null);
}
