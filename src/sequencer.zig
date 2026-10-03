//! Multi-track audio sequencer managing tempo, tracks, instruments, and wave rendering.

const std = @import("std");
const lightmix = @import("lightmix");
const Position = @import("meters").Position;
const TimeSignature = @import("meters").TimeSignature;
const Track = @import("track.zig").inner;
const Instrument = @import("resonator").Instrument;
const VoiceScheduler = @import("voice-scheduler.zig").inner;
const Renderer = @import("renderer.zig").inner;
const StreamOptions = @import("renderer.zig").StreamOptions;

/// Returns a Sequencer struct type parameterized by sample floating-point type T.
pub fn inner(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        bpm: usize,
        time_signature: TimeSignature,
        sample_rate: u32,
        channels: u16,
        tracks: std.ArrayList(Track(T)) = .empty,

        const Self = @This();

        /// Initializes a new Sequencer instance with global tempo, time signature, sample rate, and channels.
        pub fn init(
            allocator: std.mem.Allocator,
            bpm: usize,
            time_signature: TimeSignature,
            sample_rate: u32,
            channels: u16,
        ) Self {
            return .{
                .allocator = allocator,
                .bpm = bpm,
                .time_signature = time_signature,
                .sample_rate = sample_rate,
                .channels = channels,
                .tracks = .empty,
            };
        }

        /// Deinitializes sequencer tracks and frees associated event resources.
        pub fn deinit(self: *Self) void {
            for (self.tracks.items) |*tr| {
                tr.deinit(self.allocator);
            }
            self.tracks.deinit(self.allocator);
        }

        /// Creates and appends a new named track to the sequencer.
        pub fn createTrack(self: *Self, name: []const u8) !*Track(T) {
            try self.tracks.append(self.allocator, Track(T).init(name));
            return &self.tracks.items[self.tracks.items.len - 1];
        }

        /// Creates a multi-string instrument, allocating individual tracks for each string/voice.
        pub fn createInstrument(self: *Self, name: []const u8, string_count: usize) !Instrument {
            const start_idx = self.tracks.items.len;
            for (0..string_count) |_| {
                _ = try self.createTrack(name);
            }
            var indices = try self.allocator.alloc(usize, string_count);
            for (0..string_count) |i| {
                indices[i] = start_idx + i;
            }
            return Instrument.init(name, indices);
        }

        /// Returns a pointer to the track corresponding to a specific instrument string index.
        pub fn getInstrumentTrack(self: *Self, instrument: Instrument, string_index: usize) !*Track(T) {
            const idx = try instrument.getTrackIndex(string_index);
            return &self.tracks.items[idx];
        }

        /// Schedules an audio wave event onto a specific string of an instrument.
        pub fn addInstrument(
            self: *Self,
            instrument: Instrument,
            string_index: usize,
            wave: lightmix.Wave(T),
            position: Position,
        ) !void {
            const tr = try self.getInstrumentTrack(instrument, string_index);
            try self.add(tr, wave, position);
        }

        /// Schedules a borrowed audio wave event onto a specific string of an instrument.
        pub fn addInstrumentBorrowed(
            self: *Self,
            instrument: Instrument,
            string_index: usize,
            wave: lightmix.Wave(T),
            position: Position,
        ) !void {
            const tr = try self.getInstrumentTrack(instrument, string_index);
            try self.addBorrowed(tr, wave, position);
        }

        /// Schedules an audio wave event onto a target track at a specific position.
        pub fn add(self: *Self, target_track: *Track(T), wave: lightmix.Wave(T), position: Position) !void {
            try target_track.add(self.allocator, wave, position);
        }

        /// Schedules a borrowed audio wave event onto a target track at a specific position.
        pub fn addBorrowed(self: *Self, target_track: *Track(T), wave: lightmix.Wave(T), position: Position) !void {
            try target_track.addBorrowed(self.allocator, wave, position);
        }

        /// Per-track schedules produced by `scheduleAll`, plus the end frame of the last audible event.
        const Schedules = struct {
            allocator: std.mem.Allocator,
            tracks: [][]VoiceScheduler(T).ScheduledEvent,
            max_frame_end: usize,

            fn deinit(self: *Schedules) void {
                for (self.tracks) |sched| {
                    if (sched.len > 0) self.allocator.free(sched);
                }
                self.allocator.free(self.tracks);
            }
        };

        /// Validates every event's format and schedules all tracks once using VoiceScheduler.
        /// The caller owns the result and must call `deinit()` on it.
        fn scheduleAll(self: *Self) !Schedules {
            var total_events: usize = 0;

            // Validate all events format
            for (self.tracks.items) |tr| {
                for (tr.events.items) |event| {
                    total_events += 1;
                    if (event.wave.sample_rate != self.sample_rate or event.wave.channels != self.channels) {
                        return error.IncompatibleWaveFormat;
                    }
                }
            }

            if (total_events == 0) {
                return error.EmptySong;
            }

            // Default 5ms micro-fade frames (e.g. 220 samples at 44.1kHz)
            const fade_frames: usize = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.sample_rate)) * 0.005)));

            // Schedule all tracks once using VoiceScheduler
            const Scheduler = VoiceScheduler(T);
            const track_schedules = try self.allocator.alloc([]Scheduler.ScheduledEvent, self.tracks.items.len);
            @memset(track_schedules, &[_]Scheduler.ScheduledEvent{});
            var result = Schedules{
                .allocator = self.allocator,
                .tracks = track_schedules,
                .max_frame_end = 0,
            };
            errdefer result.deinit();

            for (self.tracks.items, 0..) |tr, tr_idx| {
                track_schedules[tr_idx] = try Scheduler.scheduleTrack(
                    self.allocator,
                    tr,
                    self.bpm,
                    self.time_signature,
                    self.sample_rate,
                    self.channels,
                    fade_frames,
                );
                for (track_schedules[tr_idx]) |se| {
                    if (se.active_frames > 0) {
                        result.max_frame_end = @max(result.max_frame_end, se.start_frame + se.active_frames);
                    }
                }
            }

            return result;
        }

        /// Renders all scheduled tracks into a final composite lightmix.Wave(T).
        pub fn render(self: *Self) !lightmix.Wave(T) {
            var schedules = try self.scheduleAll();
            defer schedules.deinit();

            return Renderer(T).render(
                self.allocator,
                self.sample_rate,
                self.channels,
                self.tracks.items,
                schedules.tracks,
                schedules.max_frame_end,
            );
        }

        /// A handle returned by `renderStream` that owns both the schedule memory and the
        /// inner `BlockIterator`. Call `deinit()` after consuming all blocks.
        pub const StreamHandle = struct {
            schedules: Schedules,
            iter: Renderer(T).BlockIterator,

            /// Frees the internal block buffer and the track schedule memory.
            pub fn deinit(self: *StreamHandle) void {
                self.iter.deinit();
                self.schedules.deinit();
            }

            /// Resets the stream rendering iterator back to frame 0 for multi-pass streaming.
            pub fn reset(self: *StreamHandle) void {
                self.iter.reset();
            }

            /// Renders and yields the next block of interleaved samples, or `null` once the
            /// whole timeline has been rendered. The slice is valid until the next call.
            pub fn next(self: *StreamHandle) ?[]const T {
                return self.iter.next();
            }

            /// Total number of audio frames in the complete rendered stream.
            pub fn totalFrames(self: *const StreamHandle) usize {
                return self.iter.total_frames;
            }
        };

        /// Schedules all tracks and returns a `StreamHandle` for block-based rendering.
        ///
        /// The caller owns the returned handle and must call `deinit()` on it.
        pub fn renderStream(self: *Self, options: StreamOptions) !StreamHandle {
            var schedules = try self.scheduleAll();
            errdefer schedules.deinit();

            const iter = try Renderer(T).renderStream(
                self.allocator,
                self.sample_rate,
                self.channels,
                self.tracks.items,
                schedules.tracks,
                schedules.max_frame_end,
                options,
            );

            return .{ .schedules = schedules, .iter = iter };
        }
    };
}

