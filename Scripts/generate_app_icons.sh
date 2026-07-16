#!/usr/bin/env bash
# Generate macOS app icon sets (+ optional web/PWA favicons) from the brand logo.
#
# Nocturnal is a macOS companion — primary output is .iconset / .icns with
# production / staging / dev badged variants. A static/ web favicon set is also
# emitted for docs/landing use (not wired into the SwiftUI app).
#
# Usage:
#   Scripts/generate_app_icons.sh
#   Scripts/generate_app_icons.sh /path/to/logo.png
#
# Env:
#   ICON_MASTER   Override source PNG (default: brand app icon)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MASTER="${1:-${ICON_MASTER:-}}"
if [[ -z "$MASTER" ]]; then
  for c in \
    "$ROOT/Sources/Nocturnal/Resources/Brand/nocturnal-app-icon.png" \
    "$ROOT/Assets/Brand/nocturnal-app-icon.png"
  do
    if [[ -f "$c" ]]; then MASTER="$c"; break; fi
  done
fi
if [[ -z "$MASTER" || ! -f "$MASTER" ]]; then
  echo "ERROR: no master icon PNG found" >&2
  exit 1
fi

if ! command -v sips >/dev/null || ! command -v iconutil >/dev/null; then
  echo "ERROR: need sips + iconutil (macOS)" >&2
  exit 1
fi
if command -v magick >/dev/null; then
  IM=(magick)
elif command -v convert >/dev/null; then
  IM=(convert)
else
  echo "ERROR: ImageMagick required for badges (brew install imagemagick)" >&2
  exit 1
fi

# Prefer a font that exists on stock macOS.
BADGE_FONT="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
if [[ ! -f "$BADGE_FONT" ]]; then
  BADGE_FONT="/System/Library/Fonts/Helvetica.ttc"
fi

OUT="$ROOT/Assets/AppIcons"
STATIC="$ROOT/static/icons"
mkdir -p "$OUT"/{production,staging,dev,master} "$STATIC"/{production,staging,dev}

# Normalize master to 1024×1024 PNG with alpha.
MASTER_1024="$OUT/master/icon-1024.png"
sips -s format png -z 1024 1024 "$MASTER" --out "$MASTER_1024" >/dev/null
# Ensure square RGB/A
"${IM[@]}" "$MASTER_1024" -resize 1024x1024^ -gravity center -extent 1024x1024 \
  -background none PNG32:"$MASTER_1024"

badge_stage() {
  local stage="$1"   # production | staging | dev
  local src="$2"
  local dest="$3"
  case "$stage" in
    production)
      cp "$src" "$dest"
      ;;
    staging)
      # Amber STG badge (bottom-right)
      "${IM[@]}" "$src" -gravity SouthEast \
        \( -size 340x140 xc:none \
           -fill '#C9963A' -draw 'roundrectangle 0,0 339,139 28,28' \
           -fill white -font "$BADGE_FONT" -pointsize 72 \
           -gravity center -annotate +0+0 'STG' \) \
        -geometry +48+48 -composite PNG32:"$dest"
      ;;
    dev)
      # Grey DEV badge
      "${IM[@]}" "$src" -gravity SouthEast \
        \( -size 340x140 xc:none \
           -fill '#555555' -draw 'roundrectangle 0,0 339,139 28,28' \
           -fill white -font "$BADGE_FONT" -pointsize 72 \
           -gravity center -annotate +0+0 'DEV' \) \
        -geometry +48+48 -composite PNG32:"$dest"
      ;;
    *)
      echo "unknown stage $stage" >&2
      exit 1
      ;;
  esac
}

write_iconset() {
  local master="$1"
  local iconset="$2"
  rm -rf "$iconset"
  mkdir -p "$iconset"
  local size double
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
}

write_web_set() {
  local master="$1"
  local dest="$2"
  local name="$3"
  mkdir -p "$dest"
  # Favicon / PWA common sizes
  for size in 16 32 48 64 96 128 180 192 256 512; do
    sips -z "$size" "$size" "$master" --out "$dest/icon-${size}.png" >/dev/null
  done
  # Apple touch
  sips -z 180 180 "$master" --out "$dest/apple-touch-icon.png" >/dev/null
  # favicon.ico (multi-size via ImageMagick)
  "${IM[@]}" "$dest/icon-16.png" "$dest/icon-32.png" "$dest/icon-48.png" "$dest/favicon.ico"
  # Stage-specific web manifest
  cat > "$dest/site.webmanifest" <<JSON
{
  "name": "${name}",
  "short_name": "${name}",
  "icons": [
    { "src": "icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icon-512.png", "sizes": "512x512", "type": "image/png" }
  ],
  "theme_color": "#0A0A0A",
  "background_color": "#0A0A0A",
  "display": "standalone"
}
JSON
}

echo "Master: $MASTER_1024"

for stage in production staging dev; do
  case "$stage" in
    production) NAME="Nocturnal" ;;
    staging)    NAME="Nocturnal (Staging)" ;;
    dev)        NAME="Nocturnal (Dev)" ;;
  esac

  STAGE_MASTER="$OUT/$stage/icon-1024.png"
  badge_stage "$stage" "$MASTER_1024" "$STAGE_MASTER"

  write_iconset "$STAGE_MASTER" "$OUT/$stage/Nocturnal.iconset"
  iconutil --convert icns --output "$OUT/$stage/Icon.icns" "$OUT/$stage/Nocturnal.iconset"
  # Flat copies commonly expected by packaging
  cp "$STAGE_MASTER" "$OUT/$stage/AppIcon.png"
  write_web_set "$STAGE_MASTER" "$STATIC/$stage" "$NAME"

  echo "  ✓ $stage → $OUT/$stage/Icon.icns  +  static/icons/$stage/"
