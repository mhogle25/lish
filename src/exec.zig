const std = @import("std");
const val = @import("value.zig");
const token = @import("token.zig");

const Value = val.Value;
const Allocator = std.mem.Allocator;

// Error types

pub const ExecError = Allocator.Error || error{RuntimeError};

// Position and source tracking

/// Byte-offset span into a source. Line/column computed on demand by the host
/// from these offsets plus the source content.
pub const Position = struct {
    start: u32,
    end:   u32,

    /// Synthetic position for thunks not constructed from source (e.g.,
    /// scope bindings created at runtime by setValue).
    pub const synthetic: Position = .{ .start = 0, .end = 0 };
};

/// Identifier for which source a Position indexes into. Hosts populate this
/// at evaluation entry (top-level eval) and per-Macro (when the macro is
/// loaded). At runtime, Env.current_source reflects the macro/source whose
/// thunks are currently executing.
pub const SourceId = union(enum) {
    none,
    repl,
    embedded_stdlib,
    file: u16,
};

// Runtime errors

/// Category of a runtime error. Hosts use this to distinguish (e.g.) "fuel
/// exhausted" from "type mismatch" without parsing the message text.
pub const ErrorCategory = enum {
    fuel_exhausted,            // bounds: fuel
    recursion_depth_exceeded,  // bounds: call depth
    list_too_large,            // bounds: max_list_length
    string_too_large,          // bounds: max_string_length
    unknown_op,                // name not registered in current registry chain
    arity_mismatch,            // wrong number of arguments
    type_mismatch,             // value of wrong runtime type
    bounds_violation,          // index access out of valid range
    arithmetic,                // divide by zero, integer overflow, etc.
    invalid_argument,          // right type, unacceptable value
    user,                      // explicit script-raised (assert, future panic)
    internal,                  // interpreter bug / shouldn't-happen
};

/// Structured runtime error stored on Env.runtime_error after env.fail().
/// Source and position are captured automatically from Env's current
/// evaluation context at the moment of failure.
pub const RuntimeErr = struct {
    category: ErrorCategory,
    message:  []const u8,
    source:   SourceId    = .none,
    position: ?Position   = null,
};

// Thunk

pub const Thunk = struct {
    position: Position,
    body:     ThunkBody,

    /// Evaluate this thunk in the given environment and scope. Updates
    /// env.current_position to this thunk's position for the duration of
    /// evaluation so any env.fail call inside captures the right location.
    pub fn proc(self: *const Thunk, env: *Env, scope: *const Scope) ExecError!?Value {
        const saved_position = env.current_position;
        env.current_position = self.position;
        defer env.current_position = saved_position;

        return switch (self.body) {
            .value_literal => |stored_value| stored_value,
            .scope_thunk => |id_thunk| {
                const id_value = try id_thunk.proc(env, scope) orelse
                    return env.fail(.invalid_argument, "Scope thunk ID resolved to none");

                var id_buf: [256]u8 = undefined;
                const id_string = id_value.getS(&id_buf);

                const entry = scope.get(id_string) orelse
                    return env.failFmt(.unknown_op, "Scope entry not found: '{s}'", .{id_string});

                return entry.run(env);
            },
            .expression => |expression| env.processExpression(expression, scope),
        };
    }
};

pub const ThunkBody = union(enum) {
    value_literal: ?Value,
    scope_thunk:   *const Thunk,
    expression:    Expression,
};

// ExpressionId 

pub const ExpressionId = union(enum) {
    resolved_op:    Operation,      // direct call, no registry lookup
    resolved_macro: *const Macro,   // direct call, no registry lookup
    dynamic:        *const Thunk,   // fallback: evaluate thunk, look up at runtime
};

pub const Expression = struct {
    id:   ExpressionId,
    args: []const *const Thunk,
};

// Scope 

pub const ScopeEntry = struct {
    thunk: *const Thunk,
    scope: *const Scope,

    /// Evaluate the thunk using the captured scope (closure semantics).
    pub fn run(self: ScopeEntry, env: *Env) ExecError!?Value {
        return self.thunk.proc(env, self.scope);
    }
};

// Scopes with up to INLINE_CAP bindings store entries in a flat inline array
// (linear scan). Larger scopes overflow to a HashMap. Most macro calls bind
// 1-4 parameters, so the overflow path is almost never reached.
const INLINE_CAP = 8;

const InlineEntry = struct {
    key: []const u8,

    kind: union(enum) {
        owned:    Thunk,
        borrowed: ScopeEntry,
    },

    fn toScopeEntry(self: *const InlineEntry) ScopeEntry {
        return switch (self.kind) {
            .owned    => |*thunk| .{ .thunk = thunk, .scope = &Scope.EMPTY },
            .borrowed => |entry|  entry,
        };
    }
};

