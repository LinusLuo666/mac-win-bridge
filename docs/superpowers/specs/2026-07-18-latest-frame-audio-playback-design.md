# Latest-Frame Audio Playback Design

## Goal

Prevent Mac-side stalls from creating permanent or stepwise-growing audio latency. After a pause, playback must skip stale TCP-buffered PCM and resume near the newest Windows audio frame.

## Root Cause

Commit `44c9f04` limits `AVAudioPlayerNode` to one pending buffer, but `AudioStreamPlayer` calls `AudioBufferQueueLimiter.waitForSlot()` on the same thread that reads TCP. While playback is stalled, that thread stops draining the socket. Old PCM accumulates in the TCP receive buffer and is later replayed at real-time speed, preserving the added delay.

## Considered Approaches

1. Keep one thread and drop frames when the player slot is occupied. This still cannot discard PCM that remains unread in TCP and therefore does not solve the root cause.
2. Add a larger bounded FIFO between TCP and playback. This bounds memory but intentionally preserves old frames, so every queued frame adds latency.
3. Use independent receiver and playback threads with a capacity-one latest-frame buffer. The receiver continuously drains TCP, overwriting stale unpublished frames, while playback consumes only the newest frame after the single player slot becomes available. This is the selected design.

## Components

### `LatestFrameBuffer<Element>`

Add a thread-safe generic buffer to `MacBridgeCore`, backed by `NSCondition`.

- `put(_:)` stores the new value and reports whether it replaced an older value.
- Capacity is always exactly one; replacement is the drop policy.
- `waitForLatest()` blocks only while the buffer is empty and active, removes the current latest value when available, and returns `nil` after stop.
- `stop()` clears any unpublished value, marks the buffer stopped, and broadcasts to all waiters.

### Receiver thread

The receiver thread owns socket framing and parsing. For every valid frame it:

1. increments `receivedFrames`;
2. inserts the frame into `LatestFrameBuffer`;
3. increments `droppedFrames` when the insertion replaced an unpublished frame.

It never calls `AudioBufferQueueLimiter` and never waits for AVFoundation playback.

### Playback thread

The playback thread owns format configuration, PCM conversion, and scheduling. It first reserves the sole player slot through the retained `AudioBufferQueueLimiter`, then takes the latest frame. This ordering prevents the thread from holding a stale frame while waiting for the previous scheduled buffer to finish.

Each `scheduleBuffer` completion releases the slot. At most one scheduled, unfinished `AVAudioPCMBuffer` exists at any time. A frame successfully scheduled increments `scheduledFrames`.

## Shutdown

`stop()` atomically marks the player stopped, then calls both `LatestFrameBuffer.stop()` and `AudioBufferQueueLimiter.stop()` before stopping AVFoundation. This wakes a playback thread whether it is waiting for a frame or for the previous buffer completion. If it reserved a slot before discovering the latest-frame buffer was stopped, it releases that reservation before exiting.

The receiver may still be inside a blocking `InputStream.read`; the existing owner closes the TCP streams immediately after `stop()`, which releases that read. No thread join is performed on the caller thread.

## Logging

Protect counters with a small statistics lock and emit the five-second summary with these exact field names:

- `receivedFrames`
- `droppedFrames`
- `scheduledFrames`
- `qpcJumps`
- `pcmBytes`

WASAPI supplies `qpcPosition` in 100-nanosecond units. On the playback thread, compare each scheduled frame with the previous scheduled frame. Log a QPC jump when the position moves backward/resets or when the forward gap exceeds the previous frame duration plus a small timing tolerance. A forward jump after dropped frames is expected evidence that playback skipped stale audio.

## Testing

Extend `MacBridgeCoreTestRunner` before implementation:

- Put `A`, `B`, and `C` without taking; verify the next value is `C` and exactly two replacements are reported.
- Start a waiter on an empty buffer, call `stop()`, and verify the waiter returns `nil` within a bounded timeout.
- Retain the `AudioBufferQueueLimiter` single-pending-buffer regression test from `44c9f04`.

Run the full Swift test runner and build. For manual integration, connect to the Windows Agent on port 5055, repeatedly suspend and resume the Mac process for about one second, and inspect the summary and QPC-jump logs. Acceptance requires nonzero `droppedFrames` during induced stalls and no stepwise latency accumulation.
