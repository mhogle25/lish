const std = @import("std");
const lish = @import("lish");
const line_editor_mod = lish.line_editor;
const repl_mod = lish.repl;

const Allocator = std.mem.Allocator;

const HELP =
    \\lish - interactive shell and .lish script runner
    \\
    \\Usage:
    \\  lish                  Start the interactive REPL.
    \\  lish <file.lish>      Run a script, print its result, and exit.
    \\
    \\Options:
    \\  -m, --macros PATH     Load macros from a .lishmacro file or a folder of them (repeatable).
    \\      --init-config     Write a starter config to the standard path if absent.
    \\      --dump-ops        Print the operation vocabulary as JSON and exit.
    \\      --dump-macros     Print the macro vocabulary as JSON and exit.
    \\  -h, --help            Show this help and exit.
    \\
;

/// Exit code for a command line lish can't act on.
const USAGE_EXIT_CODE = 2;

/// The line editor's own output buffer, big enough that a full redraw of a
/// maximum-length line reaches the terminal in one piece.
const EDITOR_OUTPUT_BUFFER_SIZE = 64 * 1024;

const Option = enum { help, macros, init_config, dump_ops, dump_macros };

const OPTIONS = std.StaticStringMap(Option).initComptime(.{
    .{ "-h",            .help },
    .{ "--help",        .help },
    .{ "-m",            .macros },
    .{ "--macros",      .macros },
    .{ "--init-config", .init_config },
    .{ "--dump-ops",    .dump_ops },
    .{ "--dump-macros", .dump_macros },
});

/// What the command line asked lish to do.
const Action = union(enum) {
    help,
    dump: Vocabulary,
    init_config,
    run: Run,
};

const Vocabulary = enum { ops, macros };

const Run = union(enum) {
    script: []const u8,
    repl,
};

const CommandLine = struct {
    action: Action,
    macro_paths: []const []const u8,
};

/// Something on the command line lish can't act on.
const UsageMistake = union(enum) {
    missing_macro_path: []const u8,
    unknown_option: []const u8,
    extra_script: []const u8,

    pub fn format(self: UsageMistake, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .missing_macro_path => |option| try writer.print("{s} needs a path", .{option}),
            .unknown_option     => |option| try writer.print("unknown option '{s}'", .{option}),
            .extra_script       => |path| try writer.print("only one script can be run, so '{s}' is one too many", .{path}),
        }
    }
};

const ParsedCommandLine = union(enum) {
    ok: CommandLine,
    mistakes: []const UsageMistake,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &.{});
    var stderr_writer = std.Io.File.stderr().writer(init.io, &.{});
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const arguments = try init.minimal.args.toSlice(arena);
    const command_line = switch (try parseCommandLine(arena, arguments[@min(1, arguments.len)..])) {
        .ok => |parsed| parsed,
        .mistakes => |mistakes| {
            for (mistakes) |mistake| try stderr.print("lish: {f}\n", .{mistake});
            try stderr.writeAll("Try 'lish --help'.\n");
            std.process.exit(USAGE_EXIT_CODE);
        },
    };

    switch (command_line.action) {
        .help        => try stdout.writeAll(HELP),
        .dump        => |vocabulary| try dumpVocabulary(init.gpa, stdout, vocabulary),
        .init_config => try writeStarterConfig(init, stdout, stderr),
        .run         => |run| try runLish(init, stdout, stderr, command_line.macro_paths, run),
    }
}

/// Reads the arguments after the program name. `arena` owns everything returned.
fn parseCommandLine(arena: Allocator, arguments: []const [:0]const u8) Allocator.Error!ParsedCommandLine {
    var macro_paths: std.ArrayList([]const u8) = .empty;
    var mistakes: std.ArrayList(UsageMistake) = .empty;
    var asked_for_help = false;
    var dump: ?Vocabulary = null;
    var init_config = false;
    var script: ?[]const u8 = null;

    var reader = ArgumentReader.init(arguments);
    while (reader.next()) |argument| {
        const option = OPTIONS.get(argument) orelse {
            if (looksLikeOption(argument)) {
                try mistakes.append(arena, .{ .unknown_option = argument });
            } else if (script == null) {
                script = argument;
            } else {
                try mistakes.append(arena, .{ .extra_script = argument });
            }
            continue;
        };

        switch (option) {
            .help        => asked_for_help = true,
            .init_config => init_config = true,
            .dump_ops    => dump = dump orelse .ops,
            .dump_macros => dump = dump orelse .macros,
            .macros      => {
                const path = reader.nextValue() orelse {
                    try mistakes.append(arena, .{ .missing_macro_path = argument });
                    continue;
                };
                try macro_paths.append(arena, path);
            },
        }
    }

    if (asked_for_help) return .{ .ok = .{ .action = .help, .macro_paths = &.{} } };
    if (mistakes.items.len > 0) return .{ .mistakes = mistakes.items };

    const action: Action =
        if (dump) |vocabulary| .{ .dump = vocabulary } else
        if (init_config)        .init_config else
        if (script) |path|      .{ .run = .{ .script = path } } else
                                .{ .run = .repl };
    return .{ .ok = .{ .action = action, .macro_paths = macro_paths.items } };
}

