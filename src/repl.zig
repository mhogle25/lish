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
    macro_dirs: std.ArrayListUnmanaged([]const u8) = .empty,
    bounds: exec_mod.Bounds = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator) ReplConfig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReplConfig) void {
        for (self.macro_dirs.items) |path| self.allocator.free(path);
        self.macro_dirs.deinit(self.allocator);
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

const CONFIG_FILE_NAME = "config" ++ process_mod.LISH_EXTENSION;

fn configFilePath(environ: std.process.Environ, allocator: Allocator) ?[]const u8 {
    return 
        if (environ.getPosix("XDG_CONFIG_HOME")) |xdg| std.fs.path.join(allocator, &.{ xdg, "lish", CONFIG_FILE_NAME }) catch null else
        if (environ.getPosix("HOME"))            |home| std.fs.path.join(allocator, &.{ home, ".config", "lish", CONFIG_FILE_NAME }) catch null else 
        null;
}

pub fn loadConfig(io: std.Io, environ: std.process.Environ, config: *ReplConfig, allocator: Allocator) void {
    const path = configFilePath(environ, allocator) orelse return;
    defer allocator.free(path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(CONFIG_FILE_MAX_SIZE)) catch return;
    defer allocator.free(source);

    var registry = exec_mod.Registry.init(allocator);
    defer registry.deinit(allocator);
    builtins_mod.registerCore(&registry, allocator) catch return;

    const g = registry.group(allocator, "repl-config");
    g.register(op_autopair_insert,   exec_mod.Operation.fromBoundFn(ReplConfig, autopairInsertOp,  config, .{ .signature = "autopair-insert [$on|$off] -> $none", .description = "REPL config: insert the matching closer when you type an opening bracket or quote." })) catch return;
    g.register(op_autopair_delete,   exec_mod.Operation.fromBoundFn(ReplConfig, autopairDeleteOp,  config, .{ .signature = "autopair-delete [$on|$off] -> $none", .description = "REPL config: delete the matching closer when you backspace an opening bracket." })) catch return;
    g.register(op_bracket_expand,    exec_mod.Operation.fromBoundFn(ReplConfig, bracketExpandOp,   config, .{ .signature = "bracket-expand [$on|$off] -> $none",  .description = "REPL config: Alt+Enter inside a bracket pair expands it across lines; backspace collapses it." })) catch return;
    g.register(op_highlight,         exec_mod.Operation.fromBoundFn(ReplConfig, highlightOp,       config, .{ .signature = "highlight [$on|$off] -> $none",       .description = "REPL config: syntax highlighting of the input line." })) catch return;
    g.register(op_max_call_depth,    exec_mod.Operation.fromBoundFn(ReplConfig, maxCallDepthOp,    config, .{ .signature = "max-call-depth n -> $none",           .description = "REPL config: maximum operation call-stack depth before recursion is stopped." })) catch return;
    g.register(op_fuel,              exec_mod.Operation.fromBoundFn(ReplConfig, fuelOp,            config, .{ .signature = "fuel n|$off -> $none",                .description = "REPL config: maximum evaluation steps per expression, or $off to disable." })) catch return;
    g.register(op_max_list_length,   exec_mod.Operation.fromBoundFn(ReplConfig, maxListLengthOp,   config, .{ .signature = "max-list-length n|$off -> $none",     .description = "REPL config: maximum list length, or $off to disable." })) catch return;
    g.register(op_max_string_length, exec_mod.Operation.fromBoundFn(ReplConfig, maxStringLengthOp, config, .{ .signature = "max-string-length n|$off -> $none",   .description = "REPL config: maximum string length, or $off to disable." })) catch return;
    g.register("macros",             exec_mod.Operation.fromBoundFn(ReplConfig, macrosOp,          config, .{ .signature = "macros path -> $none",                .description = "REPL config: add a directory to load macro modules from." })) catch return;

    const config_macros =
        \\|on| $some
        \\|off| $none
    ;
    _ = process_mod.loadMacroModule(&registry, config_macros) catch return;

    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return;

    var env = exec_mod.Env{ .registry = &registry, .allocator = allocator };
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
