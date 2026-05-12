#!/usr/bin/env bash
# Regenerates the macOS app icon: paints a 1024px master via a tiny Swift
# program, resizes to all 10 sizes the asset catalog wants, drops them into
# AppIcon.appiconset, and rewrites Contents.json so Xcode picks them up.
# Run after editing the design in this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$REPO_ROOT/Dream Of Spring/Dream Of Spring/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d -t dos-icon)"
trap 'rm -rf "$WORK"' EXIT

SWIFT_SOURCE="$WORK/gen.swift"
MASTER="$WORK/icon-1024.png"

cat > "$SWIFT_SOURCE" <<'SWIFT_EOF'
import AppKit
import CoreGraphics

let outputPath = CommandLine.arguments[1]
let px = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: px,
    pixelsHigh: px,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let size = CGFloat(px)

// Background: vertical gradient — pre-dawn sky.
let bgColors = [
    NSColor(srgbRed: 0.94, green: 0.71, blue: 0.62, alpha: 1.0).cgColor, // peach (top)
    NSColor(srgbRed: 0.81, green: 0.68, blue: 0.85, alpha: 1.0).cgColor, // lavender
    NSColor(srgbRed: 0.55, green: 0.69, blue: 0.88, alpha: 1.0).cgColor  // soft blue (bottom)
] as CFArray
let locations: [CGFloat] = [0.0, 0.45, 1.0]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: locations)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Crescent moon — drawn as one circle, then a second circle subtracted
// with destination-out to carve out the crescent shape.
let moonDiameter = size * 0.58
let moonOrigin = CGPoint(x: (size - moonDiameter) / 2, y: (size - moonDiameter) / 2 + size * 0.02)
let moonRect = CGRect(origin: moonOrigin, size: CGSize(width: moonDiameter, height: moonDiameter))

// Soft glow under the moon
ctx.saveGState()
let glowRect = moonRect.insetBy(dx: -size * 0.05, dy: -size * 0.05)
let glowColors = [
    NSColor(srgbRed: 1.0, green: 0.97, blue: 0.88, alpha: 0.35).cgColor,
    NSColor(srgbRed: 1.0, green: 0.97, blue: 0.88, alpha: 0.0).cgColor
] as CFArray
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1])!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: moonRect.midX, y: moonRect.midY), startRadius: 0,
    endCenter: CGPoint(x: moonRect.midX, y: moonRect.midY), endRadius: glowRect.width / 2,
    options: []
)
ctx.restoreGState()

// Moon: a transparency layer so destinationOut only carves through the
// moon disc, not through the background gradient underneath.
let moonColor = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.88, alpha: 1.0).cgColor
let crescentOffset = moonDiameter * 0.28
let cutRect = moonRect.offsetBy(dx: crescentOffset, dy: crescentOffset * 0.45)

ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(moonColor)
ctx.fillEllipse(in: moonRect)
ctx.setBlendMode(.destinationOut)
ctx.fillEllipse(in: cutRect)
ctx.setBlendMode(.normal)
ctx.endTransparencyLayer()

// Two small stars for accent
let starColor = NSColor(srgbRed: 1.0, green: 0.98, blue: 0.92, alpha: 0.85).cgColor
ctx.setFillColor(starColor)
func drawStar(at point: CGPoint, radius: CGFloat) {
    // Four-pointed star (sparkle): two overlapping diamonds
    let path = CGMutablePath()
    let armLong = radius
    let armShort = radius * 0.28
    path.move(to: CGPoint(x: point.x, y: point.y + armLong))
    path.addLine(to: CGPoint(x: point.x + armShort, y: point.y + armShort))
    path.addLine(to: CGPoint(x: point.x + armLong, y: point.y))
    path.addLine(to: CGPoint(x: point.x + armShort, y: point.y - armShort))
    path.addLine(to: CGPoint(x: point.x, y: point.y - armLong))
    path.addLine(to: CGPoint(x: point.x - armShort, y: point.y - armShort))
    path.addLine(to: CGPoint(x: point.x - armLong, y: point.y))
    path.addLine(to: CGPoint(x: point.x - armShort, y: point.y + armShort))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.fillPath()
}
drawStar(at: CGPoint(x: size * 0.78, y: size * 0.84), radius: size * 0.04)
drawStar(at: CGPoint(x: size * 0.20, y: size * 0.74), radius: size * 0.025)

NSGraphicsContext.restoreGraphicsState()

let pngData = rep.representation(using: .png, properties: [:])!
try pngData.write(to: URL(fileURLWithPath: outputPath))
SWIFT_EOF

echo "==> Rendering master 1024×1024…"
xcrun swift "$SWIFT_SOURCE" "$MASTER"

# Sizes the asset catalog asks for, as (filename, pixels) pairs.
SIZES=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

echo "==> Resizing into $ICONSET …"
# Clear out any old PNGs first so we don't leave stragglers behind.
find "$ICONSET" -name '*.png' -delete

for pair in "${SIZES[@]}"; do
    name="${pair%%:*}"
    px="${pair##*:}"
    out="$ICONSET/$name"
    if [[ "$px" == "1024" ]]; then
        cp "$MASTER" "$out"
    else
        sips -s format png -z "$px" "$px" "$MASTER" --out "$out" >/dev/null
    fi
    echo "   $name (${px}px)"
done

echo "==> Updating Contents.json…"
cat > "$ICONSET/Contents.json" <<'JSON_EOF'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON_EOF

echo
echo "Done. Rebuild to see the icon (scripts/install.sh, or open in Xcode and ⌘R)."
