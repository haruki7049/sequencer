//! Track voice priority scheduling, overlap detection, and micro-fade curve boundary calculation.
//!
//! Single String Model & Micro-Fade Architecture:
//! 1. Timeline Scheduling: Converts event musical positions (bar/beat) into absolute sample frame offsets,
//!    sorting track events in chronological onset order.
//! 2. Voice Collision & Truncation: Implements the Single String Model where a single track or instrument
//!    string represents a monophonic voice. If a subsequent note triggers before the current note finishes,
//!    `VoiceScheduler` truncates `active_frames` of the preceding note.
//! 3. Equal-Power Micro-Fades: Calculates equal-power release micro-fades (`cos` curve) on truncated
//!    note tails and equal-power attack micro-fades (`sin` curve) on interrupting note onsets,
//!    eliminating click transients and DC discontinuities during rapid note transitions.

const std = @import("std");
const Position = @import("meters").Position;
const TimeSignature = @import("meters").TimeSignature;
const Track = @import("track.zig").inner;

/// Returns a VoiceScheduler type parameterized by sample floating-point type T.
pub fn inner(comptime T: type) type {
    return struct {
        /// Scheduled event metadata defining truncated frame bounds and micro-fade curve offsets.
        pub const ScheduledEvent = struct {
            event_index: usize,
            start_frame: usize,
            active_frames: usize,
            fade_start_offset: usize,
            actual_fade_len: usize,
            has_fade: bool,
            has_attack_fade: bool,
            attack_fade_len: usize,
        };

        const Entry = struct {
            start_frame: usize,
            wave_frames: usize,
            event_index: usize,
            active_frames: usize = 0,
            fade_start_offset: usize = 0,
            actual_fade_len: usize = 0,
            has_fade: bool = false,
            has_attack_fade: bool = false,
            attack_fade_len: usize = 0,
        };

        /// Analyzes track events and computes onset frames, overlap truncations, and micro-fade schedules.
        pub fn scheduleTrack(
            allocator: std.mem.Allocator,
            tr: Track(T),
            bpm: usize,
            time_signature: TimeSignature,
            sample_rate: u32,
            channels: u16,
            fade_frames: usize,
        ) ![]ScheduledEvent {
            if (tr.events.items.len == 0) {
                return &[_]ScheduledEvent{};
            }

            var entries = try allocator.alloc(Entry, tr.events.items.len);
            defer allocator.free(entries);

            for (tr.events.items, 0..) |event, idx| {
                const sf = try event.position.toSampleOffset(bpm, time_signature, sample_rate);
                entries[idx] = .{
                    .start_frame = sf,
                    .wave_frames = event.wave.samples.len / channels,
                    .event_index = idx,
                };
            }

            const sortFn = struct {
                fn lessThan(_: void, a: Entry, b: Entry) bool {
                    if (a.start_frame == b.start_frame) {
                        return a.event_index < b.event_index;
                    }
                    return a.start_frame < b.start_frame;
                }
            }.lessThan;
            std.mem.sort(Entry, entries, {}, sortFn);

            for (entries, 0..) |*entry, i| {
                const sf = entry.start_frame;
                const wf = entry.wave_frames;

                var active_frames = wf;
                var has_fade = false;
                var fade_start_offset: usize = wf;

                if (i + 1 < entries.len) {
                    const next_sf = entries[i + 1].start_frame;
                    if (next_sf <= sf) {
                        // Superseded by subsequent event at the same start frame
                        active_frames = 0;
                    } else if (next_sf < sf + wf) {
                        const overlap_offset = next_sf - sf;
                        fade_start_offset = overlap_offset;
                        const remaining = wf - overlap_offset;
                        var actual_fade = @min(fade_frames, remaining);

                        // Clamp fade if note i+2 starts before this fade finishes
                        if (i + 2 < entries.len) {
                            const next_next_sf = entries[i + 2].start_frame;
                            if (next_sf + actual_fade > next_next_sf) {
                                actual_fade = if (next_next_sf > next_sf) (next_next_sf - next_sf) else 0;
                            }
                        }

                        active_frames = overlap_offset + actual_fade;
                        has_fade = (actual_fade > 0);
                    }
                }

                entry.active_frames = active_frames;
                entry.fade_start_offset = fade_start_offset;
                entry.actual_fade_len = if (has_fade) (active_frames - fade_start_offset) else 0;
                entry.has_fade = has_fade;

                if (tr.enable_attack_fade and active_frames > 0 and i > 0) {
                    var k: usize = i;
                    while (k > 0) {
                        k -= 1;
                        const prev_active = entries[k].active_frames;
                        if (prev_active > 0) {
                            const prev_end = entries[k].start_frame + prev_active;
                            if (prev_end > sf and sf > entries[k].start_frame) {
                                entry.has_attack_fade = true;
                                entry.attack_fade_len = @min(fade_frames, active_frames);
                            }
                            break;
                        }
                    }
                }
            }

            var result = try allocator.alloc(ScheduledEvent, entries.len);
            for (entries, 0..) |e, i| {
                result[i] = .{
                    .event_index = e.event_index,
                    .start_frame = e.start_frame,
                    .active_frames = e.active_frames,
                    .fade_start_offset = e.fade_start_offset,
                    .actual_fade_len = e.actual_fade_len,
                    .has_fade = e.has_fade,
                    .has_attack_fade = e.has_attack_fade,
                    .attack_fade_len = e.attack_fade_len,
                };
            }
            return result;
        }
    };
}

