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

## M0 输入桥接原型

M0 是键盘桥接技术验证：Mac 端捕获键盘事件，经 TCP 发送 JSON Lines 消息；Windows 端接收消息并用 `SendInput` 注入到当前桌面会话。

### Mac 控制端

构建并测试：

```bash
swift run --package-path mac-controller mac-controller-tests
swift build --package-path mac-controller
```

运行：

```bash
swift run --package-path mac-controller mac-controller <windows-host> 5055
```

Mac 进程需要获得“辅助功能”和“输入监控”权限。按 `Control + Option + Escape` 停止转发。

手动启用音频桥接原型：

```bash
scripts/start-mac-audio.sh <windows-host-or-ip> 5055
```

`--audio-only` 模式会让 Mac 键盘继续由本机使用。如果需要同时启用键盘转发和音频，请改用 `--audio`。音频模式可以选择 `lowLatency` 或 `stable`；`--muted` 会保持音频流连接，但不在 Mac 本机播放声音。

### Windows 端代理程序

在安装了 .NET SDK 的 Windows 上构建并测试：

```powershell
dotnet test windows-agent\tests\WindowsAgent.Tests\WindowsAgent.Tests.csproj
.\scripts\start-windows-agent.ps1 -Port 5055
```

Windows 端代理程序只有在收到 Mac 控制端发送的 `audioControl` 消息后，才会启动 WASAPI 回环采集。采集到的系统输出声音会通过同一个 TCP 连接，以带长度前缀的 PCM 音频帧发送到 Mac。

Windows 管理命令：

```powershell
# 前台启动：需要保持当前终端打开，按 Ctrl+C 停止代理程序。
.\scripts\start-windows-agent.ps1 -Action Foreground -Port 5055

# 后台启动：进程持续运行，日志保存在 %LOCALAPPDATA%\MacWinBridge。
.\scripts\start-windows-agent.ps1 -Action Start -Port 5055

# 查看当前 WLAN IPv4、进程 PID，以及 LISTENING 和 ESTABLISHED 连接。
.\scripts\start-windows-agent.ps1 -Action Status -Port 5055

# 查看最近的标准输出和错误日志。
.\scripts\start-windows-agent.ps1 -Action Logs -Tail 200

# 停止代理程序，并确认 5055 端口已经释放。
.\scripts\start-windows-agent.ps1 -Action Stop -Port 5055
```

默认操作是 `Foreground`，因此仍然可以直接运行 `.\scripts\start-windows-agent.ps1 -Port 5055`。后台管理功能只依赖 Windows 本机，不要求 Mac 客户端正在运行。

手动启动顺序：

1. 在 Windows 上打开 PowerShell，进入项目目录，然后运行 `.\scripts\start-windows-agent.ps1 -Port 5055`。
2. 确认日志出现 `WindowsAgent listening on port 5055`。
3. 脚本会打印 Windows 的 WLAN IPv4 地址，将该地址填写到 Mac 端。
4. 在 Mac 上运行 `scripts/start-mac-audio.sh <Windows-WLAN-IP> 5055`。
5. 前台运行时需要保持两边的终端窗口打开。Mac 端按 `Control+C` 停止，Windows 端按 `Ctrl+C` 停止。

本地管理页面：

```bash
scripts/audio-bridge-manager.py
```

在 Mac 上打开 `http://127.0.0.1:8765`。该页面可以启动或停止受管理的 Mac 音频客户端、检查 Windows 端口是否可访问、显示 Windows 启动命令，并查看最近的 Mac 音频日志。

### 音频桥接协议

Mac 发送到 Windows 的控制消息：

```json
{"type":"audioControl","enabled":true,"mode":"lowLatency","volume":1.0,"muted":false}
```

Windows 通过同一个 TCP 连接向 Mac 发送二进制帧：

- 第 0 字节：消息类型，固定为 `0xA1`
- 第 1..4 字节：小端序 `Int32` 载荷长度
- 载荷第 0..23 字节：音频元数据
- 载荷第 24 字节至末尾：交错排列的 PCM 数据

元数据布局：

- 第 0..3 字节：小端序 `Int32` 采样率
- 第 4..5 字节：小端序 `UInt16` 声道数
- 第 6..7 字节：小端序 `UInt16` 每个采样的位数
- 第 8..9 字节：小端序 `UInt16` 波形格式标记
- 第 10..11 字节：小端序 `UInt16` 块对齐值
- 第 12..15 字节：小端序 `Int32` 音频帧数
- 第 16..23 字节：小端序 `UInt64` QPC 位置

Mac 端支持播放 16、24、32 位 PCM 整数格式和 32 位 IEEE 浮点格式；当位深能够明确映射时，也支持 `WAVE_FORMAT_EXTENSIBLE`（`0xFFFE`）。

### 手动验证

1. 启动 Windows 端代理程序。
2. 在 Windows 上打开记事本。
3. 使用 Windows 主机地址或 IP 和端口启动 Mac 控制端。
4. 在 Mac 上输入字母、数字、空格、回车、制表、退格、删除和方向键。
5. 确认 Windows 记事本能够收到输入。
6. 确认 Mac 当前活动的应用程序不会收到重复的转发输入。
7. 按 `Control + Option + Escape`，确认输入转发停止。
