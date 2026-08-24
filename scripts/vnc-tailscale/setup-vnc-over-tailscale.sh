#!/usr/bin/env bash
#
# Configure a Linux machine to accept VNC connections over Tailscale only.
#
# Run this on the machine you want to CONTROL (the VNC server side).
# Use the .ps1 script in this directory instead if that machine is Windows.
#
#   sudo ./setup-vnc-over-tailscale.sh
#   sudo ./setup-vnc-over-tailscale.sh --port 5901
#   sudo ./setup-vnc-over-tailscale.sh --remove
#
# It binds x11vnc to the Tailscale IP only, so the VNC port is never exposed on
# the LAN, and opens the port to the tailnet CGNAT range in the local firewall.

set -euo pipefail

PORT=5900
REMOVE=0
SERVICE_NAME="x11vnc-tailscale"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
TAILSCALE_CIDR="100.64.0.0/10"

step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    [ok] %s\n' "$1"; }
warn() { printf '    [!]  %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n[FAIL] %s\n' "$1" >&2; exit 1; }

usage() {
    sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port)   PORT="${2:?--port needs a value}"; shift 2 ;;
        --remove) REMOVE=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run this with sudo."

# ------------------------------------------------------------------ removal --

if [ "$REMOVE" -eq 1 ]; then
    step "Removing VNC-over-Tailscale configuration"
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
        systemctl disable --now "$SERVICE_NAME" || true
        rm -f "$UNIT_PATH"
        systemctl daemon-reload
        ok "Service ${SERVICE_NAME} stopped and removed."
    else
        info "No ${SERVICE_NAME} service installed."
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow from "$TAILSCALE_CIDR" to any port "$PORT" proto tcp 2>/dev/null || true
        ok "ufw rule removed (if present)."
    fi
    exit 0
fi

# ---------------------------------------------------------------- tailscale --

step "Checking Tailscale"

command -v tailscale >/dev/null 2>&1 \
    || die "Tailscale is not installed. See https://tailscale.com/download/linux, then run 'tailscale up'."

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[ -n "$TS_IP" ] \
    || die "Tailscale is installed but not connected. Run 'sudo tailscale up' and sign in, then re-run this script."
ok "This machine's Tailscale IP: ${TS_IP}"

# Best-effort: only used to print a friendly connect address at the end.
if command -v jq >/dev/null 2>&1; then
    TS_NAME="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')"
else
    # No jq: isolate the "Self" object first so we do not pick up a peer's name.
    TS_NAME="$(tailscale status --json 2>/dev/null \
               | tr ',' '\n' \
               | grep -m1 -o '"DNSName":"[^"]*"' \
               | sed 's/.*"\([^"]*\)"$/\1/' \
               | sed 's/\.$//' || true)"
fi
[ -n "$TS_NAME" ] && ok "MagicDNS name: ${TS_NAME}"

# ------------------------------------------------------------- display check --

step "Checking the desktop session"

if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    warn "This looks like a Wayland session. x11vnc only works on X11."
    info "Either switch the login session to X11/Xorg, or use wayvnc instead."
    info "Continuing anyway - the firewall rule below is still useful."
fi

# --------------------------------------------------------------- vnc server --

step "Installing x11vnc"

if command -v x11vnc >/dev/null 2>&1; then
    ok "x11vnc already installed."
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y x11vnc
    ok "x11vnc installed."
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y x11vnc
    ok "x11vnc installed."
elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm x11vnc
    ok "x11vnc installed."
else
    die "No supported package manager found. Install x11vnc manually, then re-run."
fi

# ------------------------------------------------------------------ password --

step "VNC password"

# The desktop user, not root - x11vnc needs their X session and their password file.
DESKTOP_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
PASSWD_FILE="${DESKTOP_HOME}/.vnc/passwd"

info "Desktop user: ${DESKTOP_USER}"

if [ -f "$PASSWD_FILE" ]; then
    ok "Existing password file: ${PASSWD_FILE}"
else
    info "No password set yet - you will be prompted for one now."
    install -d -m 700 -o "$DESKTOP_USER" -g "$DESKTOP_USER" "${DESKTOP_HOME}/.vnc"
    x11vnc -storepasswd "$PASSWD_FILE"
    chown "$DESKTOP_USER":"$DESKTOP_USER" "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"
    ok "Password stored at ${PASSWD_FILE}"
fi

# ------------------------------------------------------------------- service --

step "Installing systemd service ${SERVICE_NAME}"

# -listen binds to the Tailscale IP only: the port is not offered on the LAN NIC.
cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=x11vnc bound to the Tailscale interface
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=${DESKTOP_USER}
Environment=DISPLAY=:0
ExecStart=/usr/bin/x11vnc -display :0 -auth guess \\
    -rfbauth ${PASSWD_FILE} \\
    -listen ${TS_IP} \\
    -rfbport ${PORT} \\
    -forever -loop -shared -noxdamage
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
ok "Service installed, enabled at boot, and started."

# ------------------------------------------------------------------ firewall --

step "Opening TCP ${PORT} to the tailnet only (${TAILSCALE_CIDR})"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow from "$TAILSCALE_CIDR" to any port "$PORT" proto tcp
    ok "ufw rule added."
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${TAILSCALE_CIDR} port port=${PORT} protocol=tcp accept"
    firewall-cmd --reload
    ok "firewalld rule added."
else
    info "No active ufw/firewalld detected - nothing to open."
    info "x11vnc is bound to ${TS_IP} only, so the port is not exposed on the LAN regardless."
fi

# ------------------------------------------------------------------ verify --

step "Verifying"

sleep 1
if ss -ltn 2>/dev/null | grep -q ":${PORT}"; then
    ok "Listening: $(ss -ltn | grep ":${PORT}" | tr -s ' ' | cut -d' ' -f4 | paste -sd', ' -)"
else
    warn "Nothing listening on ${PORT} yet."
    info "Check the logs: journalctl -u ${SERVICE_NAME} -n 40 --no-pager"
    info "The usual cause is no active X session on :0 (log in on the physical screen first)."
fi

step "Done. Connect from your other machine with VNC Viewer:"
[ -n "$TS_NAME" ] && printf '      %s\n' "$TS_NAME"
printf '      %s\n\n' "$TS_IP"
info "Port ${PORT} is the default, so ':${PORT}' can be left off the address."
warn "Tailscale carries the traffic but does NOT authenticate the VNC session - the VNC password above is what protects it."
