#!/bin/bash
# gp-toggle.sh — fully stop or restart GlobalProtect (Palo Alto Networks) on macOS.
#
#   sudo ./gp-toggle.sh off      stop it and keep it stopped across reboots
#   sudo ./gp-toggle.sh on       re-enable and start it again
#        ./gp-toggle.sh status   show current state (no sudo needed)
#
# All three launchd jobs use KeepAlive, so a plain `kill` just respawns them.
# This uses launchctl bootout (stop now) + disable (stop at next login/boot),
# which is fully reversible with `on`.

set -uo pipefail

AGENTS=(com.paloaltonetworks.gp.pangps com.paloaltonetworks.gp.pangpa)
DAEMON=com.paloaltonetworks.gp.pangpsd
SYSEXT=com.paloaltonetworks.GlobalProtect.client.extension

# The console user's uid — the GUI agents live in that domain, not root's.
GUI_UID=$(/usr/bin/stat -f %u /dev/console)

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This needs root. Run: sudo $0 $1" >&2
    exit 1
  fi
}

gp_off() {
  need_root off

  echo "Stopping GlobalProtect..."
  for label in "${AGENTS[@]}"; do
    launchctl disable "gui/$GUI_UID/$label" 2>/dev/null
    launchctl bootout "gui/$GUI_UID/$label" 2>/dev/null
    echo "  agent  $label -> disabled"
  done

  launchctl disable "system/$DAEMON" 2>/dev/null
  launchctl bootout "system/$DAEMON" 2>/dev/null
  echo "  daemon $DAEMON -> disabled"

  # Anything left over (the app UI, stray PanGPS) gets cleaned up here.
  sleep 1
  pkill -f "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect" 2>/dev/null
  pkill -f "/Applications/GlobalProtect.app/Contents/Resources/PanGPS" 2>/dev/null

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

  for label in "${AGENTS[@]}"; do
    launchctl enable "gui/$GUI_UID/$label" 2>/dev/null
    launchctl bootstrap "gui/$GUI_UID" /Library/LaunchAgents/$label.plist 2>/dev/null
    echo "  agent  $label -> enabled"
  done

  sleep 2
  echo
  echo "Done. If the menu bar icon doesn't come back, open /Applications/GlobalProtect.app"
}

gp_status() {
  echo "GlobalProtect status"
  echo "--------------------"
  for label in "${AGENTS[@]}"; do
    if launchctl print "gui/$GUI_UID/$label" >/dev/null 2>&1; then
      printf "  %-40s RUNNING\n" "$label"
    else
      printf "  %-40s stopped\n" "$label"
    fi
  done

  if launchctl print "system/$DAEMON" >/dev/null 2>&1; then
    printf "  %-40s RUNNING\n" "$DAEMON"
  else
    printf "  %-40s stopped\n" "$DAEMON"
  fi

  echo
  echo "Processes:"
  pgrep -fl "GlobalProtect.app" | grep -v gp-toggle || echo "  none"

  echo
  echo "System extension:"
  systemextensionsctl list 2>/dev/null | grep -i "$SYSEXT" || echo "  not listed"
}

case "${1:-status}" in
  off|disable|stop) gp_off ;;
  on|enable|start)  gp_on ;;
  status|"")        gp_status ;;
  *)
    echo "Usage: sudo $0 {on|off}   |   $0 status" >&2
    exit 1
    ;;
esac
