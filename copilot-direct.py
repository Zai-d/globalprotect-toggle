#!/usr/bin/env python3
"""Run Copilot through a temporary, interface-bound HTTPS CONNECT proxy."""

import argparse
import json
import os
import select
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
from urllib.parse import urlsplit

# Darwin netinet/in.h. Python does not expose this constant on every build.
IP_BOUND_IF = 25
DIRECT_DOMAINS = (
    "githubcopilot.com",
    "github.com",
    "githubusercontent.com",
    "githubassets.com",
    "exp-tas.com",
)


def use_direct_connection(host):
    host = host.lower().rstrip(".")
    return any(host == domain or host.endswith("." + domain)
               for domain in DIRECT_DOMAINS)


def connect_upstream(host, port, interface):
    if not use_direct_connection(host):
        # Other HTTPS destinations retain their normal routing, including the
        # Dubai VPN and internal tools. No system route or proxy changes.
        return socket.create_connection((host, port), timeout=10)
    index = socket.if_nametoindex(interface)
    last_error = None
    # en0 on the affected network has IPv4 only. Never silently fall back to
    # the VPN if this interface fails or disappears.
    for family, socktype, protocol, _, address in socket.getaddrinfo(
            host, port, socket.AF_INET, socket.SOCK_STREAM):
        upstream = socket.socket(family, socktype, protocol)
        try:
            upstream.settimeout(10)
            upstream.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, index)
            upstream.connect(address)
            return upstream
        except OSError as error:
            last_error = error
            upstream.close()
    raise last_error or OSError("No IPv4 address for " + host)


def relay(client, upstream, initial=b"", idle_timeout=300):
    """Forward opaque TLS bytes, including half-closed streams."""
    client.settimeout(30)
    upstream.settimeout(30)
    if initial:
        upstream.sendall(initial)
    peers = {client: upstream, upstream: client}
    readers = list(peers)
    while readers:
        ready, _, _ = select.select(readers, [], [], idle_timeout)
        if not ready:
            return
        for source in ready:
            data = source.recv(65536)
            if data:
                peers[source].sendall(data)
            else:
                readers.remove(source)
                try:
                    peers[source].shutdown(socket.SHUT_WR)
                except OSError:
                    pass


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(10)
        upstream = None
        established = False
        try:
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = client.recv(4096)
                if not chunk:
                    return
                request += chunk
                if len(request) > 65536:
                    self.reject(431, "Headers too large")
                    return
            headers, initial = request.split(b"\r\n\r\n", 1)
            method, authority, version = headers.split(b"\r\n", 1)[0].decode("ascii").split()
            if method != "CONNECT":
                self.reject(405, "HTTPS CONNECT required")
                return
            if version not in ("HTTP/1.0", "HTTP/1.1"):
                raise ValueError("Invalid HTTP version")
            target = urlsplit("//" + authority)
            if (not target.hostname or target.username is not None or
                    target.password is not None or target.path or
                    target.query or target.fragment or target.port is None):
                raise ValueError("Invalid CONNECT authority")
            upstream = self.server.connector(target.hostname, target.port, self.server.interface)
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            established = True
            relay(client, upstream, initial)
        except (OSError, ValueError, UnicodeError) as error:
            if not established:
                self.reject(502, "Connection failed")
            # No headers, tokens, prompts, or decrypted TLS are logged.
            # A TLS client can close while a final upstream chunk is in flight.
            if not (established and isinstance(error, (BrokenPipeError, ConnectionResetError))):
                print("Copilot proxy connection error:", error, file=sys.stderr)
        finally:
            if upstream is not None:
                upstream.close()

    def reject(self, code, message):
        try:
            self.request.sendall(
                f"HTTP/1.1 {code} {message}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode("ascii"))
        except OSError:
            pass


class ProxyServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, interface, connector=connect_upstream):
        self.interface = interface
        self.connector = connector
        # Loopback only, with a fresh OS-assigned port for each invocation.
        super().__init__(("127.0.0.1", 0), ProxyHandler)


def proxy_environment(url):
    environment = os.environ.copy()
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "all_proxy"):
        environment[key] = url
    for key in ("NO_PROXY", "no_proxy"):
        environment[key] = "localhost,127.0.0.1,::1"
    return environment


def check_connection(url):
    # macOS curl uses the system trust configuration, unlike some standalone
    # Python builds. Keep certificate verification enabled in both clients.
    def fetch(target):
        result = subprocess.run(
            ["/usr/bin/curl", "--proxy", url, "--noproxy", "", "--fail",
             "--connect-timeout", "5", "--max-time", "15", "--silent",
             "--show-error", target], capture_output=True, text=True)
        if result.returncode:
            raise OSError(result.stderr.strip() or "Connection check failed")
        return result.stdout

    for host in ("api.githubcopilot.com", "api.business.githubcopilot.com"):
        if fetch("https://" + host + "/_ping").strip() != "OK":
            raise OSError("Unexpected Copilot health response")
        print(host + ": 200 OK via direct interface")
    location = json.loads(fetch("https://ipinfo.io/json"))
    print("Other traffic location: " + location.get("city", "unknown") +
          ", " + location.get("country", "unknown"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", default="en0",
                        help="physical IPv4 interface (default: en0)")
    parser.add_argument("--check", action="store_true",
                        help="test Copilot endpoints without starting the CLI")
    parser.add_argument("copilot_args", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This launcher requires macOS")
    try:
        socket.if_nametoindex(options.interface)
    except OSError:
        parser.error("Network interface not found: " + options.interface)
    args = options.copilot_args
    if args[:1] == ["--"]:
        args = args[1:]
    copilot = shutil.which("copilot")
    if not options.check and not copilot:
        parser.error("copilot is not installed or is not on PATH")
    with ProxyServer(options.interface) as proxy:
        thread = threading.Thread(target=proxy.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        thread.start()
        url = "http://127.0.0.1:" + str(proxy.server_address[1])
        print("Copilot GitHub traffic -> " + options.interface +
              "; other destinations -> normal network routes", file=sys.stderr)
        try:
            if options.check:
                check_connection(url)
                return 0
            # Scope proxy settings to this CLI invocation and its children.
            # Do not persist settings, alter routes, or change system proxies.
            return subprocess.call([copilot] + args, env=proxy_environment(url))
        except KeyboardInterrupt:
            return 130
        except (OSError, ValueError) as error:
            print(str(error), file=sys.stderr)
            return 1
        finally:
            proxy.shutdown()
            thread.join(timeout=2)


if __name__ == "__main__":
    sys.exit(main())
