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

mcp_generate() {
  local id="$1" source="$2" out="$3"
  FAVICONTOOLS_API_KEY="$FAVICONTOOLS_API_KEY" API_KEY_FILE="$API_KEY_FILE" \
  python3 - "$id" "$source" "$out" <<'PY'
import json, os, sys, urllib.request

id_, source, out = sys.argv[1], sys.argv[2], sys.argv[3]
api_key = os.environ.get("FAVICONTOOLS_API_KEY", "").strip()
key_file = os.environ.get("API_KEY_FILE", "")
if not api_key and key_file:
    try:
        api_key = open(key_file).read().strip()
    except OSError:
        api_key = ""

arguments = {
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
    "id": int(id_),
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
open(out, "wb").write(raw)

# Parse SSE / JSON body and surface isError instead of KeyError: files later.
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
        raise SystemExit(f"favicontools: non-JSON response for id={id_}: {e}") from e

if isinstance(msg, dict) and msg.get("error"):
    raise SystemExit(f"favicontools RPC error id={id_}: {msg['error']}")

result = (msg or {}).get("result") if isinstance(msg, dict) else None
if isinstance(result, dict) and result.get("isError"):
    content = result.get("content") or []
    detail = ""
    if content and isinstance(content[0], dict):
        detail = content[0].get("text") or str(content)
    raise SystemExit(f"favicontools tool error id={id_}: {detail or result}")

# Retain returned apiKey for subsequent requests in this run.
if isinstance(result, dict):
    body_text = None
    content = result.get("content") or []
    if content and isinstance(content[0], dict):
        body_text = content[0].get("text")
    if body_text:
        try:
            body = json.loads(body_text)
            returned = body.get("apiKey") or body.get("api_key")
            if returned and key_file:
                open(key_file, "w").write(str(returned))
        except (json.JSONDecodeError, TypeError, OSError):
            pass

print("ok", out)
PY
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
  FAVICONTOOLS_API_KEY="$FAVICONTOOLS_API_KEY" API_KEY_FILE="$API_KEY_FILE" \
  python3 - "$GROK_LOGO" "$WORKDIR/grok.json" <<'PY'
import base64, json, os, pathlib, sys, urllib.request

src = pathlib.Path(sys.argv[1]).read_bytes()
data_url = "data:image/png;base64," + base64.b64encode(src).decode()
api_key = os.environ.get("FAVICONTOOLS_API_KEY", "").strip()
key_file = os.environ.get("API_KEY_FILE", "")
if not api_key and key_file:
    try:
        api_key = open(key_file).read().strip()
    except OSError:
        api_key = ""

arguments = {
    "source": data_url,
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
    "id": 5,
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
pathlib.Path(sys.argv[2]).write_bytes(raw)

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
    msg = json.loads(text)
if isinstance(msg, dict) and msg.get("error"):
    raise SystemExit(f"favicontools RPC error (grok): {msg['error']}")
result = (msg or {}).get("result") if isinstance(msg, dict) else None
if isinstance(result, dict) and result.get("isError"):
    content = result.get("content") or []
    detail = content[0].get("text") if content and isinstance(content[0], dict) else result
    raise SystemExit(f"favicontools tool error (grok): {detail}")
if isinstance(result, dict):
    content = result.get("content") or []
    if content and isinstance(content[0], dict) and content[0].get("text"):
        try:
            body = json.loads(content[0]["text"])
            returned = body.get("apiKey") or body.get("api_key")
            if returned and key_file:
                open(key_file, "w").write(str(returned))
        except (json.JSONDecodeError, TypeError, OSError):
            pass
print("ok grok")
PY
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
