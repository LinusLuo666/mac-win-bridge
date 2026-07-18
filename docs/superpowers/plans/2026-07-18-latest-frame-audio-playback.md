# Latest-Frame Audio Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac audio bridge continuously drain TCP while playing only the newest available PCM frame, so process stalls cannot permanently increase latency.

**Architecture:** A capacity-one `LatestFrameBuffer` decouples a TCP receiver thread from a playback thread. The existing `AudioBufferQueueLimiter` remains solely on the playback side, while synchronized counters and a QPC tracker expose frame drops and playback time jumps.

**Tech Stack:** Swift 6, Foundation `NSCondition`/`NSLock`/`Thread`, AVFoundation, the existing executable `MacBridgeCoreTestRunner`.

## Global Constraints

- Work only on the canonical `m1-audio-bridge` branch; create no additional branch or worktree.
- Start from `origin/m1-audio-bridge` commit `44c9f04` or later.
- The TCP receiver must never wait for AVFoundation playback.
- Latest-frame capacity and maximum unfinished scheduled buffer count are both exactly one.
- `stop()` must wake both frame and player-slot waiters.
- Preserve the existing wire protocol and Windows Agent behavior.

---

### Task 1: Capacity-one latest-frame handoff

**Files:**
- Create: `mac-controller/Sources/MacBridgeCore/LatestFrameBuffer.swift`
- Modify: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Produces: `LatestFramePutResult`, `LatestFrameBuffer<Element>.put(_:)`, `waitForLatest()`, and `stop()`.
- Consumers: the `AudioStreamPlayer` receiver and playback threads in Task 3.

- [ ] **Step 1: Write failing replacement and stop tests**

Add tests that use the intended API:

```swift
final class ThreadSafeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

("LatestFrameBuffer keeps only the newest frame", {
    let buffer = LatestFrameBuffer<String>()
    try expectEqual(buffer.put("A"), .stored, "A result")
    try expectEqual(buffer.put("B"), .replaced, "B replaces A")
    try expectEqual(buffer.put("C"), .replaced, "C replaces B")
    try expectEqual(buffer.waitForLatest(), "C", "newest frame")
}),
("LatestFrameBuffer stop wakes an empty waiter", {
    let buffer = LatestFrameBuffer<String>()
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let result = ThreadSafeBox<String?>(nil)
    Thread {
        started.signal()
        result.set(buffer.waitForLatest())
        finished.signal()
    }.start()
    try expectEqual(started.wait(timeout: .now() + 1), .success, "waiter started")
    buffer.stop()
    try expectEqual(finished.wait(timeout: .now() + 1), .success, "waiter finished")
    try expectNil(result.get(), "stopped wait result")
}),
```

- [ ] **Step 2: Run the test runner and verify RED**

Run: `swift run --package-path mac-controller mac-controller-tests`

Expected: compilation fails because `LatestFrameBuffer` and `LatestFramePutResult` do not exist.

- [ ] **Step 3: Implement the minimum condition-backed buffer**

```swift
import Foundation

public enum LatestFramePutResult: Equatable, Sendable {
    case stored
    case replaced
    case stopped
}

public final class LatestFrameBuffer<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private var latest: Element?
    private var stopped = false

    public init() {}

    @discardableResult
    public func put(_ value: Element) -> LatestFramePutResult {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { return .stopped }
        let result: LatestFramePutResult = latest == nil ? .stored : .replaced
        latest = value
        condition.signal()
        return result
    }

    public func waitForLatest() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        while !stopped && latest == nil { condition.wait() }
        guard !stopped else { return nil }
        let value = latest
        latest = nil
        return value
    }

    public func stop() {
        condition.lock()
        stopped = true
        latest = nil
        condition.broadcast()
        condition.unlock()
    }
}
```

- [ ] **Step 4: Run the test runner and verify GREEN**

Run: `swift run --package-path mac-controller mac-controller-tests`