pub const Scope = struct {
    parent:         ?*const Scope                          = null,
    inline_entries: [INLINE_CAP]InlineEntry                = undefined,
    inline_count:   usize                                  = 0,
    overflow:       ?std.StringHashMapUnmanaged(ScopeEntry) = null,

    pub fn get(self: *const Scope, key: []const u8) ?ScopeEntry {
        for (self.inline_entries[0..self.inline_count]) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.toScopeEntry();
        }
        if (self.overflow) |map| {
            if (map.get(key)) |entry| return entry;
        }
        if (self.parent) |parent| return parent.get(key);
        return null;
    }

    /// Bind an arbitrary thunk to a name with an explicit evaluation scope.
    pub fn setEntry(self: *Scope, allocator: Allocator, key: []const u8, thunk: *const Thunk, thunk_scope: *const Scope) Allocator.Error!void {
        if (self.inline_count < INLINE_CAP) {
            self.inline_entries[self.inline_count] = .{
                .key  = key,
                .kind = .{ .borrowed = .{ .thunk = thunk, .scope = thunk_scope } },
            };
            self.inline_count += 1;
            return;
        }
        try self.spillToOverflow(allocator);
        try self.overflow.?.put(allocator, key, .{ .thunk = thunk, .scope = thunk_scope });
    }

    /// Bind a static value to a name. Stores the thunk inline. No allocation for small scopes.
    pub fn setValue(self: *Scope, allocator: Allocator, key: []const u8, value: ?Value) Allocator.Error!void {
        if (self.inline_count < INLINE_CAP) {
            self.inline_entries[self.inline_count] = .{
                .key  = key,
                .kind = .{ .owned = .{ .position = Position.synthetic, .body = .{ .value_literal = value } } },
            };
            self.inline_count += 1;
            return;
        }
        // Overflow: must heap-allocate the thunk since HashMap stores *const Thunk.
        const thunk = try allocator.create(Thunk);
        thunk.* = .{ .position = Position.synthetic, .body = .{ .value_literal = value } };
        try self.spillToOverflow(allocator);
        try self.overflow.?.put(allocator, key, .{ .thunk = thunk, .scope = &Scope.EMPTY });
    }

    pub fn deinit(self: *Scope, allocator: Allocator) void {
        if (self.overflow) |*map| map.deinit(allocator);
    }

    // Migrate inline entries into the overflow HashMap on first spill.
    fn spillToOverflow(self: *Scope, allocator: Allocator) Allocator.Error!void {
        if (self.overflow != null) return;
        self.overflow = std.StringHashMapUnmanaged(ScopeEntry){};
        for (self.inline_entries[0..self.inline_count]) |*entry| {
            try self.overflow.?.put(allocator, entry.key, entry.toScopeEntry());
        }
    }

    pub const EMPTY: Scope = .{};
};

// Arg

pub const Arg = struct {
    thunk: *const Thunk,
    env: *Env,
    scope: *const Scope,

    /// Evaluate the argument thunk lazily.
    pub fn get(self: Arg) ExecError!?Value {
        return self.thunk.proc(self.env, self.scope);
    }

    /// Evaluate and require a non-null value.
    pub fn resolve(self: Arg) ExecError!Value {
        return try self.get() orelse
            return self.env.fail(.type_mismatch, "Expected a value but got none");
    }

    /// Evaluate and get as string.
    pub fn resolveString(self: Arg, buf: []u8) ExecError![]const u8 {
        const result = try self.resolve();
        return result.getS(buf);
    }

    /// Evaluate and get as integer.
    pub fn resolveInt(self: Arg) ExecError!i64 {
        const result = try self.resolve();
        return result.getI() catch
            return self.env.failFmt(.type_mismatch, "Expected a number, got {s}", .{result.typeName()});
    }

    /// Evaluate and get as float.
    pub fn resolveFloat(self: Arg) ExecError!f64 {
        const result = try self.resolve();
        return result.getF() catch
            return self.env.failFmt(.type_mismatch, "Expected a number, got {s}", .{result.typeName()});
    }

    /// Evaluate and get as list.
    pub fn resolveList(self: Arg) ExecError![]const ?Value {
        const result = try self.resolve();
        return result.getL() catch
            return self.env.failFmt(.type_mismatch, "Expected a list, got {s}", .{result.typeName()});
    }
};

// Args

