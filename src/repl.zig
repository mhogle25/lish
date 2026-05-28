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
const op_max_call_depth    = "max-call-depth";
const op_fuel              = "fuel";
const op_max_list_length   = "max-list-length";
const op_max_string_length = "max-string-length";

/// Maximum size of the REPL config file read from `~/.config/lish/config`.
const CONFIG_FILE_MAX_SIZE = 64 * 1024;

pub const ReplConfig = struct {
    autopair_insert: bool = true,
    autopair_delete: bool = true,
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
        else => return args.env.fail(op_autopair_insert ++ " takes 0 or 1 argument"),
    }
    return null;
}

fn autopairDeleteOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    switch (args.count()) {
        0 => config.autopair_delete = true,
        1 => config.autopair_delete = (try args.at(0).get()) != null,
        else => return args.env.fail(op_autopair_delete ++ " takes 0 or 1 argument"),
    }
    return null;
}

fn maxCallDepthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try args.single();
    const n = try value.resolveInt();
    if (n < 1) return args.env.fail(op_max_call_depth ++ " must be a positive integer");
    config.bounds.max_call_depth = @intCast(n);
    return null;
}

fn fuelOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get();
    if (value == null) {
        config.bounds.fuel = null;
        return null;
    }
    const n = value.?.getI() catch return args.env.fail(op_fuel ++ " expects an integer or $off");
    if (n < 1) return args.env.fail(op_fuel ++ " must be a positive integer");
    config.bounds.fuel = @intCast(n);
    return null;
}

fn maxListLengthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get();
    if (value == null) {
        config.bounds.max_list_length = null;
        return null;
    }
    const n = value.?.getI() catch return args.env.fail(op_max_list_length ++ " expects an integer or $off");
    if (n < 1) return args.env.fail(op_max_list_length ++ " must be a positive integer");
    config.bounds.max_list_length = @intCast(n);
    return null;
}

fn maxStringLengthOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    const value = try (try args.single()).get();
    if (value == null) {
        config.bounds.max_string_length = null;
        return null;
    }
    const n = value.?.getI() catch return args.env.fail(op_max_string_length ++ " expects an integer or $off");
    if (n < 1) return args.env.fail(op_max_string_length ++ " must be a positive integer");
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
    if (environ.getPosix("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "lish", CONFIG_FILE_NAME }) catch null;
    }
    if (environ.getPosix("HOME")) |home| {
        return std.fs.path.join(allocator, &.{ home, ".config", "lish", CONFIG_FILE_NAME }) catch null;
    }
    return null;
}

pub fn loadConfig(io: std.Io, environ: std.process.Environ, config: *ReplConfig, allocator: Allocator) void {
    const path = configFilePath(environ, allocator) orelse return;
    defer allocator.free(path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(CONFIG_FILE_MAX_SIZE)) catch return;
    defer allocator.free(source);

    var registry = exec_mod.Registry.init(allocator);
    defer registry.deinit(allocator);
    builtins_mod.registerCore(&registry, allocator) catch return;
    registry.registerOperation(allocator, op_autopair_insert,   exec_mod.Operation.fromBoundFn(ReplConfig, autopairInsertOp,   config)) catch return;
    registry.registerOperation(allocator, op_autopair_delete,   exec_mod.Operation.fromBoundFn(ReplConfig, autopairDeleteOp,   config)) catch return;
    registry.registerOperation(allocator, op_max_call_depth,    exec_mod.Operation.fromBoundFn(ReplConfig, maxCallDepthOp,    config)) catch return;
    registry.registerOperation(allocator, op_fuel,              exec_mod.Operation.fromBoundFn(ReplConfig, fuelOp,            config)) catch return;
    registry.registerOperation(allocator, op_max_list_length,   exec_mod.Operation.fromBoundFn(ReplConfig, maxListLengthOp,   config)) catch return;
    registry.registerOperation(allocator, op_max_string_length, exec_mod.Operation.fromBoundFn(ReplConfig, maxStringLengthOp, config)) catch return;
    registry.registerOperation(allocator, "macros",             exec_mod.Operation.fromBoundFn(ReplConfig, macrosOp,          config)) catch return;

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
                            switch (value) {
                                .string => |str| stdout.print("\x1b[2m=> \"{s}\"\x1b[0m\n", .{str}) catch {},
                                else => {
                                    stdout.writeAll("\x1b[2m=> ") catch {};
                                    value.writeTo(stdout) catch {};
                                    stdout.writeAll("\x1b[0m\n") catch {};
                                },
                            }
                        }
                    },
                    .validation_err => |errors| {
                        for (errors) |validation_error| {
                            stderr.print("\x1b[31mValidation error: {s}\x1b[0m\n", .{validation_error.message}) catch {};
                        }
                    },
                    .runtime_err => |message| {
                        stderr.print("\x1b[31mRuntime error: {s}\x1b[0m\n", .{message}) catch {};
                    },
                }
            },
        }
    }
}
