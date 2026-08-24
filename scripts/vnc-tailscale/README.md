# VNC over Tailscale

Scripts to expose a machine's VNC server to your tailnet — and only to your
tailnet — so you can connect with RealVNC Viewer from anywhere without port
forwarding, a VPN concentrator, or a public IP.

## Which script runs where

There are two sides. Run the right script on each.

| Machine | Role | Script |
| --- | --- | --- |
| The one you want to **control** | VNC **server** | `Setup-VncOverTailscale.ps1` (Windows) or `setup-vnc-over-tailscale.sh` (Linux) |
| The one you're **sitting at** | VNC **viewer** | `Test-VncOverTailscale.ps1` — only if the connection fails |

Almost every "it won't connect" case is the setup script never having been run
on the *server* side.

## Setup — on the machine you want to control

**Windows** (elevated PowerShell):

```powershell
# If a VNC server is already installed:
.\Setup-VncOverTailscale.ps1

# Or install RealVNC Server as part of the run:
.\Setup-VncOverTailscale.ps1 -InstallServer
```

**Linux**:

```bash
sudo ./setup-vnc-over-tailscale.sh
```

Both scripts are idempotent — re-run them any time to re-check the state.
Pass `-Remove` / `--remove` to undo the firewall and service changes.

## Connecting

The setup script prints the address to use when it finishes. In VNC Viewer,
type it into the search bar and press **Enter**:

```
mc-hed-t1.tail9b9828.ts.net
100.108.161.21
```

Either works. The IP is stable per machine and doesn't depend on MagicDNS, so
it's the better choice if name resolution is ever flaky. Port `5900` is the
default and can be omitted.

An empty address book — *"There are no computers in your address book at
present. 0 device(s)"* — is normal and is not the problem. The address book is
a RealVNC cloud feature; direct connections don't use it and don't require
signing in.

## When it doesn't work

Run this on the machine you're connecting **from**:

```powershell
.\Test-VncOverTailscale.ps1 -Target mc-hed-t1
```

It walks the path one layer at a time — Tailscale up, peer online, MagicDNS
resolving, tailnet reachability, then the TCP connect to 5900 — and names the
layer that's broken instead of leaving you to guess.

## What the setup actually does

1. **Confirms Tailscale is connected** and reads the machine's tailnet IP.
2. **Starts the VNC server** (installing one on request) and sets it to run at boot.
3. **Opens TCP 5900 to `100.64.0.0/10` only.** That's the Tailscale CGNAT
   range, so tailnet peers reach it and the LAN and public internet do not.
   - On Windows the rule is created for **all** firewall profiles. This matters:
     Windows classifies the Tailscale adapter as a *Public* network, so a rule
     scoped to Private only will silently fail.
   - On Linux `x11vnc` is additionally bound to the Tailscale IP with `-listen`,
     so the port isn't even offered on the LAN interface.
4. **Verifies something is listening** on the port and reports what.

## Security notes

- **Tailscale carries the traffic but does not authenticate the VNC session.**
  It puts the port on a private network; it does not decide who may log in.
  Set a VNC password. The scripts refuse to pretend otherwise.
- The firewall scope is the whole CGNAT range, which means *every* device in
  your tailnet can reach the port. To narrow it to specific machines, use a
  Tailscale ACL:

  ```json
  {
    "action": "accept",
    "src":    ["autogroup:member"],
    "dst":    ["mc-hed-t1:5900"],
    "proto":  "tcp"
  }
  ```

- For an always-on machine, **disable key expiry** in the Tailscale admin
  console (Machines → the machine → Disable key expiry). Otherwise it drops off
  the tailnet after ~180 days and you lose remote access with no way to fix it
  remotely.

## Requirements

- Tailscale installed and signed in on **both** machines, on the same tailnet.
- Windows: PowerShell 5.1+ run as Administrator. `winget` only for `-InstallServer`.
- Linux: systemd, an **X11** session (x11vnc can't capture Wayland — use
  `wayvnc` there), and `apt`/`dnf`/`pacman` for the install step.
