const std = @import("std");

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
    test_step.dependOn(&run_corpus_tests.step);
}
