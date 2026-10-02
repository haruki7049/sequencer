//! Audio sample accumulation and equal-power micro-fade rendering engine.
//!
//! DSP & Rendering Architecture:
//! 1. Equal-Power Gain Computation (`computeGain`): Calculates instant frame gain multipliers using
//!    trigonometric equal-power curves (`sin(t * pi/2)` for attack micro-fades, `cos(t * pi/2)` for
//!    release micro-fades) maintaining constant perceived power across note transitions.
//! 2. Multi-Channel Sample Mixing (`mixEvent` / `mixEventBlock`): Additively accumulates active scheduled event samples
//!    into the target buffer across all audio channels (mono/stereo).
//! 3. Composite Wave Synthesis (`render`): Allocates output sample buffer up to `max_frame_end`,
//!    mixes all scheduled track events, and returns the unified `lightmix.Wave(T)`.
//! 4. Block-Based Stream Rendering (`renderStream` / `BlockIterator`):
//!    Yields audio chunks in fixed-size blocks (e.g. 4096 frames) with O(1) peak memory consumption.

const std = @import("std");
const lightmix = @import("lightmix");
const Track = @import("track.zig").inner;
const VoiceScheduler = @import("voice-scheduler.zig").inner;

/// Configuration options for block-based stream rendering.
pub const StreamOptions = struct {
    /// Number of frames per chunk/block (default: 4096 frames).
    block_size: usize = 4096,
};

