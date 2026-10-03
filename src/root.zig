//! Multi-track event sequencer and renderer.
//!
//! Schedules `lightmix.Wave` events at musical positions (`meters.Position`) on monophonic tracks,
//! groups tracks into multi-string instruments (`resonator.Instrument`), truncates overlapping voices
//! with equal-power micro-fades, and renders the result into a single wave or a block stream.

const std = @import("std");

pub const Event = @import("event.zig").inner;
pub const Track = @import("track.zig").inner;
pub const VoiceScheduler = @import("voice-scheduler.zig").inner;
pub const Renderer = @import("renderer.zig").inner;
pub const StreamOptions = @import("renderer.zig").StreamOptions;
pub const Sequencer = @import("sequencer.zig").inner;
/// Re-exported from `resonator`: the instrument type used by `Sequencer.createInstrument`.
pub const Instrument = @import("resonator").Instrument;

test {
    std.testing.refAllDecls(@This());
    _ = @import("event.zig");
    _ = @import("track.zig");
    _ = @import("voice-scheduler.zig");
    _ = @import("renderer.zig");
    _ = @import("sequencer.zig");
}

test "meters types are shared with resonator" {
    // resonator and sequencer must resolve to the same `meters` package so positions flow between them.
    try std.testing.expect(@import("resonator").meters.Position == @import("meters").Position);
    try std.testing.expect(@import("resonator").meters.TimeSignature == @import("meters").TimeSignature);
}
