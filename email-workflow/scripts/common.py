"""Shared helpers for the bart@elbertse.info IMAP workflow.

Design rules (do not weaken):
  * READ-ONLY by default. Folders are opened with EXAMINE, headers with BODY.PEEK,
    so nothing changes on the server, not even the \\Seen flag.
  * The password is never a CLI argument, never printed, never written to disk by
    these scripts. It comes from Windows Credential Manager through `keyring`,
    or from an interactive getpass prompt that Claude Code cannot read.
  * No EXPUNGE, no DELETE of folders, no emptying of Trash, anywhere in this package.
"""
from __future__ import annotations

import imaplib
import json
import os
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
PROPOSALS = ROOT / "proposals"
HEADERS_FILE = DATA / "headers.jsonl"
FOLDERS_FILE = DATA / "folders.json"

imaplib._MAXLINE = 10_000_000  # large FETCH responses


def load_config() -> dict:
    cfg_path = ROOT / "config.toml"
    if not cfg_path.exists():
        sys.exit(f"Missing {cfg_path}. Copy config.example.toml to config.toml and fill in host/username.")
    with cfg_path.open("rb") as fh:
        cfg = tomllib.load(fh)
    cfg.setdefault("folders", {}).setdefault("protected", [])
    cfg["folders"].setdefault("trash", "INBOX.Trash")
    cfg.setdefault("scan", {}).setdefault("batch_size", 200)
    return cfg


def get_password(cfg: dict) -> str:
    """Fetch the IMAP password without ever echoing it."""
    user = cfg["imap"]["username"]
    service = cfg["imap"].get("keyring_service", "bart-imap")
    try:
        import keyring  # type: ignore

        pw = keyring.get_password(service, user)
        if pw:
            return pw
        print(f"No credential found in Windows Credential Manager for service={service!r} user={user!r}.",
              file=sys.stderr)
    except ImportError:
        print("`keyring` not installed (pip install keyring); falling back to a hidden prompt.", file=sys.stderr)
    if not sys.stdin.isatty():
        sys.exit("No TTY for a password prompt. Store the password with keyring first (see config.example.toml).")
    import getpass

    return getpass.getpass(f"IMAP password for {user} (not echoed, not stored): ")


@dataclass
class Server:
    conn: imaplib.IMAP4_SSL
    delimiter: str
    prefix: str

    def full(self, name: str) -> str:
        """Server-side name for a folder written as e.g. 'Finance and Admin'."""
        if name.upper() == "INBOX" or name.startswith(self.prefix):
            return name
        return f"{self.prefix}{name}"


def connect(cfg: dict) -> Server:
    imap = cfg["imap"]
    conn = imaplib.IMAP4_SSL(imap["host"], int(imap.get("port", 993)))
    conn.login(imap["username"], get_password(cfg))
    typ, data = conn.list("", "")
    delimiter, prefix = ".", ""
    if typ == "OK" and data and data[0]:
        m = re.match(rb'\((?P<flags>[^)]*)\) "?(?P<delim>[^" ]+)"? "?(?P<name>[^"]*)"?', data[0])
        if m:
            delimiter = m.group("delim").decode()
    # Detect an INBOX. namespace (Dovecot/Courier style, as on Bart's server).
    typ, data = conn.list()
    names = [parse_list_line(l)[2] for l in data if l]
    if any(n.startswith(f"INBOX{delimiter}") for n in names) and not any(
        n not in ("INBOX",) and not n.startswith(f"INBOX{delimiter}") for n in names
    ):
        prefix = f"INBOX{delimiter}"
    if cfg["folders"].get("prefix") is not None:
        prefix = cfg["folders"]["prefix"]
    return Server(conn, delimiter, prefix)


_LIST_RE = re.compile(rb'\((?P<flags>[^)]*)\) (?:"(?P<d1>[^"]*)"|(?P<d2>\S+)) (?:"(?P<n1>(?:[^"\\]|\\.)*)"|(?P<n2>\S+))')


def parse_list_line(line: bytes) -> tuple[list[str], str, str]:
    m = _LIST_RE.match(line)
    if not m:
        return [], ".", line.decode(errors="replace")
    flags = m.group("flags").decode().split()
    delim = (m.group("d1") or m.group("d2") or b".").decode()
    raw = m.group("n1") if m.group("n1") is not None else m.group("n2")
    name = raw.decode("utf-8", errors="replace").replace('\\"', '"').replace("\\\\", "\\")
    return flags, delim, decode_mutf7(name)


def decode_mutf7(s: str) -> str:
    """Decode IMAP modified UTF-7 folder names (e.g. '&AOk-' -> 'é')."""
    if "&" not in s:
        return s
    out, i = [], 0
    while i < len(s):
        if s[i] == "&":
            j = s.find("-", i)
            if j == -1:
                out.append(s[i:]); break
            chunk = s[i + 1:j]
            if chunk == "":
                out.append("&")
            else:
                b64 = chunk.replace(",", "/")
                b64 += "=" * (-len(b64) % 4)
                try:
                    import base64
                    out.append(base64.b64decode(b64).decode("utf-16-be"))
                except Exception:
                    out.append(s[i:j + 1])
            i = j + 1
        else:
            out.append(s[i]); i += 1
    return "".join(out)


def quote(name: str) -> str:
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def read_headers() -> list[dict]:
    if not HEADERS_FILE.exists():
        sys.exit(f"{HEADERS_FILE} missing. Run scripts/01_inventory.py first.")
    with HEADERS_FILE.open(encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


def sender_parts(addr: str) -> tuple[str, str]:
    addr = (addr or "").lower()
    if "@" not in addr:
        return addr, ""
    local, domain = addr.rsplit("@", 1)
    return local, domain


def is_protected(folder: str, cfg: dict) -> bool:
    prot = {p.lower() for p in cfg["folders"]["protected"]}
    f = folder.lower()
    short = f.split(".", 1)[1] if f.startswith("inbox.") else f
    return f in prot or short in prot or f == cfg["folders"]["trash"].lower()