test "Sequencer render basic song" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 2);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples1, 0.5);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples2, 0.25);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = samples2,
    };

    const track1 = try seq.createTrack("Melody");
    try seq.add(track1, wave1, .{ .bar = 0, .beat = 0.0 });

    const track2 = try seq.createTrack("Harmony");
    try seq.add(track2, wave2, .{ .bar = 1, .beat = 0.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    try std.testing.expectEqual(@as(usize, 441000), rendered.samples.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), rendered.samples[0], 0.0001);
}

test "Sequencer renderStream blocks concatenate to render() output" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 2);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples1, 0.5);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples2, 0.25);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = samples2,
    };

    const track1 = try seq.createTrack("Melody");
    try seq.add(track1, wave1, .{ .bar = 0, .beat = 0.0 });

    const track2 = try seq.createTrack("Harmony");
    try seq.add(track2, wave2, .{ .bar = 1, .beat = 0.0 });

    var expected = try seq.render();
    defer expected.deinit();

    // A block size that does not divide the total frame count exercises the final partial block.
    var stream = try seq.renderStream(.{ .block_size = 1000 });
    defer stream.deinit();

    try std.testing.expectEqual(expected.samples.len / 2, stream.totalFrames());

    var offset: usize = 0;
    while (stream.next()) |block| {
        try std.testing.expectEqualSlices(f64, expected.samples[offset..][0..block.len], block);
        offset += block.len;
    }
    try std.testing.expectEqual(expected.samples.len, offset);
}

