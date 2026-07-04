$ErrorActionPreference = "Stop"

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "start-windows-agent.ps1"
$source = Get-Content -Raw -LiteralPath $scriptPath
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $source,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -ne 0) {
    throw "Manager script contains PowerShell parse errors: $($parseErrors -join '; ')"
}

$getWlanFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-WlanIPv4"
}, $true)
if ($null -eq $getWlanFunction) {
    throw "Get-WlanIPv4 is not defined."
}

if ($source -notmatch '\$MyInvocation\.InvocationName\s+-eq\s+"\."') {
    throw "Manager script is not safe to dot-source."
}

. $scriptPath

function Assert-Equal {
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

$connected = @'
Ethernet adapter VMware Network Adapter VMnet1:
   IPv4 Address. . . . . . . . . . . : 192.168.199.1

Wireless LAN adapter WLAN:
   IPv4 Address. . . . . . . . . . . : 192.168.1.13
   Default Gateway . . . . . . . . . : 192.168.1.1
'@ -split "`r?`n"

$disconnected = @'
Wireless LAN adapter WLAN:
   Media State . . . . . . . . . . . : Media disconnected
'@ -split "`r?`n"

Assert-Equal "192.168.1.13" (Get-WlanIPv4 $connected) "WLAN address was not selected."
Assert-Equal $null (Get-WlanIPv4 $disconnected) "Disconnected WLAN returned an address."
Assert-Equal "Windows WLAN IPv4: 192.168.1.13" (Show-WlanIPv4 "192.168.1.13") "Connected output changed."
Assert-Equal "Windows WLAN IPv4: unavailable" (Show-WlanIPv4 $null) "Unavailable output changed."

if ($source -notmatch 'function Show-Status\s*\{\s*Show-WlanIPv4') {
    throw "Show-Status must print WLAN IPv4."
}
if ($source -notmatch '"Foreground"\s*\{\s*Show-WlanIPv4') {
    throw "Foreground must print WLAN IPv4."
}
if ($source -notmatch '"Start"\s*\{\s*Start-Background') {
    throw "Start action must retain background startup."
}

Write-Output "PowerShell tests passed: 7"
