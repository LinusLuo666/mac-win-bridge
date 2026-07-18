# Mac Audio Evidence Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add diagnostic-only, five-second wall-clock-aligned Mac audio evidence for comparison with Windows logs.

**Architecture:** Pure `MacBridgeCore` helpers aggregate windows and detect receive batches. `AudioStreamPlayer` feeds them and a diagnostic timer prints snapshots without changing transport, buffering, dropping, conversion, or playback scheduling.

**Tech Stack:** Swift 6, Foundation, AVFoundation, existing `MacBridgeCoreTestRunner`.

## Global Constraints

- Use only `m1-audio-bridge`; do not create branches or worktrees.
- Do not change audio transport, protocol, buffering, dropping, or playback behavior.
- Do not push diagnostic-only instrumentation.
- Use test-first implementation.

---

### Task 1: Diagnostic aggregation helpers

**Files:**
- Create: `mac-controller/Sources/MacBridgeCore/AudioEvidenceTracker.swift`
- Modify: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Produces: `AudioEvidenceWindowTracker`, `AudioEvidenceWindowSnapshot`, `AudioArrivalBatchTracker`, and `AudioArrivalBatch`.

- [ ] Add failing tests for five-second alignment, counter reset, frame-count distribution, QPC maximum, and batch detection.
- [ ] Run `swift run --package-path mac-controller mac-controller-tests` and confirm failures are caused by missing evidence types.
- [ ] Implement the smallest thread-confined trackers that satisfy the tests.
- [ ] Re-run the tests and confirm all pass.

### Task 2: Timestamped application integration

**Files:**
- Modify: `mac-controller/Sources/MacController/AudioStreamPlayer.swift`
- Modify: `mac-controller/Sources/MacController/main.swift`

**Interfaces:**
- Consumes: evidence trackers from Task 1.
- Produces: `audio evidence window`, `audio arrival batch`, and timestamped failure/QPC logs.

- [ ] Add a diagnostic timer aligned to five-second epoch boundaries.
- [ ] Feed receive, schedule, drop, QPC, and arrival timestamps into the trackers under the existing statistics lock.
- [ ] Prefix connection and audio error logs with local ISO-8601 timestamps.
- [ ] Confirm the diff contains no changes to `scheduleBuffer`, `LatestFrameBuffer`, `AudioBufferQueueLimiter`, stream reads, control messages, or protocol parsing.

### Task 3: Verification and evidence run

**Files:**
- Runtime output only: `.runtime/audio-bridge/mac-audio.log`

**Interfaces:**
- Produces: twelve aligned five-second records plus exact exception and batch records for a 60-second run.

- [ ] Run `swift run --package-path mac-controller mac-controller-tests` and require zero failures.
- [ ] Run `swift build --package-path mac-controller` and require success.
- [ ] Restart the single managed Mac audio client through the local manager.
- [ ] Capture 60 seconds beginning on a five-second boundary.
- [ ] Report branch, SHA, process count, engine/player state, all twelve window records, batches, and complete timestamped errors.
- [ ] Keep the diagnostic changes local and unpushed.

