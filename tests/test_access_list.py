import json
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "ngnix.sh"


class AccessListUpdateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        shutil.copy(SCRIPT, self.directory / "ngnix.sh")
        self.current = {
            "name": "block-up",
            "satisfy_any": True,
            "pass_auth": True,
            "items": [{"username": "test-user", "password": "masked"}],
            "clients": [
                {"directive": "allow", "address": "all"},
                {"directive": "deny", "address": "203.0.113.7"},
                {"directive": "allow", "address": "0.0.0.0/0"},
            ],
        }
        self.updates = []
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self, data):
                data = json.dumps(data).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                self.respond({"token": "test-token"})

            def do_GET(self):
                self.respond(test.current)

            def do_PUT(self):
                test.updates.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.respond(test.updates[-1])

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.shutdown)
        (self.directory / ".env").write_text(
            f"NPM_URL=http://127.0.0.1:{self.server.server_port}/api\n"
            "NPM_EMAIL=test@example.invalid\nNPM_PASSWORD=test\nACCESS_LIST_ID=2\n"
        )

    def run_update(self, ips, *args):
        (self.directory / "client_ips.txt").write_text(ips)
        subprocess.run(
            ["bash", str(self.directory / "ngnix.sh"), *args],
            check=True, capture_output=True, text=True, timeout=10,
        )

    def test_denies_precede_allows_and_rules_are_preserved(self):
        self.run_update("203.0.113.7\n198.51.100.1\n198.51.100.1\n")
        self.assertEqual(len(self.updates), 1)
        update = self.updates[0]
        self.assertEqual(update["name"], self.current["name"])
        self.assertEqual(update["satisfy_any"], self.current["satisfy_any"])
        self.assertEqual(update["pass_auth"], self.current["pass_auth"])
        self.assertEqual(update["items"], [{"username": "test-user", "password": ""}])
        self.assertEqual(update["clients"], [
            {"directive": "deny", "address": "198.51.100.1"},
            {"directive": "deny", "address": "203.0.113.7"},
            {"directive": "allow", "address": "0.0.0.0/0"},
            {"directive": "allow", "address": "all"},
        ])

    def test_existing_rules_are_reordered_without_new_ips(self):
        self.run_update("203.0.113.7\n")
        self.assertEqual([rule["directive"] for rule in self.updates[0]["clients"]],
                         ["deny", "allow", "allow"])

    def test_missing_allow_all_is_added_after_denies(self):
        self.current["clients"] = [{"directive": "deny", "address": "203.0.113.7"}]
        self.run_update("")
        self.assertEqual(self.updates[0]["clients"], [
            {"directive": "deny", "address": "203.0.113.7"},
            {"directive": "allow", "address": "all"},
        ])

    def test_dry_run_does_not_update_access_list(self):
        self.run_update("198.51.100.1\n", "--dry-run")
        self.assertEqual(self.updates, [])


if __name__ == "__main__":
    unittest.main()
