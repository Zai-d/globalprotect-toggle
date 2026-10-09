#!/bin/bash
# Deterministic macOS network fixtures; no host network or launchd mutations.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'if [[ ${KEEP_TEST_DIR:-0} == 1 ]]; then echo "$TEST_DIR"; else rm -rf "$TEST_DIR"; fi' EXIT
export TEST_DIR
sed '/^case "${1:-status}"/,$d' "$ROOT/gp-toggle.sh" > "$TEST_DIR/functions.sh"
source "$TEST_DIR/functions.sh"
mkdir "$TEST_DIR/keys"
cat > "$TEST_DIR/scutil" <<'MOCK'
#!/bin/bash
if [[ "${1:-}" == --proxy ]]; then
  if [[ "${MOCK_PROXY_STUCK:-0}" == 1 ]]; then
    printf '<dictionary> {\n ProxyAutoConfigEnable : 1\n ProxyAutoConfigURLString : http://127.0.0.1:9999/123_gpproxy.pac\n}\n'
  else
    echo '<dictionary> { }'
  fi
  exit 0
fi
read -r command key
[[ "${MOCK_SCUTIL_ERROR:-0}" == 1 ]] && exit 1
if [[ "$command" == remove ]]; then
  echo "$key" >> "$TEST_DIR/removed"
  if [[ "${MOCK_STATE_STUCK:-0}" != 1 ]]; then rm -f "$TEST_DIR/keys/${key##*/}"; fi
elif [[ -f "$TEST_DIR/keys/${key##*/}" ]]; then
  printf '<dictionary> {\n InterfaceName : utun6\n}\n'
else
  echo '  No such key'
fi
MOCK
cat > "$TEST_DIR/netstat" <<'MOCK'
#!/bin/bash
[[ "${MOCK_NETSTAT_ERROR:-0}" == 1 ]] && exit 1
awk -v family="$3" 'NR == FNR {gone[$1 FS $2]=1; next} {dest=$1; if ($3 ~ /H/ || (family == "inet" && dest ~ /\/32$/) || (family == "inet6" && dest ~ /\/128$/)) sub(/\/(32|128)$/, "", dest)} !(dest FS $2 in gone)' "$TEST_DIR/deleted" "$TEST_DIR/$3"
MOCK
cat > "$TEST_DIR/route" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TEST_DIR/routes"
if [[ "$*" == '-n get default' ]]; then
  read -r gateway interface < "$TEST_DIR/default"
  printf 'gateway: %s\ninterface: %s\n' "$gateway" "$interface"
elif [[ "$2" == delete ]]; then
  [[ "${MOCK_DELETE_FAIL:-0}" == 1 ]] && exit 1
  previous=''; last=''
  for arg; do previous="$last"; last="$arg"; done
  echo "$previous $last" >> "$TEST_DIR/deleted"
  if [[ "$previous" == default && "$last" == 10.81.88.198 ]]; then
    if [[ "${MOCK_PHYSICAL_DISAPPEARS:-0}" == 1 ]]; then
      : > "$TEST_DIR/default"
    else
      echo '192.168.160.1 en0' > "$TEST_DIR/default"
    fi
  fi
elif [[ "$2" == add ]]; then
  [[ "${MOCK_ADD_FAIL:-0}" == 1 ]] && exit 1
  echo '192.168.160.1 en0' > "$TEST_DIR/default"
fi
exit 0
MOCK
cat > "$TEST_DIR/networksetup" <<'MOCK'
#!/bin/bash
[[ "${MOCK_NETWORKSETUP_ERROR:-0}" == 1 ]] && exit 1
case "$1" in
 -listallnetworkservices) printf 'An asterisk denotes disabled services.\nWi-Fi\nCorporate LAN\n' ;;
 -getautoproxyurl)
   if [[ "$2" == Wi-Fi ]]; then
     printf 'URL: http://127.0.0.1:9999/123_gpproxy.pac\nEnabled: %s\n' "$(cat "$TEST_DIR/pac")"
   else
     printf 'URL: https://proxy.example.org/corporate.pac\nEnabled: Yes\n'
   fi ;;
 -setautoproxystate)
   echo "$*" >> "$TEST_DIR/proxy-changes"
   [[ "${MOCK_PAC_FAIL:-0}" == 1 ]] && exit 1
   echo No > "$TEST_DIR/pac" ;;
esac
MOCK
cat > "$TEST_DIR/curl" <<'MOCK'
#!/bin/bash
echo "$*" >> "$TEST_DIR/http"
[[ "${MOCK_HTTP_FAIL:-0}" != 1 ]]
MOCK
cat > "$TEST_DIR/dscacheutil" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$TEST_DIR/"{scutil,netstat,route,networksetup,curl,dscacheutil}
SCUTIL="$TEST_DIR/scutil" NETSTAT="$TEST_DIR/netstat" ROUTE="$TEST_DIR/route"
NETWORKSETUP="$TEST_DIR/networksetup" CURL="$TEST_DIR/curl" DSCACHEUTIL="$TEST_DIR/dscacheutil"

