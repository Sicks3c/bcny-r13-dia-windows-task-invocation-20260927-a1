#!/usr/bin/env python3
"""Create or delete one escrowed mail.tm mailbox without printing secrets."""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import string
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE = "https://api.mail.tm"
STATE = Path(os.environ.get("R13_FIXTURE_STATE", ""))


def request(method: str, path: str, body=None, token: str | None = None):
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    headers = {"Accept": "application/json", "User-Agent": "bcny-r13-owned-fixture/1"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw) if raw else None
        except Exception:
            parsed = None
        return exc.code, parsed


def password() -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(28)) + "Z9@a"


def save(state: dict) -> None:
    STATE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE.parent, 0o700)
    fd = os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
        handle.write("\n")
    os.chmod(STATE, 0o600)


def create(domain_index: int) -> None:
    if not str(STATE):
        raise SystemExit("R13_FIXTURE_STATE required")
    status, domains = request("GET", "/domains?page=1")
    members = domains if isinstance(domains, list) else (domains or {}).get("hydra:member", [])
    active = [item["domain"] for item in members if item.get("isActive") and not item.get("isPrivate")]
    if status != 200 or domain_index >= len(active):
        raise SystemExit("active mail domain unavailable")
    address = f"r13dia{secrets.token_hex(8)}@{active[domain_index]}"
    mail_password = password()
    dia_password = password()
    create_status, account = request("POST", "/accounts", {"address": address, "password": mail_password})
    if create_status != 201 or not isinstance(account, dict) or not account.get("id"):
        raise SystemExit("mailbox creation failed")
    token_status, token = request("POST", "/token", {"address": address, "password": mail_password})
    if token_status != 200 or not isinstance(token, dict) or not token.get("token"):
        raise SystemExit("mailbox token failed")
    state = {
        "address": address,
        "mail_password": mail_password,
        "dia_password": dia_password,
        "mail_account_id": account["id"],
        "mail_token": token["token"],
        "domain_index": domain_index,
        "created_epoch": int(time.time()),
    }
    save(state)
    print(json.dumps({"created": True, "domain_index": domain_index, "address_sha256": hashlib.sha256(address.encode()).hexdigest()}))


def delete() -> None:
    state = json.loads(STATE.read_text(encoding="utf-8"))
    status, _ = request("DELETE", f"/accounts/{state['mail_account_id']}", token=state["mail_token"])
    verify_status, _ = request("GET", f"/accounts/{state['mail_account_id']}", token=state["mail_token"])
    login_status, _ = request("POST", "/token", {"address": state["address"], "password": state["mail_password"]})
    if status != 204 or verify_status != 401 or login_status != 401:
        raise SystemExit("mailbox deletion readback failed")
    print(json.dumps({"deleted": True, "delete_http": status, "bearer_http": verify_status, "password_http": login_status}))


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in {"create", "delete"}:
        raise SystemExit("usage: mailbox-fixture.py create [domain-index]|delete")
    if sys.argv[1] == "create":
        create(int(sys.argv[2]) if len(sys.argv) == 3 else 0)
    else:
        delete()

