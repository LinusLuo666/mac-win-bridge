# M0 Input Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal Mac-to-Windows keyboard bridge proof of concept that captures Mac keyboard events, forwards stable key messages over TCP, and injects them into Windows with `SendInput`.

**Architecture:** The Mac side is a Swift Package with a unit-testable `MacBridgeCore` library and a tiny `mac-controller` executable. The Windows side is a .NET console app with unit-testable protocol and key mapping code plus a thin Win32 `SendInput` adapter. The protocol is newline-delimited JSON documented under `docs/protocol`.

**Tech Stack:** Swift 6.3, Swift Package Manager, XCTest, CoreGraphics `CGEventTap`, Foundation TCP sockets, C#/.NET 8, xUnit, Win32 `SendInput`.

---

## File Structure

- Create `docs/protocol/keyboard-json-lines.md`: human-readable M0 protocol contract and examples.
- Create `mac-controller/Package.swift`: Swift package definition.
- Create `mac-controller/Sources/MacBridgeCore/KeyboardMessage.swift`: protocol models and JSON line encoder.
- Create `mac-controller/Sources/MacBridgeCore/MacKeyMapper.swift`: macOS key-code to stable key identifier mapping.
- Create `mac-controller/Sources/MacBridgeCore/EscapeShortcut.swift`: local escape shortcut detection.
- Create `mac-controller/Sources/MacController/main.swift`: CLI event tap, TCP sender, and forwarding loop.
- Create `mac-controller/Tests/MacBridgeCoreTests/KeyboardMessageTests.swift`: Swift protocol encoder tests.
- Create `mac-controller/Tests/MacBridgeCoreTests/MacKeyMapperTests.swift`: Swift key mapping tests.
- Create `mac-controller/Tests/MacBridgeCoreTests/EscapeShortcutTests.swift`: Swift escape shortcut tests.
- Create `windows-agent/WindowsAgent.sln`: .NET solution.
- Create `windows-agent/src/WindowsAgent/WindowsAgent.csproj`: console app project.
- Create `windows-agent/src/WindowsAgent/Program.cs`: TCP listener and message dispatch.
- Create `windows-agent/src/WindowsAgent/KeyboardMessage.cs`: protocol model and decoder.
- Create `windows-agent/src/WindowsAgent/WindowsKeyMapper.cs`: stable key identifier to virtual-key mapping.
- Create `windows-agent/src/WindowsAgent/SendInputKeyboardInjector.cs`: Win32 injection adapter.
- Create `windows-agent/tests/WindowsAgent.Tests/WindowsAgent.Tests.csproj`: xUnit test project.
- Create `windows-agent/tests/WindowsAgent.Tests/KeyboardMessageTests.cs`: decoder tests.
- Create `windows-agent/tests/WindowsAgent.Tests/WindowsKeyMapperTests.cs`: Windows key mapping tests.
- Modify `README.md`: add M0 build and manual validation instructions.

## Task 1: Protocol Document

**Files:**
- Create: `docs/protocol/keyboard-json-lines.md`

- [ ] **Step 1: Write the protocol contract**

Create `docs/protocol/keyboard-json-lines.md` with:

```markdown
# Keyboard JSON Lines Protocol

M0 uses one UTF-8 JSON object per line. Each line represents one keyboard event from the Mac controller to the Windows agent.

## Key Message

```json
{"type":"key","event":"down","key":"KeyA","modifiers":["shift"],"sequence":42}
```

Fields:

- `type`: `key`.
- `event`: `down`, `up`, or `flagsChanged`.
- `key`: stable physical/logical key identifier, such as `KeyA`, `Digit1`, `Enter`, `Tab`, `Escape`, `ArrowLeft`, `Backspace`, or `Space`.
- `modifiers`: active modifiers from `shift`, `control`, `option`, `command`, `capsLock`, and `fn`.
- `sequence`: monotonically increasing integer assigned by the sender.

Rules:

- Messages are newline-delimited with `\n`.
- Printable text is never sent.
- Unknown message types are ignored by receivers.
- Malformed JSON is rejected without terminating the receiver.
- `Control + Option + Escape` is a local Mac escape shortcut and is never sent.
```

