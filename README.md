# Mac Win Bridge

Mac Win Bridge 是一个面向双机桌面场景的个人效率工具：让 MacBook 可以灵活接管 Windows 主机的键盘、触控板/鼠标输入，并可选地把 Windows 系统声音转到 MacBook 外放。

它不是远程桌面产品。它的核心目标是把 MacBook 临时变成 Windows 的外设控制台，同时保留 MacBook 自身可用性。

## 当前阶段

- 阶段：产品定义
- 主要文档：[PRD](docs/PRD.md)
- 目标平台：macOS + Windows

## 核心能力

- MacBook 键盘一键切换为 Windows 输入设备
- MacBook 触控板/鼠标控制 Windows
- Windows 系统声音在 MacBook 播放
- 键盘、触控板/鼠标、音频、剪贴板能力可独立开关
- 局域网配对、自动重连、低延迟传输

## MVP 边界

第一版只做输入与音频桥接，不做 Windows 画面串流，不做完整远程桌面。

## M0 Input Bridge Prototype

M0 是键盘桥接技术验证：Mac 端捕获键盘事件，经 TCP 发送 JSON Lines 消息；Windows 端接收消息并用 `SendInput` 注入到当前桌面会话。

### Mac Controller

Build and test:

```bash
swift run --package-path mac-controller mac-controller-tests
swift build --package-path mac-controller
```

Run:

```bash
swift run --package-path mac-controller mac-controller <windows-host> 5055
```

The Mac process needs Accessibility and Input Monitoring permission. Press `Control + Option + Escape` to stop forwarding.

Enable the prototype audio bridge manually:

```bash
scripts/start-mac-audio.sh <windows-host-or-ip> 5055
```

`--audio-only` leaves the Mac keyboard local. Use `--audio` instead when keyboard forwarding and audio should run together. Audio mode can be `lowLatency` or `stable`; `--muted` keeps the stream active without local playback volume.

### Windows Agent

Build and test on Windows with .NET SDK:

```powershell
dotnet test windows-agent\tests\WindowsAgent.Tests\WindowsAgent.Tests.csproj
.\scripts\start-windows-agent.ps1 -Port 5055
```

The Windows agent starts WASAPI loopback capture only after the Mac controller sends an `audioControl` message. Captured system output is streamed back over the same TCP connection as length-prefixed PCM frames.

Manual startup order:

1. On Windows, open PowerShell in the repo and run `.\scripts\start-windows-agent.ps1 -Port 5055`.
2. Confirm the log says `WindowsAgent listening on port 5055`.
3. On Windows, run `ipconfig` and copy the WLAN IPv4 address.
4. On Mac, run `scripts/start-mac-audio.sh <windows-wlan-ip> 5055`.
5. Leave both terminal windows open. Stop Mac with `Control+C`; stop Windows with `Ctrl+C`.

Local manager page:

```bash
scripts/audio-bridge-manager.py
```

Open `http://127.0.0.1:8765` on the Mac. The page can start and stop the managed Mac audio client, check whether the Windows port is reachable, show the Windows start command, and tail the Mac audio log.

### Audio Bridge Protocol

Mac to Windows control message:

```json
{"type":"audioControl","enabled":true,"mode":"lowLatency","volume":1.0,"muted":false}
```

Windows to Mac sends binary frames on the same TCP connection:

- byte 0: message type, fixed `0xA1`
- byte 1..4: little-endian `Int32` payload length
- payload byte 0..23: audio metadata
- payload byte 24..end: interleaved PCM bytes

Metadata layout:

- byte 0..3: little-endian `Int32` sample rate
- byte 4..5: little-endian `UInt16` channel count
- byte 6..7: little-endian `UInt16` bits per sample
- byte 8..9: little-endian `UInt16` wave format tag
- byte 10..11: little-endian `UInt16` block align
- byte 12..15: little-endian `Int32` frame count
- byte 16..23: little-endian `UInt64` QPC position

Supported Mac playback encodings are 16/24/32-bit PCM integer and 32-bit IEEE float, including `WAVE_FORMAT_EXTENSIBLE` (`0xFFFE`) when the bit depth maps cleanly.

### Manual Validation

1. Start the Windows agent.
2. Open Notepad on Windows.
3. Start the Mac controller with the Windows host/IP and port.
4. Type letters, digits, space, enter, tab, backspace, delete, and arrow keys on the Mac.
5. Confirm Notepad receives input.
6. Confirm the active Mac app does not receive duplicate forwarded input.
7. Press `Control + Option + Escape` and confirm forwarding stops.
