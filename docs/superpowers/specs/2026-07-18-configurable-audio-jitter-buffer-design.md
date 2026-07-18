# Configurable Mac Audio Jitter Buffer Design

## Context

The Mac audio bridge now converts Windows 480-sample-frame PCM input into fixed
512-sample-frame CoreAudio buffers. That removed the steady-state render-quantum
mismatch, but the live stream still arrives unevenly. Post-restart evidence shows
30–84 ms application-level arrival gaps followed by multiple input frames arriving
within 1–3 ms. CoreAudio scheduling and completion remain healthy, and QPC remains
continuous, but the capacity-one latest-frame handoff overwrites roughly 2% of
otherwise valid audio. Those overwrites are audible as intermittent gaps.

Physical proximity and low average ping do not eliminate scheduling, Wi-Fi, TCP,
or socket-delivery jitter. A 10 ms input handoff cannot provide continuous audio
through an observed 30–84 ms delivery gap. The product therefore needs an explicit,
bounded latency-versus-stability control.

## Goals

- Make the Mac playback latency target configurable from 10 through 120 ms.
- Default to a balanced 50 ms target.
- Provide convenient 20, 50, and 80 ms presets in the local manager page.
- Absorb ordinary delivery bursts without dropping otherwise continuous PCM.
- Bound accumulated latency and discard the oldest queued audio when the bound is
  exceeded, so a stall cannot create permanent or stair-step delay.
- Preserve the Windows protocol, Windows capture behavior, TCP settings, 480-frame
  input, 512-frame CoreAudio output, and the two-buffer schedule limit.
- Preserve stop behavior without deadlocks and clear all incomplete audio on stop,
  disconnect, or format reset.

## Non-goals

- Do not change the Windows Agent or the `audioControl` wire format.
- Do not change the manager's existing TCP reachability probe.
- Do not add an adaptive network protocol, retransmission policy, codec, or sample
  rate conversion.
- Do not promise gap-free playback when delivery stops longer than the configured
  latency target. The buffer makes the trade-off explicit; it cannot create audio
  that has not arrived.

## Configuration Surface

The Mac controller accepts a new option:

```text
--audio-latency-ms <10...120>
```

The option is a whole number of milliseconds. Values outside the inclusive range
are rejected with the existing usage error. The default is 50 ms.

`scripts/start-mac-audio.sh` reads `AUDIO_LATENCY_MS`, defaults it to `50`, and
passes it to the controller. The existing `AUDIO_MODE` remains independent and is
still sent to Windows unchanged.

The local manager stores `latency_ms` beside `host` and `port` in its runtime JSON
configuration. Its page presents:

- Low latency: 20 ms
- Balanced: 50 ms
- Stable: 80 ms
- An advanced 10–120 ms slider

Starting the managed audio process passes the selected value through
`AUDIO_LATENCY_MS`. Changing the value takes effect on the next managed start; the
page does not mutate a running audio pipeline in place.

## Architecture

### Bounded PCM jitter buffer

Add a testable, thread-safe jitter-buffer component in `MacBridgeCore`. It stores
reblocked 512-sample-frame PCM outputs and their existing QPC source-span metadata.
It tracks queued sample frames rather than assuming a fixed duration per buffer.

For a source sample rate `R` and configured latency `L` milliseconds:

```text
targetSampleFrames = round(R * L / 1000)
targetBlockFrames = ceil(targetSampleFrames / 512) * 512
maximumBlockFrames = targetBlockFrames + ceil(R * 20 / 1000 / 512) * 512
```

The 20 ms margin absorbs packet coalescing around the selected target. Whole
512-frame blocks are used, so the effective target may be up to one output block
(10.67 ms at 48 kHz) above the requested value. Logs and the manager display both
the requested value and the effective block-rounded value.

The buffer has three states:

1. `priming`: wait until queued sample frames reach `targetBlockFrames`.
2. `playing`: supply the oldest queued output to the scheduler.
3. `stopped`: clear the queue and wake every waiter immediately.

If playback consumes all queued and scheduled audio, the buffer returns to
`priming`. Playback resumes only after the target is rebuilt, preventing repeated
single-buffer starts and stops.

On enqueue, if queued audio exceeds `maximumBlockFrames`, drop the oldest queued
blocks until queued audio is back at or below `targetBlockFrames`. Blocks already
scheduled in CoreAudio cannot be recalled; at most the existing two scheduled
blocks remain ahead of the trimmed queue. This policy jumps toward current audio
instead of retaining permanent delay.