const ArgumentReader = struct {
    remaining: []const [:0]const u8,

    fn init(arguments: []const [:0]const u8) ArgumentReader {
        return .{ .remaining = arguments };
    }

    fn next(self: *ArgumentReader) ?[]const u8 {
        if (self.remaining.len == 0) return null;
        const argument = self.remaining[0];
        self.remaining = self.remaining[1..];
        return argument;
    }

    /// Takes the argument after an option, unless there is none or it's another option.
    fn nextValue(self: *ArgumentReader) ?[]const u8 {
        if (self.remaining.len == 0) return null;
        if (looksLikeOption(self.remaining[0])) return null;
        return self.next();
    }
};

fn looksLikeOption(argument: []const u8) bool {
    return std.mem.startsWith(u8, argument, "-");
}

fn dumpVocabulary(allocator: Allocator, stdout: *std.Io.Writer, vocabulary: Vocabulary) !void {
    var registry = lish.Registry.init(allocator);
    defer registry.deinit(allocator);
    try lish.builtins.registerAll(&registry, allocator);
    try lish.random.registerAll(&registry, allocator);

    switch (vocabulary) {
        .ops    => try lish.introspect.serializeOperations(stdout, &registry, allocator),
        .macros => try lish.introspect.serializeMacros(stdout, &registry, allocator),
    }
}

fn writeStarterConfig(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const result = repl_mod.initConfig(init.io, init.minimal.environ, init.gpa) catch |err| {
        try stderr.print("lish: could not write config: {s}\n", .{@errorName(err)});
        return;
    };
    const written = result orelse {
        try stderr.writeAll("lish: could not determine config path ($HOME unset)\n");
        return;
    };
    defer init.gpa.free(written.path);

    if (written.created)
        try stdout.print("Created {s}\n", .{written.path})
    else
        try stdout.print("Config already exists at {s}\n", .{written.path});
}

fn runLish(
    init: std.process.Init,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    command_line_macro_paths: []const []const u8,
    run: Run,
) !void {
    const allocator = init.gpa;
    const io = init.io;

    var repl_config = repl_mod.ReplConfig.init(allocator);
    defer repl_config.deinit();
    repl_mod.loadConfig(io, init.minimal.environ, &repl_config, allocator);

    var all_macro_paths = std.ArrayList([]const u8).empty;
    defer all_macro_paths.deinit(allocator);
    try all_macro_paths.appendSlice(allocator, repl_config.macro_dirs.items);
    try all_macro_paths.appendSlice(allocator, command_line_macro_paths);

    var session = try lish.Session.init(allocator, .{
        .io = io,
        .fragments = &.{ &lish.builtins.registerAll, &lish.random.registerAll },
        .macro_paths = all_macro_paths.items,
        .stdout = stdout,
        .stderr = stderr,
        .bounds = repl_config.bounds,
    });
    defer session.deinit();

    try lish.loadStdlib(&session.registry);

    switch (run) {
        .script => |path| runScript(io, allocator, &session, stdout, stderr, path),
        .repl => {
            // Streaming like `stdout`, so the two writers share the file position
            // instead of overwriting each other when stdout is redirected to a file.
            var editor_output_buffer: [EDITOR_OUTPUT_BUFFER_SIZE]u8 = undefined;
            var editor_output = std.Io.File.stdout().writerStreaming(io, &editor_output_buffer);

            var editor = line_editor_mod.LineEditor.init(allocator, &editor_output.interface);
            editor.autopair_insert = repl_config.autopair_insert;
            editor.autopair_delete = repl_config.autopair_delete;
            editor.bracket_expand = repl_config.bracket_expand;
            editor.renderer.highlight_enabled = repl_config.highlight;
            editor.indent_width = repl_config.indent_width;
            editor.history.setLimit(repl_config.history_size);
            if (repl_config.prompt) |prompt| editor.renderer.prompt = prompt;
            defer editor.deinit();

            repl_mod.runRepl(&session, &editor, stdout, stderr);
        },
    }
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
        std.process.exit(USAGE_EXIT_CODE);
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

fn expectCommandLine(arguments: []const [:0]const u8, expected: CommandLine) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualDeep(ParsedCommandLine{ .ok = expected }, try parseCommandLine(arena.allocator(), arguments));
}

