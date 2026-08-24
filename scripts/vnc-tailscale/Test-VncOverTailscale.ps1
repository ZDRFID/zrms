<#
.SYNOPSIS
    Diagnoses a VNC-over-Tailscale connection from the client side.

.DESCRIPTION
    Run this on the machine you are connecting FROM (the one with VNC Viewer).
    It walks the connection path one layer at a time and tells you which layer
    is broken, so you are not guessing between Tailscale, DNS, the firewall and
    the VNC server itself.

.PARAMETER Target
    The peer to test: a MagicDNS name (mc-hed-t1), a full name
    (mc-hed-t1.tail9b9828.ts.net) or a Tailscale IP (100.108.161.21).

.PARAMETER Port
    VNC port. Default 5900.

.EXAMPLE
    .\Test-VncOverTailscale.ps1 -Target mc-hed-t1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [int]$Port = 5900
)

$ErrorActionPreference = 'Continue'

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ok]   $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" }

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

# --------------------------------------------------------- 1. local tailscale --

Write-Step '1. Tailscale on this machine'

$tailscale = Get-TailscaleExe
if (-not $tailscale) {
    Write-Fail 'Tailscale is not installed here. Install it and sign in to the same tailnet.'
    exit 1
}

$selfIp = (& $tailscale ip -4 2>&1 | Select-Object -First 1)
if (-not $selfIp -or $selfIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Write-Fail "Tailscale is installed but not connected. Run 'tailscale up' and sign in."
    exit 1
}
Write-Ok "Connected. This machine is $($selfIp.Trim())"

# ------------------------------------------------------------ 2. peer lookup --

Write-Step "2. Locating peer '$Target' in the tailnet"

$peerIp   = $null
$peerName = $Target

if ($Target -match '^\d+\.\d+\.\d+\.\d+$') {
    $peerIp = $Target
    Write-Ok "Target is already an IP: $peerIp"
} else {
    try {
        $status = & $tailscale status --json 2>$null | ConvertFrom-Json
        $short  = $Target.Split('.')[0]

        $peers = @()
        if ($status.Peer) {
            $peers = $status.Peer.PSObject.Properties |
                     ForEach-Object { $_.Value } |
                     Where-Object { $_.DNSName -and $_.DNSName.Split('.')[0] -eq $short }
        }

        # The target may be this machine itself - a common mix-up.
        if (-not $peers -and $status.Self.DNSName -and $status.Self.DNSName.Split('.')[0] -eq $short) {
            Write-Fail "'$Target' is THIS machine, not a remote peer."
            Write-Info 'You are trying to VNC into the computer you are sitting at. Pick the other'
            Write-Info "machine from the Tailscale menu - run 'tailscale status' to list them."
            exit 1
        }

        if ($peers) {
            $peer     = $peers | Select-Object -First 1
            $peerIp   = $peer.TailscaleIPs | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1
            $peerName = $peer.DNSName.TrimEnd('.')
            Write-Ok "Found $peerName at $peerIp"
            if (-not $peer.Online) {
                Write-Fail 'That peer is currently OFFLINE in the tailnet.'
                Write-Info 'Wake it, or check that Tailscale is running there.'
                exit 1
            }
            Write-Ok 'Peer is online.'
        } else {
            Write-Fail "No peer matching '$Target' in this tailnet."
            Write-Info "Run 'tailscale status' to see the exact names available."
            exit 1
        }
    } catch {
        Write-Info "Could not parse tailscale status - falling back to DNS resolution."
        $peerIp = $Target
    }
}

# ------------------------------------------------------------------- 3. DNS --

if ($Target -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Write-Step "3. DNS resolution for '$Target' (MagicDNS)"
    $resolved = Resolve-DnsName -Name $Target -Type A -ErrorAction SilentlyContinue
    if ($resolved) {
        Write-Ok "Resolves to $(($resolved | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress) -join ', ')"
    } else {
        Write-Fail "'$Target' does not resolve."
        Write-Info 'Enable MagicDNS in the Tailscale admin console (DNS -> Enable MagicDNS),'
        Write-Info "or just use the IP address $peerIp instead - it works either way."
    }
} else {
    Write-Step '3. DNS resolution - skipped (target is an IP)'
}

# ------------------------------------------------------- 4. tailnet reachability --

Write-Step "4. Tailscale-level reachability to $peerIp"

$pingOutput = & $tailscale ping --c 3 --timeout 5s $peerIp 2>&1 | Out-String
Write-Info ($pingOutput.Trim())

if ($pingOutput -match 'pong') {
    Write-Ok 'Tailnet path is up.'
} else {
    Write-Fail 'No response over the tailnet.'
    Write-Info 'The peer is unreachable at the network layer. Check that Tailscale is'
    Write-Info 'running on it, and that your ACLs allow traffic between these machines.'
    exit 1
}

# ----------------------------------------------------------------- 5. tcp 5900 --

Write-Step "5. TCP connect to ${peerIp}:$Port"

$tcp = Test-NetConnection -ComputerName $peerIp -Port $Port -WarningAction SilentlyContinue
if ($tcp.TcpTestSucceeded) {
    Write-Ok "Port $Port is open and accepting connections."
    Write-Host ''
    Write-Host '    Everything checks out. Connect in VNC Viewer with:' -ForegroundColor Green
    Write-Host "      $peerName" -ForegroundColor White
    Write-Host "      $peerIp"   -ForegroundColor White
    Write-Host ''
    Write-Info 'Type it in the VNC Viewer search bar and press Enter. The empty address'
    Write-Info "book (`"0 device(s)`") is normal - you do not need to add the machine to it."
} else {
    Write-Fail "The tailnet is up, but nothing accepted a TCP connection on port $Port."
    Write-Host ''
    Write-Info 'This is the classic case. On the TARGET machine, one of these is true:'
    Write-Info '  a) No VNC server is running        -> install/start it'
    Write-Info "  b) The firewall is blocking $Port  -> run Setup-VncOverTailscale.ps1 there"
    Write-Info '  c) The VNC server is bound to localhost or the LAN NIC only'
    Write-Host ''
    Write-Info 'Running Setup-VncOverTailscale.ps1 on the target fixes (b) and reports (a)/(c).'
    exit 1
}