pub const Args = struct {
    items: []const *const Thunk,
    env: *Env,
    scope: *const Scope,

    pub fn count(self: Args) usize {
        return self.items.len;
    }

    pub fn at(self: Args, index: usize) Arg {
        return .{ .thunk = self.items[index], .env = self.env, .scope = self.scope };
    }

    /// Get a single argument, asserting exactly one was provided.
    pub fn single(self: Args) ExecError!Arg {
        if (self.items.len != 1) {
            return self.env.fail(.arity_mismatch,
                if (self.items.len == 0) "Expected 1 argument but got 0" else "Expected 1 argument but got multiple",
            );
        }
        return self.at(0);
    }

    /// Resolve single argument to a value.
    pub fn resolveSingle(self: Args) ExecError!Value {
        const arg = try self.single();
        return arg.resolve();
    }

    /// Evaluate all arguments, returning their optional values.
    pub fn getAll(self: Args) ExecError![]const ?Value {
        const results = try self.env.allocator.alloc(?Value, self.items.len);
        for (self.items, 0..) |_, i| {
            results[i] = try self.at(i).get();
        }
        return results;
    }

    /// Resolve all arguments (require non-null values).
    pub fn resolveAll(self: Args) ExecError![]const Value {
        const results = try self.env.allocator.alloc(Value, self.items.len);
        for (self.items, 0..) |_, i| {
            results[i] = try self.at(i).resolve();
        }
        return results;
    }

    /// Validate that exactly the expected number of arguments was provided.
    pub fn expectCount(self: Args, expected: usize) ExecError!void {
        if (self.items.len != expected) {
            return self.env.failFmt(.arity_mismatch, "Expected {d} argument(s) but got {d}", .{ expected, self.items.len });
        }
    }

    /// Validate at least the minimum number of arguments was provided.
    pub fn expectMinCount(self: Args, minimum: usize) ExecError!void {
        if (self.items.len < minimum) {
            return self.env.failFmt(.arity_mismatch, "Expected at least {d} argument(s) but got {d}", .{ minimum, self.items.len });
        }
    }
};

// Operation

/// One parameter in an operation's call signature. `role` is what the parameter
/// is semantically (a plain value, a name a binding form introduces, or a body
/// the binding is in scope for); `arity` is how it is supplied.
pub const Param = struct {
    name: []const u8,
    role: Role = .value,
    arity: Arity = .single,

    pub const Role = enum { value, binding, body };
    pub const Arity = enum { single, optional, variadic };

    pub fn value(name: []const u8) Param {
        return .{ .name = name };
    }
    pub fn variadic(name: []const u8) Param {
        return .{ .name = name, .arity = .variadic };
    }
    pub fn optional(name: []const u8) Param {
        return .{ .name = name, .arity = .optional };
    }
    pub fn binding(name: []const u8) Param {
        return .{ .name = name, .role = .binding };
    }
    pub fn body(name: []const u8) Param {
        return .{ .name = name, .role = .body };
    }
};

/// An operation's call shape, authored as structured data. The display string
/// (`"map name list body -> list"`) is rendered from it, and tooling reads the
/// parameter roles directly (binding/scope analysis, signature help).
pub const Signature = struct {
    params: []const Param = &.{},
    returns: []const u8,
    /// `let`-style: the params repeat as (binding, value) pairs before the body.
    /// The flat `params` list cannot express this; only `let` sets it.
    binding_pairs: bool = false,

    /// Write the display form `name p1 [opt] vararg ... -> returns`.
    pub fn render(self: Signature, writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
        try writer.writeAll(name);
        for (self.params) |param| {
            try writer.writeByte(' ');
            if (param.arity == .optional) {
                try writer.print("[{s}]", .{param.name});
            } else {
                try writer.writeAll(param.name);
            }
            if (param.arity == .variadic) try writer.writeAll(" ...");
        }
        try writer.print(" -> {s}", .{self.returns});
    }
};

pub const Operation = struct {
    context: ?*anyopaque,
    callFn: *const fn (?*anyopaque, Args) ExecError!?Value,
    signature: Signature,
    description: []const u8,

    /// Group this op belongs to (e.g. "arithmetic"), or null if registered
    /// outside a group. Not part of `Meta`: it is a property of the group doing
    /// the registering, stamped by `GroupRegistrar.register`, so call sites name
    /// the category once per group rather than once per op. Surfaced by
    /// introspection.
    category: ?[]const u8 = null,

    /// Documentation required for every operation at construction. Surfaced by
    /// the LSP (hover) and by `lish.introspect` (`lish --dump-ops`). Required,
    /// not optional: an op you cannot describe is an op nobody can discover.
    pub const Meta = struct {
        /// Call shape as structured data; the display string is rendered from it.
        signature: Signature,
        /// One-line human summary.
        description: []const u8,
    };

    pub fn call(self: Operation, args: Args) ExecError!?Value {
        return self.callFn(self.context, args);
    }

    /// Wrap a stateless function as an Operation.
    pub fn fromFn(comptime func: fn (Args) ExecError!?Value, meta: Meta) Operation {
        return .{
            .context = null,
            .callFn = struct {
                fn call(_: ?*anyopaque, args: Args) ExecError!?Value {
                    return func(args);
                }
            }.call,
            .signature = meta.signature,
            .description = meta.description,
        };
    }

    /// Wrap a context-bound function as an Operation.
    /// The cast from anyopaque to *Context is generated once here at comptime.
    pub fn fromBoundFn(
        comptime Context: type,
        comptime func: fn (*Context, Args) ExecError!?Value,
        context: *Context,
        meta: Meta,
    ) Operation {
        return .{
            .context = context,
            .callFn = struct {
                fn call(ctx: ?*anyopaque, args: Args) ExecError!?Value {
                    const typed: *Context = @ptrCast(@alignCast(ctx.?));
                    return func(typed, args);
                }
            }.call,
            .signature = meta.signature,
            .description = meta.description,
        };
    }
};