test "Sequencer renderStream empty song returns error.EmptySong" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 2);
    defer seq.deinit();

    try std.testing.expectError(error.EmptySong, seq.renderStream(.{}));
}

test "Sequencer renderStream incompatible format error frees without leaking" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 2);
    defer seq.deinit();

    const samples = try allocator.alloc(f64, 48000);
    const wave = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 48000,
        .channels = 2,
        .samples = samples,
    };

    const track = try seq.createTrack("Test");
    try seq.add(track, wave, .{ .bar = 0 });

    try std.testing.expectError(error.IncompatibleWaveFormat, seq.renderStream(.{}));
}

fn renderStreamUnderAllocator(allocator: std.mem.Allocator) !void {
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 2);
    defer seq.deinit();

    const track = try seq.createTrack("Melody");

    // The errdefer is scoped so it only covers the window before the sequencer takes ownership.
    {
        const samples = try allocator.alloc(f64, 44100 * 2);
        var wave = lightmix.Wave(f64){
            .allocator = allocator,
            .sample_rate = 44100,
            .channels = 2,
            .samples = samples,
        };
        errdefer wave.deinit();
        @memset(samples, 0.5);
        try seq.add(track, wave, .{ .bar = 0, .beat = 0.0 });
    }

    var stream = try seq.renderStream(.{ .block_size = 1000 });
    defer stream.deinit();
    while (stream.next()) |_| {}
}

test "Sequencer renderStream does not leak on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, renderStreamUnderAllocator, .{});
}

test "Sequencer render empty song returns error.EmptySong" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 2);
    defer seq.deinit();

    try std.testing.expectError(error.EmptySong, seq.render());
}

test "Sequencer render incompatible format error" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 2);
    defer seq.deinit();

    const samples = try allocator.alloc(f64, 48000);
    const wave = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 48000,
        .channels = 2,
        .samples = samples,
    };

    const track = try seq.createTrack("Test");
    try seq.add(track, wave, .{ .bar = 0 });

    try std.testing.expectError(error.IncompatibleWaveFormat, seq.render());
}

test "Sequencer render track truncates overlapping waves with micro-fade (Single String Model)" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    // Wave 1: 4 seconds long, amplitude 1.0
    const samples1 = try allocator.alloc(f64, 44100 * 4);
    @memset(samples1, 1.0);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    // Wave 2: 2 seconds long, amplitude 1.0
    const samples2 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples2, 1.0);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track = try seq.createTrack("MonoTrack");
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.add(track, wave2, .{ .bar = 0, .beat = 2.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[0], 0.001);

    // Wave 2 starts at 2 beats (2.0s = 88200 samples at 60 bpm)
    // After micro-fade (220 samples), Wave 1 is completely cut off so amplitude must be 1.0, not 2.0
    const sample_after_fade = 88200 + 250;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[sample_after_fade], 0.001);
}

