# Windows Agent IP Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Print the connected WLAN IPv4 address from the Windows Agent manager so it can be copied into the Mac client configuration.

**Architecture:** Keep network discovery inside the existing PowerShell manager. Parse the non-privileged `ipconfig` output within the `Wireless LAN adapter WLAN` section, format one stable output line, and call it from foreground startup and status reporting; background startup already delegates to status reporting.

**Tech Stack:** PowerShell 5.1, `ipconfig`, plain PowerShell regression assertions, .NET test suite

---

### Task 1: Add failing WLAN parsing and output tests

**Files:**
- Create: `scripts/tests/start-windows-agent.Tests.ps1`
- Test: `scripts/start-windows-agent.ps1`

- [ ] **Step 1: Write the failing regression test**

Create a plain PowerShell test runner that dot-sources the manager, passes representative multi-adapter text to `Get-WlanIPv4`, checks the exact WLAN address, checks the disconnected case, and verifies the required actions call `Show-WlanIPv4`.

```powershell
$ErrorActionPreference = "Stop"
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "start-windows-agent.ps1"
. $scriptPath

function Assert-Equal([object]$Expected, [object]$Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected=[$Expected] Actual=[$Actual]" }
}

$connected = @'
Ethernet adapter VMware Network Adapter VMnet1:
   IPv4 Address. . . . . . . . . . . : 192.168.199.1

Wireless LAN adapter WLAN:
   IPv4 Address. . . . . . . . . . . : 192.168.1.13
'@ -split "`r?`n"
$disconnected = @'
Wireless LAN adapter WLAN:
   Media State . . . . . . . . . . . : Media disconnected
'@ -split "`r?`n"

Assert-Equal "192.168.1.13" (Get-WlanIPv4 $connected) "WLAN address was not selected."
Assert-Equal $null (Get-WlanIPv4 $disconnected) "Disconnected WLAN returned an address."
Assert-Equal "Windows WLAN IPv4: 192.168.1.13" (Show-WlanIPv4 "192.168.1.13") "Connected output changed."
Assert-Equal "Windows WLAN IPv4: unavailable" (Show-WlanIPv4 $null) "Unavailable output changed."

$source = Get-Content -Raw -LiteralPath $scriptPath
if ($source -notmatch 'function Show-Status[\s\S]*?Show-WlanIPv4') { throw "Show-Status must print WLAN IPv4." }
if ($source -notmatch '"Foreground"\s*\{[\s\S]*?Show-WlanIPv4') { throw "Foreground must print WLAN IPv4." }
if ($source -notmatch '"Start"\s*\{\s*Start-Background') { throw "Start action must retain background startup." }
Write-Output "PowerShell tests passed: 7"
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\start-windows-agent.Tests.ps1
```

Expected: FAIL because `Get-WlanIPv4` is not defined.

### Task 2: Implement WLAN IPv4 discovery and display

**Files:**
- Modify: `scripts/start-windows-agent.ps1`
- Test: `scripts/tests/start-windows-agent.Tests.ps1`

- [ ] **Step 1: Add the minimal parser and formatter**

Add `Get-WlanIPv4`, accepting optional `ipconfig` lines for deterministic tests, and `Show-WlanIPv4`, returning either `Windows WLAN IPv4: <address>` or `Windows WLAN IPv4: unavailable`.

```powershell
function Get-WlanIPv4 {
    param([string[]]$IpConfigLines = @(& ipconfig))
    $inWlan = $false
    foreach ($line in $IpConfigLines) {
        if ($line -match '^\S.*adapter\s+WLAN:\s*$') { $inWlan = $true; continue }
        if ($inWlan -and $line -match '^\S') { break }
        if ($inWlan -and $line -match 'IPv4[^:]*:\s*(\d{1,3}(?:\.\d{1,3}){3})\s*$') {
            return $Matches[1]
        }
    }
    return $null
}

function Show-WlanIPv4 {
    param([AllowNull()][string]$Address = (Get-WlanIPv4))
    if ([string]::IsNullOrWhiteSpace($Address)) { return "Windows WLAN IPv4: unavailable" }
    return "Windows WLAN IPv4: $Address"
}
```

- [ ] **Step 2: Make dot-sourcing test-safe and add action output**

Return before the action switch only when the script is dot-sourced. Call `Show-WlanIPv4` at the start of `Show-Status` and before the foreground startup message. `Start` receives the output through its existing `Show-Status` call.

Apply these exact insertions without replacing the surrounding implementation:

```diff
 function Show-Status {
+    Show-WlanIPv4
     $entries = Get-PortEntries

+if ($MyInvocation.InvocationName -eq ".") {
+    return
+}
+
 switch ($Action) {

     "Foreground" {
+        Show-WlanIPv4
         Set-Location $Root
```

- [ ] **Step 3: Run the PowerShell test and verify GREEN**

Run the PowerShell regression test and expect `PowerShell tests passed: 7` with exit code 0.

- [ ] **Step 4: Verify real status output**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-windows-agent.ps1 -Action Status -Port 5055
```

Expected output begins with `Windows WLAN IPv4: 192.168.1.13`, followed by the current stopped status.

- [ ] **Step 5: Run Windows Agent tests**

Run:

```powershell
dotnet test windows-agent\tests\WindowsAgent.Tests\WindowsAgent.Tests.csproj
```

Expected: all tests pass with exit code 0.

- [ ] **Step 6: Commit the implementation**

```powershell
git add scripts/start-windows-agent.ps1 scripts/tests/start-windows-agent.Tests.ps1 docs/superpowers/plans/2026-07-04-windows-agent-ip-output.md
git commit -m "feat: print Windows WLAN address"
```
