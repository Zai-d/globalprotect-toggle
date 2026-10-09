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
SCUTIL=/usr/sbin/scutil
NETSTAT=/usr/sbin/netstat
ROUTE=/sbin/route
CURL=/usr/bin/curl
DSCACHEUTIL=/usr/bin/dscacheutil
ROUTE_WATCH_LABEL=com.globalprotect-toggle.route-watch
ROUTE_WATCH_DIR=/usr/local/libexec/globalprotect-toggle
ROUTE_WATCH_SCRIPT=$ROUTE_WATCH_DIR/gp-toggle.sh
ROUTE_WATCH_PLIST=/Library/LaunchDaemons/$ROUTE_WATCH_LABEL.plist
ROUTE_WATCH_STATE=/var/db/$ROUTE_WATCH_LABEL.state

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
  local service proxy url enabled services cleared=0 failed=0

  services=$("$NETWORKSETUP" -listallnetworkservices) || return 1

  while IFS= read -r service; do
    # networksetup prefixes unavailable services with an asterisk.
    [[ -z "$service" || "$service" == \** ]] && continue

    proxy=$("$NETWORKSETUP" -getautoproxyurl "$service") || { failed=1; continue; }
    url=$(awk -F': ' '/^URL:/{print $2; exit}' <<<"$proxy")
    enabled=$(awk -F': ' '/^Enabled:/{print $2; exit}' <<<"$proxy")

    if [[ "$enabled" == "Yes" ]] && is_globalprotect_pac "$url"; then
      if "$NETWORKSETUP" -setautoproxystate "$service" off; then
        echo "  proxy  $service -> disabled stale GlobalProtect PAC"
        ((cleared += 1))
      else
        echo "  proxy  $service -> failed to disable GlobalProtect PAC" >&2
        failed=1
      fi
    fi
  done < <(printf '%s\n' "$services" | tail -n +2)

  if (( cleared == 0 && failed == 0 )); then
    echo "  proxy  no enabled GlobalProtect PAC settings found"
  fi
  return "$failed"
}

start_globalprotect_app() {
  # Re-launching the app lets the currently installed GlobalProtect version
  # recreate its own PAC server and configuration after the services return.
  if [[ -n "$GUI_UID" && -d /Applications/GlobalProtect.app ]]; then
    launchctl asuser "$GUI_UID" /usr/bin/open -gja /Applications/GlobalProtect.app 2>/dev/null || true
  fi
}

stop_processes() {
  local pattern="$1"
  local pid

  while read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done < <(pgrep -f "$pattern" 2>/dev/null || true)
}

default_route() {
  local route

  route=$("$ROUTE" -n get default 2>/dev/null || true)
  awk '
    /gateway:/ { gateway = $2 }
    /interface:/ { interface = $2 }
    END {
      if (gateway != "" && interface != "") {
        print gateway, interface
      }
    }
  ' <<<"$route"
}

physical_default_route() {
  "$NETSTAT" -rn -f inet |
    awk '$1 == "default" && $3 ~ /G/ && $4 ~ /^en[0-9]+$/ {print $2, $4; exit}'
}

disable_job() {
  local target="$1"
  launchctl disable "$target" || return 1
  if launchctl print "$target" >/dev/null 2>&1; then
    launchctl bootout "$target" || return 1
  fi
}

globalprotect_processes_stopped() {
  local result=0
  pgrep -f '^/Applications/GlobalProtect.app/Contents/(Resources/PanGPS|MacOS/GlobalProtect)([[:space:]]|$)' >/dev/null || result=$?
  # pgrep: 0 = found, 1 = absent, >1 = unable to inspect processes.
  [[ "$result" == 1 ]]
}

globalprotect_interface() {
  printf 'show State:/Network/Service/gpd.pan/IPv4\nquit\n' |
    "$SCUTIL" | awk '$1 == "InterfaceName" && $3 ~ /^utun[0-9]+$/ {print $3; exit}'
}

clear_globalprotect_network_state() {
  local entity key state failed=0

  # PanGPS publishes transient service state. Killing it can leave its VPN
  # DNS, OverridePrimary route and localhost PAC selected by configd.
  # Preserve every Setup key and the physical network's DNS configuration.
  for entity in DNS IPv4 IPv6 Proxies; do
    key="State:/Network/Service/gpd.pan/$entity"
    state=$(printf 'show %s\nquit\n' "$key" | "$SCUTIL") || return 1
    [[ "$state" == *'No such key'* ]] && continue
    if [[ "$state" != *'<dictionary>'* ]]; then
      echo "  network unable to read $key" >&2
      return 1
    fi
    printf 'remove %s\nquit\n' "$key" | "$SCUTIL" >/dev/null
    state=$(printf 'show %s\nquit\n' "$key" | "$SCUTIL") || return 1
    if [[ "$state" != *'No such key'* ]]; then
      echo "  network failed to remove $key" >&2
      failed=1
    else
      echo "  network cleared stale GlobalProtect $entity state"
    fi
  done
  return "$failed"
}