test "Sequencer render three consecutive overlapping waves cascade voice priority" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100 * 4);
    @memset(samples1, 1.0);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100 * 3);
    @memset(samples2, 1.0);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const samples3 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples3, 1.0);
    const wave3 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples3,
    };

    const track = try seq.createTrack("CascadeTrack");
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.add(track, wave2, .{ .bar = 0, .beat = 1.0 });
    try seq.add(track, wave3, .{ .bar = 0, .beat = 2.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    // Wave 1 plays alone at t=0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[0], 0.001);

    // Wave 2 starts at t=1s (44100). 250 samples after 44100, Wave 1 is completely faded out
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[44100 + 250], 0.001);

    // Wave 3 starts at t=2s (88200). 250 samples after 88200, Wave 2 is completely faded out
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[88200 + 250], 0.001);
}

test "Sequencer render same timestamp collision supersedes earlier wave" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100);
    @memset(samples1, 0.3);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 0.7);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track = try seq.createTrack("CollisionTrack");
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.add(track, wave2, .{ .bar = 0, .beat = 0.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    // Wave 1 should be silenced (active_frames = 0), Wave 2 should sound at 0.7
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), rendered.samples[0], 0.001);
}

test "Sequencer render notes separated by silence play full duration without fade" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    // 1 beat = 1 second = 44100 samples
    const samples1 = try allocator.alloc(f64, 44100);
    @memset(samples1, 0.8);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 0.8);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track = try seq.createTrack("GapTrack");
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 }); // 0s - 1s
    try seq.add(track, wave2, .{ .bar = 0, .beat = 2.0 }); // 2s - 3s (1s gap)

    var rendered = try seq.render();
    defer rendered.deinit();

    // Near the end of Wave 1, should still be full amplitude (no early fade-out)
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), rendered.samples[44090], 0.001);

    // During the silence gap (1.5s = 66150 samples), amplitude is 0.0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rendered.samples[66150], 0.001);

    // Wave 2 starts at 2s (88200 samples)
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), rendered.samples[88200], 0.001);
}

test "Sequencer render note shorter than fade window does not underflow or crash" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    // 50 samples is much shorter than default 5ms (220 samples) fade
    const samples1 = try allocator.alloc(f64, 50);
    @memset(samples1, 1.0);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 0.5);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track = try seq.createTrack("ShortNoteTrack");
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.add(track, wave2, .{ .bar = 0, .beat = 20.0 / 44100.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    try std.testing.expect(rendered.samples.len > 0);
}

test "Sequencer render multi-track polyphony mixes additively without cross-track truncation" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100);
    @memset(samples1, 0.3);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 0.5);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track1 = try seq.createTrack("Track1");
    try seq.add(track1, wave1, .{ .bar = 0, .beat = 0.0 });

    const track2 = try seq.createTrack("Track2");
    try seq.add(track2, wave2, .{ .bar = 0, .beat = 0.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    // 0.3 + 0.5 = 0.8
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), rendered.samples[0], 0.001);
}

