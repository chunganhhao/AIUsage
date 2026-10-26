"""Opt-in test against an installed CPA binary; never touches the live gateway.

Uses generated fake credentials, a temporary config/auth directory, loopback ports,
embedded catalogs and a dead loopback proxy. No real Google request/paid generation.
"""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


def main():
    binary, root = Path(sys.argv[1]), Path(sys.argv[2])
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    key = secrets.token_hex(24)
    auth = root / "auth"
    a = auth / "aiusage-antigravity-a.json"
    b = auth / "aiusage-antigravity-b.json"
    before = (root / "before.json").read_bytes()
    catalog = root / "fixture-catalog.json"
    ids = json.loads(before)["antigravity_capability_hints"]["model_ids"]
    catalog.write_text(json.dumps({"antigravity": [{"id": mid, "object": "model", "owned_by": "antigravity", "type": "antigravity", "display_name": mid} for mid in ids]}))
    a.write_bytes(before)
    b.write_bytes(before)
    config = root / "isolated-cpa.yaml"
    config.write_text(f"""host: '127.0.0.1'
models:
  catalog: {json.dumps(str(catalog))}
port: {port}
auth-dir: {json.dumps(str(auth))}
proxy-url: 'http://127.0.0.1:1'
api-keys:
  - '{key}'
remote-management:
  allow-remote: false
  secret-key: '{key}'
  disable-control-panel: true
logging-to-file: false
request-retry: 0
quota-exceeded:
  switch-project: false
  switch-preview-model: false
""")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(path):
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers={"Authorization": f"Bearer {key}"})
        with opener.open(req, timeout=2) as response:
            return json.load(response)

    def models(name):
        result = request(f"/v0/management/auth-files/models?name={name}")
        return {row["id"] for row in result.get("models", [])}

    def wait_for(condition, label):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                if condition():
                    return
            except (OSError, ValueError, KeyError, urllib.error.HTTPError):
                pass
            if process.poll() is not None:
                raise RuntimeError(f"Isolated CPA exited during {label}; inspect temporary test log")
            time.sleep(0.25)
        raise AssertionError(f"Timed out proving {label}")

    def replace(name):
        temp = auth / "next.tmp"
        temp.write_bytes((root / name).read_bytes())
        os.replace(temp, a)

    with (root / "isolated-cpa.log").open("w") as log:
        process = subprocess.Popen([str(binary), "-config", str(config), "-local-model"], cwd=root,
                                   stdout=log, stderr=log, env={**os.environ, "HOME": str(root)})
        try:
            gemini = "gemini-3.8-flash-high"
            claude = "claude-opus-5-5-high"
            argon = "gemini-4-argon-medium"
            gpt = "gpt-oss-120b-medium"
            wanted = {gemini, claude, argon, gpt}
            wait_for(lambda: wanted <= models(a.name) and wanted <= models(b.name), "baseline per-account registration")
            replace("blocked.json")
            wait_for(lambda: gemini in models(a.name) and not ({claude, argon, gpt} & models(a.name)), "per-pool hot-reload exclusion")
            assert wanted <= models(b.name), "Other account lost its routes"
            statuses = request("/v0/management/auth-files")["files"]
            assert all(not row.get("disabled", False) for row in statuses if row.get("name") in {a.name, b.name})
            replace("recovered.json")
            wait_for(lambda: wanted <= models(a.name), "recovery without rewriting capability hints")
            print("CPA integration: baseline, pool-specific hot reload, account isolation, active status and recovery passed")
        except Exception:
            # Fake credentials only. Keep a bounded diagnostic if the proof fails.
            log.flush()
            try:
                print("Observed fixture model registrations:", models(a.name), models(b.name), file=sys.stderr)
            except Exception:
                pass
            print((root / "isolated-cpa.log").read_text()[-5000:], file=sys.stderr)
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
