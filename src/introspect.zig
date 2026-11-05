//! Registry introspection: the canonical machine-readable description of a
//! registry's vocabulary.
//!
//! A lish registry is self-describing. Every operation carries its signature,
//! description, and (when registered through a named group) its category. This
//! module serializes that to the JSON shape editor tooling consumes. The output
//! is registry-derived and reproducible on demand, so nothing is committed to
//! disk; callers obtain it live:
//!
//!   Zig consumers     call these functions directly (lish-lsp, etc.)
//!   `lish --dump-ops` emits the registry of whatever host is running,
//!   `--dump-macros`   including a custom host with its own DSL ops/macros
//!
//! Operations and macros are serialized separately, since they are different
//! kinds: an op is opaque native code whose signature/description must be
//! supplied by its author, while a macro is lish source whose signature is
//! derived from its parameters (`serializeMacros`). Macros carry no required
//! metadata.

const std = @import("std");
const exec = @import("exec.zig");
const val = @import("value.zig");

const Registry = exec.Registry;
const Operation = exec.Operation;
const Param = exec.Param;
const Macro = exec.Macro;
const LishType = val.LishType;
const Allocator = std.mem.Allocator;

const Entry = struct {
    name: []const u8,
    op: Operation,
};

fn lessByName(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

const MacroEntry = struct {
    name: []const u8,
    macro: *const Macro,
};

fn macroLessByName(_: void, a: MacroEntry, b: MacroEntry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn writeParams(writer: *std.Io.Writer, params: []const Param) !void {
    try writer.writeAll(", \"params\": [");
    for (params, 0..) |param, i| {
        try writer.writeAll(if (i == 0) " { \"name\": " else ", { \"name\": ");
        try writeJsonString(writer, param.name);
        try writer.writeAll(", \"type\": ");
        try writeType(writer, param.type);
        try writer.writeAll(", \"role\": ");
        try writeJsonString(writer, @tagName(param.role));
        try writer.writeAll(", \"arity\": ");
        try writeJsonString(writer, @tagName(param.arity));
        try writer.writeAll(" }");
    }
    try writer.writeAll(if (params.len == 0) "]" else " ]");
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        '\r' => try writer.writeAll("\\r"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

fn writeType(writer: *std.Io.Writer, lish_type: LishType) !void {
    switch (lish_type) {
        .literal => |text| {
            try writer.writeAll("{ \"literal\": ");
            try writeJsonString(writer, text);
            try writer.writeAll(" }");
        },
        .one_of => |members| {
            try writer.writeAll("{ \"one_of\": [");
            for (members, 0..) |member, i| {
                try writer.writeAll(if (i == 0) " " else ", ");
                try writeType(writer, member);
            }
            try writer.writeAll(" ] }");
        },
        else => try writeJsonString(writer, @tagName(lish_type)),
    }
}

pub fn serializeOperations(
    writer: *std.Io.Writer,
    registry: *const Registry,
    allocator: Allocator,
) !void {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    var it = registry.operations.iterator();
    while (it.next()) |op| {
        try entries.append(allocator, .{ .name = op.key_ptr.*, .op = op.value_ptr.* });
    }
    std.mem.sort(Entry, entries.items, {}, lessByName);

    try writer.writeAll("[\n");
    for (entries.items, 0..) |entry, i| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, entry.name);
        if (entry.op.category) |category| {
            try writer.writeAll(", \"category\": ");
            try writeJsonString(writer, category);
        }
        try writer.writeAll(", \"signature\": ");
        var sig_buf: [512]u8 = undefined;
        var sig_writer = std.Io.Writer.fixed(&sig_buf);
        try entry.op.signature.render(&sig_writer, entry.name);
        try writeJsonString(writer, sig_writer.buffered());
        try writer.writeAll(", \"description\": ");
        try writeJsonString(writer, entry.op.description);
        try writer.writeAll(", \"returns\": ");
        try writeType(writer, entry.op.signature.returns);
        if (entry.op.signature.binding_pairs) try writer.writeAll(", \"binding_pairs\": true");
        try writeParams(writer, entry.op.signature.params);
        try writer.writeAll(if (i + 1 < entries.items.len) " },\n" else " }\n");
    }
    try writer.writeAll("]\n");
}

pub fn serializeMacros(
    writer: *std.Io.Writer,
    registry: *const Registry,
    allocator: Allocator,
) !void {
    var entries: std.ArrayList(MacroEntry) = .empty;
    defer entries.deinit(allocator);

    var it = registry.macros.iterator();
    while (it.next()) |entry| {
        try entries.append(allocator, .{ .name = entry.key_ptr.*, .macro = entry.value_ptr.* });
    }
    std.mem.sort(MacroEntry, entries.items, {}, macroLessByName);

    var signature: std.Io.Writer.Allocating = .init(allocator);
    defer signature.deinit();

    try writer.writeAll("[\n");
    for (entries.items, 0..) |entry, i| {
        signature.clearRetainingCapacity();
        try entry.macro.writeSignature(&signature.writer);

        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, entry.name);
        try writer.writeAll(", \"signature\": ");
        try writeJsonString(writer, signature.written());
        try writer.writeAll(", \"description\": ");
        try writeJsonString(writer, entry.macro.description);
        try writer.writeAll(if (i + 1 < entries.items.len) " },\n" else " }\n");
    }
    try writer.writeAll("]\n");
}
