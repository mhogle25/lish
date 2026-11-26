const std = @import("std");
const exec_mod = @import("exec.zig");
const value_mod = @import("value.zig");
const builtins_mod = @import("builtins.zig");
const process_mod = @import("process.zig");
const session_mod = @import("session.zig");
const line_editor_mod = @import("line_editor.zig");
const diagnostics = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const LineEditor = line_editor_mod.LineEditor;

const PIPED_INPUT_NAME = "<stdin>";

const HOME_SHORTHAND = "~";

const RED = "\x1b[31m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

pub const ExitStatus = enum(u8) {
    ok = 0,
    runtime_error = 1,
    syntax_error = 2,
};

pub const ReplColor = struct {
    errors: bool,
    results: bool,
};

const PIPED_COMMAND_LIMIT_MB = @divExact(line_editor_mod.PIPED_COMMAND_MAX_LENGTH, 1024 * 1024);

const op_autopair_insert   = "autopair-insert";
const op_autopair_delete   = "autopair-delete";
const op_bracket_expand    = "bracket-expand";
const op_highlight         = "highlight";
const op_max_call_depth    = "max-call-depth";
const op_fuel              = "fuel";
const op_max_list_length   = "max-list-length";
const op_max_string_length = "max-string-length";
const op_max_eval_bytes    = "max-eval-bytes";
const op_indent_width      = "indent-width";
const op_history_size      = "history-size";
const op_prompt            = "prompt";

const Param = exec_mod.Param;
const on_off = [_]Param{.{ .name = "on", .arity = .optional }};
const n_off = [_]Param{.{ .name = "n", .type = .{ .one_of = &.{ .int, .none } } }};

pub fn writeResult(writer: *std.Io.Writer, value: value_mod.Value) std.Io.Writer.Error!void {
    try writer.writeAll("=> ");
    try value.format(writer);
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
    macro_dirs: std.ArrayList([]const u8) = .empty,
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
    const value = try (try args.single()).get() orelse {
        config.bounds.fuel = null;
        return null;
    };

    const n = value.getI() catch return args.env.failFmt(.type_mismatch, "{s} expects an integer or $off, got {s}", .{ op_fuel, value.typeName() });

    if (n < 1) return args.env.fail(.invalid_argument, op_fuel ++ " must be a positive integer");

    config.bounds.fuel = @intCast(n);

    return null;
}

fn maxListLengthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get() orelse {
        config.bounds.max_list_length = null;
        return null;
    };

    const n = value.getI() catch return args.env.failFmt(.type_mismatch, "{s} expects an integer or $off, got {s}", .{ op_max_list_length, value.typeName() });

    if (n < 1) return args.env.fail(.invalid_argument, op_max_list_length ++ " must be a positive integer");

    config.bounds.max_list_length = @intCast(n);

    return null;
}

fn maxStringLengthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get() orelse {
        config.bounds.max_string_length = null;
        return null;
    };

    const n = value.getI() catch return args.env.failFmt(.type_mismatch, "{s} expects an integer or $off, got {s}", .{ op_max_string_length, value.typeName() });

    if (n < 1) return args.env.fail(.invalid_argument, op_max_string_length ++ " must be a positive integer");

    config.bounds.max_string_length = @intCast(n);

    return null;
}

fn maxEvalBytesOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get() orelse {
        config.bounds.max_eval_bytes = null;
        return null;
    };

    const n = value.getI() catch return args.env.failFmt(.type_mismatch, "{s} expects an integer or $off, got {s}", .{ op_max_eval_bytes, value.typeName() });

    if (n < 1) return args.env.fail(.invalid_argument, op_max_eval_bytes ++ " must be a positive integer");

    config.bounds.max_eval_bytes = @intCast(n);

    return null;
}

fn macrosOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

