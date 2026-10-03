# Agent Guidelines for `sequencer`

This document defines core principles, architectural invariants, and non-negotiable safety rules for AI agents working on the `sequencer` repository.

______________________________________________________________________

## 1. Project Overview & Architecture

`sequencer` is an event sequencer and renderer in Zig. It places [`lightmix`](https://github.com/haruki7049/lightmix) waves at musical positions on monophonic tracks, truncates overlapping voices with equal-power micro-fades, and mixes everything into one wave or a stream of fixed-size blocks. It does not synthesize sounds or write files.

- **Library Package**: The public module is registered as `sequencer` via `b.addModule` in `build.zig`, so downstream projects consume it with `b.dependency("sequencer", .{ .target = target, .optimize = optimize })`.
- **Upstream Boundary**: The dependencies are pinned in `build.zig.zon`:
  - [`meters`](https://github.com/haruki7049/meters) (commit hash): `Position`, `TimeSignature`, and `Position.toSampleOffset`, which decides every event's start frame.
  - [`resonator`](https://github.com/haruki7049/resonator) (commit hash): `Instrument`, re-exported as `sequencer.Instrument`.
  - [`lightmix`](https://github.com/haruki7049/lightmix) (release tag): `Wave(T)`, the type of every event and of the rendered result.
- **Single Shared Upstream Types**: `resonator` must resolve to the same `meters` commit as this package (`src/root.zig` tests it), and `lightmix` is requested without build arguments (`b.dependency("lightmix", .{})`), like `timbrefolio` does, so a package that depends on both resolves one `lightmix` module. Keep both properties when bumping a dependency.
- **Downstream Consumers**: [`pulse`](https://github.com/haruki7049/pulse) pins `sequencer` to a commit hash. A change here reaches it only when it bumps that pin. Treat a change to a public type's fields, a function signature, an error, the ownership of event waves, or the rendered samples (start frames, fade lengths or curves, output length) as a breaking change, and state it in the PR description. Bumping `meters` can change rendered samples too, since start frames come from `toSampleOffset`.
- **Target Language Version**: Zig `0.16.0`, matching `minimum_zig_version` in `build.zig.zon` and the toolchain pinned in `flake.nix`.
- **Development Environment**: Managed with Nix, `direnv`, and `nix-direnv`. Formatting across all languages is handled via `treefmt` (nixfmt, zig fmt, actionlint, mdformat, shellcheck, shfmt). `.deps.nix` is the `zon2nix` lockfile of the Zig dependencies for the Nix build.
- **Source Layout** (`src/`):
  - `root.zig`: Re-exports the public types and `Instrument`.
  - `sequencer.zig`: `Sequencer(T)`, which owns the tracks, validates event formats, schedules every track once, and calls the renderer (`render`, `renderStream`).
  - `track.zig`: `Track(T)`, one monophonic voice lane with its events and `enable_attack_fade`.
  - `event.zig`: `Event(T)`, a `lightmix.Wave(T)` at a `meters.Position`, owned or borrowed.
  - `voice-scheduler.zig`: `VoiceScheduler(T)`, which turns positions into frames, sorts events, truncates overlaps and computes the micro-fade bounds.
  - `renderer.zig`: `Renderer(T)`, which mixes scheduled events into one wave (`render`) or block by block (`BlockIterator`).
- **Rendering Principles**:
  - **Single String Model**: A track is monophonic. A note that starts before the previous one on the same track ends truncates it; notes on different tracks never truncate each other and mix additively. At the same start frame, the event added later wins.
  - **Equal-Power Micro-Fades**: A truncated note ends with a `cos` release fade and an interrupting note starts with a `sin` attack fade, both 5 ms long (`fade_frames` in `Sequencer.scheduleAll`). A fade is shortened when the next note arrives first. `Track.enable_attack_fade = false` turns off the attack fade, e.g. for percussive tracks.
  - **Additive Mixing, No Clipping or Normalization**: Samples are summed as they are. Never clamp, limit or normalize in the renderer; level control belongs to the caller, and quantization to the `lightmix` codec.
  - **Strict Formats**: Every event must match the sequencer's sample rate and channel count, or rendering returns `error.IncompatibleWaveFormat`. Never resample or convert channels. An empty song returns `error.EmptySong`.
  - **Deterministic Output**: No randomness and no hidden state; the same events always render the same samples. `renderStream` must stay bitwise identical to `render` for every block size, and the tests check it.
  - **Bounded Streaming Memory**: `BlockIterator` reuses one block buffer (default 4096 frames, `StreamOptions.block_size`). Do not allocate per block.
- **Ownership**:
  - `add` / `addInstrument` take ownership of the wave; `Sequencer.deinit` frees it. `addBorrowed` / `addInstrumentBorrowed` leave it with the caller.
  - `render` may move the buffer of an owned event that spans the whole song from start to end without fades into the result instead of copying it, marking the event as borrowed. Keep that event-to-result handoff leak-free and documented when changing the renderer.
  - `createInstrument` allocates the string-to-track index slice; the caller frees it with `Instrument.deinit`.
  - Allocation failures must not leak; `renderStream` is tested with `std.testing.checkAllAllocationFailures`.

______________________________________________________________________

## 2. Strict Safety & Operational Rules (Always Enforced)

- **A change request implies commit, push and PR**: When the user instructs a change, carry it through to a pull request without asking for confirmation: work on a topic branch created from the latest `origin/main` (or the existing topic branch for that work; never commit on `main`, since it cannot be pushed), pass the verification commands, then `git commit`, `git push` the topic branch, and open a PR with `gh pr create` if none exists. If the branch already has an open PR, push to it and update the PR description when it has become stale.
- **`main` is protected on GitHub (ruleset active)**: A GitHub ruleset on the default branch requires a pull request (0 required approvals, squash merge only), signed commits, linear history and these status checks: `test` (ubuntu, macos, windows), `run-nix-check` and `run-nix-build` (ubuntu, macos), and `validate-pr-title`. It also blocks deletion and non-fast-forward pushes. `git push origin main` will therefore be rejected. AI agents **MUST NEVER** merge PRs (including enabling auto-merge with `gh pr merge --auto`) or execute `git merge` autonomously.
- **NEVER PROPOSE COMMITS OR PUSHES UNPROMPTED**: AI agents **MUST NEVER** prompt the user to commit or push, nor propose commit messages unprompted (e.g. do NOT ask "Would you like me to commit and push?"). When instructed by the user or when creating/updating pull requests on topic branches, agents may execute `git commit` and `git push` directly without seeking confirmation.
- **Mandatory Human Approval**: AI agents may create branches, create commits, push topic branches, propose PRs, format code, and run test suites, but the final action of merging changes into `main` rests strictly with the human maintainer.
- **Verification Before Submitting**: All changes must pass the commands in [Section 3](#3-verification-commands).
- **Conventional Commits**: Use conventional commit prefixes (`feat:`, `fix:`, `refactor:`, `docs:`, `build:`, `ci:`, `test:`). The PR title must follow the same format; `validate-pr-title` checks it.
- **No Issue Numbers in Commit Messages**: Do not include issue numbers (e.g. `(#5)` or `#5`) anywhere in a commit message, summary or body, or in a PR title. Squash merges copy every commit message into `main`, so a `Closes #5` in a commit body can close an issue the PR was never meant to close. Link issues only from the PR description with a closing keyword (e.g. `Closes #5`). The ` (#N)` suffix GitHub appends to a squash-merge summary is the one exception.
- **Explicit Milestone Assignment Only**: AI agents **MUST NEVER** attach or set GitHub Milestones on Pull Requests or Issues unless explicitly requested by the user.
- **Evidence First**: Base all answers and actions on actual file contents and command output. Never speculate or assume.
- **Non-Destructive**: Never perform irreversible actions (file deletions, hard resets, rewriting pushed history such as amending or rebasing pushed commits and force-pushing, pushing to `main`) without explicit user approval. Ordinary pushes of new commits to a topic branch don't need approval (see above).
- **Targeted Edits**: Make minimal, logical changes strictly necessary for the request. Do not modify unrelated files.
- **English-Only Documentation**: All repository documentation, code comments, commit messages, and PR descriptions must be written strictly in English. Never include Japanese or any non-English language in repository documentation.
- **No Session Links**: Do not include AI session URLs or other internal session identifiers (e.g. a `Claude-Session:` trailer) in commit messages, PR descriptions, issues, or comments. Such links are not accessible from outside the private session, so publishing them in this public repository serves no purpose and only confuses readers. A `Co-Authored-By:` trailer is fine. Exception: if the user explicitly states the session is public and instructs the agent to include its URL, doing so is allowed.

______________________________________________________________________

## 3. Verification Commands

Run these inside the Nix development shell (`nix develop` or `direnv allow`). CI runs the same set.

| Task | Command | Description |
| :--- | :--- | :--- |
| **Check formatting** | `treefmt --fail-on-change` | Checks every language treefmt covers; `zig fmt --check .` checks Zig files only |
| **Build** | `zig build` | Builds the static library |
| **Run tests** | `zig build test` | Runs every unit test in `src/` |
| **Check the flake** | `nix flake check` | Runs the flake checks, including the treefmt check and the package build |

**Updating dependencies**: After changing a dependency in `build.zig.zon` (`zig fetch --save <url>`), run `zon2nix > .deps.nix` in the dev shell, then `treefmt`, and commit both files together. The sandboxed Nix build has no network access and pre-fetches the Zig dependencies from `.deps.nix` (see `flake.nix`).

- **Fix the tarball URLs**: `zon2nix` writes each `fetchzip` URL as `https://codeload.github.com/<owner>/<repo>/tar.gz/refs/tags/<tag>`. Its last path segment has no archive extension, so `fetchzip` fails with `do not know how to unpack source archive`. Set each such `url` back to the `url` in `build.zig.zon` (`https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz`) and keep the generated `hash`: both URLs serve the same tarball. `fetchgit` entries need no change.
- **Fetch every dependency again**: `nix flake check` does not catch a broken `url` when the store already holds a result with the same hash, because a fixed-output derivation is not fetched again; CI, starting from an empty store, does catch it. After `nix flake check` passes, run this in the repository root. It fetches every entry of `.deps.nix` again and compares the result with its `hash`, without `sudo` or garbage collection:

```sh
nix eval --raw --impure --expr 'let pkgs = import (builtins.getFlake (toString ./.)).inputs.nixpkgs { }; in builtins.concatStringsSep "\n" (map (p: p.drvPath + "^out") (builtins.attrValues (pkgs.callPackage ./.deps.nix { }).entries))' | xargs nix build --no-link --rebuild
```

______________________________________________________________________

## 4. Coding Conventions

- **Comments**: Every file starts with a `//!` comment that says what it contains, and every new public declaration gets a `///` doc comment. Comments are in English.
- **Naming**:
  - `PascalCase` for types (`Sequencer`, `VoiceScheduler`, `ScheduledEvent`, `BlockIterator`).
  - `camelCase` for functions and methods, preferring a concise verb when the receiver makes the operand evident (`add`, `render`, `computeGain`, `mixEvent`); keep a noun only to disambiguate (`createTrack` vs. `createInstrument`).
  - `snake_case` for variables, parameters and struct fields (`sample_rate`, `start_frame`, `active_frames`, `enable_attack_fade`).
  - Comptime type parameters are always a single uppercase character (`comptime T: type`). Multi-character names such as `comptime SampleType: type` are prohibited.
  - Error tags are `PascalCase` (`error.EmptySong`, `error.IncompatibleWaveFormat`, `error.InvalidChannelCount`).
- **Generic Factories**: Each type is defined as `pub fn inner(comptime T: type) type` in its own file and re-exported under its `PascalCase` name in `root.zig` (`pub const Track = @import("track.zig").inner;`). Stay generic over the sample type; the tests cover `f64` and `f80`.
- **Tests**: Keep tests next to the code they cover, in the same file. Every file ends with `test { std.testing.refAllDecls(@This()); }`. Use `std.testing.allocator` so leaks fail the test, and add a test for every new scheduling or fade edge case (overlaps, equal start frames, notes shorter than the fade window).

______________________________________________________________________

## 5. Status Assessment Workflow

When asked to check status, assess the situation, or understand workspace context:

1. **Local Git State**: Inspect working tree (`git status -s -b`) and recent commits (`git log -n 5 --oneline`).
1. **GitHub PRs**: Check PR status (`gh pr status`) and current PR details (`gh pr view`).
1. **GitHub Issues**: Check relevant open issues (`gh issue list --limit 5`).
1. **Environment Health**: Run the commands in [Section 3](#3-verification-commands).
1. **Synthesis**: Report a concise, structured status covering local state, remote GitHub state, and environment health.
