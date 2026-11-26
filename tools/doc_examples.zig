//! Writes each doc's ```zig blocks to `<doc>.zig` on the doc's own line numbers, for a test to compile.
//! Only a fence of exactly ```zig is checked; ```zig build.zig (a build script) is not.
//! Usage: doc_examples <output-dir> <file.md>...

const std = @import("std");

const MARKDOWN_FILE_MAX_SIZE = 1024 * 1024;
const BLOCK_OPEN = "```zig";
const BLOCK_FENCE = "```";
const ROOT_FILE = "root.zig";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const output_path = arguments.next() orelse return error.MissingOutputDirectory;
    var output_dir = try std.Io.Dir.cwd().createDirPathOpen(io, output_path, .{});
    defer output_dir.close(io);

    var docs_with_blocks: std.ArrayList([]const u8) = .empty;
    while (arguments.next()) |doc_path| {
        const markdown = try std.Io.Dir.cwd().readFileAlloc(io, doc_path, allocator, .limited(MARKDOWN_FILE_MAX_SIZE));
        var zig_source: std.Io.Writer.Allocating = .init(allocator);
        if (!try writeDocAsZig(&zig_source.writer, doc_path, markdown)) continue;

        const zig_path = try std.fmt.allocPrint(allocator, "{s}.zig", .{doc_path});
        if (std.Io.Dir.path.dirname(zig_path)) |folder| try output_dir.createDirPath(io, folder);
        try output_dir.writeFile(io, .{ .sub_path = zig_path, .data = zig_source.written() });
        try docs_with_blocks.append(allocator, zig_path);
    }

    var root: std.Io.Writer.Allocating = .init(allocator);
    try writeRoot(&root.writer, docs_with_blocks.items);
    try output_dir.writeFile(io, .{ .sub_path = ROOT_FILE, .data = root.written() });
}

/// Returns whether the doc has any block.
fn writeDocAsZig(output: *std.Io.Writer, doc_path: []const u8, markdown: []const u8) !bool {
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var line_number: usize = 0;
    var open_block_line: ?usize = null;
    var found_block = false;

    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (open_block_line != null) {
            if (std.mem.startsWith(u8, trimmed, BLOCK_FENCE)) {
                try output.writeAll("};\n");
                open_block_line = null;
            } else {
                try output.print("{s}\n", .{line});
            }
            continue;
        }

        if (!std.mem.eql(u8, trimmed, BLOCK_OPEN)) {
            try output.writeByte('\n');
            continue;
        }
        try output.print("pub const @\"{s}:{d}\" = struct {{\n", .{ doc_path, line_number });
        open_block_line = line_number;
        found_block = true;
    }

    if (open_block_line) |start| {
        std.debug.print("{s}:{d}: this ```zig block is never closed\n", .{ doc_path, start });
        return error.UnclosedBlock;
    }
    return found_block;
}

fn writeRoot(output: *std.Io.Writer, zig_paths: []const []const u8) !void {
    try output.writeAll(
        \\fn compileEveryDeclaration(comptime Block: type, comptime name: []const u8) void {
        \\    const declarations = @typeInfo(Block).@"struct".decl_names;
        \\    if (declarations.len == 0) @compileError(name ++ " declares nothing public, so nothing in it is checked");
        \\    inline for (declarations) |declaration| _ = &@field(Block, declaration);
        \\}
        \\
        \\fn compileEveryBlock(comptime Doc: type) void {
        \\    inline for (@typeInfo(Doc).@"struct".decl_names) |block| compileEveryDeclaration(@field(Doc, block), block);
        \\}
        \\
        \\test "every Zig example in the docs compiles" {
        \\    comptime {
        \\
    );
    for (zig_paths) |zig_path| try output.print("        compileEveryBlock(@import(\"{s}\"));\n", .{zig_path});
    try output.writeAll(
        \\    }
        \\}
        \\
    );
}
