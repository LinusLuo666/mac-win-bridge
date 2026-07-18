# Configurable Audio Jitter Buffer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bounded, configurable 10–120 ms Mac PCM jitter buffer that defaults to 50 ms, absorbs TCP delivery bursts, and trims stale audio without permanent latency growth.

**Architecture:** The TCP receiver parses, decodes, and reblocks PCM without waiting for CoreAudio, then enqueues 512-frame outputs into a bounded jitter buffer. A scheduler waits for the configured prebuffer threshold, keeps at most two buffers scheduled, re-primes after underrun, and trims the oldest queued blocks above the target plus 20 ms.

**Tech Stack:** Swift 6, Foundation synchronization, AVFoundation, Bash, Python 3 standard library, and `MacBridgeCoreTestRunner`.

## Global Constraints

- Work only on `m1-audio-bridge`; do not create branches or worktrees.
- Commit each independently testable task immediately.
- Preserve the Windows protocol, TCP settings, 480-frame input, 512-frame output, and two-buffer schedule limit.
- Keep the manager TCP reachability probe unchanged.
- Accept whole-number values from 10 through 120 ms; default to 50 ms.
- Keep `LatestFrameBuffer` and its tests, but remove it from the active player path.
- Stop/disconnect must clear carry and queued PCM and wake every waiter.
- Never commit `.runtime/` or packet captures.

## File Map

- Create `mac-controller/Sources/MacBridgeCore/PCMOutputJitterBuffer.swift`.
- Modify `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`.
- Modify `mac-controller/Sources/MacController/AudioStreamPlayer.swift`.
- Modify `mac-controller/Sources/MacBridgeCore/AudioEvidenceTracker.swift`.
- Modify `mac-controller/Sources/MacController/main.swift`.
- Modify `scripts/start-mac-audio.sh`.
- Modify `scripts/audio-bridge-manager.py`.
- Create `scripts/tests/test_audio_bridge_manager.py`.
- Modify `README.md`.

---

### Task 1: Bounded PCM jitter-buffer core

**Files:**
- Create: `mac-controller/Sources/MacBridgeCore/PCMOutputJitterBuffer.swift`
- Modify: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Consumes: `ReblockedPCMOutput`.
- Produces: `AudioLatencySetting`, `PCMOutputJitterBuffer`, state, thresholds, enqueue result, and snapshot types.

- [ ] **Step 1: Write failing tests**

Add a 512-frame output fixture with known QPC. Test input validation, rounded thresholds, priming, order, burst preservation, oldest trimming, underrun/rebuffer, conservation, metadata, and stop wakeup.

```swift
try expectEqual(AudioLatencySetting.parse("10"), 10, "minimum")
try expectEqual(AudioLatencySetting.parse("120"), 120, "maximum")
try expectNil(AudioLatencySetting.parse("9"), "below minimum")
try expectNil(AudioLatencySetting.parse("50.5"), "whole milliseconds")

let balanced = PCMOutputJitterBuffer.thresholds(
    sampleRate: 48_000,
    requestedLatencyMilliseconds: 50
)
try expectEqual(balanced.targetSampleFrames, 2_560, "rounded target")
try expectEqual(balanced.maximumSampleFrames, 3_584, "target plus margin")
```

Start a waiter thread before five blocks are queued and assert it remains blocked. Enqueue five blocks, assert the first QPC is returned, complete/drain all scheduled blocks, assert `.priming`, then call `stop()` and assert waiting returns `nil`.

- [ ] **Step 2: Verify RED**

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/macwinbridge-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/macwinbridge-swiftpm-cache \
  swift run --disable-sandbox \
  --scratch-path /private/tmp/macwinbridge-swift-build \
  --package-path mac-controller mac-controller-tests
```

Expected: compile failure for missing jitter-buffer types.

- [ ] **Step 3: Implement the core API**

```swift
public enum AudioLatencySetting {
    public static let minimumMilliseconds = 10
    public static let maximumMilliseconds = 120
    public static let defaultMilliseconds = 50
    public static func parse(_ value: String) -> Int?
}

