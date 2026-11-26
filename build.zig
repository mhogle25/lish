const std = @import("std");

const NO_CONFIG_HOME = "/nonexistent-lish-test-home";

const BROKEN_MACRO_FILE = "double x | * :x 2 ;\nbad x | (+ :x 1 ;\n";
const BROKEN_MACRO_FILE_REPORT = ":2:9: Missing closing parenthesis\n  bad x | (+ :x 1 ;\n          ^\n";

const PipedRun = struct {
    exit_code: u8,
    name: []const u8,
    arguments: []const []const u8 = &.{},
    input: []const u8,
    stdout: []const u8,
    stderr: []const u8,
};

const PIPED_RUNS = [_]PipedRun{
    .{
        .exit_code = 0,
        .name      = "an earlier failure doesn't set the exit code",
        .input     = "nosuchop 1\n+ 1 2\n",
        .stdout    = "=> 3\n",
        .stderr    =
        \\<stdin>:1:1: Unknown operation or macro: 'nosuchop'
        \\  nosuchop 1
        \\  ^^^^^^^^^^
        \\
        ,
    },
    .{
        .exit_code = 1,
        .name      = "the last command's failure is the exit code",
        .input     = "+ 1 2\nnosuchop 1\n",
        .stdout    = "=> 3\n",
        .stderr    =
        \\<stdin>:2:1: Unknown operation or macro: 'nosuchop'
        \\  nosuchop 1
        \\  ^^^^^^^^^^
        \\
        ,
    },
    .{
        .exit_code = 2,
        .name      = "a syntax error last exits 2",
        .input     = "say (+ 1]\n",
        .stdout    = "",
        .stderr    =
        \\<stdin>:1:5: Missing closing parenthesis
        \\  say (+ 1]
        \\      ^
        \\<stdin>:1:9: Unexpected closing bracket
        \\  say (+ 1]
        \\          ^
        \\
        ,
    },
    .{
        .exit_code = 1,
        .name      = "exit keeps the last command's status",
        .input     = "nosuchop 1\nexit\n",
        .stdout    = "",
        .stderr    =
        \\<stdin>:1:1: Unknown operation or macro: 'nosuchop'
        \\  nosuchop 1
        \\  ^^^^^^^^^^
        \\
        ,
    },
    .{
        .exit_code = 1,
        .name      = "lines count from the start of the input",
        .input     = "say 1\nlist (+ 1\n  (nosuchop))\n",
        .stdout    = "1\n",
        .stderr    =
        \\<stdin>:3:3: Unknown operation or macro: 'nosuchop'
        \\  (nosuchop))
        \\  ^^^^^^^^^^
        \\
        ,
    },
    .{
        .exit_code = 0,
        .name      = "the error op writes plain text",
        .input     = "error \"oops\"\n",
        .stdout    = "",
        .stderr    = "oops\n",
    },
    .{
        .exit_code = 0,
        .name      = "a missing macro folder is reported and lish keeps going",
        .arguments = &.{ "-m", "no-such-macros" },
        .input     = "+ 1 2\n",
        .stdout    = "=> 3\n",
        .stderr    = "lish: cannot read macros 'no-such-macros': no such file\n",
    },
};

const ScriptRun = struct {
    exit_code: u8,
    file_name: []const u8,
    text: []const u8,
    stderr_contains: []const u8,
};

const SCRIPT_RUNS = [_]ScriptRun{
    .{
        .exit_code       = 1,
        .file_name       = "runtime_error.lish",
        .text            = "nosuchop 1",
        .stderr_contains = ":1:1: Unknown operation or macro: 'nosuchop'\n  nosuchop 1\n  ^^^^^^^^^^\n",
    },
    .{
        .exit_code       = 2,
        .file_name       = "syntax_error.lish",
        .text            = "say (+ 1",
        .stderr_contains = ":1:5: Missing closing parenthesis\n  say (+ 1\n      ^\n",
    },
    .{
        .exit_code       = 2,
        .file_name       = "macros.lishmacro",
        .text            = "double x | * :x 2 ;",
        .stderr_contains = "is a macro module, not a runnable script\n",
    },
};

const CommandLineRun = struct {
    exit_code: u8,
    arguments: []const []const u8,
    stderr: []const u8,
};

const COMMAND_LINE_RUNS = [_]CommandLineRun{
    .{
        .exit_code = 2,
        .arguments = &.{"--nope"},
        .stderr    = "lish: unknown option '--nope'\nTry 'lish --help'.\n",
    },
    .{
        .exit_code = 1,
        .arguments = &.{"no-such-script.lish"},
        .stderr    = "lish: cannot read 'no-such-script.lish': no such file\n",
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("lish", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Cross-language artifact generator
    const gen_exe = b.addExecutable(.{
        .name = "gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    gen_exe.root_module.addImport("lish", mod);

    const run_gen = b.addRunArtifact(gen_exe);
    run_gen.addDirectoryArg2(b.path("generated"), .{});
    const gen_step = b.step("gen", "Generate cross-language artifacts from token.zig");
    gen_step.dependOn(&run_gen.step);

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "lish",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lish", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the lish REPL");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/line_editor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    // The lish program's own code
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Scanner corpus
    const corpus_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/scanner_corpus_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    corpus_tests.root_module.addImport("lish", mod);
    const run_corpus_tests = b.addRunArtifact(corpus_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_corpus_tests.step);
    addProgramRuns(b, test_step, exe);
}

fn addProgramRuns(b: *std.Build, test_step: *std.Build.Step, exe: *std.Build.Step.Compile) void {
    for (PIPED_RUNS) |piped| {
        const run = programRun(b, exe, piped.name);
        run.addArgs(piped.arguments);
        run.setStdIn(.{ .bytes = piped.input });
        run.expectExitCode(piped.exit_code);
        run.expectStdOutEqual(piped.stdout);
        run.expectStdErrEqual(piped.stderr);
        test_step.dependOn(&run.step);
    }

    const scripts = b.addWriteFiles();
    for (SCRIPT_RUNS) |script| {
        const run = programRun(b, exe, script.file_name);
        run.addFileArg(scripts.add(script.file_name, script.text));
        run.expectExitCode(script.exit_code);
        run.expectStdErrMatch(script.stderr_contains);
        test_step.dependOn(&run.step);
    }

    const broken_macros = programRun(b, exe, "a broken macro file is reported and lish keeps going");
    broken_macros.addArg("-m");
    broken_macros.addFileArg(scripts.add("broken.lishmacro", BROKEN_MACRO_FILE));
    broken_macros.setStdIn(.{ .bytes = "+ 1 2\n" });
    broken_macros.expectExitCode(0);
    broken_macros.expectStdOutEqual("=> 3\n");
    broken_macros.expectStdErrMatch(BROKEN_MACRO_FILE_REPORT);
    test_step.dependOn(&broken_macros.step);

    for (COMMAND_LINE_RUNS) |command_line| {
        const run = programRun(b, exe, command_line.arguments[0]);
        run.addArgs(command_line.arguments);
        run.expectExitCode(command_line.exit_code);
        run.expectStdErrEqual(command_line.stderr);
        test_step.dependOn(&run.step);
    }
}

fn programRun(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.setName(b.fmt("lish program: {s}", .{name}));
    run.setEnvironmentVariable("HOME", NO_CONFIG_HOME);
    run.setEnvironmentVariable("XDG_CONFIG_HOME", NO_CONFIG_HOME);
    return run;
}