fn expectMistakes(arguments: []const [:0]const u8, expected: []const UsageMistake) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualDeep(ParsedCommandLine{ .mistakes = expected }, try parseCommandLine(arena.allocator(), arguments));
}

test "command line: nothing starts the REPL, a file runs it as a script" {
    try expectCommandLine(&.{}, .{ .action = .{ .run = .repl }, .macro_paths = &.{} });
    try expectCommandLine(&.{"three.lish"}, .{ .action = .{ .run = .{ .script = "three.lish" } }, .macro_paths = &.{} });
}

test "command line: -m and --macros collect their paths in order, with no limit" {
    try expectCommandLine(
        &.{ "-m", "first", "three.lish", "--macros", "second" },
        .{ .action = .{ .run = .{ .script = "three.lish" } }, .macro_paths = &.{ "first", "second" } },
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var twenty: [40][:0]const u8 = undefined;
    for (0..20) |pair| {
        twenty[pair * 2]     = "-m";
        twenty[pair * 2 + 1] = "folder";
    }
    switch (try parseCommandLine(arena.allocator(), &twenty)) {
        .ok       => |command_line| try std.testing.expectEqual(@as(usize, 20), command_line.macro_paths.len),
        .mistakes => return error.TestUnexpectedResult,
    }
}

test "command line: each mistake is reported, not ignored" {
    try expectMistakes(&.{ "three.lish", "-m" }, &.{.{ .missing_macro_path = "-m" }});
    try expectMistakes(&.{"--macros"}, &.{.{ .missing_macro_path = "--macros" }});
    try expectMistakes(&.{ "-m", "--dump-ops" }, &.{.{ .missing_macro_path = "-m" }});
    try expectMistakes(&.{ "--bogus", "three.lish" }, &.{.{ .unknown_option = "--bogus" }});
    try expectMistakes(&.{ "-x", "-y" }, &.{ .{ .unknown_option = "-x" }, .{ .unknown_option = "-y" } });
    try expectMistakes(&.{ "three.lish", "thirty.lish" }, &.{.{ .extra_script = "thirty.lish" }});
}

test "command line: --help wins over everything, even mistakes" {
    const help: CommandLine = .{ .action = .help, .macro_paths = &.{} };
    try expectCommandLine(&.{ "--bogus", "--help" }, help);
    try expectCommandLine(&.{ "-h", "-m" }, help);
    try expectCommandLine(&.{ "--dump-ops", "three.lish", "-h" }, help);
}

test "command line: the first dump flag wins, then --init-config, then a script" {
    try expectCommandLine(&.{ "--dump-macros", "--dump-ops" }, .{ .action = .{ .dump = .macros }, .macro_paths = &.{} });
    try expectCommandLine(&.{ "--init-config", "three.lish", "--dump-ops" }, .{ .action = .{ .dump = .ops }, .macro_paths = &.{} });
    try expectCommandLine(&.{ "three.lish", "--init-config" }, .{ .action = .init_config, .macro_paths = &.{} });
}

test "command line: mistake messages name what was wrong" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("-m needs a path", try std.fmt.bufPrint(&buffer, "{f}", .{UsageMistake{ .missing_macro_path = "-m" }}));
    try std.testing.expectEqualStrings("unknown option '--bogus'", try std.fmt.bufPrint(&buffer, "{f}", .{UsageMistake{ .unknown_option = "--bogus" }}));
    try std.testing.expectEqualStrings("only one script can be run, so 'b.lish' is one too many", try std.fmt.bufPrint(&buffer, "{f}", .{UsageMistake{ .extra_script = "b.lish" }}));
}
