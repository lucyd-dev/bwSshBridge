#!/usr/bin/env python3
"""Merge SSH key material (from the environment) into a `bw` item template.

Reads the template JSON on stdin, writes the completed type-5 SSH key item
JSON on stdout. Key material is passed via env vars so it never appears in
argv, shell history, or any file.
"""
import json
import os
import sys


def main() -> int:
    item = json.load(sys.stdin)
    item["type"] = 5
    item["name"] = os.environ.get("BW_SSH_NAME", "SSH Key")
    item["sshKey"] = {
        "privateKey": os.environ["BW_SSH_PRIV"],
        "publicKey": os.environ["BW_SSH_PUB"],
        "keyFingerprint": os.environ["BW_SSH_FP"],
    }
    for key in ("login", "secureNote", "card", "identity"):
        item.pop(key, None)
    item.setdefault("notes", None)
    item.setdefault("reprompt", 0)
    json.dump(item, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
