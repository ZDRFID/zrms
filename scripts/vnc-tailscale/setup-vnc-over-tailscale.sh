#!/usr/bin/env bash
#
# Configure a Linux machine (Raspberry Pi OS included) to accept VNC
# connections over Tailscale, and only over Tailscale.
#
# Run this on the machine you want to CONTROL, e.g. mc-hed-t1.
#
#   sudo ./setup-vnc-over-tailscale.sh
#   sudo ./setup-vnc-over-tailscale.sh --port 5900
#   sudo ./setup-vnc-over-tailscale.sh --remove
#
# On Wayland (Raspberry Pi OS Bookworm/Trixie default) it enables the built-in
# wayvnc server via raspi-config. On X11 it installs x11vnc bound to the
# Tailscale IP. Either way it restricts port 5900 to tailnet peers using a
# single targeted firewall rule - it never changes default firewall policy,
# so it cannot lock you out of SSH.

set -euo pipefail

PORT=5900
REMOVE=0
TAILSCALE_CIDR="100.64.0.0/10"
TAILSCALE_CIDR6="fd7a:115c:a1e0::/48"
X11_SERVICE="x11vnc-tailscale"
X11_UNIT="/etc/systemd/system/${X11_SERVICE}.service"
FW_SERVICE="vnc-tailscale-firewall"
FW_UNIT="/etc/systemd/system/${FW_SERVICE}.service"

step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    [ok] %s\n' "$1"; }
warn() { printf '    [!]  %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n[FAIL] %s\n' "$1" >&2; exit 1; }

usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --port)    PORT="${2:?--port needs a value}"; shift 2 ;;
        --remove)  REMOVE=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run this with sudo."

# --------------------------------------------------------------- firewall fns --

# A single targeted DROP for non-tailnet traffic to the VNC port. This is
# additive: it does not set default policies and does not touch any other port,
# so SSH and everything else keep working exactly as before.
apply_firewall() {
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$PORT" '!' -s "$TAILSCALE_CIDR" -j DROP 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$PORT" '!' -s "$TAILSCALE_CIDR" -j DROP
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C INPUT -p tcp --dport "$PORT" '!' -s "$TAILSCALE_CIDR6" -j DROP 2>/dev/null \
            || ip6tables -I INPUT -p tcp --dport "$PORT" '!' -s "$TAILSCALE_CIDR6" -j DROP 2>/dev/null \
            || true
    fi
}

remove_firewall() {
    if command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p tcp --dport "$PORT" '!' -s "$TAILSCALE_CIDR" -j DROP 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$PORT" '!' -s "$TAILSCALE_CIDR" -j DROP
        done
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C INPUT -p tcp --dport "$PORT" '!' -s "$TAILSCALE_CIDR6" -j DROP 2>/dev/null; do
            ip6tables -D INPUT -p tcp --dport "$PORT" '!' -s "$TAILSCALE_CIDR6" -j DROP
        done
    fi
}

# ------------------------------------------------------------------ removal --

if [ "$REMOVE" -eq 1 ]; then
    step "Removing VNC-over-Tailscale configuration"
    for svc in "$X11_SERVICE" "$FW_SERVICE"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
            systemctl disable --now "$svc" >/dev/null 2>&1 || true
            ok "Service ${svc} stopped and disabled."
        fi
    done
    rm -f "$X11_UNIT" "$FW_UNIT"
    systemctl daemon-reload
    remove_firewall
    ok "Firewall rules removed."
    info "The VNC server itself was left installed. Disable it with 'sudo raspi-config'"
    info "(Interface Options -> VNC -> No) if you no longer want it running at all."
    exit 0
fi

# ---------------------------------------------------------------- tailscale --

step "Checking Tailscale"

command -v tailscale >/dev/null 2>&1 \
    || die "Tailscale is not installed. See https://tailscale.com/download/linux, then 'sudo tailscale up'."

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[ -n "$TS_IP" ] \
    || die "Tailscale is installed but not connected. Run 'sudo tailscale up', then re-run this script."
ok "This machine's Tailscale IP: ${TS_IP}"

# Best-effort, only used to print a friendly connect address at the end.
if command -v jq >/dev/null 2>&1; then
    TS_NAME="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')"
else
    TS_NAME="$(tailscale status --json 2>/dev/null \
               | tr ',' '\n' \
               | grep -m1 -o '"DNSName":"[^"]*"' \
               | sed 's/.*"\([^"]*\)"$/\1/' \
               | sed 's/\.$//' || true)"
fi
[ -n "${TS_NAME:-}" ] && ok "MagicDNS name: ${TS_NAME}"

# ------------------------------------------------------- platform / session --

step "Detecting platform and desktop session"

IS_PI=0
if [ -f /proc/device-tree/model ] && tr -d '\0' < /proc/device-tree/model | grep -qi raspberry; then
    IS_PI=1
    ok "Hardware: $(tr -d '\0' < /proc/device-tree/model)"
fi

