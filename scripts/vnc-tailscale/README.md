# VNC over Tailscale

Tooling for reaching a fleet of machines over VNC across a tailnet — no port
forwarding, no public IPs, nothing exposed to the LAN.

## Scenario A — adding a new client PC (most common)

The machines already serve VNC and you can already reach them from another
computer. You just want a **new PC** to reach them too.

**Nothing changes on the servers.** Adding a client is entirely local to the
new PC:

1. **Install Tailscale** and sign in with the *same account* the working
   computer uses. This is the step that actually matters — a different account
   means a different tailnet and an empty peer list.
2. **Approve the device** if your tailnet has device approval turned on
   (admin console → Machines).
3. **Install VNC Viewer.**
4. **Connect**: type the machine's MagicDNS name into the search bar and press
   **Enter**.

Then confirm what's reachable — **double-click `Scan-VncTargets.cmd`**, or from
a PowerShell prompt:

```powershell
.\Get-VncTargets.ps1
```

This lists every peer in the tailnet and probes port 5900 on each, so you see
which machines are VNC-ready in one shot instead of finding out one failed
connection at a time. `-ReadyOnly` trims it to the working ones.

If something specific won't connect — **double-click `Test-VncConnection.cmd`**
and enter the machine name, or:

```powershell
.\Test-VncOverTailscale.ps1 -Target mc-hed-t1
```

It walks the path layer by layer — Tailscale up, peer online, MagicDNS
resolving, tailnet reachability, TCP 5900 — and names the layer that's broken.

### Bringing your saved connections across

To avoid retyping a dozen addresses, export the address book on the computer
that already works: **File → Export connections**, copy the resulting file to
the new PC, then **File → Import connections**. Saved passwords are not
included — you'll re-enter those once per machine.

### The empty address book is not the problem

*"There are no computers in your address book at present. 0 device(s)"* is
normal. The address book is a RealVNC cloud feature that requires signing in to
a RealVNC account. Direct connections over Tailscale don't use it and don't
need it. Type the address in the search bar and press Enter.

## Scenario B — setting up a new server machine

Only needed for a machine that is **not yet** serving VNC.

| Target OS | Script |
| --- | --- |
| Linux / Raspberry Pi OS | `setup-vnc-over-tailscale.sh` (run with `sudo`) |
| Windows | `Setup-VncOverTailscale.ps1` (run elevated) |

```bash
sudo ./setup-vnc-over-tailscale.sh
```

```powershell
.\Setup-VncOverTailscale.ps1              # server already installed
.\Setup-VncOverTailscale.ps1 -InstallServer   # install RealVNC Server too
```

Both are idempotent — safe to re-run to re-check state. `--remove` / `-Remove`
undoes the firewall and service changes.

What the setup does:

1. **Confirms Tailscale is connected** and reads the machine's tailnet IP.
2. **Starts the VNC server** (installing one on request) and enables it at boot.
3. **Restricts TCP 5900 to `100.64.0.0/10`**, the Tailscale CGNAT range, so
   tailnet peers reach it and the LAN and public internet do not.
   - On Linux this is **one targeted `DROP` rule** for port 5900 only. Default
     policy is never changed and no other port is touched, so it cannot lock you
     out of SSH — which matters on a headless Pi you can only reach remotely. A
     systemd oneshot re-applies it at boot, since iptables rules don't persist.
   - On X11, `x11vnc` is additionally bound to the Tailscale IP with `-listen`,
     so the port isn't even offered on the LAN interface.
   - On Windows the rule covers **all** firewall profiles. Windows classifies
     the Tailscale adapter as a *Public* network, so a Private-only rule fails
     silently.
4. **Verifies something is listening** and reports what.

### Wayland vs X11 on Raspberry Pi OS

Raspberry Pi OS Bookworm and later default to **Wayland** on the Pi 4 and 5.
`x11vnc` cannot capture a Wayland session — the most common reason a
hand-rolled VNC setup on a modern Pi yields a black screen or no listener. The
script detects the session type with `loginctl` and picks accordingly:

- **Wayland** → enables the built-in `wayvnc` via `raspi-config nonint do_vnc 0`.
- **X11** → installs `x11vnc` bound to the Tailscale IP.

To force X11: `sudo raspi-config` → Advanced Options → Wayland → X11.

**VNC shares an existing desktop session.** If the machine boots to a console or
nobody is logged in, there's nothing to share and nothing will listen on 5900.
Enable `sudo raspi-config` → System Options → Boot / Auto Login → **Desktop
Autologin**, then reboot.

## Security notes

- **Tailscale carries the traffic but does not authenticate the VNC session.**
  It puts the port on a private network; it does not decide who may log in. Set
  a VNC password.
- The firewall scope is the whole CGNAT range, so every device in your tailnet
  can reach the port. To narrow it to specific machines, use a Tailscale ACL:

  ```json
  {
    "action": "accept",
    "src":    ["autogroup:member"],
    "dst":    ["mc-hed-t1:5900"],
    "proto":  "tcp"
  }
  ```

- For always-on machines, **disable key expiry** in the admin console (Machines
  → the machine → Disable key expiry). Otherwise they drop off the tailnet after
  ~180 days and you lose remote access with no remote way to restore it.

## Running the PowerShell scripts on Windows

Windows blocks `.ps1` files by default, so a fresh download won't run on a
double-click. Three ways around it, easiest first:

**1. Use the `.cmd` launchers.** `Scan-VncTargets.cmd` and
`Test-VncConnection.cmd` are double-clickable and invoke PowerShell with the
policy bypassed for that one run. Keep them in the same folder as the `.ps1`
files. Nothing to configure.

**2. Bypass for a single run:**

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Downloads\Get-VncTargets.ps1"
```

**3. Allow local scripts for your user, once:**

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\*.ps1     # clears the "downloaded from the internet" mark
.\Get-VncTargets.ps1
```

`RemoteSigned` still refuses unsigned *downloaded* scripts, which is why
`Unblock-File` is needed alongside it. This setting is per-user and needs no
admin rights.

Common errors:

| Message | Cause |
| --- | --- |
| `running scripts is disabled on this system` | Execution policy — use any option above. |
| `is not digitally signed` | Policy is `RemoteSigned`/`AllSigned` and the file still carries the download mark. Run `Unblock-File`. |
| `The term '.\Get-VncTargets.ps1' is not recognized` | Wrong folder. `cd` to where the file is; the leading `.\` is required. |
| Window flashes and closes | Launched by double-clicking the `.ps1`. Use the `.cmd` launcher instead. |
| `could not find the scanner script next to this launcher` | The `.ps1` isn't in the same folder, or its name changed. Some download paths strip hyphens (`Get-VncTargets.ps1` → `GetVncTargets.ps1`); the launchers match either form, but the file must be alongside the `.cmd`. The error lists what it actually found. |

Only the *server* setup scripts need an elevated prompt. `Get-VncTargets.ps1`
and `Test-VncOverTailscale.ps1` run as a normal user.

## Requirements

- Tailscale installed and signed in on **both ends**, on the same tailnet.
- Client: PowerShell 5.1+ (no admin needed for `Get-VncTargets.ps1` or
  `Test-VncOverTailscale.ps1`).
- Server, Linux: systemd, plus `raspi-config` (Wayland) or `apt`/`dnf`/`pacman` (X11).
- Server, Windows: PowerShell 5.1+ as Administrator. `winget` only for `-InstallServer`.
