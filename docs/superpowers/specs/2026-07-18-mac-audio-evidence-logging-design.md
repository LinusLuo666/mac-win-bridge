# Mac Audio Evidence Logging Design

## Goal

Collect wall-clock-aligned Mac audio evidence that can be compared with the Windows WASAPI and TCP writer logs over the same 60-second interval.

## Constraints

- Do not change TCP behavior, protocol framing, latest-frame replacement, dropped-frame behavior, playback scheduling, or AVAudioPlayerNode queue depth.
- Do not declare the cross-platform root cause before the aligned Windows evidence arrives.
- Do not push diagnostic-only instrumentation.
- Keep all observations thread-safe and avoid per-frame diagnostic output beyond the existing QPC-jump log.

## Design

`AudioStreamPlayer` keeps its current receiver and playback workers. A diagnostic timer snapshots counters at wall-clock boundaries divisible by five seconds. Each snapshot reports the exact local ISO-8601 start and end, received/scheduled/dropped deltas, frame-count distribution, QPC-jump count and maximum delta, arrival-gap maximum, and current engine/player state.

An `AudioArrivalBatchTracker` observes receive timestamps without changing frame ownership. A batch is reported when a receive gap of at least three expected frame durations (and at least 50 ms) is followed by two or more frames arriving no more than 2 ms apart. The batch log contains exact start/end timestamps, received and dropped counts, and player state.

Connection, receive, playback, and QPC-jump logs receive local ISO-8601 timestamps. A 60-second evidence run captures the application log without committing or pushing the diagnostic changes.

## Verification

- Unit tests prove wall-clock five-second alignment, window reset/deltas, frame-count distribution, QPC aggregation, and batch boundaries.
- Existing `mac-controller-tests` remain green.
- `swift build --package-path mac-controller` succeeds.
- The managed Mac audio process is restarted once and produces twelve consecutive five-second window records.

