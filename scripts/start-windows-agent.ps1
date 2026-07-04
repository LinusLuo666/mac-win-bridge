param(
    [int]$Port = 5055
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

dotnet run `
    --project "windows-agent\src\WindowsAgent\WindowsAgent.csproj" `
    --configuration Release `
    -- $Port
