#!/bin/bash
# gp-toggle.sh — fully stop or restart GlobalProtect (Palo Alto Networks) on macOS.
#
#   sudo ~/scripts/gp-toggle.sh off      stop it and keep it stopped across reboots
#   sudo ~/scripts/gp-toggle.sh on       re-enable and start it again
#   ~/scripts/gp-toggle.sh status         show current state (no sudo needed)
#
# All three launchd jobs use KeepAlive, so a plain kill just respawns them.
# This uses launchctl bootout (stop now) + disable (stop at next login/boot),
# which is fully reversible with `on`.

set -uo pipefail

AGENTS=(com.paloaltonetworks.gp.pangps com.paloaltonetworks.gp.pangpa)
DAEMON=com.paloaltonetworks.gp.pangpsd
SYSEXT=com.paloaltonetworks.GlobalProtect.client.extension
NETWORKSETUP=/usr/sbin/networksetup

# GlobalProtect's system extension can leave this PAC configuration enabled
# after its launchd jobs have been stopped. Browsers honour the PAC file, but
# its localhost server is then gone, which blocks all browser traffic.
# Only URLs matching GlobalProtect's own local PAC naming scheme are changed;
# a user- or company-configured remote PAC file is left untouched.
is_globalprotect_pac() {
  [[ "$1" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?/[^[:space:]]*_gpproxy\.pac$ ]]
}

# The console user's uid — the GUI agents live in that domain, not root's.
GUI_UID=""
if [[ -r /dev/console ]]; then
  GUI_UID=$( /usr/bin/stat -f %u /dev/console 2>/dev/null || true )
fi

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This needs root. Run: sudo $0 $1" >&2
    exit 1
  fi
}

clear_globalprotect_pac() {
  local service proxy url enabled cleared=0

  while IFS= read -r service; do
    # networksetup prefixes unavailable services with an asterisk.
    [[ -z "$service" || "$service" == \** ]] && continue

    proxy=$("$NETWORKSETUP" -getautoproxyurl "$service" 2>/dev/null || true)
    url=$(awk -F': ' '/^URL:/{print $2; exit}' <<<"$proxy")
    enabled=$(awk -F': ' '/^Enabled:/{print $2; exit}' <<<"$proxy")

    if [[ "$enabled" == "Yes" ]] && is_globalprotect_pac "$url"; then
      "$NETWORKSETUP" -setautoproxystate "$service" off
      echo "  proxy  $service -> disabled stale GlobalProtect PAC"
      ((cleared += 1))
    fi
  done < <("$NETWORKSETUP" -listallnetworkservices | tail -n +2)

  if (( cleared == 0 )); then
    echo "  proxy  no enabled GlobalProtect PAC settings found"
  fi
}

start_globalprotect_app() {
  # Re-launching the app lets the currently installed GlobalProtect version
  # recreate its own PAC server and configuration after the services return.
  if [[ -n "$GUI_UID" && -d /Applications/GlobalProtect.app ]]; then
    launchctl asuser "$GUI_UID" /usr/bin/open -gja /Applications/GlobalProtect.app 2>/dev/null || true
  fi
}

print_status_line() {
  local label="$1"
  local state="stopped"
  local color=""

  if launchctl print "gui/$GUI_UID/$label" >/dev/null 2>&1; then
    state="RUNNING"
    color="\033[32m"
  else
    color="\033[90m"
  fi

  printf "  %-40s %b%s\033[0m\n" "$label" "$color" "$state"
}

print_daemon_line() {
  local label="$1"
  local state="stopped"
  local color=""

  if launchctl print "system/$label" >/dev/null 2>&1; then
    state="RUNNING"
    color="\033[32m"
  else
    color="\033[90m"
  fi

  printf "  %-40s %b%s\033[0m\n" "$label" "$color" "$state"
}

gp_off() {
  need_root off

  echo "Stopping GlobalProtect..."

  if [[ -n "$GUI_UID" ]]; then
    for label in "${AGENTS[@]}"; do
      launchctl disable "gui/$GUI_UID/$label" 2>/dev/null
      launchctl bootout "gui/$GUI_UID/$label" 2>/dev/null
      echo "  agent  $label -> disabled"
    done
  fi

  launchctl disable "system/$DAEMON" 2>/dev/null
  launchctl bootout "system/$DAEMON" 2>/dev/null
  echo "  daemon $DAEMON -> disabled"

  sleep 1
  pkill -f "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect" 2>/dev/null
  pkill -f "/Applications/GlobalProtect.app/Contents/Resources/PanGPS" 2>/dev/null
  clear_globalprotect_pac

  echo
  echo "Done. GlobalProtect stays off until you run: sudo $0 on"
  echo "Note: the network system extension is still installed but idle with"
  echo "the daemons stopped. Removing it needs SIP off, so this script leaves it."
}

gp_on() {
  need_root on

  echo "Re-enabling GlobalProtect..."
  launchctl enable "system/$DAEMON" 2>/dev/null
  launchctl bootstrap system /Library/LaunchDaemons/$DAEMON.plist 2>/dev/null
  echo "  daemon $DAEMON -> enabled"

  if [[ -n "$GUI_UID" ]]; then
    for label in "${AGENTS[@]}"; do
      launchctl enable "gui/$GUI_UID/$label" 2>/dev/null
      launchctl bootstrap "gui/$GUI_UID" /Library/LaunchAgents/$label.plist 2>/dev/null
      echo "  agent  $label -> enabled"
    done
  fi

  sleep 2
  start_globalprotect_app
  echo
  echo "Done. GlobalProtect has been relaunched so it can restore its current proxy configuration."
}

gp_status() {
  echo "GlobalProtect status"
  echo "--------------------"

  if [[ -n "$GUI_UID" ]]; then
    for label in "${AGENTS[@]}"; do
      print_status_line "$label"
    done
  else
    echo "  GUI agents not available on this host"
  fi

  print_daemon_line "$DAEMON"

  echo
  echo "Processes:"
  pgrep -fl "GlobalProtect.app" | grep -v gp-toggle || echo "  none"

  echo
  echo "System extension:"
  systemextensionsctl list 2>/dev/null | grep -i "$SYSEXT" || echo "  not listed"
}

usage() {
  echo "Usage: sudo $0 {on|off} | $0 status" >&2
}

case "${1:-status}" in
  off|disable|stop)
    gp_off
    ;;
  on|enable|start)
    gp_on
    ;;
  status|"")
    gp_status
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
