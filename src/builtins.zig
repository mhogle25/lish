const std = @import("std");
const exec = @import("exec.zig");

const Registry = exec.Registry;
const Allocator = std.mem.Allocator;

// Sub-module imports 

const constants    = @import("builtins/constants.zig");
const arithmetic   = @import("builtins/arithmetic.zig");
const comparison   = @import("builtins/comparison.zig");
pub const logic    = @import("builtins/logic.zig");
const control      = @import("builtins/control.zig");
const strings      = @import("builtins/strings.zig");
const lists        = @import("builtins/lists.zig");
const higher_order = @import("builtins/higher_order.zig");
const meta         = @import("builtins/meta.zig");
const math         = @import("builtins/math.zig");
const types        = @import("builtins/types.zig");
const sequencing   = @import("builtins/sequencing.zig");
const binding      = @import("builtins/binding.zig");
const output       = @import("builtins/output.zig");

// Registration

const RegisterFn = *const fn (*Registry, Allocator) Allocator.Error!void;

/// Pure operation groups, in registration order. Each `register` names its own
/// category (via `registry.group`); this list only fixes ordering. Excludes
/// `output` (side-effecting) and the stdlib macros (loaded separately).
const core_groups = [_]RegisterFn{
    constants.register,
    arithmetic.register,
    comparison.register,
    logic.register,
    control.register,
    strings.register,
    lists.register,
    higher_order.register,
    meta.register,
    math.register,
    types.register,
    sequencing.register,
    binding.register,
};

/// Register all built-in operations including output ops (say, error).
pub fn registerAll(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    try registerCore(registry, allocator);
    try registerOutput(registry, allocator);
}

/// Register all pure built-in operations. Safe for any context, including
/// config loading, since none of these produce visible side effects.
///
/// Also auto-loads the bundled stdlib macros at the end so consumers get
/// macros like `clamp` / `sign` / `pi` / `fill` without an extra setup step.
pub fn registerCore(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    for (core_groups) |register| try register(registry, allocator);

    const process = @import("process.zig");
    _ = try process.loadStdlib(registry);
}

/// Register output operations (say, error). These write to stdout/stderr and
/// are excluded from registerCore to keep config loading side-effect-free.
pub fn registerOutput(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    try output.register(registry, allocator);
}

// Pull sub-module tests into the test surface.
test {
    _ = constants;
    _ = arithmetic;
    _ = comparison;
    _ = logic;
    _ = control;
    _ = strings;
    _ = lists;
    _ = higher_order;
    _ = meta;
    _ = math;
    _ = types;
    _ = sequencing;
    _ = binding;
    _ = output;
}
