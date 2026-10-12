#!/usr/bin/env bash
# Builds the SPM executable (module `mcp_client`) and wraps it into a proper
# .app bundle — "Faceless MCP Client.app" — with an Info.plist (ATS relaxed for
# cleartext http:// dev servers) and the app icon rendered from
# icons/AppIcon-1024.svg.
#
# Usage:  bash build.sh [debug|release]   (default: release)
#
# Release is the default and the bundle is stripped: no debug info, no local
# symbols. `swift run mcp_client` is the debuggable dev loop.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Faceless MCP Client"
EXECUTABLE="mcp_client"
BUNDLE_ID="dev.dinos.mcp-client"
APP_DIR="build/${APP_NAME}.app"

# The version is single-sourced in AppInfo.version (Models.swift) — build.sh
# stamps it into the Info.plist, so a release is cut by editing one line.
VERSION="$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' \
  Sources/mcp_client/Models/Models.swift | head -n1)"
if [[ -z "${VERSION}" ]]; then
  echo "!! cannot read AppInfo.version from Sources/mcp_client/Models/Models.swift" >&2
  exit 1
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"
BIN="$(swift build -c "${CONFIG}" --show-bin-path)/${EXECUTABLE}"

echo "==> bundling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE}"

# No debug info ships in the bundle. SwiftPM hands a release build line tables
# as well, and the linked binary carries its symbol table: strip both. (This
# runs before codesign, which signs what is actually on disk.)
echo "==> stripping ${EXECUTABLE}"
STRIP_TARGET="${APP_DIR}/Contents/MacOS/${EXECUTABLE}"
strip -x -S "${STRIP_TARGET}" 2>/dev/null || strip "${STRIP_TARGET}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>        <string>${EXECUTABLE}</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- debug tool: must be able to reach http:// dev servers, not just localhost -->
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

# --- App icon: SVG -> PNG -> .iconset (all sizes) -> AppIcon.icns ---------
# Source of truth: icons/AppIcon-1024.svg (the same server.rack tile the app
# draws for servers that announce no icon). The 1024px PNG is re-rendered
# from it on every build — edit the SVG, rebuild, done.
# (If the SVG is ever removed, an existing PNG is used as-is.)
# macOS does NOT round icon corners itself, so the artwork carries the
# rounded-square shape and transparent padding already.
ICON_SVG="icons/AppIcon-1024.svg"
ICON_SRC="icons/AppIcon-1024.png"
if [[ -f "${ICON_SVG}" ]]; then
  echo "==> rendering ${ICON_SRC} from ${ICON_SVG}"
  sips -s format png "${ICON_SVG}" -z 1024 1024 --out "${ICON_SRC}" >/dev/null
fi
if [[ -f "${ICON_SRC}" ]]; then
  echo "==> building AppIcon.icns"
  ICONSET="build/AppIcon.iconset"
  rm -rf "${ICONSET}"
  mkdir -p "${ICONSET}"
  sips -z 16 16     "${ICON_SRC}" --out "${ICONSET}/icon_16x16.png"      >/dev/null
  sips -z 32 32     "${ICON_SRC}" --out "${ICONSET}/icon_16x16@2x.png"   >/dev/null
  sips -z 32 32     "${ICON_SRC}" --out "${ICONSET}/icon_32x32.png"      >/dev/null
  sips -z 64 64     "${ICON_SRC}" --out "${ICONSET}/icon_32x32@2x.png"   >/dev/null
  sips -z 128 128   "${ICON_SRC}" --out "${ICONSET}/icon_128x128.png"    >/dev/null
  sips -z 256 256   "${ICON_SRC}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "${ICON_SRC}" --out "${ICONSET}/icon_256x256.png"    >/dev/null
  sips -z 512 512   "${ICON_SRC}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "${ICON_SRC}" --out "${ICONSET}/icon_512x512.png"    >/dev/null
  cp "${ICON_SRC}" "${ICONSET}/icon_512x512@2x.png"
  iconutil -c icns "${ICONSET}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
  rm -rf "${ICONSET}"
else
  echo "!! no icon source (${ICON_SVG} / ${ICON_SRC}) — bundling without an app icon"
fi

# Ad-hoc signature (keeps TCC/Keychain identifiers stable across rebuilds).
codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "==> done: $(pwd)/${APP_DIR}"
open "${APP_DIR}"