// Macro

pub const MacroParameterType = enum {
    value,
    deferred,
};

pub const MacroParameter = struct {
    id: []const u8,
    param_type: MacroParameterType,
};

pub const Macro = struct {
    id: []const u8,
    parameters: []const MacroParameter,
    body: Expression,
    /// Source the macro body's thunks belong to. Swapped into env.current_source
    /// during execution so positions captured by env.fail resolve to the right
    /// file. Defaults to `.none` for macros constructed in tests.
    source: SourceId = .none,

    /// Write the macro's call signature, e.g. `clamp lo hi x`. Deferred
    /// parameters are prefixed with the source's deferred symbol (`~`), matching
    /// how they are written in a `.lishmacro` head. Unlike an operation, a macro's
    /// signature is fully recoverable from its structure, so no metadata is
    /// required of the author; introspection derives it here.
    pub fn writeSignature(self: *const Macro, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.id);
        for (self.parameters) |param| {
            try writer.writeByte(' ');
            if (param.param_type == .deferred) try writer.writeByte(token.DEFERRED);
            try writer.writeAll(param.id);
        }
    }

    /// Execute the macro: bind arguments to parameters, evaluate body.
    pub fn run(
        self: *const Macro,
        arg_thunks: []const *const Thunk,
        env: *Env,
        caller_scope: *const Scope,
    ) ExecError!?Value {
        if (self.parameters.len != arg_thunks.len) {
            return env.failFmt(.invalid_argument, 
                "Macro '{s}' expected {d} argument(s) but got {d}",
                .{ self.id, self.parameters.len, arg_thunks.len },
            );
        }

        var macro_scope = Scope{};
        // Overflow HashMap only allocated if param count exceeds INLINE_CAP (rare).
        defer macro_scope.deinit(env.allocator);

        for (self.parameters, arg_thunks) |param, arg_thunk| {
            switch (param.param_type) {
                .value => {
                    // Eagerly evaluate the argument in the caller's scope, then bind as a static value.
                    const evaluated = try arg_thunk.proc(env, caller_scope);
                    try macro_scope.setValue(env.allocator, param.id, evaluated);
                },
                .deferred => {
                    // Bind the unevaluated thunk with the caller's scope so it re-evaluates there.
                    try macro_scope.setEntry(env.allocator, param.id, arg_thunk, caller_scope);
                },
            }
        }

        // Switch source context to the macro's source while evaluating its body.
        // Positions captured during body execution will resolve against self.source.
        const saved_source = env.current_source;
        env.current_source = self.source;
        defer env.current_source = saved_source;

        return env.processExpression(self.body, &macro_scope);
    }
};

// Registry

/// Registers operations into a registry under a fixed category, carrying the
/// registry and allocator so neither is repeated per call. Obtain one from
/// `Registry.group`; this is how an op gets its `category` stamped (the category
/// is a property of the group doing the registering, not of each call site).
pub const GroupRegistrar = struct {
    registry: *Registry,
    allocator: Allocator,
    category: []const u8,

    pub fn register(self: GroupRegistrar, id: []const u8, operation: Operation) Allocator.Error!void {
        var op = operation;
        op.category = self.category;
        try self.registry.registerOperation(self.allocator, id, op);
    }
};

