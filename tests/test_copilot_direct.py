import importlib.util
import os
from pathlib import Path
import socket
import socketserver
import threading
import unittest
from unittest.mock import Mock, call, patch


spec = importlib.util.spec_from_file_location(
    "copilot_direct", Path(__file__).resolve().parents[1] / "copilot-direct.py")
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class RoutingTests(unittest.TestCase):
    def test_only_github_destinations_use_direct_interface(self):
        for host in ("github.com", "api.github.com", "api.business.githubcopilot.com",
                     "telemetry.individual.githubcopilot.com", "RAW.GITHUBUSERCONTENT.COM."):
            self.assertTrue(proxy.use_direct_connection(host), host)
        for host in ("ipinfo.io", "internal.example.org", "127.0.0.1",
                     "github.com.attacker.example", "notgithubcopilot.com"):
            self.assertFalse(proxy.use_direct_connection(host), host)

    def test_proxy_environment_is_scoped_and_overrides_conflicts(self):
        with patch.dict(os.environ, {"HTTPS_PROXY": "http://old-proxy", "NO_PROXY": "*"}):
            before = os.environ.copy()
            env = proxy.proxy_environment("http://127.0.0.1:12345")
            self.assertEqual(os.environ, before)
            for key in ("HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"):
                self.assertEqual(env[key], "http://127.0.0.1:12345")
            self.assertNotEqual(env["NO_PROXY"], "*")

    @patch.object(proxy.socket, "create_connection")
    @patch.object(proxy.socket, "socket")
    @patch.object(proxy.socket, "getaddrinfo")
    @patch.object(proxy.socket, "if_nametoindex", return_value=14)
    def test_direct_socket_is_bound_before_connect(self, index, lookup, factory, normal):
        lookup.return_value = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.1", 443))]
        upstream = factory.return_value
        proxy.connect_upstream("api.business.githubcopilot.com", 443, "en0")
        upstream.setsockopt.assert_called_once_with(socket.IPPROTO_IP, proxy.IP_BOUND_IF, 14)
        upstream.connect.assert_called_once_with(("192.0.2.1", 443))
        self.assertLess(upstream.mock_calls.index(call.setsockopt(socket.IPPROTO_IP, proxy.IP_BOUND_IF, 14)),
                        upstream.mock_calls.index(call.connect(("192.0.2.1", 443))))
        normal.assert_not_called()

    @patch.object(proxy.socket, "create_connection")
    @patch.object(proxy.socket, "socket")
    @patch.object(proxy.socket, "getaddrinfo")
    @patch.object(proxy.socket, "if_nametoindex", return_value=14)
    def test_binding_failure_does_not_fall_back_to_vpn(self, index, lookup, factory, normal):
        lookup.return_value = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.1", 443))]
        factory.return_value.setsockopt.side_effect = OSError("Interface unavailable")
        with self.assertRaises(OSError):
            proxy.connect_upstream("api.githubcopilot.com", 443, "en0")
        factory.return_value.close.assert_called_once()
        factory.return_value.connect.assert_not_called()
        normal.assert_not_called()

    @patch.object(proxy.socket, "create_connection")
    @patch.object(proxy.socket, "if_nametoindex")
    def test_other_destinations_keep_normal_routing(self, index, connect):
        proxy.connect_upstream("ipinfo.io", 443, "en0")
        connect.assert_called_once_with(("ipinfo.io", 443), timeout=10)
        index.assert_not_called()


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)


class TunnelTests(unittest.TestCase):
    def setUp(self):
        self.echo = socketserver.ThreadingTCPServer(("127.0.0.1", 0), EchoHandler)
        self.echo.daemon_threads = True
        self.connector = Mock(side_effect=lambda *args: socket.create_connection(self.echo.server_address))
        self.proxy = proxy.ProxyServer("en0", connector=self.connector)
        self.threads = []
        for server in (self.echo, self.proxy):
            thread = threading.Thread(target=server.serve_forever,
                                      kwargs={"poll_interval": 0.01}, daemon=True)
            thread.start()
            self.threads.append(thread)

    def tearDown(self):
        for server in (self.proxy, self.echo):
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(timeout=2)

    def receive_headers(self, client):
        data = b""
        while b"\r\n\r\n" not in data:
            data += client.recv(4096)
        return data.split(b"\r\n\r\n", 1)

    def test_tls_bytes_and_half_close_are_preserved(self):
        payload = b"\x16\x03\x03\x00\xffopaque TLS bytes\x00" * 6000
        with socket.create_connection(self.proxy.server_address, timeout=3) as client:
            client.sendall(b"CONNECT api.business.githubcopilot.com:443 HTTP/1.1\r\n\r\n" + payload[:32])
            headers, received = self.receive_headers(client)
            self.assertTrue(headers.startswith(b"HTTP/1.1 200"))
            client.sendall(payload[32:])
            client.shutdown(socket.SHUT_WR)
            while True:
                data = client.recv(65536)
                if not data:
                    break
                received += data
            self.assertEqual(received, payload)
        self.connector.assert_called_once_with("api.business.githubcopilot.com", 443, "en0")

    def test_bad_requests_never_connect_upstream(self):
        for request, code in ((b"GET http://example.com HTTP/1.1\r\n\r\n", b"405"),
                              (b"CONNECT user:password@github.com:443 HTTP/1.1\r\n\r\n", b"502")):
            with socket.create_connection(self.proxy.server_address, timeout=3) as client:
                client.sendall(request)
                headers, _ = self.receive_headers(client)
                self.assertIn(code, headers.split(b"\r\n")[0])
        self.connector.assert_not_called()

    def test_connection_error_is_reported_before_tls(self):
        self.connector.side_effect = OSError("Unavailable interface")
        with socket.create_connection(self.proxy.server_address, timeout=3) as client:
            client.sendall(b"CONNECT api.githubcopilot.com:443 HTTP/1.1\r\n\r\n")
            headers, _ = self.receive_headers(client)
            self.assertIn(b"502", headers.split(b"\r\n")[0])


if __name__ == "__main__":
    unittest.main()
