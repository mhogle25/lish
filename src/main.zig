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

const SYNTAX_EXIT_CODE = @intFromEnum(repl_mod.ExitStatus.syntax_error);
const RUNTIME_EXIT_CODE = @intFromEnum(repl_mod.ExitStatus.runtime_error);

const EDITOR_OUTPUT_BUFFER_SIZE = 64 * 1024;

const STDERR_BUFFER_SIZE = 4096;

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
    var stdout_writer = outputWriter(std.Io.File.stdout(), init.io, &.{});
    var stderr_buffer: [STDERR_BUFFER_SIZE]u8 = undefined;
    var stderr_writer = outputWriter(std.Io.File.stderr(), init.io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const status = runCommandLine(init, stdout, stderr) catch |err| {
        stderr.flush() catch {};
        return err;
    };
    stderr.flush() catch {};
    if (status != 0) std.process.exit(status);
}

fn runCommandLine(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const command_line = switch (try parseCommandLine(arena, arguments[@min(1, arguments.len)..])) {
        .ok => |parsed| parsed,
        .mistakes => |mistakes| {
            for (mistakes) |mistake| try stderr.print("lish: {f}\n", .{mistake});
            try stderr.writeAll("Try 'lish --help'.\n");
            return USAGE_EXIT_CODE;
        },
    };

    switch (command_line.action) {
        .help => {
            try stdout.writeAll(HELP);
            return 0;
        },
        .dump => |vocabulary| {
            try dumpVocabulary(init.gpa, stdout, vocabulary);
            return 0;
        },
        .init_config => return writeStarterConfig(init, stdout, stderr),
        .run         => |run| return runLish(init, stdout, stderr, command_line.macro_paths, run),
    }
}

/// `arena` owns everything returned.
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

fn writeStarterConfig(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const result = repl_mod.initConfig(init.io, init.minimal.environ, init.gpa) catch |err| {
        try stderr.print("lish: could not write config: {s}\n", .{fileProblem(err)});
        return RUNTIME_EXIT_CODE;
    };
    const written = result orelse {
        try stderr.writeAll("lish: could not determine config path ($HOME unset)\n");
        return RUNTIME_EXIT_CODE;
    };
    defer init.gpa.free(written.path);

    if (written.created)
        try stdout.print("Created {s}\n", .{written.path})
    else
        try stdout.print("Config already exists at {s}\n", .{written.path});
    return 0;
}

fn runLish(
    init: std.process.Init,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    command_line_macro_paths: []const []const u8,
    run: Run,
) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const error_color = useColor(init, std.Io.File.stderr());

    var repl_config = repl_mod.ReplConfig.init(allocator);
    defer repl_config.deinit();
    try loadReplConfig(init, stderr, &repl_config, error_color);

    var session = try lish.Session.init(allocator, .{
        .io = io,
        .fragments = &.{ &lish.builtins.registerAll, &lish.random.registerAll },
        .stdout = stdout,
        .stderr = stderr,
        .bounds = repl_config.bounds,
    });
    defer session.deinit();

    const home = init.minimal.environ.getPosix("HOME");
    for (repl_config.macro_dirs.items) |path| {
        const expanded = try repl_mod.expandHome(allocator, path, home);
        defer allocator.free(expanded);
        try loadMacros(&session, allocator, stderr, expanded, error_color);
    }
    for (command_line_macro_paths) |path| try loadMacros(&session, allocator, stderr, path, error_color);
    stderr.flush() catch {};

    switch (run) {
        .script => |path| return runScript(io, allocator, &session, stdout, stderr, error_color, path),
        .repl => {
            var editor_output_buffer: [EDITOR_OUTPUT_BUFFER_SIZE]u8 = undefined;
            var editor_output = outputWriter(std.Io.File.stdout(), io, &editor_output_buffer);

            var editor = line_editor_mod.LineEditor.init(allocator, &editor_output.interface);
            editor.autopair_insert = repl_config.autopair_insert;
            editor.autopair_delete = repl_config.autopair_delete;
            editor.bracket_expand = repl_config.bracket_expand;
            editor.renderer.highlight_enabled = repl_config.highlight;
            editor.indent_width = repl_config.indent_width;
            editor.history.setLimit(repl_config.history_size);
            if (repl_config.prompt) |prompt| editor.renderer.prompt = prompt;
            defer editor.deinit();

            const status = repl_mod.runRepl(&session, &editor, stdout, stderr, .{
                .errors = error_color,
                .results = useColor(init, std.Io.File.stdout()),
            });
            return @intFromEnum(status);
        },
    }
}