pub const Registry = struct {
    operations: std.StringHashMapUnmanaged(Operation) = .{},
    macros: std.StringHashMapUnmanaged(*const Macro) = .{},
    macro_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) Registry {
        return .{
            .operations    = .{},
            .macros        = .{},
            .macro_arena   = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn macroAllocator(self: *Registry) Allocator {
        return self.macro_arena.allocator();
    }

    pub fn getOperation(self: *const Registry, id: []const u8) ?Operation {
        return self.operations.get(id);
    }

    pub fn getMacro(self: *const Registry, id: []const u8) ?*const Macro {
        return self.macros.get(id);
    }

    /// Register an op with no category (test ops, ad-hoc registration). Grouped
    /// builtins go through `group(...).register(...)` so their category is set.
    pub fn registerOperation(self: *Registry, allocator: Allocator, id: []const u8, operation: Operation) Allocator.Error!void {
        try self.operations.put(allocator, id, operation);
    }

    /// A registrar that stamps everything it registers with `category`.
    pub fn group(self: *Registry, allocator: Allocator, category: []const u8) GroupRegistrar {
        return .{ .registry = self, .allocator = allocator, .category = category };
    }

    pub fn registerMacro(self: *Registry, id: []const u8, macro: *const Macro) Allocator.Error!void {
        try self.macros.put(self.macroAllocator(), id, macro);
    }

    pub fn deinit(self: *Registry, allocator: Allocator) void {
        self.operations.deinit(allocator);
        self.macro_arena.deinit();
    }

    /// Resolve a name to a pre-resolved ExpressionId, or null if unknown.
    pub fn resolveId(self: *const Registry, name: []const u8) ?ExpressionId {
        if (self.getOperation(name)) |op|    return .{ .resolved_op    = op };
        if (self.getMacro(name))    |macro|  return .{ .resolved_macro = macro };
        return null;
    }
};

// Runtime resource limits 

/// Per-evaluation resource limits. Null fields mean "unlimited".
/// `max_call_depth` always applies (no null option) since deep recursion
/// can crash the host process via Zig stack overflow.
pub const Bounds = struct {
    /// Maximum nesting depth of `processExpression` calls. Catches runaway
    /// macro recursion before it overflows the Zig stack.
    max_call_depth: usize = 1024,

    /// Maximum total `processExpression` calls per top-level evaluation.
    /// Null = unlimited. The host resets this counter before each execute.
    fuel: ?usize = null,

    /// Maximum element count for any list constructed at runtime
    /// (`list`, `range`, `until`, `fill`, `fillby`, `map`, `filter`, `flat`,
    /// `flatten`, `zip`, `sort`, `sortby`, `sortwith`, `split`, `reduce`).
    /// Null = unlimited.
    max_list_length: ?usize = null,

    /// Maximum byte length for any string constructed at runtime
    /// (`concat`, `join`, `format`, `replace`, `reverse`, `string`).
    /// Null = unlimited.
    max_string_length: ?usize = null,
};

// Env

pub const Env = struct {
    registry: *const Registry,
    allocator: Allocator,
    io: ?std.Io = null,
    runtime_error: ?RuntimeErr = null,
    stdout: ?*std.Io.Writer = null,
    stderr: ?*std.Io.Writer = null,

    /// Resource limits applied during evaluation.
    bounds: Bounds = .{},

    /// Current recursion depth, incremented at processExpression entry,
    /// decremented on exit. Should be 0 between top-level evaluations.
    call_depth: usize = 0,

    /// Remaining fuel for the current evaluation. Initialized from
    /// `bounds.fuel` at the start of each top-level execute.
    /// Null = unlimited (no decrement, no check).
    fuel_remaining: ?usize = null,

    /// Source position of the Thunk currently being evaluated. Updated on
    /// every Thunk.proc entry, restored on exit. Read by env.fail to attach
    /// the innermost position to runtime errors.
    current_position: ?Position = null,

    /// Source the currently-executing thunks belong to. Updated on macro
    /// entry (Macro.run swaps to self.source) and on top-level evaluation
    /// entry (host sets it before kicking off processing).
    current_source: SourceId = .none,

    /// Evaluate an expression: dispatch on its (possibly pre-resolved) ID.
    pub fn processExpression(self: *Env, expression: Expression, scope: *const Scope) ExecError!?Value {
        // Recursion-depth guard: prevents Zig stack overflow from runaway macros.
        self.call_depth += 1;
        defer self.call_depth -= 1;
        if (self.call_depth > self.bounds.max_call_depth) {
            return self.failFmt(.recursion_depth_exceeded, "Recursion depth exceeded (max {d})", .{self.bounds.max_call_depth});
        }

        // Fuel guard: bounds total work per top-level evaluation.
        if (self.fuel_remaining) |*fuel| {
            if (fuel.* == 0) return self.fail(.fuel_exhausted, "Fuel exhausted");
            fuel.* -= 1;
        }

        const id = expression.id;
        switch (id) {
            .resolved_op => |operation| {
                const args = Args{ .items = expression.args, .env = self, .scope = scope };
                return operation.call(args);
            },
            .resolved_macro => |macro| {
                return macro.run(expression.args, self, scope);
            },
            .dynamic => |id_thunk| {
                const id_value = try id_thunk.proc(self, scope) orelse
                    return self.fail(.invalid_argument, "Expression ID resolved to none");
                const id_string = switch (id_value) {
                    .string => |s| s,
                    .int    => |n| return self.failFmt(.type_mismatch, "Expected operation name, got int: {d}", .{n}),
                    .float  => |n| return self.failFmt(.type_mismatch, "Expected operation name, got float: {d}", .{n}),
                    .list   =>     return self.fail(.type_mismatch, "Expected operation name, got list"),
                };
                if (self.registry.getOperation(id_string)) |operation| {
                    const args = Args{ .items = expression.args, .env = self, .scope = scope };
                    return operation.call(args);
                }
                if (self.registry.getMacro(id_string)) |macro| {
                    return macro.run(expression.args, self, scope);
                }
                return self.failFmt(.unknown_op, "Unknown operation or macro: '{s}'", .{id_string});
            },
        }
    }

    /// Record a categorized runtime error and return RuntimeError. Captures
    /// the current source position and source from Env automatically.
    pub fn fail(self: *Env, category: ErrorCategory, message: []const u8) error{RuntimeError} {
        self.runtime_error = .{
            .category = category,
            .message  = message,
            .source   = self.current_source,
            .position = self.current_position,
        };
        return error.RuntimeError;
    }

    /// Record a categorized formatted runtime error and return RuntimeError.
    pub fn failFmt(self: *Env, category: ErrorCategory, comptime fmt: []const u8, args: anytype) error{RuntimeError} {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch "error (allocation failed)";
        self.runtime_error = .{
            .category = category,
            .message  = message,
            .source   = self.current_source,
            .position = self.current_position,
        };
        return error.RuntimeError;
    }
};

// Thunk construction helpers 

pub fn makeValueLiteral(allocator: Allocator, position: Position, value: ?Value) Allocator.Error!*Thunk {
    const thunk = try allocator.create(Thunk);
    thunk.* = .{ .position = position, .body = .{ .value_literal = value } };
    return thunk;
}

pub fn makeScopeThunk(allocator: Allocator, position: Position, id_thunk: *const Thunk) Allocator.Error!*Thunk {
    const thunk = try allocator.create(Thunk);
    thunk.* = .{ .position = position, .body = .{ .scope_thunk = id_thunk } };
    return thunk;
}

pub fn makeExpression(allocator: Allocator, position: Position, id: *const Thunk, args: []const *const Thunk) Allocator.Error!*Thunk {
    const duped_args = try allocator.dupe(*const Thunk, args);
    const thunk = try allocator.create(Thunk);
    thunk.* = .{ .position = position, .body = .{ .expression = .{ .id = .{ .dynamic = id }, .args = duped_args } } };
    return thunk;
}

// Resolve pass

/// Walk a thunk tree and replace dynamic string IDs with resolved references
/// where the name is a known operation or macro. Safe to call immediately after
/// parsing. Thunks are freshly allocated and not yet const-observed.
pub fn resolveThunk(thunk: *Thunk, registry: *const Registry) void {
    switch (thunk.body) {
        .value_literal, .scope_thunk => {},
        .expression => |*expr| resolveExpression(expr, registry),
    }
}

pub fn resolveExpression(expr: *Expression, registry: *const Registry) void {
    resolveExpressionId(expr, registry);
    for (expr.args) |arg| resolveThunk(@constCast(arg), registry);
}

/// Replace a dynamic string-name ID with a pre-resolved op or macro reference,
/// if the name is registered. No-op otherwise. Walks down through the dynamic
/// id thunk, extracting each layer or bailing if it does not match.
fn resolveExpressionId(expr: *Expression, registry: *const Registry) void {
    const id_thunk = switch (expr.id) {
        .dynamic => |t| t,
        else => return,
    };
    const literal = switch (id_thunk.body) {
        .value_literal => |v| v orelse return,
        else => return,
    };
    const name = switch (literal) {
        .string => |s| s,
        else => return,
    };
    if (registry.resolveId(name)) |resolved| {
        expr.id = resolved;
    }
}

/// Resolve all macro bodies in the registry. Call after all macros are loaded.
pub fn resolveRegistryMacros(registry: *Registry) void {
    var it = registry.macros.iterator();
    while (it.next()) |entry| {
        resolveExpression(&@constCast(entry.value_ptr.*).body, registry);
    }
}

// Tests

test "Macro.writeSignature renders params, marking deferred with ~" {
    const params = [_]MacroParameter{
        .{ .id = "lo", .param_type = .value },
        .{ .id = "hi", .param_type = .value },
        .{ .id = "body", .param_type = .deferred },
    };
    // writeSignature reads only id + parameters, never the body.
    const macro = Macro{ .id = "guard", .parameters = &params, .body = undefined };

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try macro.writeSignature(&writer);
    try std.testing.expectEqualStrings("guard lo hi ~body", writer.buffered());
}

test "value literal thunk returns stored value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const thunk = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 42 });
    const result = try thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

test "value literal none thunk returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const thunk = try makeValueLiteral(alloc, Position.synthetic, null);
    const result = try thunk.proc(&env, &scope);
    try std.testing.expect(result == null);
}

