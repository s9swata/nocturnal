#!/usr/bin/env bash
# Refresh agent brand PNGs via favicontools MCP generate_iconset.
# Runtime only loads PNG (see BrandAssets). SVG files are not used by the app.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="/usr/bin:/bin:/opt/homebrew/bin:$PATH"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

mcp_generate() {
  local id="$1" source="$2" out="$3"
  python3 - "$id" "$source" "$out" <<'PY'
import json, sys, urllib.request
id_, source, out = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
  "jsonrpc": "2.0", "id": int(id_), "method": "tools/call",
  "params": {"name": "generate_iconset", "arguments": {
    "source": source,
    "backgroundColor": "none",
    "backgroundShape": "square",
    "variantType": "none",
    "includeThemeAwareFavicon": False,
    "includeDevVariations": False,
    "excludeFromGraph": True,
  }},
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
  open(out, "wb").write(r.read())
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
  python3 - "$GROK_LOGO" "$WORKDIR/grok.json" <<'PY'
import base64, json, pathlib, sys, urllib.request
src = pathlib.Path(sys.argv[1]).read_bytes()
data_url = "data:image/png;base64," + base64.b64encode(src).decode()
payload = {
  "jsonrpc": "2.0", "id": 5, "method": "tools/call",
  "params": {"name": "generate_iconset", "arguments": {
    "source": data_url,
    "backgroundColor": "none",
    "backgroundShape": "square",
    "variantType": "none",
    "includeThemeAwareFavicon": False,
    "includeDevVariations": False,
    "excludeFromGraph": True,
  }},
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
  pathlib.Path(sys.argv[2]).write_bytes(r.read())
print("ok grok")
PY
else
  echo "INFO: set GROK_LOGO=/path/to/logo.png to refresh Grok icon (file is uploaded to favicontools)" >&2
fi

python3 - "$WORKDIR" "$ROOT" <<'PY'
import json, re, pathlib, subprocess, shutil, sys
from urllib.request import Request, urlopen

workdir = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
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
    msg = json.loads(m.group(1))
    text = msg["result"]["content"][0]["text"]
    return json.loads(text)["files"]

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
            "magick", str(raw),
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