/// Returns a Renderer type parameterized by sample floating-point type T.
pub fn inner(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Scheduler = VoiceScheduler(T);
        pub const ScheduledEvent = Scheduler.ScheduledEvent;

        /// Computes equal-power micro-fade gain (`sin`/`cos` curve) for a specific frame index within a scheduled event.
        pub fn computeGain(se: ScheduledEvent, frame_idx: usize) T {
            var gain: T = 1.0;
            if (se.has_attack_fade and frame_idx < se.attack_fade_len and se.attack_fade_len > 0) {
                const attack_progress = @as(f64, @floatFromInt(frame_idx + 1)) / @as(f64, @floatFromInt(se.attack_fade_len));
                gain *= @as(T, @floatCast(@sin(attack_progress * (std.math.pi / 2.0))));
            }
            if (se.has_fade and frame_idx >= se.fade_start_offset and se.actual_fade_len > 0) {
                const fade_idx = frame_idx - se.fade_start_offset;
                const progress = @as(f64, @floatFromInt(fade_idx + 1)) / @as(f64, @floatFromInt(se.actual_fade_len));
                gain *= @as(T, @floatCast(@cos(progress * (std.math.pi / 2.0))));
            }
            return gain;
        }

        /// Mixes an active scheduled event interval into a chunk/block sample buffer with equal-power micro-fade gains.
        /// Audio frames outside micro-fade boundaries bypass trigonometric gain computation for direct additive mixing.
        pub fn mixEventBlock(
            block_samples: []T,
            channels: u16,
            event_wave: lightmix.Wave(T),
            se: ScheduledEvent,
            block_start_frame: usize,
            overlap_start_frame: usize,
            raw_overlap_end_frame: usize,
        ) void {
            if (channels == 0) return;
            const max_event_frames = event_wave.samples.len / channels;
            const overlap_end_frame = @min(raw_overlap_end_frame, se.start_frame + max_event_frames);
            if (overlap_start_frame >= overlap_end_frame) return;

            const event_attack_end = if (se.has_attack_fade and se.attack_fade_len > 0)
                se.start_frame + se.attack_fade_len
            else
                se.start_frame;

            const event_fade_start = if (se.has_fade and se.actual_fade_len > 0)
                se.start_frame + se.fade_start_offset
            else
                se.start_frame + se.active_frames;

            // If attack fade and release fade overlap or meet without steady state, fall back to per-frame computeGain.
            if (event_attack_end >= event_fade_start) {
                mixGainedRange(block_samples, channels, event_wave, se, block_start_frame, overlap_start_frame, overlap_end_frame);
                return;
            }

            // Piecewise intervals:
            // 1. Attack interval: [overlap_start_frame, attack_end)
            const attack_end = std.math.clamp(event_attack_end, overlap_start_frame, overlap_end_frame);
            mixGainedRange(block_samples, channels, event_wave, se, block_start_frame, overlap_start_frame, attack_end);

            // 2. Steady-state interval: [attack_end, steady_end)
            const steady_end = std.math.clamp(event_fade_start, attack_end, overlap_end_frame);
            if (steady_end > attack_end) {
                const count = (steady_end - attack_end) * channels;
                const start_dest_idx = (attack_end - block_start_frame) * channels;
                const start_frame_idx = (attack_end - se.start_frame) * channels;
                const dst = block_samples[start_dest_idx .. start_dest_idx + count];
                const src = event_wave.samples[start_frame_idx .. start_frame_idx + count];
                for (dst, src) |*d, s| {
                    d.* += s;
                }
            }

            // 3. Fade-out interval: [steady_end, overlap_end_frame)
            mixGainedRange(block_samples, channels, event_wave, se, block_start_frame, steady_end, overlap_end_frame);
        }

        /// Mixes the frame range [start_frame, end_frame) of an event into a block buffer, applying `computeGain` per frame.
        inline fn mixGainedRange(
            block_samples: []T,
            channels: u16,
            event_wave: lightmix.Wave(T),
            se: ScheduledEvent,
            block_start_frame: usize,
            start_frame: usize,
            end_frame: usize,
        ) void {
            for (start_frame..end_frame) |current_frame| {
                const frame_idx = current_frame - se.start_frame;
                const block_frame = current_frame - block_start_frame;
                const gain = computeGain(se, frame_idx);

                for (0..channels) |ch| {
                    const sample_val = event_wave.samples[frame_idx * channels + ch] * gain;
                    block_samples[block_frame * channels + ch] += sample_val;
                }
            }
        }

        /// Mixes an active scheduled event into the destination sample buffer with equal-power micro-fade gains.
        pub fn mixEvent(
            samples: []T,
            channels: u16,
            event_wave: lightmix.Wave(T),
            se: ScheduledEvent,
        ) void {
            if (se.active_frames == 0) return;
            mixEventBlock(
                samples,
                channels,
                event_wave,
                se,
                0,
                se.start_frame,
                se.start_frame + se.active_frames,
            );
        }

        /// Allocates sample buffer and renders scheduled track events into a lightmix.Wave(T).
        /// Reuses full-span background event sample buffer as base accumulation buffer when available.
        pub fn render(
            allocator: std.mem.Allocator,
            sample_rate: u32,
            channels: u16,
            tracks: []const Track(T),
            track_schedules: []const []const ScheduledEvent,
            max_frame_end: usize,
        ) !lightmix.Wave(T) {
            if (max_frame_end == 0) {
                return error.EmptySong;
            }

            const total_samples = max_frame_end * channels;

            var base_tr_idx: ?usize = null;
            var base_se_idx: ?usize = null;

            find_base: for (tracks, 0..) |tr, tr_idx| {
                for (track_schedules[tr_idx], 0..) |se, se_idx| {
                    if (se.start_frame == 0 and
                        se.active_frames == max_frame_end and
                        !se.has_attack_fade and
                        !se.has_fade and
                        se.event_index < tr.events.items.len)
                    {
                        const ev = &tr.events.items[se.event_index];
                        if (ev.owned and ev.wave.samples.len == total_samples) {
                            base_tr_idx = tr_idx;
                            base_se_idx = se_idx;
                            break :find_base;
                        }
                    }
                }
            }

            var samples: []T = undefined;
            if (base_tr_idx) |b_tr| {
                const b_se = base_se_idx.?;
                const b_event_idx = track_schedules[b_tr][b_se].event_index;
                const base_ev = &@constCast(tracks)[b_tr].events.items[b_event_idx];
                samples = @constCast(base_ev.wave.samples);
                base_ev.owned = false;
            } else {
                samples = try allocator.alloc(T, total_samples);
                @memset(samples, 0);
            }

            for (tracks, 0..) |tr, tr_idx| {
                for (track_schedules[tr_idx], 0..) |se, se_idx| {
                    if (se.active_frames == 0) continue;
                    if (base_tr_idx) |b_tr| {
                        if (tr_idx == b_tr and se_idx == base_se_idx.?) continue;
                    }
                    const event = tr.events.items[se.event_index];
                    mixEvent(samples, channels, event.wave, se);
                }
            }

            return lightmix.Wave(T){
                .allocator = allocator,
                .sample_rate = sample_rate,
                .channels = channels,
                .samples = samples,
            };
        }

        /// Iterator that renders scheduled track events in fixed-size blocks to bound peak memory consumption.
        pub const BlockIterator = struct {
            allocator: std.mem.Allocator,
            sample_rate: u32,
            channels: u16,
            tracks: []const Track(T),
            track_schedules: []const []const ScheduledEvent,
            total_frames: usize,
            block_size: usize,
            current_frame: usize,
            block_buffer: []T,

            /// Initializes a BlockIterator, preallocating a single reusable buffer of `block_size * channels` samples.
            pub fn init(
                allocator: std.mem.Allocator,
                sample_rate: u32,
                channels: u16,
                tracks: []const Track(T),
                track_schedules: []const []const ScheduledEvent,
                total_frames: usize,
                options: StreamOptions,
            ) (error{ EmptySong, InvalidChannelCount } || std.mem.Allocator.Error)!BlockIterator {
                if (channels == 0) return error.InvalidChannelCount;
                if (total_frames == 0) return error.EmptySong;

                const bs = if (options.block_size == 0) 4096 else options.block_size;
                const buffer_len = bs * channels;
                const buf = try allocator.alloc(T, buffer_len);
                errdefer allocator.free(buf);

                return BlockIterator{
                    .allocator = allocator,
                    .sample_rate = sample_rate,
                    .channels = channels,
                    .tracks = tracks,
                    .track_schedules = track_schedules,
                    .total_frames = total_frames,
                    .block_size = bs,
                    .current_frame = 0,
                    .block_buffer = buf,
                };
            }

            /// Frees the internal block buffer.
            pub fn deinit(self: *BlockIterator) void {
                self.allocator.free(self.block_buffer);
            }

            /// Resets the block iterator position back to frame 0 for multi-pass streaming.
            pub fn reset(self: *BlockIterator) void {
                self.current_frame = 0;
            }

            /// Renders and yields the next block of multi-channel audio samples.
            ///
            /// Returns `null` when stream rendering completes across the entire timeline.
            pub fn next(self: *BlockIterator) ?[]const T {
                if (self.current_frame >= self.total_frames) {
                    return null;
                }

                const remaining_frames = self.total_frames - self.current_frame;
                const chunk_frames = @min(remaining_frames, self.block_size);
                const chunk_samples = self.block_buffer[0 .. chunk_frames * self.channels];
                @memset(chunk_samples, 0);

                const block_start = self.current_frame;
                const block_end = block_start + chunk_frames;

                for (self.tracks, 0..) |tr, tr_idx| {
                    for (self.track_schedules[tr_idx]) |se| {
                        if (se.active_frames == 0) continue;
                        const event_start = se.start_frame;
                        const event_end = event_start + se.active_frames;

                        if (event_end <= block_start or event_start >= block_end) {
                            continue;
                        }

                        const overlap_start = @max(event_start, block_start);
                        const overlap_end = @min(event_end, block_end);
                        const event = tr.events.items[se.event_index];

                        mixEventBlock(
                            chunk_samples,
                            self.channels,
                            event.wave,
                            se,
                            block_start,
                            overlap_start,
                            overlap_end,
                        );
                    }
                }

                self.current_frame += chunk_frames;
                return chunk_samples;
            }
        };

        /// Initializes a block-based stream rendering iterator for memory-efficient chunked rendering.
        pub fn renderStream(
            allocator: std.mem.Allocator,
            sample_rate: u32,
            channels: u16,
            tracks: []const Track(T),
            track_schedules: []const []const ScheduledEvent,
            max_frame_end: usize,
            options: StreamOptions,
        ) !BlockIterator {
            return BlockIterator.init(
                allocator,
                sample_rate,
                channels,
                tracks,
                track_schedules,
                max_frame_end,
                options,
            );
        }
    };
}