remove_interface_routes() {
  local interface="$1"
  local destination gateway flags kind removed=0 failed=0
  local scope=() family routes remaining

  [[ -z "$interface" || "$interface" != utun* ]] && return 0

  for family in inet inet6; do
    routes=$("$NETSTAT" -rn -f "$family") || return 1
    while read -r destination gateway flags; do
      [[ -z "$destination" ]] && continue

      kind=-net
      if [[ "$flags" == *H* || ( "$family" == inet && "$destination" == */32 ) ||
            ( "$family" == inet6 && "$destination" == */128 ) ]]; then
        kind=-host
        destination=${destination%/*}
      fi
      scope=()
      [[ "$flags" == *I* ]] && scope=(-ifscope "$interface")
      if "$ROUTE" -n delete "-$family" "$kind" ${scope[@]+"${scope[@]}"} "$destination" "$gateway" >/dev/null 2>&1; then
        ((removed += 1))
      fi
    done < <(
      printf '%s\n' "$routes" |
        awk -v interface="$interface" '$4 == interface && $3 ~ /G/ {print $1, $2, $3}'
    )
    # configd can remove a route between our snapshot and delete. Inspect the
    # result rather than mistaking that race for a cleanup failure.
    routes=$("$NETSTAT" -rn -f "$family") || return 1
    remaining=$(awk -v interface="$interface" '$4 == interface && $3 ~ /G/' <<<"$routes")
    if [[ -n "$remaining" ]]; then
      echo "  routes $interface -> $family gateway routes still present" >&2
      failed=1
    fi
  done

  echo "  routes $interface -> removed $removed stale VPN routes"
  return "$failed"
}

verify_off_state() {
  local interface="$1" entity state gateway current_interface routes family proxy url
  globalprotect_processes_stopped || return 1
  for entity in DNS IPv4 IPv6 Proxies; do
    state=$(printf 'show State:/Network/Service/gpd.pan/%s\nquit\n' "$entity" | "$SCUTIL") || return 1
    [[ "$state" == *'No such key'* ]] || return 1
  done
  read -r gateway current_interface < <(default_route)
  [[ -n "$gateway" && "$current_interface" == en[0-9]* ]] || return 1
  if [[ -n "$interface" ]]; then
    for family in inet inet6; do
      routes=$("$NETSTAT" -rn -f "$family") || return 1
      [[ -z $(awk -v interface="$interface" '$4 == interface && $3 ~ /G/' <<<"$routes") ]] || return 1
    done
  fi
  proxy=$("$SCUTIL" --proxy) || return 1
  url=$(awk '$1 == "ProxyAutoConfigURLString" {print $3; exit}' <<<"$proxy")
  if is_globalprotect_pac "$url" && [[ "$proxy" == *'ProxyAutoConfigEnable : 1'* ]]; then
    return 1
  fi
  return 0
}

verify_internet() {
  local url
  # HTTPS by hostname checks DNS, TCP, TLS and traffic through the remaining
  # network extension. Two destinations avoid declaring an outage when one
  # website is unavailable. No proxy environment variables or cached answers.
  for url in https://www.apple.com/ https://example.com/; do
    if "$CURL" --noproxy '*' --connect-timeout 5 --max-time 10 \
      --fail --silent --show-error --output /dev/null "$url"; then
      echo "  internet DNS and HTTPS verified via $url"
      return 0
    fi
  done
  echo "Internet verification failed after shutdown (DNS, HTTPS, or network filtering)." >&2
  return 1
}

ensure_physical_default_route() {
  local gateway="$1"
  local interface="$2"
  local current_gateway="" current_interface=""

  if [[ -z "$gateway" || -z "$interface" ]]; then
    echo "  routes no physical default gateway found; check the network connection" >&2
    return 1
  fi
  read -r current_gateway current_interface < <(default_route) || true

  if [[ "$current_interface" == utun* || -z "$current_gateway" ]]; then
    "$ROUTE" -n add default "$gateway" -ifp "$interface" >/dev/null 2>&1 || return 1
  fi
  read -r current_gateway current_interface < <(default_route) || true
  if [[ -z "$current_gateway" || "$current_interface" == utun* ]]; then
    echo "  routes physical default route was not restored" >&2
    return 1
  fi
  return 0
}

repair_stale_routes() {
  local old_gateway="$1"
  local old_interface="$2"
  local new_gateway="$3"
  local new_interface="${4:-$old_interface}"
  local destination flags kind routes updated=0 failed=0
  local scope=()

  # A VPN stopping is not a physical network change.
  [[ "$old_interface" == en[0-9]* ]] || return 0
  [[ "$new_interface" == en[0-9]* ]] || return 0
  routes=$("$NETSTAT" -rn -f inet) || return 1

  while read -r destination flags; do
    [[ -z "$destination" || "$destination" == "default" ]] && continue
    kind=-net
    if [[ "$flags" == *H* || "$destination" == */32 ]]; then
      kind=-host
      destination=${destination%/32}
    fi
    scope=()
    [[ "$flags" == *I* ]] && scope=(-ifscope "$old_interface")
    # An interface-scoped entry cannot become a route for another interface.
    # Drop that stale entry so lookups use the current network's routes.
    if [[ "$flags" == *I* && "$old_interface" != "$new_interface" ]]; then
      if "$ROUTE" -n delete -inet "$kind" -ifscope "$old_interface" "$destination" "$old_gateway" >/dev/null 2>&1; then
        ((updated += 1))
      else
        failed=1
      fi
    elif "$ROUTE" -n change -inet "$kind" ${scope[@]+"${scope[@]}"} "$destination" "$new_gateway" -ifp "$new_interface" >/dev/null 2>&1; then
      ((updated += 1))
    else
      failed=1
      /usr/bin/logger -t "$ROUTE_WATCH_LABEL" \
        "Failed to move route $destination from $old_gateway to $new_gateway"
    fi
  done < <(
    printf '%s\n' "$routes" |
      awk -v gateway="$old_gateway" -v interface="$old_interface" \
        '$2 == gateway && $4 == interface && $3 ~ /G/ {print $1, $3}'
  )

  if (( updated > 0 )); then
    /usr/bin/logger -t "$ROUTE_WATCH_LABEL" \
      "Repaired $updated stale routes from $old_gateway to $new_gateway"
  fi
  return "$failed"
}