### Thread and data flow

The current capacity-one latest-frame handoff leaves the primary audio data path.
Keeping it before a jitter buffer would still discard a burst before the jitter
buffer could absorb it.

The revised path is:

```text
TCP receiver thread
  -> parse Windows frame
  -> record raw-input QPC evidence
  -> decode PCM
  -> reblock 480-frame input into 512-frame outputs
  -> non-blocking enqueue into bounded PCM jitter buffer

playback scheduler thread
  -> wait for primed jitter buffer
  -> take oldest 512-frame output
  -> wait for one of two CoreAudio schedule slots
  -> schedule buffer
  -> completion releases the slot and updates counters
```

The receiver never waits for CoreAudio playback completion. Enqueue performs only
bounded in-memory work and drops oldest queued output rather than blocking when the
latency bound is exceeded. The existing `LatestFrameBuffer` remains in the core
library with its regression tests but is no longer used by `AudioStreamPlayer`.

The playback scheduler still allows at most two scheduled, incomplete buffers.
The jitter buffer is a separate latency-control layer; increasing its target does
not change CoreAudio's schedule limit.

## Lifecycle and Error Handling

- The first decoded format establishes the jitter-buffer timing and playback
  format.
- An unsupported or incompatible mid-stream format change terminates the current
  connection using the existing error path; carry and queued audio are cleared.
- `stop()` stops the latest-frame legacy component if present, the jitter buffer,
  the schedule limiter, the reblocker, the player node, and the engine.
- Jitter-buffer and schedule-limit waiters are both broadcast on stop so neither
  worker can deadlock.
- Disconnect discards carry and queued incomplete audio; a reconnect starts in
  `priming` with no stale PCM.

## Diagnostics

Keep the existing raw-input, QPC, reblocking, scheduling, and completion metrics.
Replace primary-path overwrite accounting with explicit jitter-buffer metrics:

- `configuredLatencyMs`
- `effectiveTargetSampleFrames`
- `queuedOutputBuffers` and `queuedOutputSampleFrames`
- `scheduledPendingSampleFrames`
- `trimmedOutputBuffers` and `trimmedOutputSampleFrames`
- `underrunCount`
- `rebufferCount`
- `rebufferDurationMs`
- `maximumQueuedSampleFrames`

The five-second evidence log continues to report received input, reblocked output,
scheduled output, completed output, carry frames, QPC jumps, and arrival gaps. Its
sample-frame conservation check becomes:

```text
received input sample frames
  = scheduled output sample frames
  + queued output sample frames
  + carry sample frames
  + trimmed output sample frames
  + currently held scheduler sample frames
```

Counters are interpreted across state transitions and may differ by one in-flight
block while a worker owns a buffer between components.

## Testing

Add core tests that prove:

- 10, 50, and 120 ms targets produce the expected block-rounded thresholds at
  48 kHz.
- `priming` does not release output before the target is reached.
- Reaching the target transitions to `playing` and returns buffers in source order.
- A burst within the maximum bound is preserved without trimming.
- Exceeding the maximum trims the oldest blocks back to the target.
- Emptying the playing buffer returns it to `priming`.
- `stop()` wakes both a priming waiter and an empty playing waiter immediately.
- QPC/source-span metadata remains attached to the correct retained blocks.
- Sample-frame conservation holds for long bursty input sequences.

Add controller-option tests for the default, valid boundaries, invalid values, and
argument forwarding. Add manager tests or focused Python unit tests for config
persistence and start-command environment propagation.

Keep all existing reblocker, schedule-limiter, exact-reader, latest-frame, and
evidence tests passing.

## Live Acceptance

Run the Mac controller against `192.168.137.1:5055` for at least 60 seconds at each
20, 50, and 80 ms preset with continuous time-referenced audio.

For each preset, report:

- requested and effective latency;
- received, reblocked, queued, scheduled, completed, and trimmed sample frames;
- underrun/rebuffer counts and durations;
- maximum arrival gap and maximum queued sample frames;
- QPC jumps;
- subjective continuity and approximate end-to-end delay.

Acceptance requires:

- no permanent or stair-step latency after repeated short stalls;
- completed frames continue to track scheduled frames;
- queue depth remains bounded by the configured target and margin;
- 50 and 80 ms presets remove the frequent stutters observed with the capacity-one
  handoff under ordinary 30–84 ms arrival jitter;
- 20 ms remains available as the deliberate lowest-latency, lower-stability choice;
- stop and reconnect complete without deadlock or stale playback.