test "Renderer computeGain with no fades returns 1.0" {
    const TheRenderer = inner(f64);
    const se: TheRenderer.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 100,
        .fade_start_offset = 100,
        .actual_fade_len = 0,
        .has_fade = false,
        .has_attack_fade = false,
        .attack_fade_len = 0,
    };

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), TheRenderer.computeGain(se, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), TheRenderer.computeGain(se, 50), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), TheRenderer.computeGain(se, 99), 0.0001);
}

test "Renderer computeGain with attack fade follows sine curve" {
    const TheRenderer = inner(f64);
    const se: TheRenderer.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 100,
        .fade_start_offset = 100,
        .actual_fade_len = 0,
        .has_fade = false,
        .has_attack_fade = true,
        .attack_fade_len = 100,
    };

    // frame 0: (1/100) * pi/2 => sin
    const expected_start = @sin(1.0 / 100.0 * (std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(expected_start, TheRenderer.computeGain(se, 0), 0.0001);

    // frame 99: (100/100) * pi/2 = pi/2 => sin = 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), TheRenderer.computeGain(se, 99), 0.0001);
}

test "Renderer computeGain with decay fade follows cosine curve" {
    const TheRenderer = inner(f64);
    const se: TheRenderer.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 100,
        .fade_start_offset = 80,
        .actual_fade_len = 20,
        .has_fade = true,
        .has_attack_fade = false,
        .attack_fade_len = 0,
    };

    // Before fade start: gain = 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), TheRenderer.computeGain(se, 79), 0.0001);

    // At fade start (frame 80): (1/20) * pi/2 => cos
    const expected_fade_start = @cos(1.0 / 20.0 * (std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(expected_fade_start, TheRenderer.computeGain(se, 80), 0.0001);

    // At final fade frame (frame 99): (20/20) * pi/2 => cos(pi/2) = 0.0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), TheRenderer.computeGain(se, 99), 0.0001);
}

test "Renderer mixEvent accumulates multi-channel samples with gain" {
    const allocator = std.testing.allocator;
    const TheRenderer = inner(f64);

    const wave_samples = try allocator.alloc(f64, 4);
    wave_samples[0] = 0.5; // frame 0, ch 0
    wave_samples[1] = 0.8; // frame 0, ch 1
    wave_samples[2] = 0.6; // frame 1, ch 0
    wave_samples[3] = 0.9; // frame 1, ch 1
    const wave = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = wave_samples,
    };
    defer wave.deinit();

    const dest = try allocator.alloc(f64, 8);
    @memset(dest, 0.1);
    defer allocator.free(dest);

    const se: TheRenderer.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 1,
        .active_frames = 2,
        .fade_start_offset = 2,
        .actual_fade_len = 0,
        .has_fade = false,
        .has_attack_fade = false,
        .attack_fade_len = 0,
    };

    TheRenderer.mixEvent(dest, 2, wave, se);

    // Frame 0 of dest (start_frame=1 so frame 0 is untouched)
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), dest[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), dest[1], 0.0001);

    // Frame 1 of dest: 0.1 + 0.5 = 0.6, 0.1 + 0.8 = 0.9
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), dest[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), dest[3], 0.0001);

    // Frame 2 of dest: 0.1 + 0.6 = 0.7, 0.1 + 0.9 = 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), dest[4], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), dest[5], 0.0001);
}

