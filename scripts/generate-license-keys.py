#!/usr/bin/env python3
"""Generate an Ed25519 license signing key pair.

    python3 scripts/generate-license-keys.py

Prints the private and public PEM keys. Put them in docker/.env as
LICENSE_PRIVATE_KEY / LICENSE_PUBLIC_KEY.

This deliberately lives in scripts/ and NOT in backend/. It used to be
backend/generate_license_keys.py, where `from backend import *` in app.py
executed it at import time -- so every single start of the API printed a
freshly generated private key to stdout and into the container logs. Even
though the generated key was not the one actually in use, that trains operators
to ignore key material in logs.

This script must be run deliberately, by a human, once.
"""

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519

key = ed25519.Ed25519PrivateKey.generate()

priv_pem = key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption()
).decode("utf-8")

pub_pem = key.public_key().public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo
).decode("utf-8")

print("=" * 60)
print("ED25519 LICENSE KEY PAIR")
print("=" * 60)
print()
print("--- PRIVATE KEY (set as LICENSE_PRIVATE_KEY env var on CLOUD server) ---")
print(priv_pem)
print()
print("--- PUBLIC KEY (set as LICENSE_PUBLIC_KEY env var on LOCAL server) ---")
print(pub_pem)
print()
print("=" * 60)
print("Quick env setup (Linux):")
print(f'  export LICENSE_PRIVATE_KEY="{priv_pem.strip()}"')
print(f'  export LICENSE_PUBLIC_KEY="{pub_pem.strip()}"')
print()
print("Quick env setup (Windows PowerShell):")
print(f'  $env:LICENSE_PRIVATE_KEY="{priv_pem.strip()}"')
print(f'  $env:LICENSE_PUBLIC_KEY="{pub_pem.strip()}"')
print("=" * 60)
