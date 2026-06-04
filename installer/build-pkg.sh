#!/bin/bash
set -e

# INVOX Print Agent — Build & Package Script
# Produces: dist/InvoxPrintAgent.pkg

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_DIR="$PROJECT_DIR/InvoxPrintAgent"
INSTALLER_DIR="$PROJECT_DIR/installer"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="INVOX Print Agent"
BUNDLE_ID="com.invox.printagent"
VERSION="1.0.0"

echo "=== Building INVOX Print Agent v${VERSION} ==="

# 1. Build release binary
echo "[1/4] Compiling release binary..."
cd "$AGENT_DIR"
swift build -c release 2>&1 | tail -3
BINARY="$AGENT_DIR/.build/release/InvoxPrintAgent"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Build failed. Binary not found."
    exit 1
fi
echo "  Binary: $(du -h "$BINARY" | awk '{print $1}')"

# 2. Create .app bundle
echo "[2/4] Creating app bundle..."
APP_DIR="$DIST_DIR/${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/InvoxPrintAgent"

# Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>InvoxPrintAgent</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Copy resources
cp "$INSTALLER_DIR/com.invox.printagent.plist" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/cups-backend/INVOX-IPP.ppd" "$APP_DIR/Contents/Resources/"

echo "  App: $APP_DIR"

# 3. Create pkg payload
echo "[3/4] Building .pkg installer..."
PKG_ROOT="$DIST_DIR/pkg-root"
PKG_SCRIPTS="$DIST_DIR/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"

# Payload: app goes into /Applications
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP_DIR" "$PKG_ROOT/Applications/"

# Scripts
mkdir -p "$PKG_SCRIPTS"
cp "$INSTALLER_DIR/postinstall" "$PKG_SCRIPTS/"
chmod +x "$PKG_SCRIPTS/postinstall"

# 4. Build .pkg
PKG_OUTPUT="$DIST_DIR/InvoxPrintAgent-${VERSION}.pkg"
pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$PKG_OUTPUT"

echo "[4/4] Done!"
echo ""
echo "=== Output ==="
echo "  App:     $APP_DIR"
echo "  Package: $PKG_OUTPUT"
echo "  Size:    $(du -h "$PKG_OUTPUT" | awk '{print $1}')"
echo ""
echo "To install: open $PKG_OUTPUT"
echo "Or: sudo installer -pkg $PKG_OUTPUT -target /"

# Cleanup temp dirs
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