test "Sequencer render rapid succession notes clamps preceding micro-fade before third note" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100);
    @memset(samples1, 1.0);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 1.0);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const samples3 = try allocator.alloc(f64, 44100);
    @memset(samples3, 1.0);
    const wave3 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples3,
    };

    const track = try seq.createTrack("RapidTrack");
    // Wave 1 at t=0
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    // Wave 2 at frame 50
    try seq.add(track, wave2, .{ .bar = 0, .beat = 50.0 / 44100.0 });
    // Wave 3 at frame 80
    try seq.add(track, wave3, .{ .bar = 0, .beat = 80.0 / 44100.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    // After Wave 2's fade finishes (80 + 220 = 300), only Wave 3 is sounding at amplitude 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[350], 0.001);
}

test "Sequencer render buffer length matches truncated notes instead of untruncated duration" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    // Wave 1: 10 seconds long
    const samples1 = try allocator.alloc(f64, 44100 * 10);
    @memset(samples1, 1.0);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    // Wave 2: 1 second long, starting at 1.0s (beat 1.0)
    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 1.0);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track = try seq.createTrack("TruncatedBufferTrack");
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.add(track, wave2, .{ .bar = 0, .beat = 1.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    // Wave 2 ends at 2.0s = 88200 samples.
    // Wave 1 truncated duration was 44100 + 220 = 44320 samples.
    // Total rendered samples should be 88200, NOT 441000 (10 seconds)!
    try std.testing.expectEqual(@as(usize, 88200), rendered.samples.len);
}

test "Sequencer render applies attack micro-fade-in on interrupting overlapping note" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples1, 1.0);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 1.0);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track = try seq.createTrack("AttackTrack");
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.add(track, wave2, .{ .bar = 0, .beat = 1.0 }); // frame 44100

    var rendered = try seq.render();
    defer rendered.deinit();

    // Wave 1 begins at full amplitude at t=0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[0], 0.001);

    // During crossfade transition (frame 44100), Wave 1 fades out as Wave 2 fades in
    // Total sum at transition is smooth (approximately 1.414 for equal-power in-phase, not jumping to 2.0 or 0.0)
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[44100], 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4142), rendered.samples[44100 + 110], 0.02);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rendered.samples[44100 + 220], 0.01);
}

test "Sequencer render micro-fade uses equal-power curve" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples1, 1.0);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 0.0);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track = try seq.createTrack("EqualPowerTrack");
    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.add(track, wave2, .{ .bar = 0, .beat = 1.0 }); // frame 44100

    var rendered = try seq.render();
    defer rendered.deinit();

    // At midpoint of 220-sample fade (~110 samples after 44100), equal-power cosine is cos(pi/4) ≈ 0.7071
    // (Linear fade would have been 0.5)
    try std.testing.expectApproxEqAbs(@as(f64, 0.7071), rendered.samples[44100 + 110], 0.02);
}

test "Sequencer Instrument groups tracks as strings and plays polyphonic chords" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    var guitar = try seq.createInstrument("AcousticGuitar", 6);
    defer guitar.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 6), guitar.stringCount());

    const samples1 = try allocator.alloc(f64, 44100);
    @memset(samples1, 0.4);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 0.5);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    // Play string 0 and string 1 simultaneously (chord)
    try seq.addInstrument(guitar, 0, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.addInstrument(guitar, 1, wave2, .{ .bar = 0, .beat = 0.0 });

    var rendered = try seq.render();
    defer rendered.deinit();

    // 0.4 + 0.5 = 0.9 (both strings sound together)
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), rendered.samples[0], 0.001);
}

test "Sequencer render honors enable_attack_fade = false for percussive tracks" {
    const allocator = std.testing.allocator;
    var seq = inner(f64).init(allocator, 60, .{}, 44100, 1);
    defer seq.deinit();

    const samples1 = try allocator.alloc(f64, 44100 * 2);
    @memset(samples1, 0.5);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples1,
    };

    const samples2 = try allocator.alloc(f64, 44100);
    @memset(samples2, 1.0);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 1,
        .samples = samples2,
    };

    const track = try seq.createTrack("PercussionTrack");
    track.enable_attack_fade = false;

    try seq.add(track, wave1, .{ .bar = 0, .beat = 0.0 });
    try seq.add(track, wave2, .{ .bar = 0, .beat = 1.0 }); // frame 44100

    var rendered = try seq.render();
    defer rendered.deinit();

    // At onset frame 44100: Wave 2 starts immediately at amplitude 1.0 (no sine fade-in ramp from 0.0),
    // while Wave 1 starts fading out from 0.5 with equal-power cosine.
    // 0.5 * cos(0) + 1.0 = 1.5 (Wave 2 transient preserved immediately).
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), rendered.samples[44100], 0.01);
}

test {
    std.testing.refAllDecls(@This());
}
