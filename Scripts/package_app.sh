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
# App icon: stage-aware (production | staging | dev).
# Prefer pre-generated Assets/AppIcons/<stage>/Icon.icns (Scripts/generate_app_icons.sh).
# ---------------------------------------------------------------------------
# CONF=debug → dev icon; release → production unless NOCTURNAL_ICON_STAGE overrides.
ICON_STAGE="${NOCTURNAL_ICON_STAGE:-}"
if [[ -z "$ICON_STAGE" ]]; then
  if [[ "$CONF" == "debug" ]]; then
    ICON_STAGE="dev"
  else
    ICON_STAGE="production"
  fi
fi
case "$ICON_STAGE" in
  production|staging|dev) ;;
  *)
    echo "WARNING: unknown NOCTURNAL_ICON_STAGE='$ICON_STAGE'; using production" >&2
    ICON_STAGE="production"
    ;;
esac

case "$ICON_STAGE" in
  production) APP_DISPLAY_NAME="${APP_NAME}" ;;
  staging)    APP_DISPLAY_NAME="${APP_NAME} (Staging)" ;;
  dev)        APP_DISPLAY_NAME="${APP_NAME} (Dev)" ;;
esac

ICON_TARGET="$ROOT/build/Icon.icns"
ICONSET_DIR="$ROOT/build/Nocturnal.iconset"
PREBUILT_ICNS="$ROOT/Assets/AppIcons/${ICON_STAGE}/Icon.icns"
PREBUILT_PNG="$ROOT/Assets/AppIcons/${ICON_STAGE}/AppIcon.png"

if [[ -f "$PREBUILT_ICNS" ]]; then
  cp "$PREBUILT_ICNS" "$ICON_TARGET"
  echo "Using prebuilt ${ICON_STAGE} icon: $PREBUILT_ICNS"
