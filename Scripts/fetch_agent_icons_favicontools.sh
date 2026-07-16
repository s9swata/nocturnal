#!/usr/bin/env bash
# Refresh agent brand PNGs via favicontools MCP generate_iconset.
# Runtime only loads PNG (see BrandAssets). SVG files are not used by the app.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="/usr/bin:/bin:/opt/homebrew/bin:$PATH"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Prefer ImageMagick 7 (`magick`); fall back to IM6 `convert` (same as generate_app_icons.sh).
if command -v magick >/dev/null 2>&1; then
  IM=(magick)
elif command -v convert >/dev/null 2>&1; then
  IM=(convert)
else
  echo "ERROR: need ImageMagick (magick or convert). Install via Homebrew: brew install imagemagick" >&2
  exit 1
fi

# Optional: FAVICONTOOLS_API_KEY for repeatable refreshes past the keyless quota.
FAVICONTOOLS_API_KEY="${FAVICONTOOLS_API_KEY:-}"
API_KEY_FILE="$WORKDIR/api_key.txt"
: >"$API_KEY_FILE"

# Shared MCP client: one code path for standard icons and Grok data-URL uploads.
MCP_HELPER="$WORKDIR/mcp_generate.py"
cat >"$MCP_HELPER" <<'PY'
"""favicontools MCP generate_iconset helper (single request/response path)."""
from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import sys
import urllib.request


def load_api_key(key_file: str) -> str:
    api_key = os.environ.get("FAVICONTOOLS_API_KEY", "").strip()
    if api_key:
        return api_key
    if key_file:
        try:
            return pathlib.Path(key_file).read_text().strip()
        except OSError:
            return ""
    return ""


def save_api_key(key_file: str, value: str) -> None:
    if not key_file or not value:
        return
    try:
        pathlib.Path(key_file).write_text(value)
    except OSError:
        pass


def parse_rpc_message(raw: bytes, request_id: str) -> dict:
    text = raw.decode("utf-8", errors="replace")
    msg = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            try:
                msg = json.loads(line[5:].strip())
            except json.JSONDecodeError:
                continue
    if msg is None:
        try:
            msg = json.loads(text)
        except json.JSONDecodeError as e:
            raise SystemExit(
                f"favicontools: non-JSON response for id={request_id}: {e}"
            ) from e
    if not isinstance(msg, dict):
        raise SystemExit(f"favicontools: unexpected response type for id={request_id}")
    return msg


def extract_result(msg: dict, request_id: str) -> dict | None:
    if msg.get("error"):
        raise SystemExit(f"favicontools RPC error id={request_id}: {msg['error']}")
    result = msg.get("result")
    if isinstance(result, dict) and result.get("isError"):
        content = result.get("content") or []
        detail = ""
        if content and isinstance(content[0], dict):
            detail = content[0].get("text") or str(content)
        raise SystemExit(
            f"favicontools tool error id={request_id}: {detail or result}"
        )
    return result if isinstance(result, dict) else None


def retain_returned_api_key(result: dict | None, key_file: str) -> None:
    if not result:
        return
    content = result.get("content") or []
    if not content or not isinstance(content[0], dict):
        return
    body_text = content[0].get("text")
    if not body_text:
        return
    try:
        body = json.loads(body_text)
        returned = body.get("apiKey") or body.get("api_key")
        if returned:
            save_api_key(key_file, str(returned))
    except (json.JSONDecodeError, TypeError):
        pass


def resolve_source(source: str | None, source_file: str | None) -> str:
    if source_file:
        path = pathlib.Path(source_file)
        if not path.is_file():
            raise SystemExit(f"favicontools: source file not found: {source_file}")
        data = path.read_bytes()
        # Prefer PNG; generic image/* still works for other formats.
        mime = "image/png"
        if path.suffix.lower() in (".jpg", ".jpeg"):
            mime = "image/jpeg"
        elif path.suffix.lower() == ".svg":
            mime = "image/svg+xml"
        elif path.suffix.lower() == ".webp":
            mime = "image/webp"
        return f"data:{mime};base64," + base64.b64encode(data).decode()
    if source:
        return source
    raise SystemExit("favicontools: need --source or --source-file")


