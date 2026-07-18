# CoreAudio 512-Frame Reblocking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert continuous 480-frame Windows PCM input into fixed 512-frame CoreAudio playback buffers without changing TCP buffering or the wire protocol.

**Architecture:** A unit-tested `PCMReblocker` in `MacBridgeCore` owns per-channel float carry and QPC source spans. `AudioStreamPlayer` decodes selected latest input frames, feeds the reblocker, schedules at most two complete outputs, and logs throughput in sample-frame units.

**Tech Stack:** Swift 6, AVFoundation, Foundation synchronization, existing `MacBridgeCoreTestRunner`.

## Global Constraints

- Work only on `m1-audio-bridge`; create no branch or worktree.
- Keep Windows packets at 480 frames, latest-frame capacity at one, and playback scheduling capacity at two.
- Do not change protocol framing, TCP `NoDelay`, or Windows writes.
- Discard partial carry on stop, disconnect, or format change.
- Keep all work uncommitted until the full 60-second acceptance passes.

---

### Task 1: Unit-tested PCM reblocker

**Files:**
- Create: `mac-controller/Sources/MacBridgeCore/PCMReblocker.swift`
- Test: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Consumes: `PCMInputBlock(sampleRate:qpcPosition:channels:)`.
- Produces: `[ReblockedPCMOutput]`, each containing a 512-frame `AVAudioPCMBuffer`, `startQPCPosition`, and `[PCMSourceSpan]`.

- [ ] Add failing mono, stereo, long-sequence conservation, QPC source-span, and stop tests.
- [ ] Run `swift run --package-path mac-controller mac-controller-tests` and confirm the missing reblocker API fails compilation.
- [ ] Implement locked append/reblock/stop behavior with fixed `outputFrameCount = 512`.
- [ ] Re-run the complete test runner and require zero failures.

### Task 2: Exact latest-frame overwrite accounting

**Files:**
- Modify: `mac-controller/Sources/MacBridgeCore/LatestFrameBuffer.swift`
- Test: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Produces: `putReturningReplaced(_:)`, returning the normal put result plus the exact replaced element.

- [ ] Add a failing test that verifies the replaced element is returned while capacity remains one.
- [ ] Implement the insertion outcome without changing `waitForLatest()` or stop semantics.
- [ ] Run the full test runner and require zero failures.

### Task 3: Sample-frame evidence counters

**Files:**
- Modify: `mac-controller/Sources/MacBridgeCore/AudioEvidenceTracker.swift`
- Test: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Records input receipt/overwrite/QPC, reblocked output, scheduled output, completed output, carry, and source spans.
- Produces a five-second snapshot with buffer and sample-frame counts.

- [ ] Replace the old packet-count evidence test with a failing sample-conservation snapshot test.
- [ ] Implement the new snapshot fields and record methods.
- [ ] Re-run all tests and require zero failures.

### Task 4: Playback integration

**Files:**
- Modify: `mac-controller/Sources/MacController/AudioStreamPlayer.swift`

**Interfaces:**
- Consumes: `LatestFrameBuffer.putReturningReplaced`, `PCMReblocker`, and the sample-frame evidence tracker.
- Produces: fixed 512-frame AVAudioPlayerNode schedules with two-slot completion accounting.

- [ ] Move QPC tracking to raw input receipt and count exact overwritten input sample frames.
- [ ] Decode raw PCM to `PCMInputBlock`, append to the reblocker, and release unused limiter reservations when no complete output exists.
- [ ] Schedule complete outputs, capturing 512 sample frames in each completion handler.
- [ ] Clear reblocker carry on stop and finish.
- [ ] Replace runtime/evidence log fields with buffer and sample-frame counters plus carry and source-span provenance.

### Task 5: Verification and acceptance

**Files:**
- Runtime log only: `/private/tmp/mac-audio-reblock-512.log`

**Interfaces:**
- Produces: test/build output, 60-second statistics, and final commit SHA only after acceptance.

- [ ] Run `swift run --package-path mac-controller mac-controller-tests`.
- [ ] Run `swift build --package-path mac-controller` and `git diff --check`.
- [ ] Confirm no manager or stale controller is running.
- [ ] Run one direct `192.168.137.1:5055` client with output redirected to the runtime log for at least 60 seconds.
- [ ] Verify sample conservation, near-zero overwrite, completion catch-up, and no connection/playback errors.
- [ ] Only after passing, commit and push `m1-audio-bridge`.
