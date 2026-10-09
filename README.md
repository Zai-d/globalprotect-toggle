# GlobalProtect Toggle

Install in the expected location:

```bash
mkdir -p ~/scripts
cp gp-toggle.sh ~/scripts/gp-toggle.sh
chmod +x ~/scripts/gp-toggle.sh
```

## Usage
* `sudo ~/scripts/gp-toggle.sh off`     # fully stop, stays off across reboots
* `sudo ~/scripts/gp-toggle.sh on`      # restore it
* `~/scripts/gp-toggle.sh status`       # check state, no sudo
* `sudo ~/scripts/gp-toggle.sh install-route-watch` # repair stale routes after network changes
* `sudo ~/scripts/gp-toggle.sh uninstall-route-watch` # remove automatic route repair

You can also run the script directly from this repo:

```bash
./gp-toggle.sh status
sudo ./gp-toggle.sh off
```

## Automatic route repair

GlobalProtect split-tunnel routes can retain the previous Wi-Fi or hotspot
gateway after the default network changes. This can break Teams messaging,
calls, and audio while other internet traffic continues to work.

Turning GlobalProtect off clears its transient `gpd.pan` DNS, IPv4, IPv6,
and proxy service state, then removes gateway routes from the tunnel named
by that service. This lets macOS select the underlying network's DNS and
default route again. Configured DNS servers on other services are preserved.
It also disables any enabled GlobalProtect localhost PAC on network services.
Cleanup failures are reported with a nonzero exit status.

`off` requires three consecutive clean network-state checks, then verifies
DNS and HTTPS with a direct request to `https://www.apple.com/`, falling back
to `https://example.com/`. It prints `Done` only after those checks pass.
If both sites are blocked or unavailable, verification fails even if some
other sites work. A captive portal or a managed network-extension policy
can also prevent access; this script reports that failure rather than
claiming successful recovery. It does not uninstall the system extension.

Use `./gp-toggle.sh status` after a failure to inspect the effective default
route, DNS, proxy, and remaining GlobalProtect service state. Status also
warns if the installed watcher differs from the script you are running.

Install the route watcher once:

```bash
sudo ./gp-toggle.sh install-route-watch
```

The watcher records a physical (`en*`) default gateway, ignoring VPN gateways.
When it changes, only gateway routes
that still point to the previous gateway and interface are changed to the new
gateway. A scoped route belonging to a previous physical interface is removed
so traffic can follow the new interface's routes. VPN, connected-network, and
default routes are excluded from migration.

Run `install-route-watch` again after updating the script to refresh the
installed copy. `off` suspends a running watcher during cleanup and refreshes
it before restarting it, so an older watcher cannot migrate VPN routes when
the VPN stops. The refreshed watcher is checked again before shutdown is
reported as successful. If cleanup or the first internet check fails, the
watcher remains stopped until you retry `off` or reinstall it.

Run the isolated network cleanup regression checks with:

```bash
bash tests/network-cleanup.sh
```

These fixtures exercise IPv4/IPv6 route cleanup, DNS and PAC cleanup, repeated
shutdown, gateway/interface changes, process and command failures, settings
reappearing after removal, and unavailable HTTPS. They do not substitute for
a live `sudo ./gp-toggle.sh off` test on the affected network. macOS CI runs
the same checks on every push and pull request.