test "Renderer render empty max_frame_end returns error.EmptySong" {
    const allocator = std.testing.allocator;
    const TheRenderer = inner(f64);
    const result = TheRenderer.render(allocator, 44100, 2, &[_]Track(f64){}, &[_][]const TheRenderer.ScheduledEvent{}, 0);
    try std.testing.expectError(error.EmptySong, result);
}

test "Renderer renderStream empty max_frame_end returns error.EmptySong" {
    const allocator = std.testing.allocator;
    const TheRenderer = inner(f64);
    const result = TheRenderer.renderStream(allocator, 44100, 2, &[_]Track(f64){}, &[_][]const TheRenderer.ScheduledEvent{}, 0, .{});
    try std.testing.expectError(error.EmptySong, result);
}

test "Renderer renderStream zero channels returns error.InvalidChannelCount" {
    const allocator = std.testing.allocator;
    const TheRenderer = inner(f64);
    const result = TheRenderer.renderStream(allocator, 44100, 0, &[_]Track(f64){}, &[_][]const TheRenderer.ScheduledEvent{}, 100, .{});
    try std.testing.expectError(error.InvalidChannelCount, result);
}

test "Renderer renderStream produces bitwise identical output to render() across various block sizes" {
    const allocator = std.testing.allocator;
    const TheRenderer = inner(f64);

    // Track 1
    var track1 = Track(f64).init("Track1");
    defer track1.deinit(allocator);

    const wave1_samples = try allocator.alloc(f64, 40); // 20 frames stereo
    for (0..20) |f| {
        wave1_samples[f * 2] = @as(f64, @floatFromInt(f + 1)) * 0.05;
        wave1_samples[f * 2 + 1] = @as(f64, @floatFromInt(f + 1)) * -0.05;
    }
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = wave1_samples,
    };
    try track1.add(allocator, wave1, .{ .bar = 0, .beat = 0 });

    // Track 2
    var track2 = Track(f64).init("Track2");
    defer track2.deinit(allocator);

    const wave2_samples = try allocator.alloc(f64, 30); // 15 frames stereo
    for (0..15) |f| {
        wave2_samples[f * 2] = 0.2;
        wave2_samples[f * 2 + 1] = 0.3;
    }
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = wave2_samples,
    };
    try track2.add(allocator, wave2, .{ .bar = 0, .beat = 1 });

    const tracks = [_]Track(f64){ track1, track2 };

    const se1: TheRenderer.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 5,
        .active_frames = 20,
        .fade_start_offset = 15,
        .actual_fade_len = 5,
        .has_fade = true,
        .has_attack_fade = true,
        .attack_fade_len = 5,
    };

    const se2: TheRenderer.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 15,
        .active_frames = 15,
        .fade_start_offset = 10,
        .actual_fade_len = 5,
        .has_fade = true,
        .has_attack_fade = false,
        .attack_fade_len = 0,
    };

    const track1_events = [_]TheRenderer.ScheduledEvent{se1};
    const track2_events = [_]TheRenderer.ScheduledEvent{se2};
    const track_schedules = [_][]const TheRenderer.ScheduledEvent{
        &track1_events,
        &track2_events,
    };

    const max_frame_end: usize = 30;

    // 1. One-shot baseline render
    const baseline_wave = try TheRenderer.render(
        allocator,
        44100,
        2,
        &tracks,
        &track_schedules,
        max_frame_end,
    );
    defer baseline_wave.deinit();

    try std.testing.expectEqual(@as(usize, 60), baseline_wave.samples.len);

    // 2. Test stream rendering across various block sizes
    const test_block_sizes = [_]usize{ 1, 2, 3, 7, 16, 30, 64, 4096 };
    for (test_block_sizes) |bs| {
        var iter = try TheRenderer.renderStream(
            allocator,
            44100,
            2,
            &tracks,
            &track_schedules,
            max_frame_end,
            .{ .block_size = bs },
        );
        defer iter.deinit();

        var streamed_samples: std.ArrayList(f64) = .empty;
        defer streamed_samples.deinit(allocator);

        while (iter.next()) |chunk| {
            try streamed_samples.appendSlice(allocator, chunk);
        }

        // Post-termination call must return null
        try std.testing.expect(iter.next() == null);

        // Bitwise identity check
        try std.testing.expectEqual(baseline_wave.samples.len, streamed_samples.items.len);
        try std.testing.expectEqualSlices(f64, baseline_wave.samples, streamed_samples.items);
    }
}

