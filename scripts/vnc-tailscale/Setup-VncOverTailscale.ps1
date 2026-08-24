<#
.SYNOPSIS
    Configures this Windows machine to accept VNC connections over Tailscale only.

.DESCRIPTION
    Run this on the machine you want to CONTROL (the VNC server side).

    It will:
      1. Verify Tailscale is installed, running, and report this machine's tailnet IP/name.
      2. Optionally install a VNC server via winget (-InstallServer).
      3. Create an inbound firewall rule for TCP 5900 scoped to the Tailscale
         CGNAT range (100.64.0.0/10) on all profiles, so the LAN and the public
         internet stay blocked.
      4. Verify something is actually listening on 5900 and report what.

    Everything is idempotent - re-running it is safe.

.PARAMETER Port
    VNC port to open. Default 5900.

.PARAMETER InstallServer
    Install a VNC server with winget if none is detected. Choose which with -Server.

.PARAMETER Server
    Which server -InstallServer should install: RealVNC (default) or TightVNC.

.PARAMETER Remove
    Remove the firewall rule this script creates, then exit.

.EXAMPLE
    # Standard setup, VNC server already installed:
    .\Setup-VncOverTailscale.ps1

.EXAMPLE
    # Setup including installing RealVNC Server:
    .\Setup-VncOverTailscale.ps1 -InstallServer

.NOTES
    Must be run from an elevated (Administrator) PowerShell prompt.
#>

[CmdletBinding()]
param(
    [int]$Port = 5900,
    [switch]$InstallServer,
    [ValidateSet('RealVNC', 'TightVNC')]
    [string]$Server = 'RealVNC',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$RuleName       = 'VNC over Tailscale'
$TailscaleCidr  = '100.64.0.0/10'   # Tailscale CGNAT range - covers every tailnet peer

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ok] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [!]  $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "    $Message" }

function Test-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

# ---------------------------------------------------------------- preflight --

if (-not (Test-Admin)) {
    Write-Error "This script needs an elevated prompt. Right-click PowerShell -> 'Run as Administrator', then re-run it."
    exit 1
}

# ------------------------------------------------------------------ removal --

if ($Remove) {
    Write-Step "Removing firewall rule '$RuleName'"
    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        $existing | Remove-NetFirewallRule
        Write-Ok "Rule removed. VNC is no longer reachable over Tailscale."
    } else {
        Write-Info "No rule named '$RuleName' found - nothing to do."
    }
    exit 0
}

# ----------------------------------------------------------------- tailscale --

Write-Step 'Checking Tailscale'

$tailscale = Get-TailscaleExe
if (-not $tailscale) {
    Write-Error "Tailscale not found. Install it from https://tailscale.com/download/windows, run 'tailscale up', then re-run this script."
    exit 1
}
Write-Ok "Found: $tailscale"

$tsIp = (& $tailscale ip -4 2>&1 | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or -not $tsIp -or $tsIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    Write-Error "Tailscale is installed but not connected (could not read a tailnet IP). Run 'tailscale up' and sign in, then re-run this script. Output was: $tsIp"
    exit 1
}
$tsIp = $tsIp.Trim()
Write-Ok "This machine's Tailscale IP: $tsIp"

# MagicDNS name, if the status JSON exposes one.
$dnsName = $null
try {
    $status = & $tailscale status --json 2>$null | ConvertFrom-Json
    if ($status.Self.DNSName) { $dnsName = $status.Self.DNSName.TrimEnd('.') }
} catch {
    Write-Warn "Could not parse 'tailscale status --json' - continuing without the MagicDNS name."
}
if ($dnsName) { Write-Ok "MagicDNS name: $dnsName" }

# ------------------------------------------------------------- server check --

Write-Step 'Checking for an installed VNC server'

$knownServices = @{
    'vncserver'    = 'RealVNC Server'
    'tvnserver'    = 'TightVNC Server'
    'uvnc_service' = 'UltraVNC Server'
}

$foundServices = @()
foreach ($name in $knownServices.Keys) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        $foundServices += $svc
        Write-Ok "$($knownServices[$name]) - service '$($svc.Name)' is $($svc.Status)"
        if ($svc.Status -ne 'Running') {
            Write-Info "Starting it..."
            try {
                Start-Service -Name $svc.Name
                Set-Service  -Name $svc.Name -StartupType Automatic
                Write-Ok "Started and set to start automatically."
            } catch {
                Write-Warn "Could not start '$($svc.Name)': $($_.Exception.Message)"
            }
        }
    }
}

if (-not $foundServices) {
    if ($InstallServer) {
        $pkg = if ($Server -eq 'RealVNC') { 'RealVNC.VNCServer' } else { 'GlavSoft.TightVNC' }
        Write-Info "No VNC server detected. Installing $Server ($pkg) via winget..."
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Error "winget is not available on this machine. Install $Server manually, then re-run this script."
            exit 1
        }
        & winget install --id $pkg --exact --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Error "winget install failed (exit $LASTEXITCODE). Install $Server manually, then re-run this script."
            exit 1
        }
        Write-Ok "$Server installed. You must now set a VNC password in its control panel before connecting."
    } else {
        Write-Warn "No VNC server detected (RealVNC / TightVNC / UltraVNC)."
        Write-Info "Re-run with -InstallServer to install one, or install it yourself."
        Write-Info "The firewall rule below will still be created so it works once a server is present."
    }
}

# ------------------------------------------------------------------ firewall --

Write-Step "Opening TCP $Port to the tailnet only ($TailscaleCidr)"

$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Info "Rule already exists - recreating it so the port and scope are current."
    $existing | Remove-NetFirewallRule
}

New-NetFirewallRule `
    -DisplayName  $RuleName `
    -Description  'Allow VNC (RFB) from Tailscale peers only. Created by Setup-VncOverTailscale.ps1' `
    -Direction    Inbound `
    -Protocol     TCP `
    -LocalPort    $Port `
    -RemoteAddress $TailscaleCidr `
    -Profile      Any `
    -Action       Allow | Out-Null

Write-Ok "Rule '$RuleName' created: TCP $Port inbound, source $TailscaleCidr, all profiles."
Write-Info "Profile 'Any' matters here - Windows treats the Tailscale adapter as a Public network."

# ------------------------------------------------------------------ listener --

Write-Step "Verifying something is listening on port $Port"

$listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($listeners) {
    foreach ($l in $listeners) {
        $procName = 'unknown'
        try { $procName = (Get-Process -Id $l.OwningProcess -ErrorAction Stop).ProcessName } catch { }
        Write-Ok "$($l.LocalAddress):$($l.LocalPort) - $procName (pid $($l.OwningProcess))"
    }
} else {
    Write-Warn "Nothing is listening on port $Port yet."
    Write-Info "Start your VNC server and set a VNC password, then re-run this script to confirm."
}

# --------------------------------------------------------------------- done --

Write-Step 'Done. Connect from your other machine with RealVNC Viewer:'
if ($dnsName) { Write-Host "      $dnsName"  -ForegroundColor White }
Write-Host     "      $tsIp" -ForegroundColor White
Write-Host ''
Write-Info "Port $Port is the default, so you can leave ':$Port' off the address."
Write-Info "If it refuses to connect, run Test-VncOverTailscale.ps1 on the machine you are connecting FROM."
Write-Host ''
Write-Warn "Tailscale carries the traffic but does NOT authenticate the VNC session - make sure a VNC password is set."
if ($foundServices) {
    Write-Info "Also consider disabling key expiry for this machine in the Tailscale admin console if it is always-on."
}
