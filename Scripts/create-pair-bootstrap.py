#!/usr/bin/env python3
"""Developer install helper. Creates one pair secret locally; never prints it."""
import base64
import json
import os
from pathlib import Path
import secrets

root = Path(__file__).resolve().parents[1]
private = root / "build/private/pairing"
private.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(private, 0o700)
destination = private / "WristControl-Pairing.json"
# Exclusive creation: re-running does not silently revoke an installed pair.
descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w") as file:
    json.dump({"version": 1, "secret": base64.b64encode(secrets.token_bytes(32)).decode("ascii")}, file)
print("Created build/private/pairing/WristControl-Pairing.json; secret not printed.")
