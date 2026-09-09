#!/usr/bin/env python3
"""Opt-in native regression; requires the optional Python `websockets` package.

Run with --codex /absolute/path/to/codex or CODEX_NATIVE_TEST_BINARY.
Uses an isolated home and a local Responses fixture; no credentials or paid calls.
"""

import argparse
import asyncio
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading


async def verify(binary, websockets):
    repo = Path(__file__).resolve().parents[2]
    request_seen, release = threading.Event(), threading.Event()
    requests = []

    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            requests.append(self.path)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()

            def send(kind, **payload):
                self.wfile.write(("data: " + json.dumps({"type": kind, **payload}) + "\n\n").encode())
                self.wfile.flush()

            response = {"id": "resp_fixture", "object": "response", "status": "in_progress", "output": []}
            send("response.created", response=response)
            request_seen.set()
            if not release.wait(20):
                return
            item = {"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": "Offline fixture completed.", "annotations": []}]}
            send("response.output_item.added", output_index=0, item={**item, "status": "in_progress", "content": []})
            send("response.output_text.delta", item_id="msg_fixture", output_index=0,
                 content_index=0, delta="Offline fixture completed.")
            send("response.output_item.done", output_index=0, item=item)
            send("response.completed", response={**response, "status": "completed", "output": [item],
                 "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}})

    class Client:
        def __init__(self, connection):
            self.connection, self.next_id, self.notifications = connection, 0, []

        async def receive(self):
            return json.loads(await asyncio.wait_for(self.connection.recv(), 8))

        async def call(self, method, params):
            self.next_id += 1
            await self.connection.send(json.dumps({"id": self.next_id, "method": method, "params": params}))
            while True:
                message = await self.receive()
                if message.get("id") == self.next_id:
                    assert "error" not in message, message
                    return message["result"]
                self.notifications.append(message)

    with tempfile.TemporaryDirectory(prefix="cx-native-") as temporary:
        root = Path(temporary)
        home, codex_home = root / "home", root / "codex"
        home.mkdir()
        codex_home.mkdir()
        (root / "dotfiles").symlink_to(repo, target_is_directory=True)
        env = {"HOME": str(home), "CODEX_HOME": str(codex_home), "PATH": os.defpath,
               "LANG": "C.UTF-8", "TZ": "UTC", "HTTP_PROXY": "http://127.0.0.1:9",
               "HTTPS_PROXY": "http://127.0.0.1:9", "ALL_PROXY": "http://127.0.0.1:9",
               "NO_PROXY": "127.0.0.1,localhost"}
        fixture = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        fixture_thread = threading.Thread(target=fixture.serve_forever, daemon=True)
        fixture_thread.start()
        (codex_home / "config.toml").write_text(f'''model = "fixture-model"
model_provider = "fixture"
check_for_update_on_startup = false
[model_providers.fixture]
name = "Offline fixture"
base_url = "http://127.0.0.1:{fixture.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
[analytics]
enabled = false
[feedback]
enabled = false
''')
        clients, server = [], None
        log_path = root / "app-server.log"
        try:
            with log_path.open("w") as log:
                server = subprocess.Popen([str(binary), "app-server", "--listen", "unix://"],
                                          cwd=root, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            socket_path = codex_home / "app-server-control/app-server-control.sock"
            for _ in range(500):
                assert server.poll() is None, log_path.read_text()
                if socket_path.exists():
                    break
                await asyncio.sleep(0.02)
            assert socket_path.exists(), "native app-server did not create its Unix socket"
            for index in range(2):
                connection = await websockets.unix_connect(str(socket_path), uri="ws://localhost/",
                                                           compression=None, open_timeout=8, close_timeout=2)
                client = Client(connection)
                clients.append(client)
                initialized = await client.call("initialize", {"clientInfo": {"name": f"native-probe-{index}", "version": "1"}})
                assert initialized["codexHome"] == str(codex_home), initialized
                await connection.send('{"method":"initialized"}')
            first, second = clients
            thread_id = (await first.call("thread/start", {"cwd": str(root)}))["thread"]["id"]
            other_id = (await second.call("thread/start", {"cwd": str(root)}))["thread"]["id"]
            turn_id = (await first.call("turn/start", {"threadId": thread_id,
                      "input": [{"type": "text", "text": "Disposable local fixture request."}]}))["turn"]["id"]
            assert await asyncio.to_thread(request_seen.wait, 8), "native server did not reach the local fixture"
            pid_file = codex_home / "app-server-daemon/app-server.pid"
            pid_file.parent.mkdir(exist_ok=True)
            started = subprocess.run(["ps", "-p", str(server.pid), "-o", "lstart="],
                                     env=env, check=True, capture_output=True, text=True).stdout.strip()
            skewed = datetime.datetime.strptime(started, "%a %b %d %H:%M:%S %Y") + datetime.timedelta(seconds=3)
            record = json.dumps({"pid": server.pid, "processStartTime": skewed.strftime("%a %b %e %H:%M:%S %Y")})
            pid_file.write_text(record)
            shell = '''source "$1/.bash_aliases"
_DEV_DIR_CACHE="$2"
_codex_remote_run() { printf 'unexpected daemon management\\n' >&2; return 99; }
_codex_ensure_remote_control
'''
            for index in range(6):
                if index == 5:
                    pid_file.unlink()
                result = subprocess.run(["bash", "--noprofile", "--norc", "-c", shell,
                                         "native-probe", str(repo), str(root)], cwd=root, env=env,
                                        capture_output=True, text=True, timeout=8)
                assert result.returncode == 0 and not result.stderr, result
                assert server.poll() is None, "launcher terminated the existing app-server"
                assert set((await second.call("thread/loaded/list", {}))["data"]) == {thread_id, other_id}
                assert (await first.call("thread/read", {"threadId": thread_id}))["thread"]["status"]["type"] == "active"
                assert not pid_file.exists() if index == 5 else pid_file.read_text() == record
            release.set()
            while True:
                notification = await first.receive()
                if notification.get("method") == "turn/completed":
                    turn = notification["params"]["turn"]
                    assert turn["id"] == turn_id and turn["status"] == "completed", turn
                    break
            assert requests == ["/v1/responses"], requests
            assert (await first.call("thread/read", {"threadId": thread_id}))["thread"]["status"]["type"] == "idle"
            assert set((await second.call("thread/loaded/list", {}))["data"]) == {thread_id, other_id}
            print("PASS: two native clients retained both threads through six launcher checks; "
                  "the same active turn completed with one local request and unchanged/missing PID metadata.")
        finally:
            release.set()
            try:
                await asyncio.gather(*(client.connection.close() for client in clients), return_exceptions=True)
            finally:
                if server is not None and server.poll() is None:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
                fixture.shutdown()
                fixture.server_close()
                fixture_thread.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=os.environ.get("CODEX_NATIVE_TEST_BINARY"))
    args = parser.parse_args()
    if not args.codex:
        parser.error("supply --codex or CODEX_NATIVE_TEST_BINARY to opt in")
    binary = Path(args.codex)
    if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--codex must be an absolute path to an executable native Codex binary")
    try:
        from websockets.legacy import client as websockets
    except ImportError:
        parser.error("this optional native test requires the Python websockets package")
    asyncio.run(verify(binary, websockets))


if __name__ == "__main__":
    main()
