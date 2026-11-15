import http.server
import sys

# An optional second argument makes every request require that bearer token,
# so a test can prove install.sh sends SNAILS_GITHUB_TOKEN to the release API.
expected_token = sys.argv[2] if len(sys.argv) > 2 else None


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if expected_token is not None and self.headers.get("Authorization") != f"Bearer {expected_token}":
            self.send_error(401)
            return
        path = self.path.split("?")[0]
        if path == "/api-latest-toolchain/releases":
            self.path = "/api-latest-toolchain/list.json"
        super().do_GET()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.serve_forever()
