#!/bin/bash
# Builds SwitchClaude.app. Usage: ./build.sh            -> build/SwitchClaude.app
#                                ./build.sh --install  -> also copies it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install"
  exit 1
fi

ARCH="$(uname -m)"
APP="build/SwitchClaude.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling for ${ARCH}..."
swiftc -O -parse-as-library -swift-version 5 \
  -target "${ARCH}-apple-macos12.0" \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
  Sources/*.swift -o "$APP/Contents/MacOS/SwitchClaude"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Simple app icon: a stack of coloured circles, drawn with the system's own tools.
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
cat > build/icon.swift <<'SWIFT'
import AppKit
let out = CommandLine.arguments[1]
let specs: [(String, Int)] = [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),
  ("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)]
let colours: [NSColor] = [NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                          NSColor(srgbRed: 0.0, green: 0.56, blue: 1.0, alpha: 1),
                          NSColor(srgbRed: 0.19, green: 0.64, blue: 0.42, alpha: 1)]
for (name, px) in specs {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px)
  let bg = NSRect(x: s*0.1, y: s*0.1, width: s*0.8, height: s*0.8)
  NSColor(white: 0.12, alpha: 1).setFill()
  NSBezierPath(roundedRect: bg, xRadius: s*0.18, yRadius: s*0.18).fill()
  let d = s*0.3
  for (i, c) in colours.enumerated() {
    let x = s*0.2 + CGFloat(i)*s*0.15
    let r = NSRect(x: x, y: s*0.5 - d/2, width: d, height: d)
    c.setFill(); NSBezierPath(ovalIn: r).fill()
    NSColor(white: 0.12, alpha: 1).setStroke()
    let p = NSBezierPath(ovalIn: r); p.lineWidth = max(1, s*0.02); p.stroke()
  }
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
SWIFT
if swiftc -O build/icon.swift -o build/makeicon 2>/dev/null && build/makeicon "$ICONSET" \
   && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "(Skipped app icon - not essential.)"
fi

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/SwitchClaude.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/SwitchClaude.app"
  open "$HOME/Applications/SwitchClaude.app"
fi
