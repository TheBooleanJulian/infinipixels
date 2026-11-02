"""Upload the Worker secrets from .env to Cloudflare (wrangler secret bulk). Stdlib only.

Run from anywhere:  python tools/push_secrets.py
Only the keys in WORKER_SECRETS are sent; values never touch disk or the terminal.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKER_SECRETS = ["SUPABASE_SERVICE_ROLE_KEY"]


def read_env(path):
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def main():
    env = read_env(ROOT / ".env")
    secrets = {k: env[k] for k in WORKER_SECRETS if env.get(k)}
    missing = [k for k in WORKER_SECRETS if k not in secrets]
    if not secrets:
        sys.exit(f"No Worker secrets found in .env (expected: {', '.join(WORKER_SECRETS)})")

    npx = shutil.which("npx")
    if not npx:
        sys.exit("npx not found on PATH")
    print(f"Uploading: {', '.join(secrets)}")
    result = subprocess.run([npx, "--yes", "wrangler@4", "secret", "bulk"],
                            input=json.dumps(secrets), text=True, cwd=ROOT)
    if missing:
        print(f"Not in .env, skipped: {', '.join(missing)}")
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
