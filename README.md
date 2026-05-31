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