DESKTOP_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
info "Desktop user: ${DESKTOP_USER}"

SESSION_TYPE=""
SESSION_ID="$(loginctl show-user "$DESKTOP_USER" -p Display --value 2>/dev/null || true)"
if [ -n "$SESSION_ID" ]; then
    SESSION_TYPE="$(loginctl show-session "$SESSION_ID" -p Type --value 2>/dev/null || true)"
fi

if [ -n "$SESSION_TYPE" ]; then
    ok "Graphical session type: ${SESSION_TYPE}"
else
    warn "No graphical session detected for ${DESKTOP_USER}."
    info "VNC shares an existing desktop session - if this machine boots to a console"
    info "or nobody is logged in, there is nothing to share. Enable desktop autologin:"
    info "  sudo raspi-config  ->  System Options  ->  Boot / Auto Login  ->  Desktop Autologin"
fi

# --------------------------------------------------------------- vnc server --

if [ "$SESSION_TYPE" = "wayland" ] || { [ "$IS_PI" -eq 1 ] && [ -z "$SESSION_TYPE" ]; }; then

    step "Enabling the built-in VNC server (wayvnc, for Wayland)"

    info "x11vnc cannot capture a Wayland session, so the Pi's own wayvnc is used."

    if command -v raspi-config >/dev/null 2>&1; then
        raspi-config nonint do_vnc 0
        ok "VNC enabled via raspi-config."
    else
        die "raspi-config not found and the session is Wayland. Enable VNC manually, or switch the session to X11 (raspi-config -> Advanced Options -> Wayland -> X11) and re-run."
    fi

    if [ -f /etc/wayvnc/config ]; then
        info "wayvnc config (/etc/wayvnc/config):"
        grep -E '^(address|enable_auth|username|port)' /etc/wayvnc/config 2>/dev/null \
            | sed 's/^/      /' || info "      (no address/auth keys set - defaults apply)"
    fi

    info "Sign in with this machine's own username and password when VNC Viewer asks."

else

    step "Installing x11vnc (for X11)"

    if command -v x11vnc >/dev/null 2>&1; then
        ok "x11vnc already installed."
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y x11vnc
        ok "x11vnc installed."
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y x11vnc && ok "x11vnc installed."
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm x11vnc && ok "x11vnc installed."
    else
        die "No supported package manager found. Install x11vnc manually, then re-run."
    fi

    step "VNC password"

    PASSWD_FILE="${DESKTOP_HOME}/.vnc/passwd"
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

    step "Installing systemd service ${X11_SERVICE}"

    # -listen binds to the Tailscale IP only: the port is never offered on the LAN NIC.
    cat > "$X11_UNIT" <<UNIT
[Unit]
Description=x11vnc bound to the Tailscale interface
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

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
    systemctl enable "$X11_SERVICE" >/dev/null
    systemctl restart "$X11_SERVICE"
    ok "Service installed, enabled at boot, and started."
fi

# ------------------------------------------------------------------ firewall --

step "Restricting port ${PORT} to tailnet peers"

apply_firewall
ok "Rule applied: TCP ${PORT} dropped unless the source is ${TAILSCALE_CIDR}."
info "This is a single targeted rule - default policy is untouched, so SSH is unaffected."

# iptables rules are not persistent across reboots on their own.
cat > "$FW_UNIT" <<UNIT
[Unit]
Description=Restrict VNC port ${PORT} to Tailscale peers
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -C INPUT -p tcp --dport ${PORT} ! -s ${TAILSCALE_CIDR} -j DROP 2>/dev/null || iptables -I INPUT -p tcp --dport ${PORT} ! -s ${TAILSCALE_CIDR} -j DROP'

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$FW_SERVICE" >/dev/null
ok "Rule will be re-applied at boot by ${FW_SERVICE}.service."

# -------------------------------------------------------------------- verify --

step "Verifying"

sleep 2
if ss -ltn 2>/dev/null | grep -q ":${PORT}\b"; then
    ok "Listening on: $(ss -ltn | grep ":${PORT}\b" | tr -s ' ' | cut -d' ' -f4 | paste -sd', ' -)"
else
    warn "Nothing is listening on port ${PORT} yet."
    info "Most likely there is no active desktop session to share. Check:"
    info "  loginctl list-sessions"
    if [ -f "$X11_UNIT" ]; then
        info "  journalctl -u ${X11_SERVICE} -n 40 --no-pager"
    else
        info "  systemctl status wayvnc  (or: journalctl -u wayvnc -n 40 --no-pager)"
    fi
    info "A reboot after enabling desktop autologin usually resolves it."
fi

step "Done. Connect from your Windows PC with VNC Viewer:"
[ -n "${TS_NAME:-}" ] && printf '      %s\n' "$TS_NAME"
printf '      %s\n\n' "$TS_IP"
info "Port ${PORT} is the default, so ':${PORT}' can be left off the address."
warn "Tailscale carries the traffic but does NOT authenticate the VNC session."