test "Renderer BlockIterator bounded O(1) buffer allocation" {
    const allocator = std.testing.allocator;
    const TheRenderer = inner(f64);

    var track = Track(f64).init("Track");
    defer track.deinit(allocator);

    const wave_samples = try allocator.alloc(f64, 20);
    @memset(wave_samples, 0.1);
    const wave = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = wave_samples,
    };
    try track.add(allocator, wave, .{ .bar = 0, .beat = 0 });

    const se: TheRenderer.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 10,
        .fade_start_offset = 10,
        .actual_fade_len = 0,
        .has_fade = false,
        .has_attack_fade = false,
        .attack_fade_len = 0,
    };
    const events = [_]TheRenderer.ScheduledEvent{se};
    const schedules = [_][]const TheRenderer.ScheduledEvent{&events};
    const tracks = [_]Track(f64){track};

    const huge_frame_count: usize = 10_000_000;
    const block_size: usize = 256;
    var iter = try TheRenderer.renderStream(
        allocator,
        44100,
        2,
        &tracks,
        &schedules,
        huge_frame_count,
        .{ .block_size = block_size },
    );
    defer iter.deinit();

    // The allocated buffer length must be block_size * channels, strictly bounded independent of total_frames
    try std.testing.expectEqual(block_size * 2, iter.block_buffer.len);
}

