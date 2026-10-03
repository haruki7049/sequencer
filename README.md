# sequencer

Lightweight event sequencer and scheduler for audio playback in Zig

Schedules [`lightmix`](https://github.com/haruki7049/lightmix) waves at musical positions on monophonic tracks,
truncates overlapping voices with equal-power micro-fades, and renders everything into a single wave or a stream of
fixed-size blocks. Requires Zig `0.16.0`.

## Dependencies

| Package | Used for |
| :--- | :--- |
| [`meters`](https://github.com/haruki7049/meters) | `Position`, `TimeSignature` |
| [`resonator`](https://github.com/haruki7049/resonator) | `Instrument` (string-to-track mapping) |
| [`lightmix`](https://github.com/haruki7049/lightmix) | `Wave(T)` |

## Provided types

| Symbol | Description |
| :--- | :--- |
| `Sequencer(T)` | Owns tracks; `createTrack`, `createInstrument`, `add`, `addInstrument`, `render`, `renderStream` |
| `Track(T)` | Monophonic voice lane holding an ordered list of events |
| `Event(T)` | A `lightmix.Wave(T)` placed at a `meters.Position` (owned or borrowed) |
| `VoiceScheduler(T)` | Converts positions to sample frames, truncates overlapping notes, computes micro-fade bounds |
| `Renderer(T)` | Mixes scheduled events into a wave, or block by block (`BlockIterator`) |
| `StreamOptions` | Block size for `renderStream` (default 4096 frames) |
| `Instrument` | Re-exported from `resonator` |

## Usage

```sh
zig fetch --save git+https://github.com/haruki7049/sequencer
```

```zig
// build.zig
const sequencer = b.dependency("sequencer", .{ .target = target, .optimize = optimize });
mod.addImport("sequencer", sequencer.module("sequencer"));
```

```zig
const std = @import("std");
const lightmix = @import("lightmix");
const sequencer = @import("sequencer");

fn render(allocator: std.mem.Allocator, note: lightmix.Wave(f64)) !lightmix.Wave(f64) {
    // 120 BPM, 4/4, 44100 Hz, mono
    var seq = sequencer.Sequencer(f64).init(allocator, 120, .{}, 44100, 1);
    defer seq.deinit();

    var guitar = try seq.createInstrument("AcousticGuitar", 6);
    defer guitar.deinit(allocator);

    // The sequencer takes ownership of `note` and frees it in `deinit`.
    try seq.addInstrument(guitar, 0, note, .{ .bar = 0, .beat = 1.0 });

    return try seq.render();
}
```

## Development

```sh
zig build test
```

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.
