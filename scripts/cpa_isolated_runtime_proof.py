"""Opt-in sealed real-binary proof for CPA API-key-only isolation (§39.1).

Launches an installed CLIProxyAPI binary through compiled production Swift
(`CLIProxyRuntimeController.start()`) inside a disposable temporary root with:
  - legacy subscription auth JSON files in `auth/` and nested `auth/backup/`
  - a poisoned `.env` file in the binary's directory
  - poisoned store/home/proxy/management environment variables in parent env
  - one user-configured fake `openai-compatibility` mock upstream on loopback returning 429

Asserts:
  1. CPA starts cleanly (`healthz` 200) using isolated `runtime-auth/` & `runtime-wd/`.
  2. Management `/v0/management/auth-files` exposes ZERO subscription/file auth entries.
  3. Legacy `auth/` and `auth/backup/` files stay byte-for-byte untouched.
  4. A chat completion request to the configured fake API-key upstream hits the loopback
     429 mock server exactly once (zero retries); the harness and child run with loopback-only socket access.
"""
import errno
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_socket_policy() -> None:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        with socket.create_connection(listener.getsockname(), timeout=2):
            with listener.accept()[0]:
                pass
    # UDP connect checks the policy without sending packets, even if isolation fails.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            probe.connect(("192.0.2.1", 9))  # documentation address
        except OSError as exc:
            if exc.errno not in (errno.EPERM, errno.EACCES):
                raise
        else:
            raise RuntimeError("CPA fixture sandbox did not block non-loopback sockets")


def loopback_sandbox() -> list[str]:
    cmd = ["/usr/bin/sandbox-exec", "-p", """
        (version 1)
        (allow default)
        (deny network*)
        (allow network-bind (local ip "localhost:*"))
        (allow network-inbound (local ip "localhost:*"))
        (allow network-outbound (remote ip "localhost:*"))
    """]
    subprocess.run([*cmd, sys.executable, str(Path(__file__).resolve()), "--check-socket-policy"], check=True)
    print("PASS: [§41.5] Sandbox allowed loopback TCP and denied non-loopback socket connect", flush=True)
    return cmd