public enum PCMOutputJitterBufferState: Equatable, Sendable {
    case priming, playing, stopped
}

public final class PCMOutputJitterBuffer: @unchecked Sendable {
    public init(requestedLatencyMilliseconds: Int)
    public static func thresholds(
        sampleRate: Int,
        requestedLatencyMilliseconds: Int,
        blockSampleFrames: Int = PCMReblocker.outputFrameCount,
        marginMilliseconds: Int = 20
    ) -> PCMOutputJitterBufferThresholds
    public func enqueue(
        _ outputs: [ReblockedPCMOutput],
        at date: Date = Date()
    ) -> PCMOutputJitterBufferEnqueueResult
    public func waitForNextToSchedule() -> ReblockedPCMOutput?
    public func completeScheduled(sampleFrames: Int, at date: Date = Date())
    public func snapshot() -> PCMOutputJitterBufferSnapshot
    public func stop()
}
```

Use one `NSCondition`. Derive thresholds from the first output sample rate. Enqueue never waits. If `queued + scheduledPending > maximum`, remove oldest queued blocks until the total is at or below target. Enter `.playing` at target. Dequeue blocks during priming/empty-playing and atomically increments scheduled-pending frames. Completion decrements pending; zero pending plus empty queue enters priming and records an underrun/rebuffer interval. Stop clears and broadcasts.

- [ ] **Step 4: Verify GREEN and build**

Run Step 2, then:

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/macwinbridge-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/macwinbridge-swiftpm-cache \
  swift build --disable-sandbox \
  --scratch-path /private/tmp/macwinbridge-swift-build \
  --package-path mac-controller
```

- [ ] **Step 5: Commit**

```bash
git add mac-controller/Sources/MacBridgeCore/PCMOutputJitterBuffer.swift \
  mac-controller/Sources/MacBridgeCoreTestRunner/main.swift
git commit -m "feat: add bounded PCM jitter buffer"
```

---

### Task 2: Playback-pipeline integration

**Files:**
- Modify: `mac-controller/Sources/MacController/AudioStreamPlayer.swift`
- Modify: `mac-controller/Sources/MacBridgeCore/AudioEvidenceTracker.swift`
- Modify: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Consumes: Task 1 jitter buffer.
- Produces: `AudioStreamPlayer(... latencyMilliseconds: Int ...)` and jitter evidence.

- [ ] **Step 1: Write failing evidence tests**

Add `recordJitterBuffer(...)` to the evidence tracker contract. Test configured/effective latency, queued/pending frames, trim deltas, underrun/rebuffer deltas, duration, and maximum depth. Reset must clear deltas but preserve gauges.

- [ ] **Step 2: Verify RED**

Run Task 1 tests. Expected: missing evidence API compile failure.

- [ ] **Step 3: Implement receiver/scheduler separation**

Remove `latestFrameBuffer` from `AudioStreamPlayer`. Add a jitter-buffer property and latency initializer argument. In `receiveLoop`:

```swift
recordReceived(frame: frame)
try configurePlaybackIfNeeded(for: frame.metadata)
let outputs = try reblocker.append(decodeInputBlock(frame: frame))
recordReblocked(outputs: outputs, carrySampleFrames: reblocker.carrySampleFrames)
let result = jitterBuffer.enqueue(outputs)
recordJitterBuffer(enqueueResult: result)
```

In `playbackLoop`:

```swift
while shouldRun {
    guard bufferQueueLimiter.waitForSlot() else { return }
    guard let output = jitterBuffer.waitForNextToSchedule() else { return }
    let frames = Int(output.buffer.frameLength)
    playerNode.scheduleBuffer(output.buffer) { [weak self] in
        guard let self else { return }
        jitterBuffer.completeScheduled(sampleFrames: frames)
        bufferQueueLimiter.release()
        recordCompleted(outputSampleFrames: frames)
        recordJitterBuffer(enqueueResult: nil)
    }
    recordScheduled(output: output)
    recordJitterBuffer(enqueueResult: nil)
}
```