def main() -> None:
    parser = argparse.ArgumentParser(description="favicontools generate_iconset")
    parser.add_argument("--id", required=True, help="JSON-RPC request id")
    parser.add_argument("--source", default=None, help="Icon source (simple-icons:… or data URL)")
    parser.add_argument("--source-file", default=None, help="Local image file to upload as data URL")
    parser.add_argument("--out", required=True, help="Write raw MCP response body here")
    args = parser.parse_args()

    key_file = os.environ.get("API_KEY_FILE", "")
    api_key = load_api_key(key_file)
    source = resolve_source(args.source, args.source_file)

    arguments: dict = {
        "source": source,
        "backgroundColor": "none",
        "backgroundShape": "square",
        "variantType": "none",
        "includeThemeAwareFavicon": False,
        "includeDevVariations": False,
        "excludeFromGraph": True,
    }
    if api_key:
        arguments["apiKey"] = api_key

    payload = {
        "jsonrpc": "2.0",
        "id": int(args.id),
        "method": "tools/call",
        "params": {"name": "generate_iconset", "arguments": arguments},
    }
    req = urllib.request.Request(
        "https://favicontools.com/api/mcp",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
    pathlib.Path(args.out).write_bytes(raw)

    msg = parse_rpc_message(raw, args.id)
    result = extract_result(msg, args.id)
    retain_returned_api_key(result, key_file)
    print("ok", args.out)


if __name__ == "__main__":
    main()
PY

mcp_generate() {
  local id="$1" source="$2" out="$3"
  FAVICONTOOLS_API_KEY="$FAVICONTOOLS_API_KEY" API_KEY_FILE="$API_KEY_FILE" \
    python3 "$MCP_HELPER" --id "$id" --source "$source" --out "$out"
}

mcp_generate_file() {
  local id="$1" file="$2" out="$3"
  FAVICONTOOLS_API_KEY="$FAVICONTOOLS_API_KEY" API_KEY_FILE="$API_KEY_FILE" \
    python3 "$MCP_HELPER" --id "$id" --source-file "$file" --out "$out"
}

# Brand sources
mcp_generate 1 "simple-icons:openai" "$WORKDIR/openai.json"
mcp_generate 2 "simple-icons:claude" "$WORKDIR/claude.json"
mcp_generate 3 "simple-icons:cursor" "$WORKDIR/cursor.json"
mcp_generate 4 "simple-icons:opencode" "$WORKDIR/opencode.json"

# Grok: opt-in only. The file is base64-uploaded to favicontools — never default
# to a personal path under ~/Documents.
if [[ -n "${GROK_LOGO:-}" && -f "${GROK_LOGO}" ]]; then
  echo "Uploading GROK_LOGO=$GROK_LOGO to favicontools…" >&2
  mcp_generate_file 5 "$GROK_LOGO" "$WORKDIR/grok.json"
else
  echo "INFO: set GROK_LOGO=/path/to/logo.png to refresh Grok icon (file is uploaded to favicontools)" >&2
fi

# Export IM for Python resize loop.
export IM_CMD="${IM[*]}"

python3 - "$WORKDIR" "$ROOT" <<'PY'
import json, os, re, pathlib, shutil, subprocess, sys
from urllib.request import Request, urlopen

workdir = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
im = os.environ.get("IM_CMD", "magick").split()
mapping = {
    "openai": "agent-openai",
    "claude": "agent-claude",
    "cursor": "agent-cursor",
    "opencode": "agent-opencode",
    "grok": "agent-grok",
}

def parse_files(agent):
    p = workdir / f"{agent}.json"
    if not p.exists():
        return None
    raw = p.read_text()
    m = re.search(r"data:\s*(\{.*\})\s*$", raw, re.S)
    if m:
        msg = json.loads(m.group(1))
    else:
        msg = json.loads(raw)
    if isinstance(msg, dict) and msg.get("error"):
        raise SystemExit(f"{agent}: RPC error {msg['error']}")
    result = msg.get("result") if isinstance(msg, dict) else None
    if isinstance(result, dict) and result.get("isError"):
        content = result.get("content") or []
        detail = content[0].get("text") if content and isinstance(content[0], dict) else result
        raise SystemExit(f"{agent}: tool error {detail}")
    if not isinstance(result, dict):
        raise SystemExit(f"{agent}: missing result in response")
    content = result.get("content") or []
    if not content or not isinstance(content[0], dict) or "text" not in content[0]:
        raise SystemExit(f"{agent}: unexpected content shape (rate limit or API error?)")
    body = json.loads(content[0]["text"])
    if "files" not in body:
        raise SystemExit(f"{agent}: response missing 'files' (got keys {list(body.keys())})")
    return body["files"]

def pick(files):
    by = {f["filename"]: f["blobUrl"] for f in files}
    for n in ("icon-1024x1024.png", "icon-560x560.png", "apple-touch-icon.png"):
        if n in by:
            return by[n]
    return max(files, key=lambda f: f.get("sizeBytes", 0))["blobUrl"]

def download(url, path):
    req = Request(url, headers={"User-Agent": "NocturnalBrandFetch/1.0"})
    path.write_bytes(urlopen(req, timeout=60).read())

dests = [root / "Sources/Nocturnal/Resources/Brand", root / "Assets/Brand"]
for agent, base in mapping.items():
    files = parse_files(agent)
    if not files:
        continue
    raw = workdir / f"{agent}-src.png"
    download(pick(files), raw)
    for size, name in ((128, f"{base}.png"), (256, f"{base}@2x.png"), (1024, f"{base}-1024.png")):
        out = workdir / name
        subprocess.check_call([
            *im, str(raw),
            "-resize", f"{size}x{size}",
            "-background", "none", "-gravity", "center", "-extent", f"{size}x{size}",
            "-channel", "RGB", "-evaluate", "set", "0", "+channel",
            f"PNG32:{out}",
        ])
        for d in dests:
            shutil.copy(out, d / name)
    print("installed", base)
print("done")
PY

echo "Agent PNGs updated under Sources/Nocturnal/Resources/Brand and Assets/Brand"
