#!/usr/bin/env python3
"""
Proxmox VM Cloner
Clones a source VM into multiple resource pools via the Proxmox API.

Usage:
    python proxmox_clone.py
    python proxmox_clone.py --config my_config.json
"""

import argparse
import json
import time
import urllib.request
import urllib.error
import ssl
import sys

# ──────────────────────────────────────────────
#  CONFIGURATION  –  edit this or pass --config
# ──────────────────────────────────────────────
DEFAULT_CONFIG = {
    # Proxmox host (no trailing slash)
    "host": "https://proxmox.example.com:8006",

    # Authentication – use either API token (recommended) or password
    "auth": {
        "type": "token",               # "token" | "password"
        "token_id": "user@pam!mytoken",
        "token_secret": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        # --- password auth (used when type == "password") ---
        # "username": "root@pam",
        # "password": "secret"
    },

    # Source VM to clone
    "source": {
        "node": "pve",                 # Proxmox node that hosts the template
        "vmid": 9000,                  # Template / VM ID to clone from
        "snapshot": None               # Snapshot name, or null for current state
    },

    # Whether to do a full clone (True) or linked clone (False)
    "full_clone": True,

    # Target node for all clones (null = same as source node)
    "target_node": None,

    # Starting VM ID for clones; each clone increments by 1
    "start_vmid": 200,

    # Resource pools to clone into – one VM will be created per entry
    "pools": [
        {"pool": "pool-dev",     "name": "dev-vm-01"},
        {"pool": "pool-staging", "name": "staging-vm-01"},
        {"pool": "pool-prod",    "name": "prod-vm-01"}
    ],

    # Seconds to wait between clone requests (avoid overloading the host)
    "delay_between_clones": 5,

    # Skip TLS certificate verification (set True for self-signed certs)
    "verify_ssl": False
}
# ──────────────────────────────────────────────


