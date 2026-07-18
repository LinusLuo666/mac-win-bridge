# CoreAudio 512-Frame Reblocking Design

## Goal

Keep Windows audio packets at 480 sample frames and the TCP latest-frame buffer at capacity one, while feeding `AVAudioPlayerNode` fixed 512-frame non-interleaved float buffers that match the Mac output render quantum.

## Selected Architecture

`AudioStreamPlayer` continues to use independent receiver and playback threads. The receiver parses every original Windows frame, records input/QPC statistics, and replaces only the single unpublished latest frame. The playback thread decodes the selected raw frame to non-interleaved float channels, appends it to a thread-safe `PCMReblocker`, and schedules each complete 512-frame output through the existing two-slot `AudioBufferQueueLimiter`.

The reblocker owns less than 512 sample frames of carry per channel. It never pads or schedules a partial block. Format changes, disconnect, and stop clear carry. Its output records the QPC of the first source sample and the exact source slices contributing to the output block.

## Data Model

- `PCMInputBlock` contains sample rate, QPC position, and equally sized non-interleaved float channels.
- `PCMSourceSpan` contains the original input QPC, source-frame offset, and number of source sample frames consumed.
- `ReblockedPCMOutput` contains one 512-frame `AVAudioPCMBuffer`, its first-sample QPC, and ordered source spans.
- `PCMReblocker` appends input, produces all complete blocks, exposes carry sample frames, and clears state on stop or format change.

## Flow Control

The playback loop takes the latest input frame and enters it into the reblocker before waiting for a scheduling slot. It waits on `AudioBufferQueueLimiter` only after a complete 512-frame output exists. A scheduled output consumes one of two reservations until its AVAudioPlayerNode completion handler releases it. With fixed 480-frame input, a single append produces at most one 512-frame output, so at most one complete unscheduled output is held locally while waiting. This keeps normal 100-input-buffer/s ingestion independent from the 93.75-output-buffer/s render cadence without increasing the scheduled-buffer limit.

## Statistics

Five-second and cumulative logs use separate input-buffer and sample-frame counters:

- received and overwritten input buffers/sample frames;
- reblocked, scheduled, and completed output buffers/sample frames;
- current carry sample frames;
- raw-input QPC jumps, maximum QPC delta, input frame-count distribution, and arrival gaps.

Output source provenance is aggregated as the first output start QPC, final source end QPC, and source-span count for each evidence window. QPC continuity checks run when raw input frames are received, before latest-frame replacement can hide an input packet.

## Shutdown

`stop()` and connection termination stop the latest-frame buffer and scheduling limiter, stop the reblocker, and discard carry. No partial tail buffer is scheduled. All waiting threads retain the existing broadcast-based exit behavior.

## Verification

Unit tests prove mono and stereo ordering, 480/480/480 reblocking, long-sequence sample conservation, source-span/QPC provenance, stop clearing carry, and the existing two-slot scheduling limiter behavior. Integration acceptance uses one direct connection with output redirected to a file and requires near-zero overwritten input sample frames plus sample-frame conservation over 60 seconds.
