const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Param = exec.Param;
const Allocator = std.mem.Allocator;

const x_variadic = [_]Param{.{ .name = "x", .arity = .variadic }};

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "output");
    try g.register("say", Operation.fromFn(sayOp, .{
        .signature = .{ .params = &x_variadic, .returns = .none },
        .description = "Write the arguments to stdout followed by a newline.",
    }));

    try g.register("error", Operation.fromFn(errorOp, .{
        .signature = .{ .params = &x_variadic, .returns = .none },
        .description = "Write the arguments to stderr followed by a newline.",
    }));
}

fn sayOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const writer = args.env.stdout orelse return null;
    for (0..args.count()) |i| {
        var buf: [256]u8 = undefined;
        const str = try args.at(i).resolveString(&buf);
        writer.writeAll(str)  catch return args.env.fail(.internal, "Failed to write to stdout");
    }
    writer.writeByte('\n')    catch return args.env.fail(.internal, "Failed to write to stdout");
    writer.flush()            catch return args.env.fail(.internal, "Failed to write to stdout");
    return null;
}

fn errorOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const writer = args.env.stderr orelse return null;
    for (0..args.count()) |i| {
        var buf: [256]u8 = undefined;
        const str = try args.at(i).resolveString(&buf);
        writer.writeAll(str) catch return args.env.fail(.internal, "Failed to write to stderr");
    }
    writer.writeByte('\n') catch return args.env.fail(.internal, "Failed to write to stderr");
    writer.flush()         catch return args.env.fail(.internal, "Failed to write to stderr");
    return null;
}