test "Renderer renderStream with f80 sample type" {
    const allocator = std.testing.allocator;
    const TheRenderer = inner(f80);

    var track = Track(f80).init("Track80");
    defer track.deinit(allocator);

    const wave_samples = try allocator.alloc(f80, 8);
    @memset(wave_samples, 0.42);
    const wave = lightmix.Wave(f80){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = wave_samples,
    };
    try track.add(allocator, wave, .{ .bar = 0, .beat = 0 });

    const se: TheRenderer.ScheduledEvent = .{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 8,
        .fade_start_offset = 8,
        .actual_fade_len = 0,
        .has_fade = false,
        .has_attack_fade = false,
        .attack_fade_len = 0,
    };
    const events = [_]TheRenderer.ScheduledEvent{se};
    const schedules = [_][]const TheRenderer.ScheduledEvent{&events};
    const tracks = [_]Track(f80){track};

    var iter = try TheRenderer.renderStream(
        allocator,
        44100,
        1,
        &tracks,
        &schedules,
        8,
        .{ .block_size = 4 },
    );
    defer iter.deinit();

    var count: usize = 0;
    while (iter.next()) |chunk| {
        count += chunk.len;
    }
    try std.testing.expectEqual(@as(usize, 8), count);
}

test "Renderer mixEventBlock piecewise intervals match naive per-frame computeGain across all fade configurations" {
    const allocator = std.testing.allocator;
    const TheRenderer = inner(f64);

    const Helper = struct {
        fn naiveMix(
            dest: []f64,
            channels: u16,
            wave: lightmix.Wave(f64),
            se: TheRenderer.ScheduledEvent,
            block_start: usize,
            overlap_start: usize,
            overlap_end: usize,
        ) void {
            for (overlap_start..overlap_end) |current_frame| {
                const frame_idx = current_frame - se.start_frame;
                const block_frame = current_frame - block_start;
                const gain = TheRenderer.computeGain(se, frame_idx);
                for (0..channels) |ch| {
                    dest[block_frame * channels + ch] += wave.samples[frame_idx * channels + ch] * gain;
                }
            }
        }
    };

    const channels: u16 = 2;
    const total_event_frames: usize = 100;
    const total_samples = total_event_frames * channels;

    const wave_samples = try allocator.alloc(f64, total_samples);
    defer allocator.free(wave_samples);
    for (0..total_event_frames) |f| {
        wave_samples[f * channels] = @as(f64, @floatFromInt(f + 1)) * 0.01;
        wave_samples[f * channels + 1] = @as(f64, @floatFromInt(f + 1)) * -0.01;
    }
    const wave = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = channels,
        .samples = wave_samples,
    };

    const TestCase = struct {
        name: []const u8,
        se: TheRenderer.ScheduledEvent,
    };

    const test_cases = [_]TestCase{
        .{
            .name = "Attack, steady-state, and fade-out non-overlapping",
            .se = .{
                .event_index = 0,
                .start_frame = 10,
                .active_frames = 100,
                .fade_start_offset = 70,
                .actual_fade_len = 30,
                .has_fade = true,
                .has_attack_fade = true,
                .attack_fade_len = 20,
            },
        },
        .{
            .name = "Attack fade only with remaining steady-state",
            .se = .{
                .event_index = 0,
                .start_frame = 10,
                .active_frames = 100,
                .fade_start_offset = 100,
                .actual_fade_len = 0,
                .has_fade = false,
                .has_attack_fade = true,
                .attack_fade_len = 25,
            },
        },
        .{
            .name = "Release fade only with initial steady-state",
            .se = .{
                .event_index = 0,
                .start_frame = 10,
                .active_frames = 100,
                .fade_start_offset = 60,
                .actual_fade_len = 40,
                .has_fade = true,
                .has_attack_fade = false,
                .attack_fade_len = 0,
            },
        },
        .{
            .name = "No fades (pure steady-state bypass throughout)",
            .se = .{
                .event_index = 0,
                .start_frame = 10,
                .active_frames = 100,
                .fade_start_offset = 100,
                .actual_fade_len = 0,
                .has_fade = false,
                .has_attack_fade = false,
                .attack_fade_len = 0,
            },
        },
        .{
            .name = "Overlapping attack and release fade (fallback branch)",
            .se = .{
                .event_index = 0,
                .start_frame = 10,
                .active_frames = 50,
                .fade_start_offset = 20,
                .actual_fade_len = 30,
                .has_fade = true,
                .has_attack_fade = true,
                .attack_fade_len = 35,
            },
        },
    };

    const actual = try allocator.alloc(f64, 120 * channels);
    defer allocator.free(actual);
    const expected = try allocator.alloc(f64, 120 * channels);
    defer allocator.free(expected);

    for (test_cases) |tc| {
        // 1. Full single-block render test
        @memset(actual, 0.25);
        @memset(expected, 0.25);

        TheRenderer.mixEventBlock(
            actual,
            channels,
            wave,
            tc.se,
            tc.se.start_frame,
            tc.se.start_frame,
            tc.se.start_frame + tc.se.active_frames,
        );

        Helper.naiveMix(
            expected,
            channels,
            wave,
            tc.se,
            tc.se.start_frame,
            tc.se.start_frame,
            tc.se.start_frame + tc.se.active_frames,
        );

        try std.testing.expectEqualSlices(f64, expected, actual);

        // 2. Chunked block render across arbitrary block sizes (1, 7, 13, 32)
        const chunk_sizes = [_]usize{ 1, 7, 13, 32 };
        for (chunk_sizes) |chunk_size| {
            @memset(actual, 0.0);
            @memset(expected, 0.0);

            var frame = tc.se.start_frame;
            const end_frame = tc.se.start_frame + tc.se.active_frames;

            while (frame < end_frame) {
                const next_frame = @min(frame + chunk_size, end_frame);
                TheRenderer.mixEventBlock(
                    actual,
                    channels,
                    wave,
                    tc.se,
                    0,
                    frame,
                    next_frame,
                );
                Helper.naiveMix(
                    expected,
                    channels,
                    wave,
                    tc.se,
                    0,
                    frame,
                    next_frame,
                );
                frame = next_frame;
            }

            try std.testing.expectEqualSlices(f64, expected, actual);
        }
    }
}