test "scope thunk resolves entry from scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    // Create a scope with "x" bound to 99
    const value_thunk = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 99 });
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    var scope = Scope{};
    try scope.setEntry(alloc, "x", value_thunk, empty_scope);

    // Create :x (scope thunk that looks up "x")
    const id_thunk = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "x" });
    const lookup_thunk = try makeScopeThunk(alloc, Position.synthetic, id_thunk);

    const result = try lookup_thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 99), result.?.int);
}

test "scope thunk fails for missing entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const id_thunk = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "missing" });
    const lookup_thunk = try makeScopeThunk(alloc, Position.synthetic, id_thunk);

    const result = lookup_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
    try std.testing.expectEqualStrings("Scope entry not found: 'missing'", env.runtime_error.?.message);
}

test "resolveInt names the type it actually received" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // A list where an integer is expected: the error should say "got list".
    const thunk = try makeValueLiteral(alloc, Position.synthetic, .{ .list = &.{} });
    const arg = Arg{ .thunk = thunk, .env = &env, .scope = &scope };

    try std.testing.expectError(error.RuntimeError, arg.resolveInt());
    try std.testing.expectEqualStrings("Expected a number, got list", env.runtime_error.?.message);
}

test "expression evaluates operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try registry.registerOperation(alloc, "double", Operation.fromFn(testDoubleOp, .{
        .signature = .{ .params = comptime &.{Param.value("n")}, .returns = "int" },
        .description = "Test op: double an integer.",
    }));

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "double" });
    const arg = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 21 });
    const expr_thunk = try makeExpression(alloc, Position.synthetic, id, &.{arg});

    const result = try expr_thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