fn loadReplConfig(init: std.process.Init, stderr: *std.Io.Writer, config: *repl_mod.ReplConfig, color: bool) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    switch (try repl_mod.loadConfig(init.io, init.minimal.environ, config, arena.allocator())) {
        .absent     => {},
        .unreadable => |unreadable| stderr.print("lish: cannot read config '{s}': {s}\n", .{ unreadable.path, fileProblem(unreadable.reason) }) catch {},
        .ran        => |ran| repl_mod.writeProblems(stderr, .{ .name = ran.path, .text = ran.text }, ran.result, color),
    }
}

fn loadMacros(session: *lish.Session, allocator: Allocator, stderr: *std.Io.Writer, path: []const u8, color: bool) Allocator.Error!void {
    const result = try session.loadMacroPath(path);
    defer result.deinit(allocator);

    for (result.problems) |problem| switch (problem.kind) {
        .unreadable => |reason| stderr.print("lish: cannot read macros '{s}': {s}\n", .{ problem.path, fileProblem(reason) }) catch {},
        .invalid    => |invalid| for (invalid.errors) |validation_error| {
            lish.diagnostics.writeValidationReport(stderr, .{ .name = problem.path, .text = invalid.text }, validation_error, color) catch {};
        },
    };
}

fn outputWriter(file: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    return file.writerStreaming(io, buffer);
}

fn useColor(init: std.process.Init, file: std.Io.File) bool {
    if (init.minimal.environ.getPosix("NO_COLOR")) |value| {
        if (value.len > 0) return false;
    }
    return file.isTty(init.io) catch false;
}

fn fileProblem(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound  => "no such file",
        error.AccessDenied  => "permission denied",
        error.IsDir         => "is a directory",
        error.StreamTooLong => "larger than the 1 MB limit",
        error.OutOfMemory   => "out of memory",
        else                => @errorName(err),
    };
}

fn runScript(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *lish.Session,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    color: bool,
    path: []const u8,
) u8 {
    if (std.mem.endsWith(u8, path, lish.MACRO_EXTENSION)) {
        stderr.print("lish: '{s}' is a macro module, not a runnable script\n", .{path}) catch {};
        return USAGE_EXIT_CODE;
    }

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(lish.LISH_FILE_MAX_SIZE)) catch |err| {
        stderr.print("lish: cannot read '{s}': {s}\n", .{ path, fileProblem(err) }) catch {};
        return RUNTIME_EXIT_CODE;
    };
    defer allocator.free(source);

    const result = session.execute(source) catch {
        stderr.writeAll("lish: out of memory\n") catch {};
        return RUNTIME_EXIT_CODE;
    };

    repl_mod.writeProblems(stderr, .{ .name = path, .text = source }, result, color);
    switch (result) {
        .ok => |maybe_value| {
            const value = maybe_value orelse return 0;
            repl_mod.writeResult(stdout, value) catch {};
            stdout.writeByte('\n') catch {};
            return 0;
        },
        .validation_err => return SYNTAX_EXIT_CODE,
        .runtime_err    => return RUNTIME_EXIT_CODE,
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

test "file problems are given in words, with the error's name as the fallback" {
    try std.testing.expectEqualStrings("no such file", fileProblem(error.FileNotFound));
    try std.testing.expectEqualStrings("is a directory", fileProblem(error.IsDir));
    try std.testing.expectEqualStrings("larger than the 1 MB limit", fileProblem(error.StreamTooLong));
    try std.testing.expectEqualStrings("NotOpenForReading", fileProblem(error.NotOpenForReading));
}

test "output writers sharing one file keep their order" {
    var io_instance: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "both.txt", .{});
    defer file.close(io);

    var results = outputWriter(file, io, &.{});
    var errors_buffer: [64]u8 = undefined;
    var errors = outputWriter(file, io, &errors_buffer);
    try results.interface.writeAll("a\n");
    try errors.interface.writeAll("report\n");
    try errors.interface.flush();
    try results.interface.writeAll("b\n");

    var contents_buffer: [64]u8 = undefined;
    const contents = try tmp.dir.readFile(io, "both.txt", &contents_buffer);
    try std.testing.expectEqualStrings("a\nreport\nb\n", contents);
}