Stop the jitter buffer from both stop paths. Keep limiter capacity two. Compute counter deltas under `statisticsLock`; add requested/effective latency, queue, pending, trimmed, underrun, rebuffer, duration, and maximum-depth fields to five-second logs.

- [ ] **Step 4: Verify**

Run Swift tests/build, then:

```bash
git diff --check
rg -n "latestFrameBuffer|overwrittenInput" \
  mac-controller/Sources/MacController/AudioStreamPlayer.swift
```

Expected: build/tests pass, diff check is silent, and no active latest/overwrite path remains.

- [ ] **Step 5: Commit**

```bash
git add mac-controller/Sources/MacController/AudioStreamPlayer.swift \
  mac-controller/Sources/MacBridgeCore/AudioEvidenceTracker.swift \
  mac-controller/Sources/MacBridgeCoreTestRunner/main.swift
git commit -m "fix: buffer bursty Mac audio playback"
```

---

### Task 3: CLI and launch-script configuration

**Files:**
- Modify: `mac-controller/Sources/MacController/main.swift`
- Modify: `scripts/start-mac-audio.sh`
- Modify: `mac-controller/Sources/MacBridgeCoreTestRunner/main.swift`

**Interfaces:**
- Consumes: `AudioLatencySetting` and the Task 2 player initializer.
- Produces: `ControllerOptions.audioLatencyMilliseconds`, `--audio-latency-ms`, and `AUDIO_LATENCY_MS`.

- [ ] **Step 1: Write failing boundary tests**

Assert `10`, `50`, and `120` pass; `9`, `121`, `50.5`, and `abc` fail. Confirm the default constant equals 50.

- [ ] **Step 2: Implement CLI and script forwarding**

Default `ControllerOptions.audioLatencyMilliseconds` to 50 and parse:

```swift
case "--audio-latency-ms":
    guard index + 1 < args.count,
          let latency = AudioLatencySetting.parse(args[index + 1]) else {
        return nil
    }
    audioLatencyMilliseconds = latency
    index += 2
```

Pass the value to both player construction sites, add it to usage, and log it. Update the script:

```bash
AUDIO_LATENCY_MS="${AUDIO_LATENCY_MS:-50}"

exec swift run \
  --package-path "$ROOT_DIR/mac-controller" \
  mac-controller "$WINDOWS_HOST" "$PORT" \
  --audio-only \
  --audio-mode "$AUDIO_MODE" \
  --audio-latency-ms "$AUDIO_LATENCY_MS" \
  --volume "$AUDIO_VOLUME"
```

- [ ] **Step 3: Verify**

Run Swift tests/build, then:

```bash
bash -n scripts/start-mac-audio.sh
rg -n -- "--audio-latency-ms|AUDIO_LATENCY_MS" \
  mac-controller/Sources/MacController/main.swift scripts/start-mac-audio.sh
```

- [ ] **Step 4: Commit**

```bash
git add mac-controller/Sources/MacController/main.swift \
  mac-controller/Sources/MacBridgeCoreTestRunner/main.swift \
  scripts/start-mac-audio.sh
git commit -m "feat: configure Mac audio latency"
```

---

### Task 4: Manager presets and persistence

**Files:**
- Modify: `scripts/audio-bridge-manager.py`
- Create: `scripts/tests/test_audio_bridge_manager.py`

**Interfaces:**
- Consumes: Task 3 `AUDIO_LATENCY_MS`.
- Produces: persisted `latency_ms`, 20/50/80 presets, a 10–120 slider, and process environment forwarding.

- [ ] **Step 1: Write failing Python tests**

Import the hyphenated script with `importlib.util.spec_from_file_location`, redirect runtime paths to a `TemporaryDirectory`, and test:

```python
self.assertEqual(module.load_config()["latency_ms"], 50)
module.save_config("192.168.137.1", 5055, 80)
self.assertEqual(module.load_config()["latency_ms"], 80)

with mock.patch.object(module.subprocess, "Popen") as popen:
    popen.return_value.pid = 1234
    module.start_audio("192.168.137.1", 5055, 20)
    environment = popen.call_args.kwargs["env"]
    self.assertEqual(environment["AUDIO_LATENCY_MS"], "20")
```

