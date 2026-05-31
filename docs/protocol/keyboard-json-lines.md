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