fn testDoubleOp(args: Args) ExecError!?Value {
    const arg_value = try args.at(0).resolveInt();
    return .{ .int = arg_value * 2 };
}

test "expression fails when op id is int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const id = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 42 });
    const expr_thunk = try makeExpression(alloc, Position.synthetic, id, &.{});

    const result = expr_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
    try std.testing.expectEqualStrings("Expected operation name, got int: 42", env.runtime_error.?.message);
}

test "expression fails when op id is float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const id = try makeValueLiteral(alloc, Position.synthetic, .{ .float = 3.14 });
    const expr_thunk = try makeExpression(alloc, Position.synthetic, id, &.{});

    const result = expr_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
    try std.testing.expectEqualStrings("Expected operation name, got float: 3.14", env.runtime_error.?.message);
}

test "expression fails when op id is list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const items = [_]?Value{.{ .int = 1 }};
    const id = try makeValueLiteral(alloc, Position.synthetic, .{ .list = &items });
    const expr_thunk = try makeExpression(alloc, Position.synthetic, id, &.{});

    const result = expr_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
    try std.testing.expectEqualStrings("Expected operation name, got list", env.runtime_error.?.message);
}

test "expression fails for unknown operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "nonexistent" });
    const expr_thunk = try makeExpression(alloc, Position.synthetic, id, &.{});

    const result = expr_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
}

test "nested expression evaluation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try registry.registerOperation(alloc, "add", Operation.fromFn(testAddOp, .{
        .signature = .{ .params = comptime &.{ Param.value("a"), Param.value("b") }, .returns = "int" },
        .description = "Test op: add two integers.",
    }));

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // Build: add (add 1 2) 3 -> expects 6
    const add_id_inner = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "add" });
    const one = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 1 });
    const two = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 2 });
    const inner_expr = try makeExpression(alloc, Position.synthetic, add_id_inner, &.{ one, two });

    const add_id_outer = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "add" });
    const three = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 3 });
    const outer_expr = try makeExpression(alloc, Position.synthetic, add_id_outer, &.{ inner_expr, three });

    const result = try outer_expr.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

fn testAddOp(args: Args) ExecError!?Value {
    const left = try args.at(0).resolveInt();
    const right = try args.at(1).resolveInt();
    return .{ .int = left + right };
}