reset_fixture() {
  unset MOCK_STATE_STUCK MOCK_SCUTIL_ERROR MOCK_NETSTAT_ERROR MOCK_DELETE_FAIL MOCK_ADD_FAIL
  unset MOCK_PROXY_STUCK MOCK_NETWORKSETUP_ERROR MOCK_PAC_FAIL MOCK_HTTP_FAIL
  unset MOCK_PGREP_ERROR MOCK_PROCESS_STUCK MOCK_DISABLE_FAIL MOCK_REAPPEAR
  unset MOCK_WATCHER_MISSING
  unset MOCK_PHYSICAL_DISAPPEARS
  for entity in DNS IPv4 IPv6 Proxies; do touch "$TEST_DIR/keys/$entity"; done
  # A nonempty sentinel keeps awk NR==FNR correct even before any deletions.
  echo sentinel > "$TEST_DIR/deleted"
  : > "$TEST_DIR/routes"; : > "$TEST_DIR/removed"; : > "$TEST_DIR/events"
  : > "$TEST_DIR/proxy-changes"; : > "$TEST_DIR/http"
  echo '10.81.88.198 utun6' > "$TEST_DIR/default"
  echo Yes > "$TEST_DIR/pac"
  cat > "$TEST_DIR/inet" <<'ROUTES'
Destination Gateway Flags Netif
default 10.81.88.198 UGScg utun6
default 192.168.160.1 UGScIg en0
10.250.0.1 10.81.88.198 UGHS utun6
13.107.64/18 10.81.88.198 UGSc utun6
52.112/14 10.81.88.198 UGScI utun6
224.0.0/4 link#25 UmCS utun6
default 10.99.0.1 UGScg utun9
ROUTES
  cat > "$TEST_DIR/inet6" <<'ROUTES'
Destination Gateway Flags Netif
default fe80::1%utun6 UGcIg utun6
2001:db8::/32 fe80::1%utun6 UGSc utun6
2001:db8::1/128 fe80::1%utun6 UGHS utun6
default fe80::1%utun9 UGcIg utun9
ROUTES
}
expect_failure() {
  if "$@"; then echo "Expected failure: $*" >&2; exit 1; fi
}
reset_fixture
[[ $(globalprotect_interface) == utun6 ]]
[[ $(physical_default_route) == '192.168.160.1 en0' ]]
clear_globalprotect_network_state
[[ $(wc -l < "$TEST_DIR/removed" | tr -d ' ') == 4 ]]
for entity in DNS IPv4 IPv6 Proxies; do
  grep -Eqx "State:/Network/Service/gpd.pan/$entity" "$TEST_DIR/removed"
done
clear_globalprotect_network_state
[[ $(wc -l < "$TEST_DIR/removed" | tr -d ' ') == 4 ]]
remove_interface_routes utun6
[[ $(wc -l < "$TEST_DIR/routes" | tr -d ' ') == 7 ]]
grep -Eqx -- '-n delete -inet -host 10.250.0.1 10.81.88.198' "$TEST_DIR/routes"
grep -Eqx -- '-n delete -inet -net -ifscope utun6 52.112/14 10.81.88.198' "$TEST_DIR/routes"
grep -Eqx -- '-n delete -inet6 -host 2001:db8::1 fe80::1%utun6' "$TEST_DIR/routes"
! grep -Eq 'utun9|link#|192.168.160.1' "$TEST_DIR/routes"
remove_interface_routes ''
repair_stale_routes 10.81.88.198 utun6 192.168.160.1
[[ $(wc -l < "$TEST_DIR/routes" | tr -d ' ') == 7 ]]
clear_globalprotect_pac
[[ $(cat "$TEST_DIR/pac") == No ]]
! grep -Eq 'Corporate LAN' "$TEST_DIR/proxy-changes"
ensure_physical_default_route 192.168.160.1 en0
expect_failure ensure_physical_default_route '' ''
echo 'missing missing' > "$TEST_DIR/default"
# Restoration must add an unscoped default through the captured physical NIC.
echo '' > "$TEST_DIR/default"
ensure_physical_default_route 192.168.160.1 en0
grep -Eqx -- '-n add default 192.168.160.1 -ifp en0' "$TEST_DIR/routes"

reset_fixture
export MOCK_STATE_STUCK=1
expect_failure clear_globalprotect_network_state
unset MOCK_STATE_STUCK
export MOCK_SCUTIL_ERROR=1
expect_failure clear_globalprotect_network_state
unset MOCK_SCUTIL_ERROR
export MOCK_DELETE_FAIL=1
expect_failure remove_interface_routes utun6
unset MOCK_DELETE_FAIL
export MOCK_NETSTAT_ERROR=1
expect_failure remove_interface_routes utun6
unset MOCK_NETSTAT_ERROR
export MOCK_PAC_FAIL=1
expect_failure clear_globalprotect_pac
unset MOCK_PAC_FAIL
export MOCK_NETWORKSETUP_ERROR=1
expect_failure clear_globalprotect_pac
unset MOCK_NETWORKSETUP_ERROR

