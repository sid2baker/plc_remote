#!/usr/bin/env python3
import argparse
import base64
import json
import os
import stat
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_BASE = "https://api.tailscale.com"


def request(method, path, token=None, body=None):
    headers = {"Accept": "application/json", "User-Agent": "plc-remote-integration"}
    data = None

    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(API_BASE + path, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            payload = response.read()
            return json.loads(payload) if payload else None
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Tailscale API {method} {path} failed with HTTP {error.code}") from None


def oauth_token():
    client_id = os.environ.get("TS_OAUTH_CLIENT_ID", "")
    client_secret = os.environ.get("TS_OAUTH_SECRET", "")
    if not client_id or not client_secret:
        raise RuntimeError("TS_OAUTH_CLIENT_ID and TS_OAUTH_SECRET are required")

    encoded = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    headers["Authorization"] = f"Basic {credentials}"
    req = urllib.request.Request(
        API_BASE + "/api/v2/oauth/token", data=encoded, headers=headers, method="POST"
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            token = json.loads(response.read())["access_token"]
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Tailscale OAuth failed with HTTP {error.code}") from None

    return token


def write_private_json(path, value):
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(json.dumps(value), encoding="utf-8")
    temporary.chmod(stat.S_IRUSR | stat.S_IWUSR)
    temporary.replace(destination)
    destination.chmod(stat.S_IRUSR | stat.S_IWUSR)


def issue(args):
    tags = [tag.strip() for tag in args.tags.split(",") if tag.strip()]
    if not tags or any(not tag.startswith("tag:") for tag in tags):
        raise RuntimeError("at least one tag:name device tag is required")

    token = oauth_token()
    response = request(
        "POST",
        "/api/v2/tailnet/-/keys",
        token=token,
        body={
            "capabilities": {
                "devices": {
                    "create": {
                        "reusable": False,
                        "ephemeral": True,
                        "preauthorized": True,
                        "tags": tags,
                    }
                }
            },
            "expirySeconds": args.expiry_seconds,
        },
    )

    write_private_json(
        args.payload,
        {"auth_key": response["key"], "hostname": args.hostname, "tags": tags},
    )
    write_private_json(args.state, {"key_id": response["id"]})
    print("Created one-use tailnet enrollment payload")


def cleanup(args):
    token = oauth_token()
    state_path = Path(args.state)
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        key_id = state.get("key_id")
        if key_id:
            try:
                request("DELETE", f"/api/v2/tailnet/-/keys/{key_id}", token=token)
            except RuntimeError:
                # A one-use key may already be absent after successful enrollment.
                pass

    for path in (Path(args.payload), state_path):
        try:
            path.unlink()
        except FileNotFoundError:
            pass

    print("Removed disposable tailnet key; the ephemeral gateway expires automatically")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)

    issue_parser = subparsers.add_parser("issue")
    issue_parser.add_argument("--hostname", required=True)
    issue_parser.add_argument("--tags", required=True)
    issue_parser.add_argument("--payload", required=True)
    issue_parser.add_argument("--state", required=True)
    issue_parser.add_argument("--expiry-seconds", type=int, default=900)
    issue_parser.set_defaults(handler=issue)

    cleanup_parser = subparsers.add_parser("cleanup")
    cleanup_parser.add_argument("--hostname", required=False)
    cleanup_parser.add_argument("--payload", required=True)
    cleanup_parser.add_argument("--state", required=True)
    cleanup_parser.set_defaults(handler=cleanup)

    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