- [ ] **Step 2: Commit**

Run:

```bash
git add docs/protocol/keyboard-json-lines.md
git commit -m "docs: add keyboard protocol contract"
```

Expected: commit succeeds.

## Task 2: Swift Package Scaffold

**Files:**
- Create: `mac-controller/Package.swift`
- Create: `mac-controller/Sources/MacBridgeCore/KeyboardMessage.swift`
- Create: `mac-controller/Sources/MacController/main.swift`

- [ ] **Step 1: Create the Swift package definition**

Create `mac-controller/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacController",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacBridgeCore", targets: ["MacBridgeCore"]),
        .executable(name: "mac-controller", targets: ["MacController"])
    ],
    targets: [
        .target(name: "MacBridgeCore"),
        .executableTarget(
            name: "MacController",
            dependencies: ["MacBridgeCore"]
        ),
        .testTarget(
            name: "MacBridgeCoreTests",
            dependencies: ["MacBridgeCore"]
        )
    ]
)
```

- [ ] **Step 2: Add the initial core event type**

Create `mac-controller/Sources/MacBridgeCore/KeyboardMessage.swift`:

```swift
import Foundation

public enum KeyboardEventKind: String, Codable, Equatable {
    case down
    case up
    case flagsChanged
}
```

- [ ] **Step 3: Add a minimal executable**

Create `mac-controller/Sources/MacController/main.swift`:

```swift
import Foundation

print("mac-controller M0 scaffold")
```

- [ ] **Step 4: Build the scaffold**

Run:

```bash
swift build --package-path mac-controller
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

Run:

```bash
git add mac-controller
git commit -m "build: scaffold mac controller package"
```

Expected: commit succeeds.

## Task 3: Swift Keyboard Protocol Encoder

**Files:**
- Modify: `mac-controller/Sources/MacBridgeCore/KeyboardMessage.swift`
- Create: `mac-controller/Tests/MacBridgeCoreTests/KeyboardMessageTests.swift`

- [ ] **Step 1: Write failing encoder tests**

Create `mac-controller/Tests/MacBridgeCoreTests/KeyboardMessageTests.swift`:

```swift
import XCTest
@testable import MacBridgeCore