done

# Convenience: production masters at repo-known paths used by package_app
cp "$OUT/production/Icon.icns" "$ROOT/build/Icon.icns" 2>/dev/null || {
  mkdir -p "$ROOT/build"
  cp "$OUT/production/Icon.icns" "$ROOT/build/Icon.icns"
}
cp "$OUT/production/AppIcon.png" "$ROOT/Sources/Nocturnal/Resources/Brand/nocturnal-app-icon.png"
cp "$OUT/production/AppIcon.png" "$ROOT/Assets/Brand/nocturnal-app-icon.png"

# Default static index (production) + stage-aware HTML head snippet
cat > "$STATIC/head-icons.html" <<'HTML'
<!-- Nocturnal stage-aware icons. Set data-nocturnal-stage on <html> to production|staging|dev -->
<link rel="icon" type="image/x-icon" href="/static/icons/production/favicon.ico" id="nocturnal-favicon">
<link rel="icon" type="image/png" sizes="32x32" href="/static/icons/production/icon-32.png" id="nocturnal-favicon-32">
<link rel="apple-touch-icon" href="/static/icons/production/apple-touch-icon.png" id="nocturnal-apple-touch">
<link rel="manifest" href="/static/icons/production/site.webmanifest" id="nocturnal-manifest">
<script>
(function () {
  var stage = (document.documentElement.getAttribute("data-nocturnal-stage")
    || (typeof process !== "undefined" && process.env && process.env.NOCTURNAL_STAGE)
    || "production").toLowerCase();
  if (stage !== "staging" && stage !== "dev") stage = "production";
  var base = "/static/icons/" + stage + "/";
  function set(id, attr, val) {
    var el = document.getElementById(id);
    if (el) el.setAttribute(attr, val);
  }
  set("nocturnal-favicon", "href", base + "favicon.ico");
  set("nocturnal-favicon-32", "href", base + "icon-32.png");
  set("nocturnal-apple-touch", "href", base + "apple-touch-icon.png");
  set("nocturnal-manifest", "href", base + "site.webmanifest");
})();
</script>
HTML

# Tiny verification HTML (open in browser to check tab icon)
cat > "$STATIC/verify.html" <<'HTML'
<!doctype html>
<html lang="en" data-nocturnal-stage="production">
<head>
  <meta charset="utf-8">
  <title>Nocturnal icon verify</title>
  <link rel="icon" type="image/x-icon" href="production/favicon.ico" id="nocturnal-favicon">
  <link rel="icon" type="image/png" sizes="32x32" href="production/icon-32.png" id="nocturnal-favicon-32">
  <link rel="apple-touch-icon" href="production/apple-touch-icon.png" id="nocturnal-apple-touch">
  <link rel="manifest" href="production/site.webmanifest" id="nocturnal-manifest">
  <style>
    body { font: 15px/1.5 system-ui; background: #0a0a0a; color: #ededed; padding: 2rem; }
    button { margin: 0.25rem; padding: 0.5rem 0.75rem; cursor: pointer; }
    img { width: 64px; height: 64px; margin: 0.5rem; border-radius: 12px; background: #141414; }
  </style>
</head>
<body>
  <h1>Nocturnal icon stage check</h1>
  <p>Current stage: <strong id="stage">production</strong> — check the browser tab icon.</p>
  <p>
    <button type="button" data-stage="production">Production</button>
    <button type="button" data-stage="staging">Staging</button>
    <button type="button" data-stage="dev">Dev</button>
  </p>
  <div id="previews"></div>
  <script>
    function apply(stage) {
      document.documentElement.setAttribute("data-nocturnal-stage", stage);
      document.getElementById("stage").textContent = stage;
      var base = stage + "/";
      document.getElementById("nocturnal-favicon").href = base + "favicon.ico";
      document.getElementById("nocturnal-favicon-32").href = base + "icon-32.png";
      document.getElementById("nocturnal-apple-touch").href = base + "apple-touch-icon.png";
      document.getElementById("nocturnal-manifest").href = base + "site.webmanifest";
      document.getElementById("previews").innerHTML =
        [16,32,64,128,192,512].map(function (s) {
          return '<img src="' + base + 'icon-' + s + '.png" alt="' + s + '" title="' + s + '">';
        }).join("");
      document.title = "Nocturnal [" + stage + "]";
    }
    document.querySelectorAll("button[data-stage]").forEach(function (b) {
      b.addEventListener("click", function () { apply(b.getAttribute("data-stage")); });
    });
    apply("production");
  </script>
</body>
</html>
HTML

echo ""
echo "Generated:"
echo "  Assets/AppIcons/{production,staging,dev}/Icon.icns"
echo "  static/icons/{production,staging,dev}/  (favicon + PWA)"
echo "  static/icons/verify.html  → open to check tab icons"
echo ""
echo "Package with:"
echo "  NOCTURNAL_ICON_STAGE=production Scripts/package_app.sh"
echo "  NOCTURNAL_ICON_STAGE=staging    Scripts/package_app.sh"
echo "  NOCTURNAL_ICON_STAGE=dev        Scripts/package_app.sh   # or CONF=debug"