route_watch() {
  local previous_gateway="" previous_interface=""
  local current_gateway="" current_interface=""
  local state_dir

  need_root route-watch
  state_dir=$(dirname "$ROUTE_WATCH_STATE")
  mkdir -p "$state_dir"

  while true; do
    read -r current_gateway current_interface < <(physical_default_route)

    if [[ -n "$current_gateway" && -n "$current_interface" ]]; then
      if [[ -r "$ROUTE_WATCH_STATE" ]]; then
        read -r previous_gateway previous_interface < "$ROUTE_WATCH_STATE" || true
      fi

      if [[ -n "$previous_gateway" && -n "$previous_interface" &&
            ( "$previous_gateway" != "$current_gateway" ||
              "$previous_interface" != "$current_interface" ) ]]; then
        repair_stale_routes \
          "$previous_gateway" "$previous_interface" "$current_gateway" "$current_interface" || {
            sleep 5
            continue
          }
      fi

      if [[ "$previous_gateway" != "$current_gateway" ||
            "$previous_interface" != "$current_interface" ]]; then
        printf '%s %s\n' "$current_gateway" "$current_interface" \
          > "$ROUTE_WATCH_STATE.tmp"
        mv "$ROUTE_WATCH_STATE.tmp" "$ROUTE_WATCH_STATE"
      fi
    fi

    sleep 5
  done
}

install_route_watch() {
  need_root install-route-watch

  mkdir -p "$ROUTE_WATCH_DIR" || return 1
  if [[ ! "$0" -ef "$ROUTE_WATCH_SCRIPT" ]]; then
    cp "$0" "$ROUTE_WATCH_SCRIPT" || return 1
  fi
  chmod 755 "$ROUTE_WATCH_SCRIPT" || return 1

  cat > "$ROUTE_WATCH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$ROUTE_WATCH_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ROUTE_WATCH_SCRIPT</string>
    <string>route-watch</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
EOF

  /usr/bin/plutil -lint "$ROUTE_WATCH_PLIST" >/dev/null || return 1
  launchctl bootout "system/$ROUTE_WATCH_LABEL" 2>/dev/null || true
  launchctl enable "system/$ROUTE_WATCH_LABEL" || return 1
  launchctl bootstrap system "$ROUTE_WATCH_PLIST" || return 1

  echo "Installed automatic stale-route repair."
}

