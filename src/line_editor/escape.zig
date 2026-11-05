const std = @import("std");

/// High-level intent dispatched from a recognised ANSI/VT escape sequence.
/// The parser is namespace-agnostic about what these mean; LineEditor maps
/// each action to a method call.
pub const Action = enum {
    move_up,
    move_down,
    move_right,
    move_left,
    move_word_right,
    move_word_left,
    home,
    end,
    delete_forward,
    /// Alt+Enter: insert a newline at cursor (with current-line indent preserved).
    insert_newline,
    /// Shift+Tab (ESC[Z): remove up to INDENT_WIDTH leading spaces from the
    /// current logical line.
    dedent,
    /// ESC[200~: terminal begins bracketed paste; subsequent bytes are literal.
    paste_start,
    /// ESC[201~: terminal ends bracketed paste; resume normal input handling.
    paste_end,
};

/// Result of feeding one byte to the parser.
/// - `not_escape`: byte is not part of any sequence; caller handles it normally.
/// - `consumed`:   byte was eaten (mid-sequence) but no action yet.
/// - `action`:     byte completed a recognised sequence.
pub const Step = union(enum) {
    not_escape,
    consumed,
    action: Action,
};

/// One recognised escape sequence: its literal byte pattern and the action
/// that fires when the full pattern matches. All patterns must start with
/// 0x1b (ESC).
const Sequence = struct {
    pattern: []const u8,
    action: Action,
};

/// All recognised escape sequences. Order doesn't matter for correctness;
/// the parser tracks all viable candidates as bytes arrive.
const SEQUENCES = [_]Sequence{
    // CSI cursor / function keys
    .{ .pattern = "\x1b[A",    .action = .move_up },
    .{ .pattern = "\x1b[B",    .action = .move_down },
    .{ .pattern = "\x1b[C",    .action = .move_right },
    .{ .pattern = "\x1b[D",    .action = .move_left },
    .{ .pattern = "\x1b[H",    .action = .home },
    .{ .pattern = "\x1b[F",    .action = .end },
    .{ .pattern = "\x1b[Z",    .action = .dedent },
    .{ .pattern = "\x1b[3~",   .action = .delete_forward },
    .{ .pattern = "\x1b[200~", .action = .paste_start },
    .{ .pattern = "\x1b[201~", .action = .paste_end },

    // xterm-style Alt+Arrow
    .{ .pattern = "\x1b[1;3C", .action = .move_word_right },
    .{ .pattern = "\x1b[1;3D", .action = .move_word_left },

    // ESC + single letter (readline/emacs Alt+X form)
    .{ .pattern = "\x1bb",   .action = .move_word_left },
    .{ .pattern = "\x1bf",   .action = .move_word_right },
    .{ .pattern = "\x1b\r",  .action = .insert_newline },
    .{ .pattern = "\x1b\n",  .action = .insert_newline },
};

/// Bit-packed (sequence index << 16) | match-position-so-far. Lets us track
/// candidates compactly without a separate heap allocation.
const Candidate = u32;

fn packCand(idx: usize, pos: usize) Candidate {
    return @intCast((idx << 16) | pos);
}

fn candIdx(c: Candidate) usize {
    return c >> 16;
}

fn candPos(c: Candidate) usize {
    return c & 0xFFFF;
}

pub const Mode = enum {
    /// Not in an escape sequence.
    ground,
    /// Saw ESC; awaiting next byte to decide single-letter form or CSI.
    escape,
    /// Saw ESC [; consuming parameter bytes and waiting for CSI final byte.
    csi,
};

/// Table-driven ANSI/VT escape sequence parser. Feed it one byte at a time;
/// it returns a `Step` describing whether the byte was part of a sequence
/// and whether a recognised sequence completed. Unknown CSI sequences are
/// silently consumed up to their final byte (range 0x40..0x7E) per ECMA-48.
pub const Parser = struct {
    mode: Mode = .ground,
    candidates: [SEQUENCES.len]Candidate = undefined,
    candidate_count: usize = 0,

    pub fn process(self: *Parser, byte: u8) Step {
        switch (self.mode) {
            .ground => {
                if (byte != 0x1b) return .not_escape;
                self.mode = .escape;
                self.seedCandidates();
                return .consumed;
            },
            .escape => {
                if (self.advance(byte)) |action| {
                    self.reset();
                    return .{ .action = action };
                }
                if (byte == '[') {
                    self.mode = .csi;
                    return .consumed;
                }
                self.reset();
                return .consumed;
            },
            .csi => {
                if (self.advance(byte)) |action| {
                    self.reset();
                    return .{ .action = action };
                }
                if (byte >= 0x40 and byte <= 0x7E) {
                    self.reset();
                }
                return .consumed;
            },
        }
    }

    pub fn reset(self: *Parser) void {
        self.mode = .ground;
        self.candidate_count = 0;
    }

    fn seedCandidates(self: *Parser) void {
        self.candidate_count = 0;
        for (SEQUENCES, 0..) |seq, idx| {
            if (seq.pattern.len > 1) {
                self.candidates[self.candidate_count] = packCand(idx, 1);
                self.candidate_count += 1;
            }
        }
    }

    fn advance(self: *Parser, byte: u8) ?Action {
        var write_idx: usize = 0;
        var i: usize = 0;
        while (i < self.candidate_count) : (i += 1) {
            const cand = self.candidates[i];
            const idx = candIdx(cand);
            const pos = candPos(cand);
            const seq = SEQUENCES[idx];
            if (pos < seq.pattern.len and seq.pattern[pos] == byte) {
                if (pos + 1 == seq.pattern.len) {
                    return seq.action;
                }
                self.candidates[write_idx] = packCand(idx, pos + 1);
                write_idx += 1;
            }
        }
        self.candidate_count = write_idx;
        return null;
    }
};

