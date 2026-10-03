//! Sequencer event binding an audio Wave to a musical Position.

const std = @import("std");
const lightmix = @import("lightmix");
const Position = @import("meters").Position;

/// Returns an Event type parameterized by sample floating-point type T.
pub fn inner(comptime T: type) type {
    return struct {
        wave: lightmix.Wave(T),
        position: Position,
        owned: bool = true,
    };
}

test {
    std.testing.refAllDecls(@This());
}
