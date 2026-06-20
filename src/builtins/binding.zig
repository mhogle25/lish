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

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "binding");
    try g.register("let", Operation.fromFn(letOp, .{
        .signature = .{ .params = comptime &.{ Param.binding("name"), Param.variadic("value"), Param.body("body") }, .returns = "value", .binding_pairs = true },
        .description = "Bind name/value pairs in a new scope, then evaluate the trailing body in it.",
    }));

    try g.register("pipe", Operation.fromFn(pipeOp, .{
        .signature = .{ .params = comptime &.{ Param.binding("name"), Param.value("initial"), .{ .name = "step", .role = .body, .arity = .variadic } }, .returns = "value" },
        .description = "Thread an initial value through each step, rebinding name to the running result.",
    }));

    try g.register("given", Operation.fromFn(givenOp, .{
        .signature = .{ .params = comptime &.{ Param.binding("name"), Param.value("source"), Param.body("ok"), .{ .name = "else", .role = .body, .arity = .optional } }, .returns = "value" },
        .description = "Evaluate source; if non-$none bind it to name and run the ok body, else run the optional else body (or $none).",
    }));
}

fn givenOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count != 3 and count != 4) {
        return args.env.fail(.arity_mismatch, "'given' expects 3 or 4 arguments (name, source, ok-body, [else-body])");
    }

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);

    const source = try args.items[1].proc(args.env, args.scope);
    if (source) |value| {
        var bound_scope = exec.Scope{ .parent = args.scope };
        defer bound_scope.deinit(args.env.allocator);
        const name = try args.env.allocator.dupe(u8, raw_name);
        try bound_scope.setValue(args.env.allocator, name, value);
        return args.items[2].proc(args.env, &bound_scope);
    }

    if (count == 4) return args.items[3].proc(args.env, args.scope);
    return null;
}

fn letOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 3 or count % 2 == 0) {
        return args.env.fail(.arity_mismatch, "'let' expects an odd number of arguments (name/value pairs + body)");
    }

    var extended_scope = exec.Scope{ .parent = args.scope };
    defer extended_scope.deinit(args.env.allocator);

    const body_index = count - 1;
    var name_buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < body_index) : (i += 2) {
        const raw_name = try args.at(i).resolveString(&name_buf);
        const name     = try args.env.allocator.dupe(u8, raw_name);
        const value    = try args.items[i + 1].proc(args.env, &extended_scope);
        try extended_scope.setValue(args.env.allocator, name, value);
    }

    return args.items[body_index].proc(args.env, &extended_scope);
}

fn pipeOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 3) {
        return args.env.fail(.arity_mismatch, "'pipe' expects at least 3 arguments (name, initial value, step+)");
    }

    var pipe_scope = exec.Scope{ .parent = args.scope };
    defer pipe_scope.deinit(args.env.allocator);

    var name_buf: [256]u8 = undefined;
    const raw_name = try args.at(0).resolveString(&name_buf);
    const name     = try args.env.allocator.dupe(u8, raw_name);

    var current = try args.items[1].proc(args.env, &pipe_scope);

    var i: usize = 2;
    while (i < count) : (i += 1) {
        pipe_scope.inline_count = 0;
        try pipe_scope.setValue(args.env.allocator, name, current);
        current = try args.items[i].proc(args.env, &pipe_scope);
    }

    return current;
}


const testing = @import("testing.zig");

test "let: basic binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let x 5 :x");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "let: value is computed once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let x (+ 1 2) :x");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "let: body uses binding multiple times" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let x 5 (+ :x :x)");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "let: string binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let greeting \"hello\" :greeting");
    try std.testing.expectEqualStrings("hello", result.?.string);
}

test "let: outer visible in inner body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let x 5 (let y :x :y)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "let: nested bindings compose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let x 5 (let y 10 (+ :x :y))");
    try std.testing.expectEqual(@as(i64, 15), result.?.int);
}