Expected: the two new tests and all existing tests pass.

- [ ] **Step 5: Commit the tested handoff**

```bash
git add mac-controller/Sources/MacBridgeCore/LatestFrameBuffer.swift mac-controller/Sources/MacBridgeCoreTestRunner/main.swift
git commit -m "feat: add latest-frame audio handoff"
```

### Task 2: Testable QPC jump detection

**Files:**
- Create: `mac-controller/Sources/MacBridgeCore/AudioQPCJumpTracker.swift`
- Modify: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Produces: `AudioQPCJump`, and `AudioQPCJumpTracker.record(position:frameCount:sampleRate:)`.
- Consumer: playback statistics in Task 3.

- [ ] **Step 1: Write failing contiguous and skipped-frame tests**

```swift
("AudioQPCJumpTracker accepts contiguous packets", {
    var tracker = AudioQPCJumpTracker()
    try expectNil(tracker.record(position: 1_000_000, frameCount: 480, sampleRate: 48_000), "first frame")
    try expectNil(tracker.record(position: 1_100_000, frameCount: 480, sampleRate: 48_000), "contiguous frame")
}),
("AudioQPCJumpTracker reports skipped playback time", {
    var tracker = AudioQPCJumpTracker()
    _ = tracker.record(position: 1_000_000, frameCount: 480, sampleRate: 48_000)
    let jump = tracker.record(position: 1_400_000, frameCount: 480, sampleRate: 48_000)
    try expectEqual(jump?.actualDelta, 400_000, "actual QPC delta")
    try expectEqual(jump?.expectedDelta, 100_000, "expected QPC delta")
}),
```

- [ ] **Step 2: Run tests and verify RED**

Run: `swift run --package-path mac-controller mac-controller-tests`

Expected: compilation fails because `AudioQPCJumpTracker` does not exist.

- [ ] **Step 3: Implement the tracker**

```swift
public enum AudioQPCJumpDirection: String, Equatable, Sendable {
    case forward
    case backwardOrReset
}

public struct AudioQPCJump: Equatable, Sendable {
    public let direction: AudioQPCJumpDirection
    public let previousPosition: UInt64
    public let currentPosition: UInt64
    public let actualDelta: UInt64?
    public let expectedDelta: UInt64
}

public struct AudioQPCJumpTracker: Sendable {
    private var previousPosition: UInt64?
    private var previousDuration: UInt64?

    public init() {}

    public mutating func record(position: UInt64, frameCount: Int, sampleRate: Int) -> AudioQPCJump? {
        let duration = Self.duration100Nanoseconds(frameCount: frameCount, sampleRate: sampleRate)
        defer {
            previousPosition = position
            previousDuration = duration
        }
        guard let previousPosition, let expectedDelta = previousDuration else { return nil }
        guard position > previousPosition else {
            return AudioQPCJump(
                direction: .backwardOrReset,
                previousPosition: previousPosition,
                currentPosition: position,
                actualDelta: nil,
                expectedDelta: expectedDelta
            )
        }
        let actualDelta = position - previousPosition
        let tolerance = max(10_000, expectedDelta / 2)
        guard actualDelta > expectedDelta,
              actualDelta - expectedDelta > tolerance else { return nil }
        return AudioQPCJump(
            direction: .forward,
            previousPosition: previousPosition,
            currentPosition: position,
            actualDelta: actualDelta,
            expectedDelta: expectedDelta
        )
    }

    private static func duration100Nanoseconds(frameCount: Int, sampleRate: Int) -> UInt64 {
        guard frameCount > 0, sampleRate > 0 else { return 0 }
        return UInt64(frameCount) * 10_000_000 / UInt64(sampleRate)
    }
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Run: `swift run --package-path mac-controller mac-controller-tests`

Expected: all tests pass, including contiguous and skipped QPC cases.

- [ ] **Step 5: Commit QPC diagnostics**

```bash
git add mac-controller/Sources/MacBridgeCore/AudioQPCJumpTracker.swift mac-controller/Sources/MacBridgeCoreTestRunner/main.swift
git commit -m "feat: track audio QPC jumps"
```

### Task 3: Decouple TCP receipt from AVFoundation playback

**Files:**
- Modify: `mac-controller/Sources/MacController/AudioStreamPlayer.swift`

**Interfaces:**
- Consumes: `LatestFrameBuffer<WindowsAudioFrame>`, `AudioBufferQueueLimiter`, and `AudioQPCJumpTracker`.
- Produces: independent `receiveLoop()` and `playbackLoop()` workers plus synchronized statistics logs.

- [ ] **Step 1: Split worker ownership and shutdown signals**

Add these fields and replace `start()`/`stop()`:

```swift
private let latestFrameBuffer = LatestFrameBuffer<WindowsAudioFrame>()
private let bufferQueueLimiter = AudioBufferQueueLimiter(maximumPendingBuffers: 1)
private let stateLock = NSLock()
private let statisticsLock = NSLock()
private var receiverWorker: Thread?
private var playbackWorker: Thread?
private var running = true
private var terminationReported = false