fn configFilePath(environ: std.process.Environ, allocator: Allocator) Allocator.Error!?[]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |xdg| return try std.Io.Dir.path.join(allocator, &.{ xdg, "lish", CONFIG_FILE_NAME });
    if (environ.getPosix("HOME"))            |home| return try std.Io.Dir.path.join(allocator, &.{ home, ".config", "lish", CONFIG_FILE_NAME });
    return null;
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

pub fn initConfig(io: std.Io, environ: std.process.Environ, allocator: Allocator) !?InitConfigResult {
    const path = (try configFilePath(environ, allocator)) orelse return null;
    errdefer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.Io.Dir.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
            try cwd.writeFile(io, .{ .sub_path = path, .data = STARTER_CONFIG });
            return .{ .path = path, .created = true };
        },
        else => return err,
    };
    return .{ .path = path, .created = false };
}

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

    try g.register(op_max_eval_bytes, exec_mod.Operation.fromBoundFn(ReplConfig, maxEvalBytesOp, config, .{
        .signature = .{ .params = &n_off, .returns = .none },
        .description = "REPL config: maximum bytes one evaluation may allocate, or $off to disable.",
    }));

    try g.register("macros", exec_mod.Operation.fromBoundFn(ReplConfig, macrosOp, config, .{
        .signature = .{ .params = comptime &.{Param{ .name = "path" }}, .returns = .none },
        .description = "REPL config: load macros from a .lishmacro file or a folder of them; a leading ~/ is your home folder.",
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

    try process_mod.loadMacroBundle(registry,
        \\on | some ;
        \\off | none ;
    );
}

pub const ConfigLoad = union(enum) {
    absent,
    unreadable: Unreadable,
    ran: Ran,

    pub const Unreadable = struct {
        path: []const u8,
        reason: std.Io.Dir.ReadFileAllocError,
    };

    pub const Ran = struct {
        path: []const u8,
        text: []const u8,
        result: process_mod.ProcessResult,
    };
};

/// `arena` owns everything returned.
pub fn loadConfig(io: std.Io, environ: std.process.Environ, config: *ReplConfig, arena: Allocator) Allocator.Error!ConfigLoad {
    const path = (try configFilePath(environ, arena)) orelse return .absent;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(CONFIG_FILE_MAX_SIZE)) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        error.OutOfMemory  => return error.OutOfMemory,
        else               => |reason| return .{ .unreadable = .{ .path = path, .reason = reason } },
    };
    return .{ .ran = .{ .path = path, .text = text, .result = try applyConfig(config, text, arena) } };
}

fn applyConfig(config: *ReplConfig, text: []const u8, arena: Allocator) Allocator.Error!process_mod.ProcessResult {
    var registry = exec_mod.Registry.init(arena);
    try builtins_mod.registerCore(&registry, arena);
    try registerConfigOps(&registry, config, arena);

    var env = exec_mod.Env{ .registry = &registry, .allocator = arena };
    return process_mod.processRaw(&env, text, null);
}

pub fn expandHome(allocator: Allocator, path: []const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    const home_folder = home orelse return allocator.dupe(u8, path);
    if (std.mem.eql(u8, path, HOME_SHORTHAND)) return allocator.dupe(u8, home_folder);
    if (!std.mem.startsWith(u8, path, HOME_SHORTHAND ++ "/")) return allocator.dupe(u8, path);
    return std.Io.Dir.path.join(allocator, &.{ home_folder, path[HOME_SHORTHAND.len + 1 ..] });
}

pub fn writeProblems(stderr: *std.Io.Writer, source: diagnostics.Source, result: process_mod.ProcessResult, color: bool) void {
    switch (result) {
        .ok => {},
        .validation_err => |errors| for (errors) |problem| diagnostics.writeValidationReport(stderr, source, problem, color) catch {},
        .runtime_err    => |problem| diagnostics.writeRuntimeReport(stderr, source, problem, color) catch {},
    }
}