fn expectAction(expected: Action, step: Step) !void {
    try std.testing.expect(step == .action);
    try std.testing.expectEqual(expected, step.action);
}

test "parser: not_escape on ordinary byte" {
    var p = Parser{};
    try std.testing.expectEqual(Step.not_escape, p.process('a'));
    try std.testing.expectEqual(Mode.ground, p.mode);
}

test "parser: arrow keys" {
    var p = Parser{};
    try std.testing.expectEqual(Step.consumed, p.process(0x1b));
    try std.testing.expectEqual(Mode.escape, p.mode);
    try std.testing.expectEqual(Step.consumed, p.process('['));
    try std.testing.expectEqual(Mode.csi, p.mode);
    try expectAction(.move_up, p.process('A'));
    try std.testing.expectEqual(Mode.ground, p.mode);
}

test "parser: home / end" {
    var p = Parser{};
    _ = p.process(0x1b);
    _ = p.process('[');
    try expectAction(.home, p.process('H'));

    _ = p.process(0x1b);
    _ = p.process('[');
    try expectAction(.end, p.process('F'));
}

test "parser: delete key (ESC [ 3 ~)" {
    var p = Parser{};
    _ = p.process(0x1b);
    _ = p.process('[');
    _ = p.process('3');
    try std.testing.expectEqual(Mode.csi, p.mode);
    try expectAction(.delete_forward, p.process('~'));
}

test "parser: bracketed paste markers" {
    var p = Parser{};
    _ = p.process(0x1b); _ = p.process('['); _ = p.process('2'); _ = p.process('0'); _ = p.process('0');
    try expectAction(.paste_start, p.process('~'));

    _ = p.process(0x1b); _ = p.process('['); _ = p.process('2'); _ = p.process('0'); _ = p.process('1');
    try expectAction(.paste_end, p.process('~'));
}

test "parser: ESC b / ESC f (readline Alt+arrow)" {
    var p = Parser{};
    _ = p.process(0x1b);
    try expectAction(.move_word_left, p.process('b'));

    _ = p.process(0x1b);
    try expectAction(.move_word_right, p.process('f'));
}

test "parser: ESC \\r / ESC \\n (Alt+Enter)" {
    var p = Parser{};
    _ = p.process(0x1b);
    try expectAction(.insert_newline, p.process('\r'));

    _ = p.process(0x1b);
    try expectAction(.insert_newline, p.process('\n'));
}

test "parser: xterm Alt+arrow (ESC [ 1 ; 3 C/D)" {
    var p = Parser{};
    for ("\x1b[1;3C") |b| {
        const step = p.process(b);
        if (b == 'C') try expectAction(.move_word_right, step);
    }

    for ("\x1b[1;3D") |b| {
        const step = p.process(b);
        if (b == 'D') try expectAction(.move_word_left, step);
    }
}

test "parser: Shift+Tab (ESC [ Z)" {
    var p = Parser{};
    _ = p.process(0x1b);
    _ = p.process('[');
    try expectAction(.dedent, p.process('Z'));
}

test "parser: unknown CSI sequence consumed up to final byte" {
    var p = Parser{};
    _ = p.process(0x1b);
    _ = p.process('[');
    try std.testing.expectEqual(Step.consumed, p.process('5'));
    try std.testing.expectEqual(Step.consumed, p.process('~'));
    try std.testing.expectEqual(Mode.ground, p.mode);
}

test "parser: incomplete escape resets on non-matching ESC X" {
    var p = Parser{};
    try std.testing.expectEqual(Step.consumed, p.process(0x1b));
    try std.testing.expectEqual(Mode.escape, p.mode);
    try std.testing.expectEqual(Step.consumed, p.process('x'));
    try std.testing.expectEqual(Mode.ground, p.mode);
}