test "renderer reuses owned full-span base track event buffer" {
    const allocator = std.testing.allocator;
    const RendererT = inner(f64);

    var tr = Track(f64).init("BaseTrack");
    defer tr.deinit(allocator);

    const base_samples = try allocator.alloc(f64, 100);
    @memset(base_samples, 0.5);
    const base_ptr = base_samples.ptr;

    const base_wave = lightmix.Wave(f64){
        .allocator = allocator,
        .samples = base_samples,
        .sample_rate = 44100,
        .channels = 1,
    };
    try tr.add(allocator, base_wave, .{ .bar = 0, .beat = 0.0 });

    const tracks = [_]Track(f64){tr};
    const sched = [_]RendererT.ScheduledEvent{.{
        .event_index = 0,
        .start_frame = 0,
        .active_frames = 100,
        .fade_start_offset = 100,
        .actual_fade_len = 0,
        .has_fade = false,
        .attack_fade_len = 0,
        .has_attack_fade = false,
    }};
    const track_schedules = [_][]const RendererT.ScheduledEvent{&sched};

    var result = try RendererT.render(allocator, 44100, 1, &tracks, &track_schedules, 100);
    defer result.deinit();

    try std.testing.expectEqual(base_ptr, result.samples.ptr);
    try std.testing.expectEqual(@as(usize, 100), result.samples.len);
    try std.testing.expectEqual(@as(f64, 0.5), result.samples[0]);
}

test {
    std.testing.refAllDecls(@This());
}