# Physical gateway changes must preserve route type/scope and leave VPNs alone.
reset_fixture
cat >> "$TEST_DIR/inet" <<'ROUTES'
13.107.64/18 192.168.160.1 UGSc en0
52.112/14 192.168.160.1 UGScI en0
94.56.76.171 192.168.160.1 UGHS en0
ROUTES
repair_stale_routes 192.168.160.1 en0 192.168.170.1 en0
grep -Eqx -- '-n change -inet -net -ifscope en0 52.112/14 192.168.170.1 -ifp en0' "$TEST_DIR/routes"
grep -Eqx -- '-n change -inet -host 94.56.76.171 192.168.170.1 -ifp en0' "$TEST_DIR/routes"
! grep -Eq 'utun|default|10.81.88.198' "$TEST_DIR/routes"
: > "$TEST_DIR/routes"
repair_stale_routes 192.168.160.1 en0 192.168.170.1 en1
grep -Eqx -- '-n delete -inet -net -ifscope en0 52.112/14 192.168.160.1' "$TEST_DIR/routes"
echo 'PASS physical gateway and interface changes'

# Full shutdown flow: replace every command that can affect the real host.
need_root() { :; }
stop_processes() {
  echo stop >> "$TEST_DIR/events"
  if [[ "${MOCK_PHYSICAL_DISAPPEARS:-0}" == 1 ]]; then
    awk '$1 != "default" || $4 != "en0"' "$TEST_DIR/inet" > "$TEST_DIR/inet.tmp"
    mv "$TEST_DIR/inet.tmp" "$TEST_DIR/inet"
  fi
}
killall() { :; }
pgrep() {
  [[ "${MOCK_PGREP_ERROR:-0}" != 1 ]] || return 2
  [[ "${MOCK_PROCESS_STUCK:-0}" == 1 ]] && return 0
  return 1
}
launchctl() {
  echo "$*" >> "$TEST_DIR/events"
  case "$1" in
    print) [[ "$2" == "system/$ROUTE_WATCH_LABEL" && "${MOCK_WATCHER_MISSING:-0}" != 1 ]] ;;
    disable) [[ "${MOCK_DISABLE_FAIL:-0}" != 1 ]] ;;
    *) return 0 ;;
  esac
}
sleep() {
  # Model the extension republishing state after a successful removal.
  if [[ "${MOCK_REAPPEAR:-0}" == 1 ]]; then touch "$TEST_DIR/keys/DNS"; fi
}
install_route_watch() { echo refresh-watcher >> "$TEST_DIR/events"; }
GUI_UID=502
ROUTE_WATCH_PLIST="$TEST_DIR/watcher.plist"
for scenario in success repeat gateway_restore http state proxy process inspect disable reappear reappear_without_watcher routes; do
  reset_fixture
  case "$scenario" in
    http) export MOCK_HTTP_FAIL=1 ;;
    state) export MOCK_STATE_STUCK=1 ;;
    proxy) export MOCK_PROXY_STUCK=1 ;;
    process) export MOCK_PROCESS_STUCK=1 ;;
    inspect) export MOCK_PGREP_ERROR=1 ;;
    disable) export MOCK_DISABLE_FAIL=1 ;;
    reappear) export MOCK_REAPPEAR=1 ;;
    reappear_without_watcher) export MOCK_REAPPEAR=1 MOCK_WATCHER_MISSING=1 ;;
    routes) export MOCK_DELETE_FAIL=1 ;;
    gateway_restore) export MOCK_PHYSICAL_DISAPPEARS=1 ;;
  esac
  if gp_off > "$TEST_DIR/output" 2>&1; then
    [[ "$scenario" == success || "$scenario" == repeat || "$scenario" == gateway_restore ]] || { cat "$TEST_DIR/output"; exit 1; }
    grep -Eq 'DNS and HTTPS verified' "$TEST_DIR/output"
    grep -Eq '^Done\.' "$TEST_DIR/output"
    [[ $(head -n 2 "$TEST_DIR/events" | tail -n 1) == "bootout system/$ROUTE_WATCH_LABEL" ]]
    grep -Eqx refresh-watcher "$TEST_DIR/events"
    ! grep -Eq 'utun9|link#' "$TEST_DIR/routes"
    if [[ "$scenario" == repeat ]]; then gp_off > "$TEST_DIR/output" 2>&1; fi
    if [[ "$scenario" == gateway_restore ]]; then
      grep -Eqx -- '-n add default 192.168.160.1 -ifp en0' "$TEST_DIR/routes"
    fi
  else
    [[ "$scenario" != success && "$scenario" != repeat && "$scenario" != gateway_restore ]] || { cat "$TEST_DIR/output"; exit 1; }
    ! grep -Eq '^Done\.' "$TEST_DIR/output"
    ! grep -Eqx refresh-watcher "$TEST_DIR/events"
    if [[ "$scenario" == routes ]]; then
      # Failed route deletion must retain the ownership key for a safe retry.
      [[ -f "$TEST_DIR/keys/IPv4" ]]
    fi
  fi
  echo "PASS full shutdown: $scenario"
done
echo 'Network cleanup regression checks passed.'
