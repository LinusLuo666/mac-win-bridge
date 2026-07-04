[CmdletBinding()]
param(
    [ValidateSet("Start", "Stop", "Status", "Logs", "Foreground")]
    [string]$Action = "Foreground",
    [ValidateRange(1, 65535)]
    [int]$Port = 5055,
    [ValidateRange(1, 10000)]
    [int]$Tail = 100,
    [string]$StateDirectory = (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "MacWinBridge")
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $Root "windows-agent\src\WindowsAgent\WindowsAgent.csproj"
$StatePath = Join-Path $StateDirectory "windows-agent.json"
$StdoutPath = Join-Path $StateDirectory "windows-agent.stdout.log"
$StderrPath = Join-Path $StateDirectory "windows-agent.stderr.log"

function Get-PortEntries {
    $pattern = "^\s*TCP\s+\S+:$Port\s+\S+\s+(LISTENING|ESTABLISHED)\s+\d+\s*$"
    return @(netstat -ano -p tcp | Select-String -Pattern $pattern | ForEach-Object {
        $parts = $_.Line.Trim() -split "\s+"
        [pscustomobject]@{
            Protocol = $parts[0]
            LocalAddress = $parts[1]
            RemoteAddress = $parts[2]
            State = $parts[3]
            Pid = [int]$parts[4]
            Line = $_.Line.Trim()
        }
    })
}

function Get-ListenerEntry {
    return Get-PortEntries | Where-Object State -eq "LISTENING" | Select-Object -First 1
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
    }
    catch {
        Write-Warning "Ignoring invalid state file: $StatePath"
        return $null
    }
}

function Show-Status {
    $entries = Get-PortEntries
    $listener = $entries | Where-Object State -eq "LISTENING" | Select-Object -First 1
    if ($null -eq $listener) {
        Write-Output "WindowsAgent status: STOPPED (no LISTENING socket on port $Port)"
        return
    }

    Write-Output "WindowsAgent status: RUNNING pid=$($listener.Pid) port=$Port"
    foreach ($entry in $entries) {
        Write-Output $entry.Line
    }

    $process = Get-Process -Id $listener.Pid -ErrorAction SilentlyContinue
    if ($process) {
        Write-Output "Process: $($process.ProcessName) started=$($process.StartTime.ToString('s'))"
    }
}

function Start-Background {
    $existing = Get-ListenerEntry
    if ($existing) {
        Write-Output "WindowsAgent is already listening on port $Port (pid=$($existing.Pid))."
        Show-Status
        return
    }

    New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    $command = "dotnet run --project `"$Project`" --configuration Release -- $Port 1>`"$StdoutPath`" 2>`"$StderrPath`""
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "$env:SystemRoot\System32\cmd.exe"
    $startInfo.Arguments = "/d /c `"$command`""
    $startInfo.WorkingDirectory = $Root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $launcher = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $launcher) {
        throw "Failed to create the WindowsAgent launcher process."
    }

    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        $listener = Get-ListenerEntry
        $launcher.Refresh()
    } while ($null -eq $listener -and -not $launcher.HasExited -and (Get-Date) -lt $deadline)

    if ($null -eq $listener) {
        Write-Output "WindowsAgent failed to start."
        if (Test-Path -LiteralPath $StdoutPath) {
            Get-Content -LiteralPath $StdoutPath -Tail $Tail
        }
        if (Test-Path -LiteralPath $StderrPath) {
            Get-Content -LiteralPath $StderrPath -Tail $Tail
        }
        throw "No LISTENING socket appeared on port $Port within 30 seconds."
    }

    [pscustomobject]@{
        AgentPid = $listener.Pid
        LauncherPid = $launcher.Id
        Port = $Port
        StartedAt = (Get-Date).ToString("o")
        Stdout = $StdoutPath
        Stderr = $StderrPath
    } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8

    Write-Output "WindowsAgent started in background (pid=$($listener.Pid), port=$Port)."
    Write-Output "Logs: $StdoutPath"
    Show-Status
}

function Stop-Agent {
    $state = Read-State
    $processIds = @(
        (Get-PortEntries | Where-Object State -eq "LISTENING" | Select-Object -ExpandProperty Pid)
        if ($state) {
            $state.AgentPid
            $state.LauncherPid
        }
    ) | Where-Object { $_ } | Sort-Object -Unique

    if ($processIds.Count -eq 0) {
        Write-Output "WindowsAgent is already stopped."
    }
    else {
        foreach ($processId in $processIds) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($process) {
                Stop-Process -Id $processId -Force
                Write-Output "Stopped process pid=$processId name=$($process.ProcessName)."
            }
        }
    }

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        $listener = Get-ListenerEntry
    } while ($listener -and (Get-Date) -lt $deadline)

    if ($listener) {
        throw "Port $Port is still listening after stop."
    }
    Write-Output "WindowsAgent stopped; port $Port is not listening."
}

function Show-Logs {
    Write-Output "=== stdout: $StdoutPath ==="
    if (Test-Path -LiteralPath $StdoutPath) {
        Get-Content -LiteralPath $StdoutPath -Tail $Tail
    }
    else {
        Write-Output "No stdout log exists."
    }

    Write-Output "=== stderr: $StderrPath ==="
    if (Test-Path -LiteralPath $StderrPath) {
        Get-Content -LiteralPath $StderrPath -Tail $Tail
    }
    else {
        Write-Output "No stderr log exists."
    }
}

switch ($Action) {
    "Start" { Start-Background }
    "Stop" { Stop-Agent }
    "Status" { Show-Status }
    "Logs" { Show-Logs }
    "Foreground" {
        Set-Location $Root
        Write-Output "Starting WindowsAgent in foreground on port $Port. Press Ctrl+C to stop."
        & dotnet run --project $Project --configuration Release -- $Port
        exit $LASTEXITCODE
    }
}