uninstall_route_watch() {
  need_root uninstall-route-watch

  launchctl bootout "system/$ROUTE_WATCH_LABEL" 2>/dev/null || true
  rm -f "$ROUTE_WATCH_PLIST" "$ROUTE_WATCH_SCRIPT" "$ROUTE_WATCH_STATE"
  rmdir "$ROUTE_WATCH_DIR" 2>/dev/null || true

  echo "Removed automatic stale-route repair."
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
  local vpn_interface="" watcher_installed=0 attempt stable=0 step_failed=0
  local physical_gateway="" physical_interface=""
  local refreshed_gateway="" refreshed_interface=""

  need_root off

  echo "Stopping GlobalProtect..."
  vpn_interface=$(globalprotect_interface) || return 1
  read -r physical_gateway physical_interface < <(physical_default_route)
  [[ -f "$ROUTE_WATCH_PLIST" ]] && watcher_installed=1

  # Suspend even an older installed watcher before the VPN gateway disappears.
  if launchctl print "system/$ROUTE_WATCH_LABEL" >/dev/null 2>&1; then
    watcher_installed=1
    launchctl bootout "system/$ROUTE_WATCH_LABEL" || return 1
  fi

  if [[ -n "$GUI_UID" ]]; then
    for label in "${AGENTS[@]}"; do
      disable_job "gui/$GUI_UID/$label" || return 1
      echo "  agent  $label -> disabled"
    done
  fi

  disable_job "system/$DAEMON" || return 1
  echo "  daemon $DAEMON -> disabled"

  sleep 1
  stop_processes "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect"
  stop_processes "/Applications/GlobalProtect.app/Contents/Resources/PanGPS"
  # Give SIGTERM time to finish before removing state that PanGPS can recreate.
  for attempt in {1..5}; do
    globalprotect_processes_stopped && break
    sleep 1
  done
  if ! globalprotect_processes_stopped; then
    echo "GlobalProtect processes are still running or cannot be inspected; retry off." >&2
    return 1
  fi
  # configd and the extension can settle asynchronously. Require three clean
  # observations instead of assuming one successful delete means recovery.
  for attempt in {1..10}; do
    globalprotect_processes_stopped || break
    if (( stable > 0 )) && ! verify_off_state "$vpn_interface"; then
      stable=0
    fi
    step_failed=0
    # Retain the service's tunnel identity if route removal fails so retrying
    # off can still identify the correct VPN without guessing other utuns.
    if remove_interface_routes "$vpn_interface"; then
      clear_globalprotect_network_state || step_failed=1
    else
      step_failed=1
    fi
    if read -r refreshed_gateway refreshed_interface < <(physical_default_route); then
      physical_gateway="$refreshed_gateway"
      physical_interface="$refreshed_interface"
    fi
    ensure_physical_default_route "$physical_gateway" "$physical_interface" || step_failed=1
    clear_globalprotect_pac || step_failed=1
    if (( step_failed == 0 )) && verify_off_state "$vpn_interface"; then
      ((stable += 1))
      (( stable >= 3 )) && break
    else
      stable=0
    fi
    sleep 1
  done
  if (( stable < 3 )); then
    echo "GlobalProtect stopped, but network cleanup was incomplete; see errors above." >&2
    echo "Run $0 status for the remaining network state." >&2
    return 1
  fi
  "$DSCACHEUTIL" -flushcache || return 1
  killall -HUP mDNSResponder 2>/dev/null || true
  verify_internet || return 1
  verify_off_state "$vpn_interface" || {
    echo "GlobalProtect network state returned during the internet check; retry off." >&2
    return 1
  }

  if (( watcher_installed )); then
    install_route_watch || return 1
    sleep 1
    verify_off_state "$vpn_interface" && verify_internet || return 1
  fi

  echo
  echo "Done. GlobalProtect stays off until you run: sudo $0 on"
  echo "The network system extension remains installed."
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

  echo
  echo "Automatic route repair:"
  if launchctl print "system/$ROUTE_WATCH_LABEL" >/dev/null 2>&1; then
    echo "  RUNNING"
  else
    echo "  not installed or stopped"
  fi
  if [[ -f "$ROUTE_WATCH_SCRIPT" && ! "$0" -ef "$ROUTE_WATCH_SCRIPT" ]] &&
     ! cmp -s "$0" "$ROUTE_WATCH_SCRIPT"; then
    echo "  installed script differs; run: sudo $0 install-route-watch"
  fi

  echo
  echo "Default route: $(default_route)"
  echo "GlobalProtect network state:"
  for entity in DNS IPv4 IPv6 Proxies; do
    printf 'show State:/Network/Service/gpd.pan/%s\nquit\n' "$entity" | "$SCUTIL"
  done
  echo "Effective DNS:"
  "$SCUTIL" --dns
  echo "Effective proxy:"
  "$SCUTIL" --proxy
}

usage() {
  echo "Usage: sudo $0 {on|off|install-route-watch|uninstall-route-watch} | $0 status" >&2
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
  install-route-watch)
    install_route_watch
    ;;
  uninstall-route-watch)
    uninstall_route_watch
    ;;
  route-watch)
    route_watch
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