test "VoiceScheduler resolves single string truncation and micro-fade windows" {
    const lightmix = @import("lightmix");
    const allocator = std.testing.allocator;

    var tr = Track(f64).init("TestTrack");
    defer tr.deinit(allocator);

    const samples1 = try allocator.alloc(f64, 44100 * 2);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    try tr.add(allocator, wave1, .{ .bar = 0, .beat = 0.0 });
    try tr.add(allocator, wave2, .{ .bar = 0, .beat = 1.0 }); // starts at frame 44100

    const Scheduler = inner(f64);
    const scheduled = try Scheduler.scheduleTrack(allocator, tr, 60, .{}, 44100, 1, 220);
    defer allocator.free(scheduled);

    try std.testing.expectEqual(@as(usize, 2), scheduled.len);

    // Note 1: start_frame 0, truncated at 44100 + 220 = 44320
    try std.testing.expectEqual(@as(usize, 0), scheduled[0].start_frame);
    try std.testing.expectEqual(@as(usize, 44320), scheduled[0].active_frames);
    try std.testing.expect(scheduled[0].has_fade);
    try std.testing.expectEqual(@as(usize, 44100), scheduled[0].fade_start_offset);
    try std.testing.expectEqual(@as(usize, 220), scheduled[0].actual_fade_len);

    // Note 2: start_frame 44100, full duration 44100, has attack fade
    try std.testing.expectEqual(@as(usize, 44100), scheduled[1].start_frame);
    try std.testing.expectEqual(@as(usize, 44100), scheduled[1].active_frames);
    try std.testing.expect(scheduled[1].has_attack_fade);
    try std.testing.expectEqual(@as(usize, 220), scheduled[1].attack_fade_len);
}

test "VoiceScheduler honors enable_attack_fade = false" {
    const lightmix = @import("lightmix");
    const allocator = std.testing.allocator;

    var tr = Track(f64).init("TestTrack");
    tr.enable_attack_fade = false;
    defer tr.deinit(allocator);

    const samples1 = try allocator.alloc(f64, 44100 * 2);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    try tr.add(allocator, wave1, .{ .bar = 0, .beat = 0.0 });
    try tr.add(allocator, wave2, .{ .bar = 0, .beat = 1.0 });

    const Scheduler = inner(f64);
    const scheduled = try Scheduler.scheduleTrack(allocator, tr, 60, .{}, 44100, 1, 220);
    defer allocator.free(scheduled);

    try std.testing.expectEqual(@as(usize, 2), scheduled.len);
    try std.testing.expect(!scheduled[1].has_attack_fade);
    try std.testing.expectEqual(@as(usize, 0), scheduled[1].attack_fade_len);
}

test {
    std.testing.refAllDecls(@This());
}