final class KeyboardMessageTests: XCTestCase {
    func testEncodesKeyMessageAsOneJsonLine() throws {
        let message = KeyboardMessage(
            event: .down,
            key: "KeyA",
            modifiers: [.shift],
            sequence: 42
        )

        let line = try message.jsonLine()

        XCTAssertEqual(line, #"{"type":"key","event":"down","key":"KeyA","modifiers":["shift"],"sequence":42}"# + "\n")
    }

    func testEncodesEmptyModifiers() throws {
        let message = KeyboardMessage(
            event: .up,
            key: "Enter",
            modifiers: [],
            sequence: 7
        )

        let line = try message.jsonLine()

        XCTAssertEqual(line, #"{"type":"key","event":"up","key":"Enter","modifiers":[],"sequence":7}"# + "\n")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --package-path mac-controller --filter KeyboardMessageTests
```

Expected: FAIL because `KeyboardMessage`, `KeyboardModifier`, or `jsonLine()` is not defined.

- [ ] **Step 3: Implement the encoder**

Replace `mac-controller/Sources/MacBridgeCore/KeyboardMessage.swift` with:

```swift
import Foundation

public enum KeyboardEventKind: String, Codable, Equatable {
    case down
    case up
    case flagsChanged
}

public enum KeyboardModifier: String, Codable, Equatable, Comparable {
    case shift
    case control
    case option
    case command
    case capsLock
    case fn

    public static func < (lhs: KeyboardModifier, rhs: KeyboardModifier) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ modifier: KeyboardModifier) -> Int {
        switch modifier {
        case .shift: return 0
        case .control: return 1
        case .option: return 2
        case .command: return 3
        case .capsLock: return 4
        case .fn: return 5
        }
    }
}

public struct KeyboardMessage: Codable, Equatable {
    public let type: String
    public let event: KeyboardEventKind
    public let key: String
    public let modifiers: [KeyboardModifier]
    public let sequence: Int

    public init(event: KeyboardEventKind, key: String, modifiers: [KeyboardModifier], sequence: Int) {
        self.type = "key"
        self.event = event
        self.key = key
        self.modifiers = modifiers.sorted()
        self.sequence = sequence
    }

    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
swift test --package-path mac-controller --filter KeyboardMessageTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add mac-controller/Sources/MacBridgeCore/KeyboardMessage.swift mac-controller/Tests/MacBridgeCoreTests/KeyboardMessageTests.swift
git commit -m "feat: encode keyboard protocol messages"
```

Expected: commit succeeds.

## Task 4: Swift Key Mapping and Escape Detection

**Files:**
- Create: `mac-controller/Sources/MacBridgeCore/MacKeyMapper.swift`
- Create: `mac-controller/Sources/MacBridgeCore/EscapeShortcut.swift`
- Create: `mac-controller/Tests/MacBridgeCoreTests/MacKeyMapperTests.swift`
- Create: `mac-controller/Tests/MacBridgeCoreTests/EscapeShortcutTests.swift`

- [ ] **Step 1: Write failing mapping tests**

Create `mac-controller/Tests/MacBridgeCoreTests/MacKeyMapperTests.swift`:

```swift
import XCTest
@testable import MacBridgeCore

final class MacKeyMapperTests: XCTestCase {
    func testMapsLetterDigitAndSpecialKeys() {
        XCTAssertEqual(MacKeyMapper.stableKey(for: 0), "KeyA")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 11), "KeyB")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 18), "Digit1")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 36), "Enter")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 48), "Tab")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 49), "Space")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 51), "Backspace")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 53), "Escape")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 123), "ArrowLeft")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 124), "ArrowRight")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 125), "ArrowDown")
        XCTAssertEqual(MacKeyMapper.stableKey(for: 126), "ArrowUp")
    }

    func testReturnsNilForUnsupportedKeyCode() {
        XCTAssertNil(MacKeyMapper.stableKey(for: 999))
    }
}
```

- [ ] **Step 2: Write failing escape shortcut tests**

Create `mac-controller/Tests/MacBridgeCoreTests/EscapeShortcutTests.swift`:

```swift
import XCTest
@testable import MacBridgeCore

final class EscapeShortcutTests: XCTestCase {
    func testRecognizesControlOptionEscape() {
        XCTAssertTrue(EscapeShortcut.isEscape(keyCode: 53, modifiers: [.control, .option]))
    }