func start() {
    playbackWorker = Thread { [weak self] in self?.playbackLoop() }
    playbackWorker?.name = "AudioStreamPlayback"
    playbackWorker?.start()
    receiverWorker = Thread { [weak self] in self?.receiveLoop() }
    receiverWorker?.name = "AudioStreamReceiver"
    receiverWorker?.start()
}

func stop() {
    stateLock.lock()
    running = false
    terminationReported = true
    stateLock.unlock()
    latestFrameBuffer.stop()
    bufferQueueLimiter.stop()
    playerNode.stop()
    engine.stop()
}
```

Add a single-notification termination helper used by both workers:

```swift
private func finish(error: Error?) {
    stateLock.lock()
    let shouldNotify = !terminationReported
    running = false
    terminationReported = true
    stateLock.unlock()
    latestFrameBuffer.stop()
    bufferQueueLimiter.stop()
    if shouldNotify { onTermination(error) }
}
```

- [ ] **Step 2: Implement the nonblocking receiver loop**

```swift
private func receiveLoop() {
    var terminationError: Error?
    do {
        receiveFrames: while shouldRun {
            guard let header = try readExactly(byteCount: WindowsAudioFrameProtocol.headerLength) else { break }
            let payloadLength = try WindowsAudioFrameProtocol.payloadLength(from: header)
            guard let payload = try readExactly(byteCount: payloadLength) else {
                throw RuntimeError("audio stream closed before payload")
            }
            let frame = try WindowsAudioFrameProtocol.parse(payload: payload)
            let putResult = latestFrameBuffer.put(frame)
            recordReceived(frame: frame, putResult: putResult)
            if putResult == .stopped { break receiveFrames }
        }
    } catch {
        terminationError = error
        if shouldRun { print("audio receive failed: \(error)") }
    }
    finish(error: terminationError)
}
```

- [ ] **Step 3: Implement latest-only playback scheduling**

```swift
private func playbackLoop() {
    do {
        while shouldRun && bufferQueueLimiter.waitForSlot() {
            guard let frame = latestFrameBuffer.waitForLatest() else {
                bufferQueueLimiter.release()
                break
            }
            do {
                try configurePlaybackIfNeeded(for: frame.metadata)
                guard let playbackFormat,
                      let buffer = makeBuffer(frame: frame, playbackFormat: playbackFormat) else {
                    throw RuntimeError("failed to create PCM playback buffer")
                }
                playerNode.scheduleBuffer(buffer) { [weak self] in
                    self?.bufferQueueLimiter.release()
                }
                recordScheduled(frame: frame)
            } catch {
                bufferQueueLimiter.release()
                throw error
            }
        }
    } catch {
        if shouldRun { print("audio playback failed: \(error)") }
        finish(error: error)
    }
}
```

- [ ] **Step 4: Add synchronized counters and QPC logs**

Emit five-second summaries in this shape:

```text
audio stats elapsed=5.0s receivedFrames=500 droppedFrames=12 scheduledFrames=488 qpcJumps=1 pcmBytes=...
```

When `AudioQPCJumpTracker` returns a jump, print previous/current positions, actual delta, expected delta, and current dropped count.

Store `receivedFrames`, `droppedFrames`, `scheduledFrames`, `qpcJumps`, `receivedPcmBytes`, and an `AudioQPCJumpTracker` beside the existing statistics timer. Implement updates under `statisticsLock`:

```swift
private func recordReceived(frame: WindowsAudioFrame, putResult: LatestFramePutResult) {
    statisticsLock.lock()
    receivedFrames += 1
    receivedPcmBytes += frame.pcm.count
    if putResult == .replaced { droppedFrames += 1 }
    if statisticsStartedAt == nil { statisticsStartedAt = Date() }
    let elapsed = Date().timeIntervalSince(statisticsStartedAt ?? Date())
    let shouldLog = elapsed >= nextStatisticsLogAt
    if shouldLog { nextStatisticsLogAt += 5 }
    let snapshot = (receivedFrames, droppedFrames, scheduledFrames, qpcJumps, receivedPcmBytes)
    statisticsLock.unlock()
    if shouldLog {
        print(String(
            format: "audio stats elapsed=%.1fs receivedFrames=%d droppedFrames=%d scheduledFrames=%d qpcJumps=%d pcmBytes=%d engineRunning=%@ playerPlaying=%@",
            elapsed, snapshot.0, snapshot.1, snapshot.2, snapshot.3, snapshot.4,
            engine.isRunning.description, playerNode.isPlaying.description
        ))
    }
}

