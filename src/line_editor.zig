//! Line editor: terminal raw-mode REPL input with history, autopair,
//! multi-row rendering, bracketed paste, and key bindings.
//!
//! The implementation is split across three modules in `line_editor/`:
//! - `buffer.zig`   editable text + cursor primitives
//! - `renderer.zig` ANSI-emitting multi-row redraw
//! - `editor.zig`   raw-mode lifecycle + escape FSM + history + key dispatch

const buffer_mod = @import("line_editor/buffer.zig");
const renderer_mod = @import("line_editor/renderer.zig");
const editor_mod = @import("line_editor/editor.zig");

pub const LineBuffer = buffer_mod.LineBuffer;
pub const LINE_MAX_LENGTH = buffer_mod.LINE_MAX_LENGTH;
pub const rowOf = buffer_mod.rowOf;
pub const colOf = buffer_mod.colOf;
pub const offsetAt = buffer_mod.offsetAt;

pub const Renderer = renderer_mod.Renderer;
pub const PROMPT = renderer_mod.PROMPT;

pub const LineEditor = editor_mod.LineEditor;
pub const ReadLineResult = editor_mod.ReadLineResult;
pub const PIPED_COMMAND_MAX_LENGTH = editor_mod.PIPED_COMMAND_MAX_LENGTH;

test {
    _ = buffer_mod;
    _ = renderer_mod;
    _ = editor_mod;
}