test "let: inner shadows outer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let x 5 (let x 10 :x)");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "let: shadow does not leak past inner body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Inner let shadows x with 10, but outer body after inner should see x=5
    const result = try testing.evalWithBuiltins(arena.allocator(), "let x 5 (+ (let x 10 :x) :x)");
    try std.testing.expectEqual(@as(i64, 15), result.?.int);
}

test "let: sibling proc expressions do not see binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // First sub-expr binds x; second references :x which should not be in scope
    const result = testing.evalWithBuiltins(arena.allocator(), "proc (let x 5 :x) :x");
    try std.testing.expectError(error.RuntimeError, result);
}

test "let: wrong arg count fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "let x 5");
    try std.testing.expectError(error.RuntimeError, result);
}

test "let: unknown reference in body fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "let x 5 :y");
    try std.testing.expectError(error.RuntimeError, result);
}

test "let: hyphenated name binds correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let my-val 7 (* :my-val 3)");
    try std.testing.expectEqual(@as(i64, 21), result.?.int);
}

test "let: multi-binding pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let a 1 b 2 (+ :a :b)");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "let: three bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let a 1 b 2 c 3 (+ :a (+ :b :c))");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "let: later binding sees earlier (sequential)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let a 1 b :a :b");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "let: later binding can compute from earlier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "let a 5 b (* :a 2) :b");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "let: even arg count fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "let a 1 b 2");
    try std.testing.expectError(error.RuntimeError, result);
}

test "pipe: single step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "pipe x 5 (* :x 2)");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "pipe: multi-step rebinds between steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 5 -> +3 -> 8 -> *2 -> 16
    const result = try testing.evalWithBuiltins(arena.allocator(), "pipe x 5 (+ :x 3) (* :x 2)");
    try std.testing.expectEqual(@as(i64, 16), result.?.int);
}

test "pipe: chain of same-op rebinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 1 -> +1 -> 2 -> +1 -> 3 -> +1 -> 4
    const result = try testing.evalWithBuiltins(arena.allocator(), "pipe v 1 (+ :v 1) (+ :v 1) (+ :v 1)");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "pipe: nested pipes with different names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // outer x = 10; inner pipe y = (* :x 2) = 20; inner step (+ :y 5) -> 25
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "pipe x 10 (pipe y (* :x 2) (+ :y 5))");
    try std.testing.expectEqual(@as(i64, 25), result.?.int);
}

test "pipe: inner pipe sees outer binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // outer = 7; inner pipe references outer :a inside steps
    const result = try testing.evalWithBuiltins(arena.allocator(),
        "pipe a 7 (pipe b 3 (+ :a :b))");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "pipe: too few args fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "pipe x 5");
    try std.testing.expectError(error.RuntimeError, result);
}

test "given: binds the source and runs the ok body when non-none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "given x 5 (* :x 2) 0");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "given: runs the else body when the source is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "given x $none (* :x 2) 99");
    try std.testing.expectEqual(@as(i64, 99), result.?.int);
}

test "given: a missing else yields none on a none source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "given x $none (* :x 2)");
    try std.testing.expect(result == null);
}

test "given: the binding is not visible to the else body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // :x must resolve to the outer binding, not the (unbound) given name.
    const result = try testing.evalWithBuiltins(arena.allocator(), "let x 7 (given x $none :x :x)");
    try std.testing.expectEqual(@as(i64, 7), result.?.int);
}

test "given: the binding does not leak past the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "proc (given x 5 :x) :x");
    try std.testing.expectError(error.RuntimeError, result);
}

test "given: the ok body is not evaluated on a none source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // If the ok body ran, :x would be unbound and this would error; the else wins.
    const result = try testing.evalWithBuiltins(arena.allocator(), "given x $none :x 1");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "given: wrong arg count fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "given x 5");
    try std.testing.expectError(error.RuntimeError, result);
}