test "macro with value parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try registry.registerOperation(alloc, "add", Operation.fromFn(testAddOp, .{
        .signature = .{ .params = comptime &.{ Param.value("a"), Param.value("b") }, .returns = "int" },
        .description = "Test op: add two integers.",
    }));

    // Define macro: |add-one x| add :x 1
    const params = [_]MacroParameter{
        .{ .id = "x", .param_type = .value },
    };

    const add_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "add" });
    const x_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "x" });
    const x_ref = try makeScopeThunk(alloc, Position.synthetic, x_id);
    const one = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 1 });

    const macro = try alloc.create(Macro);
    macro.* = .{
        .id = "add-one",
        .parameters = &params,
        .body = .{
            .id   = .{ .dynamic = add_id },
            .args = try alloc.dupe(*const Thunk, &.{ x_ref, one }),
        },
    };
    try registry.registerMacro("add-one", macro);

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // Call: add-one 5 -> expects 6
    const call_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "add-one" });
    const five = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 5 });
    const call_thunk = try makeExpression(alloc, Position.synthetic, call_id, &.{five});

    const result = try call_thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "macro with deferred parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try registry.registerOperation(alloc, "passthrough", Operation.fromFn(testPassthroughOp, .{
        .signature = .{ .params = comptime &.{Param.value("x")}, .returns = "any" },
        .description = "Test op: return its argument unchanged.",
    }));

    // Define macro: |run-deferred ~thunk| passthrough :thunk
    // The deferred parameter means the thunk is not evaluated until :thunk is referenced
    const params = [_]MacroParameter{
        .{ .id = "thunk", .param_type = .deferred },
    };

    const identity_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "passthrough" });
    const thunk_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "thunk" });
    const thunk_ref = try makeScopeThunk(alloc, Position.synthetic, thunk_id);

    const macro = try alloc.create(Macro);
    macro.* = .{
        .id = "run-deferred",
        .parameters = &params,
        .body = .{
            .id   = .{ .dynamic = identity_id },
            .args = try alloc.dupe(*const Thunk, &.{thunk_ref}),
        },
    };
    try registry.registerMacro("run-deferred", macro);

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // Call: run-deferred 42 -> the literal 42 is passed deferred, resolved when :thunk is accessed
    const call_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "run-deferred" });
    const forty_two = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 42 });
    const call_thunk = try makeExpression(alloc, Position.synthetic, call_id, &.{forty_two});

    const result = try call_thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

fn testPassthroughOp(args: Args) ExecError!?Value {
    return args.at(0).get();
}

test "macro arity mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    const params = [_]MacroParameter{
        .{ .id = "x", .param_type = .value },
        .{ .id = "y", .param_type = .value },
    };
    const dummy_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "proc" });
    const macro = try alloc.create(Macro);
    macro.* = .{
        .id = "needs-two",
        .parameters = &params,
        .body = .{ .id = .{ .dynamic = dummy_id }, .args = &.{} },
    };
    try registry.registerMacro("needs-two", macro);

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // Call with wrong arity: needs-two 1 (missing second arg)
    const call_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "needs-two" });
    const one = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 1 });
    const call_thunk = try makeExpression(alloc, Position.synthetic, call_id, &.{one});

    const result = call_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
}

test "args validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const thunk_a = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 10 });
    const thunk_b = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 20 });
    const items = try alloc.alloc(*const Thunk, 2);
    items[0] = thunk_a;
    items[1] = thunk_b;

    const args = Args{ .items = items, .env = &env, .scope = &scope };

    try std.testing.expectEqual(@as(usize, 2), args.count());
    try std.testing.expectEqual(@as(i64, 10), try args.at(0).resolveInt());
    try std.testing.expectEqual(@as(i64, 20), try args.at(1).resolveInt());

    // single() should fail with 2 args
    try std.testing.expectError(error.RuntimeError, args.single());
}

test "scope entry closure captures scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try registry.registerOperation(alloc, "add", Operation.fromFn(testAddOp, .{
        .signature = .{ .params = comptime &.{ Param.value("a"), Param.value("b") }, .returns = "int" },
        .description = "Test op: add two integers.",
    }));

    var env = Env{ .registry = &registry, .allocator = alloc };

    // Create an inner scope where "y" = 10
    const y_value = try makeValueLiteral(alloc, Position.synthetic, .{ .int = 10 });
    const inner_scope = try alloc.create(Scope);
    inner_scope.* = .{};
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    try inner_scope.setEntry(alloc, "y", y_value, empty_scope);

    // Create a thunk that references :y, captured with inner_scope
    const y_id = try makeValueLiteral(alloc, Position.synthetic, .{ .string = "y" });
    const y_ref = try makeScopeThunk(alloc, Position.synthetic, y_id);

    // Create an outer scope where "my-val" is bound to :y with inner_scope as the captured scope
    var outer_scope = Scope{};
    try outer_scope.setEntry(alloc, "my-val", y_ref, inner_scope);

    // Resolving "my-val" should evaluate :y in inner_scope, finding y=10
    const entry = outer_scope.get("my-val").?;
    const result = try entry.run(&env);
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}
