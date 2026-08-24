<#
.SYNOPSIS
    Lists every machine on your tailnet and shows which are ready for VNC.

.DESCRIPTION
    Run this on the PC you are connecting FROM. It reads the tailnet peer list
    from Tailscale, probes TCP 5900 on each peer in parallel, and prints a table
    of which machines will accept a VNC connection right now.

    Useful when you have a fleet of machines and want to know at a glance which
    ones are up, rather than discovering it one failed connection at a time.

.PARAMETER Port
    VNC port to probe. Default 5900.

.PARAMETER TimeoutMs
    Per-machine connection timeout in milliseconds. Default 1500.

.PARAMETER ReadyOnly
    Only list machines that accepted a connection.

.EXAMPLE
    .\Get-VncTargets.ps1

.EXAMPLE
    .\Get-VncTargets.ps1 -ReadyOnly
#>

[CmdletBinding()]
param(
    [int]$Port      = 5900,
    [int]$TimeoutMs = 1500,
    [switch]$ReadyOnly
)

$ErrorActionPreference = 'Stop'

function Get-TailscaleExe {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return $null
}

# Fast TCP probe. Test-NetConnection is far too slow to run across a fleet.
function Test-TcpPort {
    param([string]$ComputerName, [int]$TcpPort, [int]$Timeout)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $TcpPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($Timeout, $false)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ------------------------------------------------------------------ tailnet --

$tailscale = Get-TailscaleExe
if (-not $tailscale) {
    Write-Host "Tailscale is not installed on this PC." -ForegroundColor Red
    Write-Host "Install it from https://tailscale.com/download/windows and sign in"
    Write-Host "with the SAME account you use on your laptop, then re-run this."
    exit 1
}

try {
    $status = & $tailscale status --json 2>$null | ConvertFrom-Json
} catch {
    Write-Host "Could not read Tailscale status. Is Tailscale running?" -ForegroundColor Red
    exit 1
}

if ($status.BackendState -ne 'Running') {
    Write-Host "Tailscale is installed but not connected (state: $($status.BackendState))." -ForegroundColor Red
    Write-Host "Open the Tailscale tray icon and sign in, or run: tailscale up"
    exit 1
}

$selfName = if ($status.Self.DNSName) { $status.Self.DNSName.TrimEnd('.') } else { 'this machine' }
$selfIp   = $status.Self.TailscaleIPs | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1

Write-Host ''
Write-Host "Tailnet:      $($status.MagicDNSSuffix)" -ForegroundColor Cyan
Write-Host "This PC:      $selfName ($selfIp)" -ForegroundColor Cyan

$peers = @()
if ($status.Peer) {
    $peers = $status.Peer.PSObject.Properties | ForEach-Object { $_.Value }
}

if (-not $peers) {
    Write-Host ''
    Write-Host "No peers visible in this tailnet." -ForegroundColor Red
    Write-Host "This PC is signed in, but to a tailnet with no other machines - which"
    Write-Host "usually means it is signed in to a DIFFERENT account than your laptop."
    Write-Host "Sign out from the Tailscale tray icon and sign back in with the same account."
    exit 1
}

Write-Host "Peers:        $($peers.Count)" -ForegroundColor Cyan
Write-Host ''
Write-Host "Probing TCP $Port across the tailnet..." -ForegroundColor DarkGray

# ------------------------------------------------------------------- probe --

$results = foreach ($peer in $peers) {
    $ip   = $peer.TailscaleIPs | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1
    $name = if ($peer.DNSName) { $peer.DNSName.TrimEnd('.') } else { $peer.HostName }
    $short = $name.Split('.')[0]

    $ready = $false
    if ($peer.Online -and $ip) {
        $ready = Test-TcpPort -ComputerName $ip -TcpPort $Port -Timeout $TimeoutMs
    }

    [PSCustomObject]@{
        Machine = $short
        Address = $ip
        Online  = [bool]$peer.Online
        VNC     = $ready
        FQDN    = $name
    }
}

if ($ReadyOnly) { $results = $results | Where-Object { $_.VNC } }

# ------------------------------------------------------------------ output --

Write-Host ''
$results = $results | Sort-Object -Property @{Expression = 'VNC'; Descending = $true}, 'Machine'

$fmt = "{0,-20} {1,-17} {2,-9} {3}"
Write-Host ($fmt -f 'MACHINE', 'ADDRESS', 'ONLINE', 'VNC') -ForegroundColor White
Write-Host ($fmt -f '-------', '-------', '------', '---') -ForegroundColor DarkGray

foreach ($r in $results) {
    $vncText = if ($r.VNC) { 'READY' } elseif (-not $r.Online) { '-' } else { 'no answer' }
    $color   = if ($r.VNC) { 'Green' } elseif (-not $r.Online) { 'DarkGray' } else { 'Yellow' }
    $online  = if ($r.Online) { 'yes' } else { 'no' }
    Write-Host ($fmt -f $r.Machine, $r.Address, $online, $vncText) -ForegroundColor $color
}

$ready = @($results | Where-Object { $_.VNC })

Write-Host ''
if ($ready.Count -gt 0) {
    Write-Host "$($ready.Count) machine(s) ready. In VNC Viewer, type one of these into the" -ForegroundColor Green
    Write-Host "search bar and press Enter:" -ForegroundColor Green
    Write-Host ''
    foreach ($r in $ready | Select-Object -First 5) {
        Write-Host "      $($r.FQDN)" -ForegroundColor White
    }
    if ($ready.Count -gt 5) { Write-Host "      ... and $($ready.Count - 5) more" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host "An empty address book (`"0 device(s)`") is normal - it is a RealVNC cloud" -ForegroundColor DarkGray
    Write-Host "feature. Direct connections do not use it and need no sign-in." -ForegroundColor DarkGray
} else {
    Write-Host "No machine accepted a VNC connection." -ForegroundColor Red
    Write-Host ''
    Write-Host "Since these machines work from your laptop, the servers are fine and the"
    Write-Host "problem is on this PC. Most likely one of:"
    Write-Host "  - This PC is signed in to a different tailnet than the laptop."
    Write-Host "  - This PC is pending approval in the admin console (Machines list)."
    Write-Host "  - A local security suite is blocking outbound 5900."
    Write-Host ''
    Write-Host "Run .\Test-VncOverTailscale.ps1 -Target <machine> for a layer-by-layer trace."
}
Write-Host ''
