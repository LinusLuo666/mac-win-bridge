# M0 Input Bridge Design

Date: 2026-05-24

## Purpose

This spec defines the first technical validation slice for Mac Win Bridge: prove that a Mac can capture keyboard input, forward it over the local network, and have a Windows process inject the matching keyboard events into the active Windows desktop session.

The goal is a small, testable proof of concept for the highest-risk part of the PRD: input interception and forwarding. It is not a product UI milestone.

## Scope

In scope:

- macOS keyboard event capture with `CGEventTap`.
- Best-effort suppression of forwarded keyboard events on macOS.
- A local escape shortcut that is never forwarded.
- A simple local-network TCP connection from Mac to Windows.
- A small keyboard event protocol shared by both endpoints.
- Windows keyboard injection through `SendInput`.
- Unit-testable protocol encoding, decoding, and key mapping logic.
- Console logging for connection state, forwarded events, mapping failures, and escape handling.

Out of scope:

- Menu bar UI and tray UI.
- Pairing, encryption, automatic discovery, and reconnect.
- Trackpad or mouse forwarding.
- Audio capture or playback.
- Clipboard sync.
- Windows lock screen, UAC secure desktop, administrator-only windows, and game compatibility.
- Installer, code signing, notarization, and packaging.

## Architecture

The proof of concept has three boundaries:

- `mac-controller`: captures keyboard events and sends protocol messages.
- `windows-agent`: receives protocol messages and injects Windows input.
- `docs/protocol`: records the protocol contract and message examples.

The macOS side is responsible for deciding whether an event should stay local or be forwarded. The Windows side is intentionally passive: it trusts messages from the active TCP connection and translates them to `SendInput` calls.

This keeps the core validation focused. If the event tap or `SendInput` approach fails, the failure will be visible without UI or pairing complexity hiding it.

## Mac Controller

The initial Mac controller should be a Swift command-line tool or the smallest Swift target that can run from the terminal.

Responsibilities:

- Install a `CGEventTap` for keyboard down, keyboard up, and flag-change events.
- Request or surface missing Accessibility/Input Monitoring permissions clearly in logs.
- Connect to a configured Windows host and port.
- Convert captured events into protocol messages.
- Suppress forwarded events from reaching macOS when running in Windows-forwarding mode.
- Preserve a local escape shortcut, `Control + Option + Escape`, that stops forwarding and exits or returns to local-only mode.
- Log each forwarded event without logging typed characters.

The first version can run in one forwarding mode only: all captured supported keyboard events are forwarded until the process exits or the escape shortcut is pressed. Full Mac/Windows/temporary mode switching belongs to later MVP work.

## Windows Agent

The initial Windows agent should be a C#/.NET console app.

Responsibilities:

- Listen on a configured TCP port.
- Accept a single Mac client connection.
- Decode keyboard protocol messages.
- Map protocol key identifiers to Windows virtual-key codes and scan-code data where needed.
- Inject key-down and key-up events with `SendInput`.
- Log received events, rejected messages, mapping failures, and injection failures.

The agent does not implement pairing or authentication in M0. It should bind to a configured interface or localhost by default during development, with explicit instructions for LAN testing.

## Protocol

M0 should use newline-delimited JSON messages because it is simple to inspect, easy to test, and good enough for keyboard validation.

Example:

```json
{"type":"key","event":"down","key":"KeyA","modifiers":["shift"],"sequence":42}
```

Fields:

- `type`: currently always `key`.
- `event`: `down`, `up`, or `flagsChanged`.
- `key`: a stable logical key identifier, such as `KeyA`, `Digit1`, `Enter`, `Tab`, `Escape`, `ArrowLeft`, `Backspace`, or `Space`.
- `modifiers`: zero or more active modifiers: `shift`, `control`, `option`, `command`, `capsLock`, `fn`.
- `sequence`: monotonically increasing integer assigned by the Mac sender.

Rules:

- Unknown message types are ignored and logged.
- Malformed messages are rejected without terminating the agent.
- The protocol must not include printable text payloads, only key identifiers and modifier state.
- The escape shortcut is handled locally on macOS and is never sent to Windows.

## Key Mapping

M0 key coverage:

- Letters A-Z.
- Digits 0-9.
- Space, Enter, Tab, Escape, Backspace, Delete.
- Arrow keys.
- Common punctuation keys available through physical key positions.
- Modifier flag state for Shift, Control, Option, Command, Caps Lock, and Fn.

Default modifier interpretation:

- Mac `Control` maps to Windows `Ctrl`.
- Mac `Option` maps to Windows `Alt`.
- Mac `Command` maps to Windows `Win` for M0 validation.
- Mac `Shift` maps to Windows `Shift`.

This mapping is intentionally simple. Configurable modifier mapping is a later MVP feature.

## Error Handling

Mac controller:

- If permissions are missing, log the missing capability and exit with a non-zero status.
- If the Windows connection fails, log the host and port and exit with a non-zero status.
- If a captured key cannot be mapped, log the key code and continue.
- If sending fails, stop forwarding and exit with a non-zero status.

Windows agent:

- If a message is malformed, log it as a protocol error and keep listening.
- If a key cannot be mapped, log the stable key identifier and skip that event.
- If `SendInput` fails, log the Windows error code and continue when possible.
- If the Mac disconnects, return to listening for a new client.

## Testing

Automated tests should cover logic that does not depend on OS event APIs:

- Protocol encoder emits one newline-delimited JSON object per event.
- Protocol decoder accepts valid messages and rejects malformed messages.
- Unsupported message types do not crash the decoder.
- Mac key-code mapping returns the expected stable key identifiers for the M0 key set.
- Windows key mapping returns expected virtual-key codes for the M0 key set.
- The escape shortcut detector recognizes `Control + Option + Escape` and does not classify similar combinations as escape.

Manual validation should cover system behavior:

- Start Windows agent.
- Start Mac controller pointing at the Windows host.
- Open Notepad on Windows.
- Type letters, digits, space, enter, tab, backspace, delete, and arrow keys on the Mac.
- Confirm Windows receives input and the active Mac text field does not receive duplicated forwarded characters.
- Press `Control + Option + Escape` and confirm forwarding stops immediately.

## Success Criteria

The M0 slice is successful when:

- A Windows text field receives ordinary key input from the Mac keyboard over LAN.
- Supported special keys work in Notepad.
- Forwarded keys are not also typed into the active Mac app during forwarding mode, within macOS event-tap limitations.
- The escape shortcut always remains local and stops forwarding.
- Protocol and mapping tests pass on their respective platforms.
- Logs are useful for diagnosing permission, connection, mapping, and injection failures.

## Known Risks

- macOS may not allow suppression of some system shortcuts or protected event paths.
- `CGEventTap` behavior depends on Accessibility and Input Monitoring permissions.
- `SendInput` is expected to work for normal desktop apps but not secure desktop prompts or some elevated/game contexts.
- Newline-delimited JSON is not the final low-latency protocol, but it is sufficient for M0 keyboard validation.

## Next Step

After this spec is approved, create an implementation plan that starts with protocol and mapping tests, then implements the smallest Mac sender and Windows receiver needed to complete the manual Notepad validation.