class ProxmoxClient:
    """Minimal Proxmox API client using only the standard library."""

    def __init__(self, host: str, auth: dict, verify_ssl: bool = True):
        self.host = host.rstrip("/")
        self.auth = auth
        self.verify_ssl = verify_ssl
        self._ticket = None
        self._csrf = None
        self._token_header = None
        self._authenticate()

    # ── Auth ──────────────────────────────────

    def _authenticate(self):
        if self.auth["type"] == "token":
            # API token – no ticket needed
            self._token_header = (
                f"PVEAPIToken={self.auth['token_id']}={self.auth['token_secret']}"
            )
            print(f"[auth] Using API token: {self.auth['token_id']}")
        else:
            # Username/password – obtain a ticket
            data = json.dumps({
                "username": self.auth["username"],
                "password": self.auth["password"]
            }).encode()
            resp = self._raw_request("POST", "/api2/json/access/ticket", data,
                                     content_type="application/json", authed=False)
            self._ticket = resp["data"]["ticket"]
            self._csrf = resp["data"]["CSRFPreventionToken"]
            print(f"[auth] Ticket obtained for {self.auth['username']}")

    # ── HTTP helpers ──────────────────────────

    def _ssl_context(self):
        ctx = ssl.create_default_context()
        if not self.verify_ssl:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        return ctx

    def _raw_request(self, method, path, body=None,
                     content_type="application/json", authed=True):
        url = self.host + path
        headers = {"Content-Type": content_type}

        if authed:
            if self._token_header:
                headers["Authorization"] = self._token_header
            elif self._ticket:
                headers["Cookie"] = f"PVEAuthCookie={self._ticket}"
                if method in ("POST", "PUT", "DELETE"):
                    headers["CSRFPreventionToken"] = self._csrf

        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, context=self._ssl_context()) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            body_text = e.read().decode()
            raise RuntimeError(
                f"HTTP {e.code} {e.reason} for {method} {path}\n{body_text}"
            ) from e

    def get(self, path):
        return self._raw_request("GET", path)

    def post(self, path, payload: dict):
        body = json.dumps(payload).encode()
        return self._raw_request("POST", path, body)

    # ── Proxmox helpers ───────────────────────

    def get_next_vmid(self):
        resp = self.get("/api2/json/cluster/nextid")
        return int(resp["data"])

    def wait_for_task(self, node: str, upid: str, timeout: int = 300):
        """Poll a task until it finishes or timeout (seconds) is reached."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            resp = self.get(f"/api2/json/nodes/{node}/tasks/{upid}/status")
            status = resp["data"]["status"]
            if status == "stopped":
                exit_status = resp["data"].get("exitstatus", "")
                if exit_status != "OK":
                    raise RuntimeError(f"Task {upid} failed: {exit_status}")
                return
            time.sleep(3)
        raise TimeoutError(f"Task {upid} did not finish within {timeout}s")

    def clone_vm(self, node: str, vmid: int, new_vmid: int,
                 name: str, pool: str, full: bool,
                 target_node: str = None, snapshot: str = None):
        payload = {
            "newid": new_vmid,
            "name":  name,
            "pool":  pool,
            "full":  int(full),
        }
        if target_node:
            payload["target"] = target_node
        if snapshot:
            payload["snapname"] = snapshot

        path = f"/api2/json/nodes/{node}/qemu/{vmid}/clone"
        resp = self.post(path, payload)
        return resp["data"]   # UPID task string


# ── Main cloning logic ────────────────────────

def run(config: dict):
    client = ProxmoxClient(
        host=config["host"],
        auth=config["auth"],
        verify_ssl=config.get("verify_ssl", True)
    )

    src      = config["source"]
    src_node = src["node"]
    src_vmid = src["vmid"]
    snapshot = src.get("snapshot")
    full     = config.get("full_clone", True)
    tgt_node = config.get("target_node")
    delay    = config.get("delay_between_clones", 5)
    pools    = config["pools"]
    start_id = config.get("start_vmid")

    print(f"\n{'─'*55}")
    print(f"  Source VM : {src_vmid} on node '{src_node}'")
    print(f"  Full clone: {full}")
    print(f"  Pools     : {[p['pool'] for p in pools]}")
    print(f"{'─'*55}\n")

    results = []
    current_vmid = start_id

    for i, entry in enumerate(pools):
        pool = entry["pool"]
        name = entry.get("name", f"clone-{pool}-{i+1}")

        # Determine VM ID for this clone
        if current_vmid is None:
            vmid = client.get_next_vmid()
        else:
            vmid = current_vmid
            current_vmid += 1

        print(f"[{i+1}/{len(pools)}] Cloning → pool='{pool}'  name='{name}'  vmid={vmid}")

        try:
            upid = client.clone_vm(
                node=src_node,
                vmid=src_vmid,
                new_vmid=vmid,
                name=name,
                pool=pool,
                full=full,
                target_node=tgt_node,
                snapshot=snapshot
            )
            print(f"         Task started: {upid}")
            print(f"         Waiting for task to complete…")
            client.wait_for_task(src_node, upid)
            print(f"         ✓ Done\n")
            results.append({"vmid": vmid, "name": name, "pool": pool, "status": "ok"})
        except Exception as exc:
            print(f"         ✗ FAILED: {exc}\n")
            results.append({"vmid": vmid, "name": name, "pool": pool,
                            "status": "failed", "error": str(exc)})

        if i < len(pools) - 1:
            time.sleep(delay)

    # ── Summary ───────────────────────────────
    print(f"\n{'═'*55}")
    print("  CLONE SUMMARY")
    print(f"{'═'*55}")
    ok  = [r for r in results if r["status"] == "ok"]
    err = [r for r in results if r["status"] != "ok"]
    for r in results:
        icon = "✓" if r["status"] == "ok" else "✗"
        print(f"  {icon}  vmid={r['vmid']:>5}  pool={r['pool']:<20}  {r['name']}")
        if r["status"] != "ok":
            print(f"        error: {r['error']}")
    print(f"{'─'*55}")
    print(f"  {len(ok)} succeeded, {len(err)} failed")
    print(f"{'═'*55}\n")
    return len(err) == 0


# ── CLI entry point ───────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Clone a Proxmox VM into multiple resource pools")
    parser.add_argument("--config", help="Path to a JSON config file (overrides defaults)")
    args = parser.parse_args()

    config = DEFAULT_CONFIG.copy()

    if args.config:
        with open(args.config) as f:
            override = json.load(f)
        config.update(override)
        print(f"[config] Loaded from {args.config}")
    else:
        print("[config] Using DEFAULT_CONFIG defined at the top of this file")

    success = run(config)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()