pub fn runRepl(
    session: *session_mod.Session,
    editor: *LineEditor,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    color: ReplColor,
) ExitStatus {
    var last: ExitStatus = .ok;
    while (true) {
        const read = editor.readLine() catch {
            stderr.writeAll("lish: out of memory\n") catch {};
            stderr.flush() catch {};
            return .runtime_error;
        };

        switch (read) {
            .eof => break,
            .too_long => |first_line| {
                writeTooLong(stderr, first_line, color.errors) catch {};
                stderr.flush() catch {};
                last = .syntax_error;
            },
            .line => |line| {
                const trimmed = std.mem.trim(u8, line.text, " \t\r");
                if (trimmed.len == 0) continue;

                if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) break;

                if (std.mem.eql(u8, trimmed, "clear")) {
                    stdout.print("\x1b[2J\x1b[H", .{}) catch {};
                    last = .ok;
                    continue;
                }

                const source: diagnostics.Source = if (line.first_line) |first_line|
                    .{ .name = PIPED_INPUT_NAME, .text = line.text, .first_line = first_line }
                else
                    .{ .name = null, .text = line.text };
                last = runCommand(session, source, stdout, stderr, color);
                stderr.flush() catch {};
            },
        }
    }
    return if (editor.is_terminal) .ok else last;
}

pub fn runCommand(
    session: *session_mod.Session,
    source: diagnostics.Source,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    color: ReplColor,
) ExitStatus {
    const result = session.execute(source.text) catch {
        stderr.writeAll("lish: out of memory\n") catch {};
        return .runtime_error;
    };

    writeProblems(stderr, source, result, color.errors);
    switch (result) {
        .ok => |maybe_value| {
            const value = maybe_value orelse return .ok;
            writeResultLine(stdout, value, color.results) catch {};
            return .ok;
        },
        .validation_err => return .syntax_error,
        .runtime_err    => return .runtime_error,
    }
}

fn writeResultLine(stdout: *std.Io.Writer, value: value_mod.Value, dim: bool) std.Io.Writer.Error!void {
    if (dim) try stdout.writeAll(DIM);
    try writeResult(stdout, value);
    if (dim) try stdout.writeAll(RESET);
    try stdout.writeByte('\n');
}

fn writeTooLong(stderr: *std.Io.Writer, first_line: usize, color: bool) std.Io.Writer.Error!void {
    if (color) try stderr.writeAll(RED);
    try stderr.print("{s}:{d}: command is longer than the {d} MB limit", .{ PIPED_INPUT_NAME, first_line, PIPED_COMMAND_LIMIT_MB });
    if (color) try stderr.writeAll(RESET);
    try stderr.writeByte('\n');
}

const testing = std.testing;

test "piped input and script files share one size limit" {
    try std.testing.expectEqual(process_mod.LISH_FILE_MAX_SIZE, line_editor_mod.PIPED_COMMAND_MAX_LENGTH);
}

test "writeResult renders source style" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeResult(&writer, .{ .string = "hi" });
    try std.testing.expectEqualStrings("=> \"hi\"", writer.buffered());

    const items = [_]?value_mod.Value{ .{ .int = 1 }, .{ .string = "a" }, null };
    var list_buf: [64]u8 = undefined;
    var list_writer = std.Io.Writer.fixed(&list_buf);
    try writeResult(&list_writer, .{ .list = &items });
    try std.testing.expectEqualStrings("=> [1 \"a\" $none]", list_writer.buffered());
}

test "applyConfig sets indent-width, history-size, and prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    try expectApplied(try applyConfig(&config, "proc (indent-width 2) (history-size 500) (prompt \"# \")", arena.allocator()));

    try testing.expectEqual(@as(usize, 2), config.indent_width);
    try testing.expectEqual(@as(usize, 500), config.history_size);
    try testing.expectEqualStrings("# ", config.prompt.?);
}

test "applyConfig applies the shipped starter config (comments + multiline)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    try expectApplied(try applyConfig(&config, STARTER_CONFIG, arena.allocator()));

    try testing.expectEqual(@as(usize, 4), config.indent_width);
    try testing.expectEqual(@as(usize, 1000), config.history_size);
    try testing.expectEqualStrings("> ", config.prompt.?);
}

