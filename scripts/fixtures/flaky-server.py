import http.server
import sys

# Serve a directory like api-server.py, but answer 503 to the first N
# requests whose path ends with <suffix>. The install test uses it to prove
# a transient release-download failure is retried instead of ending the
# install. /__ready answers 200 without consuming a failure, so the test can
# wait for the server without spending the fixture.
port = int(sys.argv[1])
failures_left = int(sys.argv[2])
suffix = sys.argv[3]


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        global failures_left
        path = self.path.split("?")[0]
        if path == "/__ready":
            self.send_response(200)
            self.end_headers()
            return
        if path.endswith(suffix) and failures_left > 0:
            failures_left -= 1
            self.send_error(503)
            return
        super().do_GET()

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", port), Handler)
server.serve_forever()
