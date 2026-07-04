# Windows Agent IP Output Design

## Goal

Make the Windows Agent management script print the WLAN IPv4 address that a Mac client should use when connecting to the agent.

## Scope

Only `scripts/start-windows-agent.ps1` and its PowerShell regression tests are in scope. Windows audio transport behavior and all Mac/Swift files remain unchanged.

## Behavior

- `Foreground`, `Start`, and `Status` print `Windows WLAN IPv4: <address>`.
- The script selects the IPv4 address from the connected `WLAN` adapter in `ipconfig` output.
- If no connected WLAN IPv4 address is available, it prints `Windows WLAN IPv4: unavailable` and continues the requested action.
- Existing PID, listening-state, and log output remains unchanged.

## Implementation

Add a small function that runs `ipconfig`, scopes parsing to the `Wireless LAN adapter WLAN` section, and extracts its IPv4 address. Add a second function that formats the user-facing output consistently. Invoke it before foreground startup, after background startup status, and at the beginning of status output.

Parsing `ipconfig` is intentional: the current non-administrator environment returns access-denied errors from `Get-NetIPConfiguration`, while `ipconfig` succeeds without elevation.

## Testing

Add a PowerShell regression test that supplies representative `ipconfig` text and verifies:

- the connected WLAN IPv4 address is selected instead of virtual-adapter addresses;
- a missing or disconnected WLAN address produces `unavailable`;
- the three required actions contain the IP output path.

Run the PowerShell regression test first to observe the missing behavior, then implement the minimum script change and rerun it. Finally run the existing Windows Agent .NET test suite.
