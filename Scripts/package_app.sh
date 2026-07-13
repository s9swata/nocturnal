#!/usr/bin/env bash
# Package Nocturnal as build/Nocturnal.app (menu-bar companion + helper CLIs).
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=${APP_NAME:-Nocturnal}
BUNDLE_ID=${BUNDLE_ID:-app.nocturnal.Nocturnal}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-14.0}
MENU_BAR_APP=${MENU_BAR_APP:-1}
SIGNING_MODE=${SIGNING_MODE:-adhoc}
APP_IDENTITY=${APP_IDENTITY:-}

if [[ -f "$ROOT/version.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/version.env"
else
  MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
  BUILD_NUMBER=${BUILD_NUMBER:-1}
fi

ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  ARCH_LIST=("$HOST_ARCH")
fi

for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c "$CONF" --arch "$ARCH"
done

# Output under build/ (not project root).
APP="$ROOT/build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/Helpers" \
  "$APP/Contents/Resources/Fixtures" \
  "$APP/Contents/Resources/Brand" \
  "$APP/Contents/Frameworks"

# ---------------------------------------------------------------------------
# App icon: generate Icon.icns from full-bleed brand PNG source.
# ---------------------------------------------------------------------------
ICON_PNG_CANDIDATES=(
  "$ROOT/Assets/Brand/nocturnal-app-icon.png"
  "$ROOT/Sources/Nocturnal/Resources/Brand/nocturnal-app-icon.png"
)
ICON_PNG=""
for candidate in "${ICON_PNG_CANDIDATES[@]}"; do
  if [[ -f "$candidate" ]]; then
    ICON_PNG="$candidate"
    break
  fi
done

ICON_TARGET="$ROOT/build/Icon.icns"
ICONSET_DIR="$ROOT/build/Nocturnal.iconset"
if [[ -n "$ICON_PNG" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  # Standard macOS iconset sizes (1x + 2x).
  declare -a ICON_SIZES=(16 32 128 256 512)
  for size in "${ICON_SIZES[@]}"; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done
  # 32x32@1x is also icon_32x32.png; 16@2x is icon_16x16@2x already covered.
  # iconutil also expects icon_32x32.png (32) and icon_32x32@2x (64) — done above.
  iconutil --convert icns --output "$ICON_TARGET" "$ICONSET_DIR"
  echo "Generated $ICON_TARGET from $ICON_PNG"
elif [[ -f "$ROOT/Icon.icns" ]]; then
  cp "$ROOT/Icon.icns" "$ICON_TARGET"
  echo "Using existing Icon.icns"
else
  echo "WARNING: No app icon source found; CFBundleIconFile may be missing." >&2
  ICON_TARGET=""
fi

# Also keep legacy Icon.icon → icns path if present and we have no PNG.
if [[ -z "${ICON_TARGET}" || ! -f "${ICON_TARGET}" ]]; then
  if [[ -f "$ROOT/Icon.icon" ]]; then
    iconutil --convert icns --output "$ROOT/build/Icon.icns" "$ROOT/Icon.icon" || true
    ICON_TARGET="$ROOT/build/Icon.icns"
  fi
fi

LSUI_VALUE="false"
if [[ "$MENU_BAR_APP" == "1" ]]; then
  LSUI_VALUE="true"
fi

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Nocturnal Contributors. Apache-2.0.</string>
</dict>
</plist>
PLIST

build_product_path() {
  local name="$1"
  local arch="$2"
  case "$arch" in
    arm64|x86_64) echo ".build/${arch}-apple-macosx/$CONF/$name" ;;
    *) echo ".build/$CONF/$name" ;;
  esac
}

verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  local actual_count expected_count
  actual_count=$(wc -w <<<"$actual" | tr -d ' ')
  expected_count=${#expected[@]}
  if [[ "$actual_count" -ne "$expected_count" ]]; then
    echo "ERROR: $binary arch mismatch (expected: ${expected[*]}, actual: ${actual})" >&2
    exit 1
  fi
  for arch in "${expected[@]}"; do
    if [[ "$actual" != *"$arch"* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

install_binary() {
  local name="$1"
  local dest="$2"
  local binaries=()
  for arch in "${ARCH_LIST[@]}"; do
    local src
    src=$(build_product_path "$name" "$arch")
    if [[ ! -f "$src" ]]; then
      echo "ERROR: Missing ${name} build for ${arch} at ${src}" >&2
      exit 1
    fi
    binaries+=("$src")
  done
  if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$dest"
  else
    cp "${binaries[0]}" "$dest"
  fi
  chmod +x "$dest"
  verify_binary_arches "$dest" "${ARCH_LIST[@]}"
}

# Main app binary
install_binary "$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Helper CLIs (used by nocturnal-setup and agent hooks)
install_binary "nocturnal-hook-forwarder" \
  "$APP/Contents/Resources/Helpers/nocturnal-hook-forwarder"
install_binary "nocturnal-setup" \
  "$APP/Contents/Resources/Helpers/nocturnal-setup"

# Also place setup on MacOS path for convenience (optional symlink-style copy)
install_binary "nocturnal-setup" "$APP/Contents/MacOS/nocturnal-setup"
install_binary "nocturnal-hook-forwarder" "$APP/Contents/MacOS/nocturnal-hook-forwarder"

# Bundle app resources (if any). Skip Brand here — copied explicitly below so
# working files (e.g. chroma intermediates) never ship.
APP_RESOURCES_DIR="$ROOT/Sources/$APP_NAME/Resources"
if [[ -d "$APP_RESOURCES_DIR" ]]; then
  # Copy everything except Brand/ (handled by production allow-list).
  shopt -s nullglob dotglob
  for entry in "$APP_RESOURCES_DIR"/*; do
    base=$(basename "$entry")
    if [[ "$base" == "Brand" ]]; then
      continue
    fi
    if [[ -d "$entry" ]]; then
      mkdir -p "$APP/Contents/Resources/$base"
      cp -R "$entry/." "$APP/Contents/Resources/$base/"
    else
      cp "$entry" "$APP/Contents/Resources/"
    fi
  done
  shopt -u nullglob dotglob
fi

# Brand assets — production allow-list only (never recursive Assets/Brand).
# Runtime source of truth: Sources/Nocturnal/Resources/Brand.
BRAND_DEST="$APP/Contents/Resources/Brand"
mkdir -p "$BRAND_DEST"
# Clear any prior contents so only the two production files remain.
rm -rf "${BRAND_DEST:?}/"*
BRAND_PRODUCTION_PNGS=(nocturnal-app-icon.png nocturnal-owl-mark.png)
for name in "${BRAND_PRODUCTION_PNGS[@]}"; do
  if [[ -f "$ROOT/Sources/Nocturnal/Resources/Brand/$name" ]]; then
    cp "$ROOT/Sources/Nocturnal/Resources/Brand/$name" "$BRAND_DEST/$name"
  elif [[ -f "$ROOT/Assets/Brand/$name" ]]; then
    cp "$ROOT/Assets/Brand/$name" "$BRAND_DEST/$name"
  else
    echo "ERROR: missing production brand asset: $name" >&2
    exit 1
  fi
done
BRAND_COUNT=$(find "$BRAND_DEST" -type f | wc -l | tr -d ' ')
if [[ "$BRAND_COUNT" -ne 2 ]]; then
  echo "ERROR: Resources/Brand must contain exactly 2 production PNGs, found ${BRAND_COUNT}:" >&2
  ls -la "$BRAND_DEST" >&2
  exit 1
fi
for name in "${BRAND_PRODUCTION_PNGS[@]}"; do
  if [[ ! -f "$BRAND_DEST/$name" ]]; then
    echo "ERROR: Brand missing required file: $name" >&2
    exit 1
  fi
done

# Ship Codex/Claude simulation fixtures.
if [[ -d "$ROOT/Fixtures" ]]; then
  cp -R "$ROOT/Fixtures/." "$APP/Contents/Resources/Fixtures/"
fi

# SwiftPM resource bundles are emitted next to the built binary.
PREFERRED_BUILD_DIR="$(dirname "$(build_product_path "$APP_NAME" "${ARCH_LIST[0]}")")"
shopt -s nullglob
SWIFTPM_BUNDLES=("${PREFERRED_BUILD_DIR}/"*.bundle)
shopt -u nullglob
if [[ ${#SWIFTPM_BUNDLES[@]} -gt 0 ]]; then
  for bundle in "${SWIFTPM_BUNDLES[@]}"; do
    cp -R "$bundle" "$APP/Contents/Resources/"
  done
fi

# Embed frameworks if any exist in the build folder.
FRAMEWORK_DIRS=(".build/$CONF" ".build/${ARCH_LIST[0]}-apple-macosx/$CONF")
for dir in "${FRAMEWORK_DIRS[@]}"; do
  if compgen -G "${dir}/*.framework" >/dev/null; then
    cp -R "${dir}/"*.framework "$APP/Contents/Frameworks/"
    chmod -R a+rX "$APP/Contents/Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" || true
    break
  fi
done

if [[ -n "${ICON_TARGET}" && -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

chmod -R u+w "$APP"
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
DEFAULT_ENTITLEMENTS="$ENTITLEMENTS_DIR/${APP_NAME}.entitlements"
mkdir -p "$ENTITLEMENTS_DIR"

APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  cat > "$APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Local-only companion; add entitlements only if required. -->
</dict>
</plist>
PLIST
fi

if [[ "$SIGNING_MODE" == "adhoc" || -z "$APP_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "-")
else
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
fi

sign_frameworks() {
  local fw
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    if [[ ! -d "$fw" ]]; then
      continue
    fi
    while IFS= read -r -d '' bin; do
      codesign "${CODESIGN_ARGS[@]}" "$bin"
    done < <(find "$fw" -type f -perm -111 -print0)
    codesign "${CODESIGN_ARGS[@]}" "$fw"
  done
}
sign_frameworks

# Sign helpers before the main bundle.
codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/Resources/Helpers/nocturnal-hook-forwarder"
codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/Resources/Helpers/nocturnal-setup"
codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/MacOS/nocturnal-hook-forwarder"
codesign "${CODESIGN_ARGS[@]}" "$APP/Contents/MacOS/nocturnal-setup"

codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP"

echo "Created $APP"
echo "Helpers: $APP/Contents/Resources/Helpers/"
echo "Icon: $APP/Contents/Resources/Icon.icns"
echo "Brand: $APP/Contents/Resources/Brand/"
ls -la "$APP/Contents/MacOS"
ls -la "$APP/Contents/Resources/Helpers"
ls -la "$APP/Contents/Resources/Brand" 2>/dev/null || true
ls -la "$APP/Contents/Resources/Icon.icns" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true