Assert invalid persistence falls back to 50. Assert rendered HTML contains `min="10"`, `max="120"`, presets 20/50/80, the block-rounded effective value at 48 kHz, and the unchanged `Port check`.

- [ ] **Step 2: Verify RED**

```bash
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

Expected: failures because latency persistence/forwarding is absent.

- [ ] **Step 3: Implement manager behavior**

```python
DEFAULT_LATENCY_MS = 50
MIN_LATENCY_MS = 10
MAX_LATENCY_MS = 120

def valid_latency_ms(value):
    try:
        latency = int(value)
    except (TypeError, ValueError):
        return DEFAULT_LATENCY_MS
    return latency if MIN_LATENCY_MS <= latency <= MAX_LATENCY_MS else DEFAULT_LATENCY_MS
```

Include `latency_ms` in load/save and POST handling. Change `start_audio(host, port, latency_ms)` to copy `os.environ`, set `AUDIO_LATENCY_MS`, and pass `env=environment` to `Popen`. Add preset buttons plus synchronized range/number inputs. Display the requested value and the effective value computed as `ceil(48_000 * latency_ms / 1_000 / 512) * 512 / 48_000 * 1_000`. Do not modify `tcp_status`, refresh frequency, or Port check.

- [ ] **Step 4: Verify GREEN**

```bash
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
python3 -m py_compile scripts/audio-bridge-manager.py \
  scripts/tests/test_audio_bridge_manager.py
```

Then run Swift tests/build. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/audio-bridge-manager.py scripts/tests/test_audio_bridge_manager.py
git commit -m "feat: add audio latency controls to manager"
```

---

### Task 5: Documentation and complete validation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: user instructions, verification evidence, live preset results, and final pushed SHA.

- [ ] **Step 1: Document usage and trade-offs**

```bash
# Balanced default
scripts/start-mac-audio.sh 192.168.137.1 5055

# Presets
AUDIO_LATENCY_MS=20 scripts/start-mac-audio.sh 192.168.137.1 5055
AUDIO_LATENCY_MS=50 scripts/start-mac-audio.sh 192.168.137.1 5055
AUDIO_LATENCY_MS=80 scripts/start-mac-audio.sh 192.168.137.1 5055
```

Explain 512-frame upward rounding, preset trade-offs, rebuffering, and stale-audio trimming.

- [ ] **Step 2: Run complete automated verification**

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/macwinbridge-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/macwinbridge-swiftpm-cache \
  swift run --disable-sandbox \
  --scratch-path /private/tmp/macwinbridge-swift-build \
  --package-path mac-controller mac-controller-tests

env CLANG_MODULE_CACHE_PATH=/private/tmp/macwinbridge-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/macwinbridge-swiftpm-cache \
  swift build --disable-sandbox \
  --scratch-path /private/tmp/macwinbridge-swift-build \
  --package-path mac-controller

python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
bash -n scripts/start-mac-audio.sh
git diff --check
```

Expected: all tests/builds pass and diff check is silent.

- [ ] **Step 3: Commit documentation**

```bash
git add README.md
git commit -m "docs: document configurable audio latency"
```

- [ ] **Step 4: Run live preset windows**

Ensure only one Mac audio process exists. Run 20, 50, and 80 ms separately for at least 60 seconds against `192.168.137.1:5055`. For each window report requested/effective latency, received/reblocked/queued/scheduled/completed/trimmed sample frames, underrun/rebuffer counts/duration, maximum arrival gap, maximum queue depth, QPC jumps, continuity, and approximate delay.

- [ ] **Step 5: Verify branch and push**

```bash
git status --short --branch
git log -7 --oneline --decorate
git push origin m1-audio-bridge
```

Expected: only `.runtime/` is untracked, all five implementation commits follow the design/plan commits, and the remote advances to the final verified SHA.