fn expectApplied(result: process_mod.ProcessResult) !void {
    switch (result) {
        .ok                             => {},
        .validation_err, .runtime_err   => return error.TestUnexpectedResult,
    }
}

test "applyConfig reports a failing setting with where it is, keeping the settings before it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    const text = "\n\nproc (prompt \"# \") (indent-width 0) (history-size 9)";
    switch (try applyConfig(&config, text, arena.allocator())) {
        .runtime_err => |problem| {
            try testing.expectEqualStrings("indent-width must be a positive integer", problem.message);
            const position = problem.position orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("(indent-width 0)", text[position.start..position.end]);
        },
        .ok, .validation_err => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("# ", config.prompt.?);
    try testing.expectEqual(@as(usize, 4), config.indent_width);
    try testing.expectEqual(@as(usize, 256), config.history_size);
}

test "applyConfig reports a syntax error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    switch (try applyConfig(&config, "proc (indent-width 2", arena.allocator())) {
        .validation_err => |errors| try testing.expectEqualStrings("Missing closing parenthesis", errors[0].message),
        .ok, .runtime_err => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 4), config.indent_width);
}

test "applyConfig turns settings off with $off and keeps applying the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    try expectApplied(try applyConfig(&config, "proc (highlight $off) (autopair-insert $off) (fuel 500) (fuel $off) (indent-width 2)", arena.allocator()));

    try testing.expect(!config.highlight);
    try testing.expect(!config.autopair_insert);
    try testing.expect(config.bounds.fuel == null);
    try testing.expectEqual(@as(usize, 2), config.indent_width);
}

test "applyConfig turns a setting back on with $on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    try expectApplied(try applyConfig(&config, "proc (bracket-expand $off) (bracket-expand $on)", arena.allocator()));
    try testing.expect(config.bracket_expand);
}

test "applyConfig applies the docs/repl.md example" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    try expectApplied(try applyConfig(&config,
        \\proc
        \\    (autopair-insert $off)
        \\    (autopair-delete $off)
        \\    (macros '~/.config/lish/macros')
        \\    (max-call-depth 512)
        \\    (fuel 100000)
        \\    (max-list-length 100000)
        \\    (max-string-length 65536)
    , arena.allocator()));

    try testing.expect(!config.autopair_insert);
    try testing.expect(!config.autopair_delete);
    try testing.expectEqual(@as(usize, 1), config.macro_dirs.items.len);
    try testing.expectEqual(@as(usize, 512), config.bounds.max_call_depth);
    try testing.expectEqual(@as(?usize, 100000), config.bounds.fuel);
    try testing.expectEqual(@as(?usize, 100000), config.bounds.max_list_length);
    try testing.expectEqual(@as(?usize, 65536), config.bounds.max_string_length);
}

