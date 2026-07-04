$ErrorActionPreference = "Stop"
$Manager = Join-Path $PSScriptRoot "start-windows-agent.ps1"
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $Manager,
    [ref]$tokens,
    [ref]$parseErrors) | Out-Null

if ($parseErrors.Count -ne 0) {
    throw ($parseErrors | ForEach-Object Message | Out-String)
}

$source = Get-Content -Raw -LiteralPath $Manager
if ($source -match "(?m)\\\s*$") {
    throw "Manager contains invalid backslash line continuation."
}
if ($source -match "(?m)\bStart-Process\b") {
    throw "Manager must not use Start-Process because Path/PATH duplicates break it."
}

$command = Get-Command $Manager
foreach ($parameterName in @("Action", "Port", "Tail", "StateDirectory")) {
    if (-not $command.Parameters.ContainsKey($parameterName)) {
        throw "Missing manager parameter: $parameterName"
    }
}

$unusedPort = 65432
$status = & $Manager -Action Status -Port $unusedPort | Out-String
if ($status -notmatch "STOPPED" -or $status -notmatch "$unusedPort") {
    throw "Unexpected status output: $status"
}

Write-Output "Windows Agent manager checks passed."