def main() -> None:
    if sys.argv[1:] == ["--check-socket-policy"]:
        check_socket_policy()
        return
    if sys.argv[1:] == ["--verify-sandbox"]:
        loopback_sandbox()
        return
    if len(sys.argv) != 3:
        raise SystemExit("Usage: cpa_isolated_runtime_proof.py <cpa-binary> <cpa-runtime-regression-bin>")
    binary = Path(sys.argv[1]).resolve()
    harness = Path(sys.argv[2]).resolve()
    if not binary.is_file():
        raise SystemExit(f"CPA binary not found: {binary}")

    sandbox_cmd = loopback_sandbox()
    mock_requests: list[tuple[str, str]] = []
    mock_lock = threading.Lock()
    mock_port = free_port()

    class MockUpstreamHandler(http.server.BaseHTTPRequestHandler):
        def _record(self) -> None:
            with mock_lock:
                mock_requests.append((self.command, self.path))

        def do_GET(self) -> None:
            self._record()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"data": [{"id": "mock-api-model", "object": "model"}]}).encode())

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length > 0:
                self.rfile.read(length)
            self._record()
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"message": "rate limited", "type": "rate_limit_error"}}).encode())

        def log_message(self, *args) -> None:
            pass

    class ReuseTCP(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    server = ReuseTCP(("127.0.0.1", mock_port), MockUpstreamHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    with tempfile.TemporaryDirectory(prefix="aiusage-cpa-isolated-") as td:
        temp_dir = Path(td)
        cpa_root = temp_dir / "cpa-root"
        v_dir = cpa_root / "versions" / "v8.0.74"
        v_dir.mkdir(parents=True, exist_ok=True)
        copied_bin = v_dir / "CLIProxyAPI"
        shutil.copy2(binary, copied_bin)
        copied_bin.chmod(0o755)
        (cpa_root / "current").symlink_to(v_dir)

        # Poison `.env` in binary directory to catch any cwd `.env` leak.
        poisoned_dir = temp_dir / "poison-auth"
        poisoned_dir.mkdir()
        (poisoned_dir / "poisoned-external.json").write_text(json.dumps({
            "type": "codex",
            "email": "poison@example.invalid",
            "access_token": "tok",
            "refresh_token": "ref",
            "disabled": False,
        }))
        (v_dir / ".env").write_text(
            f"AUTH_DIR={poisoned_dir}\nDEPLOY=cloud\nPGSTORE_DSN=postgres://invalid\n"
            f"GITSTORE_GIT_URL=https://invalid.example/repo.git\nHOME_JWT=header.payload.sig\n"
        )

        # Preserve legacy credentials on disk outside CPA's isolated runtime-auth loader.
        auth_dir = cpa_root / "auth"
        nested_dir = auth_dir / "backup"
        nested_dir.mkdir(parents=True, exist_ok=True)
        legacy_top = auth_dir / "legacy-codex.json"
        legacy_nested = nested_dir / "nested-plus.json"
        legacy_top.write_text(json.dumps({
            "type": "codex",
            "email": "legacy@example.com",
            "plan_type": "plus",
            "access_token": "legacy-tok",
            "refresh_token": "legacy-ref",
            "disabled": False,
        }))
        legacy_nested.write_text(json.dumps({
            "type": "codex",
            "email": "nested@example.com",
            "plan_type": "plus",
            "access_token": "nested-tok",
            "refresh_token": "nested-ref",
            "disabled": False,
        }))
        top_hash_before = sha256(legacy_top)
        nested_hash_before = sha256(legacy_nested)

        # Seed a mock API-key-only upstream in config.yaml (loopback HTTP 429 responder).
        (cpa_root / "config.yaml").write_text(f"""openai-compatibility:
  - name: "mock-api-upstream"
    base-url: "http://127.0.0.1:{mock_port}/v1"
    api-key-entries:
      - api-key: "sk-mock-local-only"
    models:
      - name: "mock-api-model"
        alias: "mock-api-model"
""")

        cpa_port = free_port()
        ready_file = temp_dir / "ready.json"
        stop_file = temp_dir / "stop.flag"
        poisoned_env = {
            **os.environ,
            "HOME": str(temp_dir / "poison-home"),
            "PGSTORE_DSN": "postgres://127.0.0.1:9/poison",
            "GITSTORE_GIT_URL": "https://127.0.0.1:9/poison.git",
            "OBJECTSTORE_ENDPOINT": "http://127.0.0.1:9",
            "HOME_JWT": "poison.jwt.token",
            "DEPLOY": "cloud",
            "WRITABLE_PATH": str(temp_dir / "poison-writable"),
            "MANAGEMENT_PASSWORD": "poison-mgmt-password",
            "HTTP_PROXY": "http://127.0.0.1:1",
            "HTTPS_PROXY": "http://127.0.0.1:1",
        }
        Path(poisoned_env["HOME"]).mkdir(parents=True, exist_ok=True)

        proc = subprocess.Popen(
            [*sandbox_cmd, str(harness), "--verify-isolated-binary", str(cpa_root), str(cpa_port), str(ready_file), str(stop_file)],
            env=poisoned_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 20.0
            while time.monotonic() < deadline:
                if ready_file.is_file():
                    break
                if proc.poll() is not None:
                    out, err = proc.communicate()
                    raise RuntimeError(f"Harness exited early ({proc.returncode}): {out}\n{err}")
                time.sleep(0.1)
            if not ready_file.is_file():
                raise TimeoutError("Timed out waiting for isolated real CPA binary readiness")

            info = json.loads(ready_file.read_text())
            mgmt_key = info["managementKey"]
            client_key = info["clientAPIKey"]
            class NoRedirect(urllib.request.HTTPRedirectHandler):
                def redirect_request(self, req, fp, code, msg, headers, newurl):
                    return None

            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

            req_files = urllib.request.Request(
                f"http://127.0.0.1:{cpa_port}/v0/management/auth-files",
                headers={"Authorization": f"Bearer {mgmt_key}"},
            )
            with opener.open(req_files, timeout=3) as resp:
                files = json.load(resp).get("files", [])
            non_api_files = [
                f for f in files
                if not (f.get("runtime_only") and str(f.get("provider") or f.get("type") or "").lower().startswith("openai-compatib"))
            ]
            assert not non_api_files, f"[§39.1] Isolated CPA binary loaded non-API auth rows: {non_api_files}"

            # Confirm config.yaml preserves openai-compatibility and isolates auth-dir/plugins/retries.
            cfg_text = (cpa_root / "config.yaml").read_text()
            assert "runtime-auth" in cfg_text and "request-retry: 0" in cfg_text, "[§39.1] Isolated config mismatch"

            # Verify zero ambient files leaked into runtime-auth or runtime-wd.
            assert list((cpa_root / "runtime-auth").iterdir()) == [], "[§39.1] runtime-auth must remain empty"
            assert list((cpa_root / "runtime-wd").iterdir()) == [], "[§39.1] runtime-wd must remain empty"

            # Send 1 inference request to mock-api-model -> expect HTTP 429 after <= 1 upstream hit (no retries).
            chat_req = urllib.request.Request(
                f"http://127.0.0.1:{cpa_port}/v1/chat/completions",
                data=json.dumps({
                    "model": "mock-api-model",
                    "messages": [{"role": "user", "content": "ping"}],
                }).encode(),
                headers={
                    "Authorization": f"Bearer {client_key}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            try:
                with opener.open(chat_req, timeout=5) as resp:
                    raise AssertionError(f"Expected 429 from mock upstream, got {resp.status}")
            except urllib.error.HTTPError as http_err:
                assert http_err.code == 429, f"Expected 429 from CPA, got {http_err.code}: {http_err.read().decode()}"

            with mock_lock:
                post_hits = [r for r in mock_requests if r[0] == "POST"]
            assert len(post_hits) == 1, f"[§39.2] Expected exactly 1 POST attempt (0 retries), got {post_hits}"

            # Confirm legacy files in auth/ were untouched byte-for-byte.
            assert sha256(legacy_top) == top_hash_before, "[§39.1] legacy-codex.json was modified"
            assert sha256(legacy_nested) == nested_hash_before, "[§39.1] nested-plus.json was modified"

            stop_file.write_text("stop\n")
            out, err = proc.communicate(timeout=15)
            assert proc.returncode == 0, f"Isolated binary shutdown failed ({proc.returncode}): {out}\n{err}"
            print(
                f"PASS: [§39.1 + §39.2] Real binary under loopback socket policy ({binary.name}) loaded 0 subscription rows, "
                f"ignored poisoned .env/env, preserved legacy auth/, and hit 429 mock once (0 retries)"
            )
        finally:
            if proc.poll() is None:
                stop_file.write_text("stop\n")
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