elif [[ -f "$PREBUILT_PNG" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PREBUILT_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PREBUILT_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil --convert icns --output "$ICON_TARGET" "$ICONSET_DIR"
  echo "Generated $ICON_TARGET from $PREBUILT_PNG (${ICON_STAGE})"
else
  # Fallback: brand PNG (unbadged production art).
  ICON_PNG=""
  for candidate in \
    "$ROOT/Sources/Nocturnal/Resources/Brand/nocturnal-app-icon.png" \
    "$ROOT/Assets/Brand/nocturnal-app-icon.png"
  do
    if [[ -f "$candidate" ]]; then ICON_PNG="$candidate"; break; fi
  done
  if [[ -n "$ICON_PNG" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    for size in 16 32 128 256 512; do
      sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
      double=$((size * 2))
      sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil --convert icns --output "$ICON_TARGET" "$ICONSET_DIR"
    echo "Generated $ICON_TARGET from brand PNG (no stage set under Assets/AppIcons)"
  elif [[ -f "$ROOT/Icon.icns" ]]; then
    cp "$ROOT/Icon.icns" "$ICON_TARGET"
    echo "Using existing Icon.icns"
  else
    echo "WARNING: No app icon source found; CFBundleIconFile may be missing." >&2
    ICON_TARGET=""
  fi
fi

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
    <key>CFBundleDisplayName</key><string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>NocturnalIconStage</key><string>${ICON_STAGE}</string>
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
rm -rf "${BRAND_DEST:?}/"*
# Core marks + monochrome agent product icons.
BRAND_PRODUCTION_PNGS=(
  nocturnal-app-icon.png
  nocturnal-owl-mark.png
  agent-openai.png
  agent-claude.png
  agent-opencode.png
  agent-cursor.png
  agent-grok.png
)
for name in "${BRAND_PRODUCTION_PNGS[@]}"; do
  if [[ -f "$ROOT/Sources/Nocturnal/Resources/Brand/$name" ]]; then
    cp "$ROOT/Sources/Nocturnal/Resources/Brand/$name" "$BRAND_DEST/$name"
  elif [[ -f "$ROOT/Assets/Brand/$name" ]]; then
    cp "$ROOT/Assets/Brand/$name" "$BRAND_DEST/$name"
  elif [[ "$name" == "agent-grok.png" && -f "$ROOT/Assets/Brand/grok.png" ]]; then
    # Canonical Grok mark lives at Assets/Brand/grok.png; convert-ish copy for runtime name.
    cp "$ROOT/Assets/Brand/grok.png" "$BRAND_DEST/$name"
  else
    echo "ERROR: missing production brand asset: $name" >&2
    exit 1
  fi
done
EXPECTED_BRAND_COUNT=${#BRAND_PRODUCTION_PNGS[@]}
BRAND_COUNT=$(find "$BRAND_DEST" -type f | wc -l | tr -d ' ')
if [[ "$BRAND_COUNT" -ne "$EXPECTED_BRAND_COUNT" ]]; then
  echo "ERROR: Resources/Brand must contain exactly ${EXPECTED_BRAND_COUNT} production PNGs, found ${BRAND_COUNT}:" >&2
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

# ---------------------------------------------------------------------------
# Framework packaging (architecture-safe)
#
# Policy (documented choice):
# - Nocturnal currently ships **zero** third-party frameworks. Empty Frameworks/
#   is expected and not an error.
# - When frameworks appear under a build product dir, require the same basenames
#   for every arch in ARCH_LIST; fail clearly on partial coverage.
# - Single-arch: copy frameworks as-is.
# - Multi-arch (universal): copy structure from the first arch, then `lipo -create`
#   matching framework Mach-O binaries (top-level + nested *.framework binaries).
#   Discovery uses file(1) Mach-O detection — not the +x bit — because valid
#   framework payloads may lack execute permission after copy or from third parties.
# - Do not silently copy only one architecture into a multi-arch app bundle.
# ---------------------------------------------------------------------------
lipo_framework_tree() {
  # dest_fw is already a copy of sources[0]; replace Mach-O slices with lipo merges.
  local dest_fw="$1"
  shift
  local sources=("$@")

  # Enumerate regular files; filter to Mach-O via file(1). Do not require -perm -111:
  # non-executable Mach-O framework binaries are still valid lipo inputs.
  while IFS= read -r -d '' dest_bin; do
    # Only merge real Mach-O files (skip plists, scripts, resources).
    if ! file "$dest_bin" | grep -q 'Mach-O'; then
      continue
    fi
    local rel="${dest_bin#"$dest_fw"/}"
    local bins=()
    local src
    for src in "${sources[@]}"; do
      local candidate="$src/$rel"
      if [[ ! -f "$candidate" ]]; then
        echo "ERROR: framework binary missing for arch merge: $candidate" >&2
        exit 1
      fi
      bins+=("$candidate")
    done
    lipo -create "${bins[@]}" -output "$dest_bin"
    verify_binary_arches "$dest_bin" "${ARCH_LIST[@]}"
  done < <(find "$dest_fw" -type f -print0 2>/dev/null)
}

embed_frameworks() {
  local dest="$APP/Contents/Frameworks"
  mkdir -p "$dest"

  local arch_dirs=()
  local arch
  for arch in "${ARCH_LIST[@]}"; do
    arch_dirs+=("$(dirname "$(build_product_path "$APP_NAME" "$arch")")")
  done

  # Union of framework basenames across arch build dirs (bash 3.2-safe).
  local names_file
  names_file=$(mktemp)
  local dir fw base
  for dir in "${arch_dirs[@]}"; do
    shopt -s nullglob
    for fw in "$dir"/*.framework; do
      basename "$fw" >>"$names_file"
    done
    shopt -u nullglob
  done

  if [[ ! -s "$names_file" ]]; then
    rm -f "$names_file"
    echo "Frameworks: none (OK — product does not bundle third-party frameworks)"
    return 0
  fi

  local unique_names
  unique_names=$(sort -u "$names_file")
  rm -f "$names_file"
  local name_count
  name_count=$(printf '%s\n' "$unique_names" | grep -c . || true)
  echo "Frameworks: packaging ${name_count} bundle(s) for arch(es): ${ARCH_LIST[*]}"

  while IFS= read -r base; do
    [[ -z "$base" ]] && continue
    local sources=()
    for dir in "${arch_dirs[@]}"; do
      if [[ -d "$dir/$base" ]]; then
        sources+=("$dir/$base")
      else
        echo "ERROR: framework $base missing under $dir (required for arch(es): ${ARCH_LIST[*]})" >&2
        if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
          echo "ERROR: refusing to ship a partial-arch framework set inside a multi-arch app." >&2
        fi
        exit 1
      fi
    done

    rm -rf "$dest/$base"
    if [[ ${#ARCH_LIST[@]} -eq 1 ]]; then
      cp -R "${sources[0]}" "$dest/$base"
    else
      cp -R "${sources[0]}" "$dest/$base"
      lipo_framework_tree "$dest/$base" "${sources[@]}"
    fi
  done <<<"$unique_names"

  chmod -R a+rX "$dest"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" || true
}

embed_frameworks

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
    # Match lipo_framework_tree: sign Mach-O payloads even when they lack +x.
    while IFS= read -r -d '' bin; do
      if file "$bin" | grep -q 'Mach-O'; then
        codesign "${CODESIGN_ARGS[@]}" "$bin"
      fi
    done < <(find "$fw" -type f -print0)
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