private func recordScheduled(frame: WindowsAudioFrame) {
    statisticsLock.lock()
    scheduledFrames += 1
    let jump = qpcJumpTracker.record(
        position: frame.metadata.qpcPosition,
        frameCount: frame.metadata.frameCount,
        sampleRate: frame.metadata.sampleRate
    )
    if jump != nil { qpcJumps += 1 }
    let droppedSnapshot = droppedFrames
    statisticsLock.unlock()
    if let jump {
        print(
            "audio qpc jump direction=\(jump.direction.rawValue) previous=\(jump.previousPosition) current=\(jump.currentPosition) actualDelta=\(jump.actualDelta.map(String.init) ?? \"n/a\") expectedDelta=\(jump.expectedDelta) droppedFrames=\(droppedSnapshot)"
        )
    }
}
```

- [ ] **Step 5: Run focused regression tests and build**

Run:

```bash
swift run --package-path mac-controller mac-controller-tests
swift build --package-path mac-controller
```

Expected: all tests pass and the debug executable builds without errors.

- [ ] **Step 6: Commit the player refactor**

```bash
git add mac-controller/Sources/MacController/AudioStreamPlayer.swift
git commit -m "fix: drop stale Mac audio frames"
```

### Task 4: Integration evidence and final branch verification

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: Windows Agent port 5055 and `scripts/start-mac-audio.sh`.
- Produces: final test/build output and runtime statistics evidence.

- [ ] **Step 1: Verify the Windows listener if reachable**

Use the configured Windows host from existing runtime state if present. Check port 5055 before starting the Mac client; do not invent an address.

- [ ] **Step 2: Run manual pause/resume validation when the Windows host is available**

Start `scripts/start-mac-audio.sh <Windows-IP> 5055`, play time-referenced audio, send `SIGSTOP` for about one second and then `SIGCONT`, and repeat. Confirm playback resumes near current audio and logs show dropped frames/QPC jumps without stepwise delay growth.

- [ ] **Step 3: Run fresh final verification**

Run the complete test runner, build, `git diff --check`, and inspect `git status --short` and recent commits. Report any environmental limitation instead of claiming unperformed manual validation.