    func testRejectsSimilarShortcuts() {
        XCTAssertFalse(EscapeShortcut.isEscape(keyCode: 53, modifiers: [.control]))
        XCTAssertFalse(EscapeShortcut.isEscape(keyCode: 53, modifiers: [.option]))
        XCTAssertFalse(EscapeShortcut.isEscape(keyCode: 36, modifiers: [.control, .option]))
        XCTAssertFalse(EscapeShortcut.isEscape(keyCode: 53, modifiers: [.control, .option, .shift]))
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
swift test --package-path mac-controller --filter MacBridgeCoreTests
```

Expected: FAIL because `MacKeyMapper` and `EscapeShortcut` are not defined.

- [ ] **Step 4: Implement mapping and escape detection**

Create `mac-controller/Sources/MacBridgeCore/MacKeyMapper.swift`:

```swift
import Foundation

public enum MacKeyMapper {
    private static let mapping: [Int: String] = [
        0: "KeyA", 11: "KeyB", 8: "KeyC", 2: "KeyD", 14: "KeyE", 3: "KeyF",
        5: "KeyG", 4: "KeyH", 34: "KeyI", 38: "KeyJ", 40: "KeyK", 37: "KeyL",
        46: "KeyM", 45: "KeyN", 31: "KeyO", 35: "KeyP", 12: "KeyQ", 15: "KeyR",
        1: "KeyS", 17: "KeyT", 32: "KeyU", 9: "KeyV", 13: "KeyW", 7: "KeyX",
        16: "KeyY", 6: "KeyZ",
        18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 23: "Digit5",
        22: "Digit6", 26: "Digit7", 28: "Digit8", 25: "Digit9", 29: "Digit0",
        36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape",
        117: "Delete", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown",
        126: "ArrowUp",
        27: "Minus", 24: "Equal", 33: "BracketLeft", 30: "BracketRight",
        42: "Backslash", 41: "Semicolon", 39: "Quote", 43: "Comma",
        47: "Period", 44: "Slash", 50: "Backquote"
    ]

    public static func stableKey(for keyCode: Int) -> String? {
        mapping[keyCode]
    }
}
```

Create `mac-controller/Sources/MacBridgeCore/EscapeShortcut.swift`:

```swift
import Foundation

public enum EscapeShortcut {
    public static func isEscape(keyCode: Int, modifiers: Set<KeyboardModifier>) -> Bool {
        keyCode == 53 && modifiers == [.control, .option]
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run:

```bash
swift test --package-path mac-controller --filter MacBridgeCoreTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add mac-controller/Sources/MacBridgeCore/MacKeyMapper.swift mac-controller/Sources/MacBridgeCore/EscapeShortcut.swift mac-controller/Tests/MacBridgeCoreTests/MacKeyMapperTests.swift mac-controller/Tests/MacBridgeCoreTests/EscapeShortcutTests.swift
git commit -m "feat: map mac keyboard events"
```

Expected: commit succeeds.

## Task 5: Mac Controller CLI

**Files:**
- Modify: `mac-controller/Sources/MacController/main.swift`

- [ ] **Step 1: Replace the scaffold with the CLI sender**

Replace `mac-controller/Sources/MacController/main.swift` with:

```swift
import CoreGraphics
import Foundation
import MacBridgeCore

final class TcpLineSender {
    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    func connect(host: String, port: Int) throws {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)

        guard let read = readStream?.takeRetainedValue(),
              let write = writeStream?.takeRetainedValue() else {
            throw RuntimeError("failed to create TCP streams")
        }

        inputStream = read
        outputStream = write
        inputStream?.open()
        outputStream?.open()
    }

    func send(_ line: String) throws {
        guard let outputStream else {
            throw RuntimeError("TCP output stream is not connected")
        }

        let bytes = Array(line.utf8)
        let written = outputStream.write(bytes, maxLength: bytes.count)
        if written != bytes.count {
            throw RuntimeError("failed to send full message")
        }
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

final class KeyboardForwarder {
    private let sender: TcpLineSender
    private var sequence = 0
    private var shouldStop = false

    init(sender: TcpLineSender) {
        self.sender = sender
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Self.modifiers(from: event.flags)

        if EscapeShortcut.isEscape(keyCode: keyCode, modifiers: modifiers) {
            print("escape shortcut received; stopping forwarding")
            shouldStop = true
            CFRunLoopStop(CFRunLoopGetMain())
            return nil
        }

        guard let stableKey = MacKeyMapper.stableKey(for: keyCode) else {
            print("unsupported keyCode=\(keyCode)")
            return Unmanaged.passUnretained(event)
        }

        guard let eventKind = Self.eventKind(from: type) else {
            return Unmanaged.passUnretained(event)
        }

        sequence += 1
        let message = KeyboardMessage(
            event: eventKind,
            key: stableKey,
            modifiers: Array(modifiers),
            sequence: sequence
        )

        do {
            try sender.send(message.jsonLine())
            print("forwarded sequence=\(sequence) event=\(eventKind.rawValue) key=\(stableKey)")
            return nil
        } catch {
            print("send failed: \(error)")
            shouldStop = true
            CFRunLoopStop(CFRunLoopGetMain())
            return nil
        }
    }

    private static func eventKind(from type: CGEventType) -> KeyboardEventKind? {
        switch type {
        case .keyDown:
            return .down
        case .keyUp:
            return .up
        case .flagsChanged:
            return .flagsChanged
        default:
            return nil
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> Set<KeyboardModifier> {
        var modifiers = Set<KeyboardModifier>()
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlphaShift) { modifiers.insert(.capsLock) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.fn) }
        return modifiers
    }
}

let args = CommandLine.arguments
guard args.count == 3, let port = Int(args[2]) else {
    print("usage: mac-controller <windows-host> <port>")
    exit(64)
}

guard AXIsProcessTrusted() else {
    print("missing Accessibility/Input Monitoring permission for keyboard event capture")
    exit(77)
}

let sender = TcpLineSender()
do {
    try sender.connect(host: args[1], port: port)
} catch {
    print("connection failed: \(error)")
    exit(69)
}

let forwarder = KeyboardForwarder(sender: sender)
let mask = (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(mask),
    callback: { proxy, type, event, refcon in
        let forwarder = Unmanaged<KeyboardForwarder>.fromOpaque(refcon!).takeUnretainedValue()
        return forwarder.handle(proxy: proxy, type: type, event: event)
    },
    userInfo: Unmanaged.passUnretained(forwarder).toOpaque()
) else {
    print("failed to create CGEventTap")
    exit(77)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("forwarding keyboard events to \(args[1]):\(port); press Control+Option+Escape to stop")
CFRunLoopRun()
```

- [ ] **Step 2: Build the CLI**

Run:

```bash
swift build --package-path mac-controller
```

Expected: build succeeds.

- [ ] **Step 3: Run Swift tests**

Run:

```bash
swift test --package-path mac-controller
```

Expected: PASS.

- [ ] **Step 4: Commit**

Run:

```bash
git add mac-controller/Sources/MacController/main.swift
git commit -m "feat: forward mac keyboard events over tcp"
```

Expected: commit succeeds.

## Task 6: Windows Protocol Decoder and Key Mapping

**Files:**
- Create: `windows-agent/src/WindowsAgent/WindowsAgent.csproj`
- Create: `windows-agent/src/WindowsAgent/KeyboardMessage.cs`
- Create: `windows-agent/src/WindowsAgent/WindowsKeyMapper.cs`
- Create: `windows-agent/tests/WindowsAgent.Tests/WindowsAgent.Tests.csproj`
- Create: `windows-agent/tests/WindowsAgent.Tests/KeyboardMessageTests.cs`
- Create: `windows-agent/tests/WindowsAgent.Tests/WindowsKeyMapperTests.cs`

- [ ] **Step 1: Create project files**

Create `windows-agent/src/WindowsAgent/WindowsAgent.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
  </PropertyGroup>
</Project>
```

Create `windows-agent/tests/WindowsAgent.Tests/WindowsAgent.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0-windows</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.10.0" />
    <PackageReference Include="xunit" Version="2.8.1" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.1" />
    <ProjectReference Include="../../src/WindowsAgent/WindowsAgent.csproj" />
  </ItemGroup>
</Project>
```

- [ ] **Step 2: Write failing decoder tests**

Create `windows-agent/tests/WindowsAgent.Tests/KeyboardMessageTests.cs`:

```csharp
using WindowsAgent;

namespace WindowsAgent.Tests;

public sealed class KeyboardMessageTests
{
    [Fact]
    public void ParsesValidKeyMessage()
    {
        var message = KeyboardMessage.Parse("""{"type":"key","event":"down","key":"KeyA","modifiers":["shift"],"sequence":42}""");

        Assert.NotNull(message);
        Assert.Equal("down", message.Event);
        Assert.Equal("KeyA", message.Key);
        Assert.Equal(new[] { "shift" }, message.Modifiers);
        Assert.Equal(42, message.Sequence);
    }

    [Fact]
    public void RejectsMalformedJson()
    {
        Assert.Null(KeyboardMessage.Parse("{not-json"));
    }

    [Fact]
    public void RejectsUnknownMessageType()
    {
        Assert.Null(KeyboardMessage.Parse("""{"type":"mouse","event":"down","key":"KeyA","modifiers":[],"sequence":1}"""));
    }
}
```

- [ ] **Step 3: Write failing key mapper tests**

Create `windows-agent/tests/WindowsAgent.Tests/WindowsKeyMapperTests.cs`:

```csharp
using WindowsAgent;

namespace WindowsAgent.Tests;

public sealed class WindowsKeyMapperTests
{
    [Theory]
    [InlineData("KeyA", 0x41)]
    [InlineData("Digit1", 0x31)]
    [InlineData("Enter", 0x0D)]
    [InlineData("Tab", 0x09)]
    [InlineData("Space", 0x20)]
    [InlineData("Backspace", 0x08)]
    [InlineData("Escape", 0x1B)]
    [InlineData("ArrowLeft", 0x25)]
    [InlineData("ArrowRight", 0x27)]
    [InlineData("ArrowDown", 0x28)]
    [InlineData("ArrowUp", 0x26)]
    public void MapsStableKeysToVirtualKeys(string stableKey, ushort expectedVirtualKey)
    {
        Assert.True(WindowsKeyMapper.TryMap(stableKey, out var virtualKey));
        Assert.Equal(expectedVirtualKey, virtualKey);
    }

    [Fact]
    public void RejectsUnknownStableKey()
    {
        Assert.False(WindowsKeyMapper.TryMap("UnknownKey", out _));
    }
}
```

- [ ] **Step 4: Run tests to verify failure on Windows or .NET SDK environment**

Run:

```bash
dotnet test windows-agent/tests/WindowsAgent.Tests/WindowsAgent.Tests.csproj
```

Expected: FAIL because `KeyboardMessage` and `WindowsKeyMapper` are not defined.

- [ ] **Step 5: Implement decoder and mapper**

Create `windows-agent/src/WindowsAgent/KeyboardMessage.cs`:

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsAgent;

public sealed record KeyboardMessage(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("event")] string Event,
    [property: JsonPropertyName("key")] string Key,
    [property: JsonPropertyName("modifiers")] string[] Modifiers,
    [property: JsonPropertyName("sequence")] long Sequence)
{
    public static KeyboardMessage? Parse(string line)
    {
        try
        {
            var message = JsonSerializer.Deserialize<KeyboardMessage>(line);
            return message is { Type: "key" } ? message : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
```

Create `windows-agent/src/WindowsAgent/WindowsKeyMapper.cs`:

```csharp
namespace WindowsAgent;

public static class WindowsKeyMapper
{
    private static readonly IReadOnlyDictionary<string, ushort> Keys = new Dictionary<string, ushort>
    {
        ["KeyA"] = 0x41, ["KeyB"] = 0x42, ["KeyC"] = 0x43, ["KeyD"] = 0x44,
        ["KeyE"] = 0x45, ["KeyF"] = 0x46, ["KeyG"] = 0x47, ["KeyH"] = 0x48,
        ["KeyI"] = 0x49, ["KeyJ"] = 0x4A, ["KeyK"] = 0x4B, ["KeyL"] = 0x4C,
        ["KeyM"] = 0x4D, ["KeyN"] = 0x4E, ["KeyO"] = 0x4F, ["KeyP"] = 0x50,
        ["KeyQ"] = 0x51, ["KeyR"] = 0x52, ["KeyS"] = 0x53, ["KeyT"] = 0x54,
        ["KeyU"] = 0x55, ["KeyV"] = 0x56, ["KeyW"] = 0x57, ["KeyX"] = 0x58,
        ["KeyY"] = 0x59, ["KeyZ"] = 0x5A,
        ["Digit0"] = 0x30, ["Digit1"] = 0x31, ["Digit2"] = 0x32, ["Digit3"] = 0x33,
        ["Digit4"] = 0x34, ["Digit5"] = 0x35, ["Digit6"] = 0x36, ["Digit7"] = 0x37,
        ["Digit8"] = 0x38, ["Digit9"] = 0x39,
        ["Enter"] = 0x0D, ["Tab"] = 0x09, ["Space"] = 0x20, ["Backspace"] = 0x08,
        ["Escape"] = 0x1B, ["Delete"] = 0x2E, ["ArrowLeft"] = 0x25,
        ["ArrowRight"] = 0x27, ["ArrowDown"] = 0x28, ["ArrowUp"] = 0x26,
        ["Minus"] = 0xBD, ["Equal"] = 0xBB, ["BracketLeft"] = 0xDB,
        ["BracketRight"] = 0xDD, ["Backslash"] = 0xDC, ["Semicolon"] = 0xBA,
        ["Quote"] = 0xDE, ["Comma"] = 0xBC, ["Period"] = 0xBE, ["Slash"] = 0xBF,
        ["Backquote"] = 0xC0
    };

    public static bool TryMap(string stableKey, out ushort virtualKey)
    {
        return Keys.TryGetValue(stableKey, out virtualKey);
    }
}
```

- [ ] **Step 6: Run tests to verify pass**

Run:

```bash
dotnet test windows-agent/tests/WindowsAgent.Tests/WindowsAgent.Tests.csproj
```

Expected: PASS on an environment with .NET SDK.

- [ ] **Step 7: Commit**

Run:

```bash
git add windows-agent
git commit -m "feat: decode windows keyboard messages"
```

Expected: commit succeeds.

## Task 7: Windows Agent TCP Listener and SendInput Adapter

**Files:**
- Create: `windows-agent/src/WindowsAgent/SendInputKeyboardInjector.cs`
- Create: `windows-agent/src/WindowsAgent/Program.cs`

- [ ] **Step 1: Implement SendInput adapter**

Create `windows-agent/src/WindowsAgent/SendInputKeyboardInjector.cs`:

```csharp
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WindowsAgent;

public sealed class SendInputKeyboardInjector
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;

    public void Inject(KeyboardMessage message)
    {
        if (!WindowsKeyMapper.TryMap(message.Key, out var virtualKey))
        {
            Console.WriteLine($"unsupported key={message.Key} sequence={message.Sequence}");
            return;
        }

        var flags = message.Event == "up" ? KeyEventKeyUp : 0;
        var input = new Input
        {
            Type = InputKeyboard,
            Data = new InputUnion
            {
                Keyboard = new KeyboardInput
                {
                    VirtualKey = virtualKey,
                    ScanCode = 0,
                    Flags = flags,
                    Time = 0,
                    ExtraInfo = UIntPtr.Zero
                }
            }
        };

        var sent = SendInput(1, new[] { input }, Marshal.SizeOf<Input>());
        if (sent != 1)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int inputSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }
}
```

- [ ] **Step 2: Implement TCP listener**

Create `windows-agent/src/WindowsAgent/Program.cs`:

```csharp
using System.Net;
using System.Net.Sockets;
using WindowsAgent;

var port = args.Length > 0 && int.TryParse(args[0], out var parsedPort) ? parsedPort : 5055;
var listener = new TcpListener(IPAddress.Any, port);
var injector = new SendInputKeyboardInjector();

listener.Start();
Console.WriteLine($"WindowsAgent listening on port {port}");

while (true)
{
    using var client = await listener.AcceptTcpClientAsync();
    Console.WriteLine($"client connected from {client.Client.RemoteEndPoint}");

    using var stream = client.GetStream();
    using var reader = new StreamReader(stream);

    while (await reader.ReadLineAsync() is { } line)
    {
        var message = KeyboardMessage.Parse(line);
        if (message is null)
        {
            Console.WriteLine($"rejected message: {line}");
            continue;
        }

        if (message.Event is not ("down" or "up" or "flagsChanged"))
        {
            Console.WriteLine($"ignored event={message.Event} sequence={message.Sequence}");
            continue;
        }

        if (message.Event == "flagsChanged")
        {
            Console.WriteLine($"flagsChanged sequence={message.Sequence}");
            continue;
        }

        try
        {
            injector.Inject(message);
            Console.WriteLine($"injected sequence={message.Sequence} event={message.Event} key={message.Key}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"injection failed sequence={message.Sequence}: {ex.Message}");
        }
    }

    Console.WriteLine("client disconnected");
}
```

- [ ] **Step 3: Build Windows agent on Windows or .NET SDK environment**

Run:

```bash
dotnet build windows-agent/src/WindowsAgent/WindowsAgent.csproj
```

Expected: build succeeds on Windows with .NET SDK.

- [ ] **Step 4: Run Windows tests**

Run:

```bash
dotnet test windows-agent/tests/WindowsAgent.Tests/WindowsAgent.Tests.csproj
```

Expected: PASS on Windows or compatible .NET SDK environment.

- [ ] **Step 5: Commit**

Run:

```bash
git add windows-agent/src/WindowsAgent/SendInputKeyboardInjector.cs windows-agent/src/WindowsAgent/Program.cs
git commit -m "feat: inject windows keyboard input"
```

Expected: commit succeeds.

## Task 8: README and Manual Validation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add M0 build instructions**

Append to `README.md`:

```markdown

## M0 Input Bridge Prototype

### Mac Controller

Build and test:

```bash
swift test --package-path mac-controller
swift build --package-path mac-controller
```

Run:

```bash
swift run --package-path mac-controller mac-controller <windows-host> 5055
```

The Mac process needs Accessibility and Input Monitoring permission. Press `Control + Option + Escape` to stop forwarding.

### Windows Agent

Build and test on Windows with .NET SDK:

```powershell
dotnet test windows-agent\tests\WindowsAgent.Tests\WindowsAgent.Tests.csproj
dotnet run --project windows-agent\src\WindowsAgent\WindowsAgent.csproj -- 5055
```

### Manual Validation

1. Start the Windows agent.
2. Open Notepad on Windows.
3. Start the Mac controller with the Windows host/IP and port.
4. Type letters, digits, space, enter, tab, backspace, delete, and arrow keys on the Mac.
5. Confirm Notepad receives input.
6. Confirm the active Mac app does not receive duplicate forwarded input.
7. Press `Control + Option + Escape` and confirm forwarding stops.
```

- [ ] **Step 2: Run available local verification**

Run:

```bash
swift test --package-path mac-controller
swift build --package-path mac-controller
```

Expected: PASS/build succeeds on macOS.

- [ ] **Step 3: Record unavailable local Windows verification**

Run:

```bash
dotnet --version
```

Expected in the current Mac workspace: `command not found`. Record in the final status that Windows verification requires a Windows/.NET SDK environment.

- [ ] **Step 4: Commit**

Run:

```bash
git add README.md
git commit -m "docs: add m0 validation instructions"
```

Expected: commit succeeds.

## Self-Review

Spec coverage:

- macOS event capture and suppression: Task 5.
- Escape shortcut: Task 4 and Task 5.
- TCP forwarding: Task 5 and Task 7.
- Protocol contract: Task 1, Task 3, Task 6.
- Windows `SendInput`: Task 7.
- Protocol and mapping tests: Task 3, Task 4, Task 6.
- Manual Notepad validation: Task 8.
- Pairing, UI, audio, clipboard, discovery, packaging: intentionally out of scope.

Local environment note:

- Swift is available locally.
- `dotnet` is not installed in the current Mac workspace, so Windows build/test steps are planned but must be verified on Windows or after installing .NET SDK.
