//! Sequencer audio track structure managing an ordered list of audio events.

const std = @import("std");
const lightmix = @import("lightmix");
const Position = @import("meters").Position;
const Event = @import("event.zig").inner;

/// Returns a Track type parameterized by sample floating-point type T.
pub fn inner(comptime T: type) type {
    return struct {
        name: []const u8,
        events: std.ArrayList(Event(T)) = .empty,
        enable_attack_fade: bool = true,

        const Self = @This();

        /// Initializes a track with a given name.
        pub fn init(name: []const u8) Self {
            return .{
                .name = name,
                .events = .empty,
                .enable_attack_fade = true,
            };
        }

        /// Deinitializes track resources and frees wave samples of owned attached events.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.events.items) |*event| {
                if (event.owned) {
                    event.wave.deinit();
                }
            }
            self.events.deinit(allocator);
        }

        /// Adds an audio wave event to the track at the specified musical position with ownership.
        pub fn add(self: *Self, allocator: std.mem.Allocator, wave: lightmix.Wave(T), position: Position) !void {
            try self.events.append(allocator, .{
                .wave = wave,
                .position = position,
                .owned = true,
            });
        }

        /// Adds a borrowed audio wave event to the track without taking ownership.
        pub fn addBorrowed(self: *Self, allocator: std.mem.Allocator, wave: lightmix.Wave(T), position: Position) !void {
            try self.events.append(allocator, .{
                .wave = wave,
                .position = position,
                .owned = false,
            });
        }
    };
}

test "Track add" {
    const allocator = std.testing.allocator;
    var track = inner(f64).init("Test Track");
    defer track.deinit(allocator);

    const samples = try allocator.alloc(f64, 44100);
    const wave = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = samples,
    };

    try track.add(allocator, wave, .{ .bar = 1, .beat = 0.0 });
    try std.testing.expectEqual(@as(usize, 1), track.events.items.len);
    try std.testing.expectEqual(@as(usize, 1), track.events.items[0].position.bar);
}

test "Track add multiple events and deinit clean memory" {
    const allocator = std.testing.allocator;
    var track = inner(f64).init("MultiTrack");
    defer track.deinit(allocator);

    const samples1 = try allocator.alloc(f64, 100);
    const wave1 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = samples1,
    };
    try track.add(allocator, wave1, .{ .bar = 0, .beat = 0.0 });

    const samples2 = try allocator.alloc(f64, 200);
    const wave2 = lightmix.Wave(f64){
        .allocator = allocator,
        .sample_rate = 44100,
        .channels = 2,
        .samples = samples2,
    };
    try track.add(allocator, wave2, .{ .bar = 1, .beat = 2.0 });

    try std.testing.expectEqual(@as(usize, 2), track.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), track.events.items[0].position.bar);
    try std.testing.expectEqual(@as(usize, 1), track.events.items[1].position.bar);
    try std.testing.expectEqual(@as(f64, 2.0), track.events.items[1].position.beat);
}

test {
    std.testing.refAllDecls(@This());
}
