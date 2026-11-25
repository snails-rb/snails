import http.server
import os
import socketserver
import sys

# An optional second argument makes every request require that bearer token,
# so a test can prove install.sh sends SNAILS_GITHUB_TOKEN to the release API.
expected_token = sys.argv[2] if len(sys.argv) > 2 else None
# A test can make the first N requests for one asset answer 503, to prove a
# retry. Both default to off, so the normal dist and token servers are
# unchanged.
failures_left = int(os.environ.get("FIXTURE_FAILURES", "0"))
fail_suffix = os.environ.get("FIXTURE_FAIL_SUFFIX", "")


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        global failures_left
        path = self.path.split("?")[0]
        # Readiness answers without the token and without spending a failure,
        # so a test can wait for the server before the first real request.
        if path == "/__ready":
            self.send_response(200)
            self.end_headers()
            return
        if expected_token is not None and self.headers.get("Authorization") != f"Bearer {expected_token}":
            self.send_error(401)
            return
        if fail_suffix and path.endswith(fail_suffix) and failures_left > 0:
            failures_left -= 1
            self.send_error(503)
            return
        if path == "/api-latest-toolchain/releases":
            self.path = "/api-latest-toolchain/list.json"
        super().do_GET()

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    # HTTPServer.server_bind resolves the bind address with socket.getfqdn().
    # GitHub's macOS runners answer that reverse lookup about 35 seconds late,
    # and the server does not listen until it returns, so every readiness poll
    # waits out the delay on a fresh process. This fixture never uses the host
    # name, so bind without the lookup.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


server = Server(("127.0.0.1", int(sys.argv[1])), Handler)
server.serve_forever()