test "applyConfig: a config with no expression is a syntax error, like any lish file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var config = ReplConfig.init(arena.allocator());

    for ([_][]const u8{ "", "   \n  ", "## only a comment\n" }) |text| {
        switch (try applyConfig(&config, text, arena.allocator())) {
            .validation_err  => {},
            .ok, .runtime_err => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(@as(usize, 4), config.indent_width);
}

fn environForTest(allocator: Allocator, config_home: []const u8) !std.process.Environ {
    const entries = try allocator.allocSentinel(?[*:0]const u8, 1, null);
    entries[0] = try std.fmt.allocPrintSentinel(allocator, "XDG_CONFIG_HOME={s}", .{config_home}, 0);
    return .{ .block = .{ .slice = entries } };
}

test "loadConfig: no file is absent, a folder in its place is unreadable, a file runs" {
    var io_instance: std.Io.Threaded = .init(testing.allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_home = try std.Io.Dir.path.join(memory, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const environ = try environForTest(memory, config_home);
    var config = ReplConfig.init(memory);

    try testing.expectEqual(ConfigLoad.absent, try loadConfig(io, environ, &config, memory));

    try tmp.dir.createDirPath(io, "lish/config.lish");
    switch (try loadConfig(io, environ, &config, memory)) {
        .unreadable => |unreadable| try testing.expectEqual(error.IsDir, unreadable.reason),
        .absent, .ran => return error.TestUnexpectedResult,
    }

    try tmp.dir.deleteDir(io, "lish/config.lish");
    try tmp.dir.writeFile(io, .{ .sub_path = "lish/config.lish", .data = "indent-width 2" });
    switch (try loadConfig(io, environ, &config, memory)) {
        .ran => |ran| {
            try expectApplied(ran.result);
            try testing.expectEqualStrings("indent-width 2", ran.text);
        },
        .absent, .unreadable => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 2), config.indent_width);
}

test "expandHome: only a leading ~ or ~/ becomes the home folder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();

    try testing.expectEqualStrings("/home/someone", try expandHome(memory, "~", "/home/someone"));
    try testing.expectEqualStrings("/home/someone/macros", try expandHome(memory, "~/macros", "/home/someone"));
    try testing.expectEqualStrings("a~b", try expandHome(memory, "a~b", "/home/someone"));
    try testing.expectEqualStrings("macros/~old", try expandHome(memory, "macros/~old", "/home/someone"));
    try testing.expectEqualStrings("~other/macros", try expandHome(memory, "~other/macros", "/home/someone"));
    try testing.expectEqualStrings("~/macros", try expandHome(memory, "~/macros", null));
}

const CommandRun = struct {
    status: ExitStatus,
    out: []const u8,
    err: []const u8,
};

fn runForTest(allocator: Allocator, source: diagnostics.Source, color: ReplColor) !CommandRun {
    var session = try session_mod.Session.init(std.testing.allocator, .{
        .io = std.Io.failing,
        .fragments = &.{&builtins_mod.registerAll},
    });
    defer session.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    var err: std.Io.Writer.Allocating = .init(allocator);
    const status = runCommand(&session, source, &out.writer, &err.writer, color);
    return .{ .status = status, .out = out.written(), .err = err.written() };
}

const no_color: ReplColor = .{ .errors = false, .results = false };

test "runCommand: a result is plain, or dim only when results get colour" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plain = try runForTest(arena.allocator(), .{ .name = null, .text = "+ 1 2" }, no_color);
    try std.testing.expectEqual(ExitStatus.ok, plain.status);
    try std.testing.expectEqualStrings("=> 3\n", plain.out);

    const dim = try runForTest(arena.allocator(), .{ .name = null, .text = "+ 1 2" }, .{ .errors = false, .results = true });
    try std.testing.expectEqualStrings(DIM ++ "=> 3" ++ RESET ++ "\n", dim.out);
}

test "runCommand: an error typed at the prompt has no file name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const run = try runForTest(arena.allocator(), .{ .name = null, .text = "nosuchop 1" }, no_color);
    try std.testing.expectEqual(ExitStatus.runtime_error, run.status);
    try std.testing.expectEqualStrings(
        \\1:1: Unknown operation or macro: 'nosuchop'
        \\  nosuchop 1
        \\  ^^^^^^^^^^
        \\
    , run.err);
}

test "runCommand: piped input names <stdin> and counts lines from the start of the input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const run = try runForTest(arena.allocator(), .{ .name = "<stdin>", .text = "say (+ 1]", .first_line = 2 }, no_color);
    try std.testing.expectEqual(ExitStatus.syntax_error, run.status);
    try std.testing.expectEqualStrings(
        \\<stdin>:2:5: Missing closing parenthesis
        \\  say (+ 1]
        \\      ^
        \\<stdin>:2:9: Unexpected closing bracket
        \\  say (+ 1]
        \\          ^
        \\
    , run.err);
}
