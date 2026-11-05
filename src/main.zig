const std = @import("std");
const lish = @import("lish");
const line_editor_mod = lish.line_editor;
const repl_mod = lish.repl;

const HELP =
    \\lish - interactive shell and .lish script runner
    \\
    \\Usage:
    \\  lish                  Start the interactive REPL.
    \\  lish <file.lish>      Run a script, print its result, and exit.
    \\
    \\Options:
    \\  -m, --macros DIR      Load macros from DIR (repeatable, max 16).
    \\      --init-config     Write a starter config to the standard path if absent.
    \\      --dump-ops        Print the operation vocabulary as JSON and exit.
    \\      --dump-macros     Print the macro vocabulary as JSON and exit.
    \\  -h, --help            Show this help and exit.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    var stderr_writer = std.Io.File.stderr().writer(io, &.{});
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    {
        var probe = init.minimal.args.iterate();
        _ = probe.next();
        while (probe.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try stdout.writeAll(HELP);
                return;
            }
        }
    }

    {
        var probe = init.minimal.args.iterate();
        _ = probe.next();
        while (probe.next()) |arg| {
            const dump_ops = std.mem.eql(u8, arg, "--dump-ops");
            const dump_macros = std.mem.eql(u8, arg, "--dump-macros");
            if (dump_ops or dump_macros) {
                var registry = lish.Registry.init(allocator);
                defer registry.deinit(allocator);
                try lish.builtins.registerAll(&registry, allocator);
                try lish.random.registerAll(&registry, allocator);
                if (dump_ops)
                    try lish.introspect.serializeOperations(stdout, &registry, allocator)
                else
                    try lish.introspect.serializeMacros(stdout, &registry, allocator);
                return;
            }
        }
    }

    {
        var probe = init.minimal.args.iterate();
        _ = probe.next();
        while (probe.next()) |arg| {
            if (!std.mem.eql(u8, arg, "--init-config")) continue;
            const result = repl_mod.initConfig(io, init.minimal.environ, allocator) catch |err| {
                try stderr.print("lish: could not write config: {s}\n", .{@errorName(err)});
                return;
            };
            if (result) |r| {
                defer allocator.free(r.path);
                if (r.created)
                    try stdout.print("Created {s}\n", .{r.path})
                else
                    try stdout.print("Config already exists at {s}\n", .{r.path});
            } else {
                try stderr.writeAll("lish: could not determine config path ($HOME unset)\n");
            }
            return;
        }
    }

    var macro_dir_storage: [16][]const u8 = undefined;
    var macro_dir_count: usize = 0;
    var script_path: ?[]const u8 = null;
    var arg_iter = init.minimal.args.iterate();
    _ = arg_iter.next();

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--macros") or std.mem.eql(u8, arg, "-m")) {
            const path = arg_iter.next() orelse break;
            if (macro_dir_count >= macro_dir_storage.len) {
                try stderr.print("Too many --macros arguments (max 16)\n", .{});
                return;
            }
            macro_dir_storage[macro_dir_count] = path;
            macro_dir_count += 1;
        } else if (script_path == null and !std.mem.startsWith(u8, arg, "-")) {
            script_path = arg;
        }
    }

    var repl_config = repl_mod.ReplConfig.init(allocator);
    defer repl_config.deinit();
    repl_mod.loadConfig(io, init.minimal.environ, &repl_config, allocator);

    var all_macro_dirs = std.ArrayList([]const u8).empty;
    defer all_macro_dirs.deinit(allocator);
    try all_macro_dirs.appendSlice(allocator, repl_config.macro_dirs.items);
    try all_macro_dirs.appendSlice(allocator, macro_dir_storage[0..macro_dir_count]);

    var session = try lish.Session.init(allocator, .{
        .io = io,
        .fragments = &.{ &lish.builtins.registerAll, &lish.random.registerAll },
        .macro_paths = all_macro_dirs.items,
        .stdout = stdout,
        .stderr = stderr,
        .bounds = repl_config.bounds,
    });
    defer session.deinit();

    _ = try lish.loadStdlib(&session.registry);

    if (script_path) |path| {
        runScript(io, allocator, &session, stdout, stderr, path);
        return;
    }

    var editor = line_editor_mod.LineEditor.init(allocator, stdout);
    editor.autopair_insert = repl_config.autopair_insert;
    editor.autopair_delete = repl_config.autopair_delete;
    editor.bracket_expand = repl_config.bracket_expand;
    editor.renderer.highlight_enabled = repl_config.highlight;
    editor.indent_width = repl_config.indent_width;
    editor.history.setLimit(repl_config.history_size);
    if (repl_config.prompt) |prompt| editor.renderer.prompt = prompt;
    defer editor.deinit();

    repl_mod.runRepl(&session, &editor, stdout, stderr);
}

fn runScript(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *lish.Session,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    path: []const u8,
) void {
    if (std.mem.endsWith(u8, path, lish.MACRO_EXTENSION)) {
        stderr.print("lish: '{s}' is a macro module, not a runnable script\n", .{path}) catch {};
        std.process.exit(2);
    }

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(lish.LISH_FILE_MAX_SIZE)) catch |err| {
        stderr.print("lish: cannot read '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        std.process.exit(1);
    };
    defer allocator.free(source);

    const result = session.execute(source) catch |err| {
        stderr.print("lish: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };

    switch (result) {
        .ok => |maybe_value| if (maybe_value) |value| {
            repl_mod.writeResult(stdout, value) catch {};
            stdout.writeByte('\n') catch {};
        },
        .validation_err => |errors| {
            for (errors) |validation_error| {
                stderr.print("Validation error: {s}\n", .{validation_error.message}) catch {};
            }
            std.process.exit(1);
        },
        .runtime_err => |runtime_error| {
            stderr.print("Runtime error: {s}\n", .{runtime_error.message}) catch {};
            std.process.exit(1);
        },
    }
}
