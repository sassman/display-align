#!/usr/bin/env swift
// Renders the SF Symbol "display.2" into an .iconset and converts to .icns
import AppKit

let iconsetPath = "/tmp/DisplayAlign.iconset"
let icnsPath = "/tmp/DisplayAlign.icns"

// Required icon sizes: (filename, point size, scale)
let sizes: [(String, CGFloat, CGFloat)] = [
    ("icon_16x16.png",      16,  1),
    ("icon_16x16@2x.png",   16,  2),
    ("icon_32x32.png",      32,  1),
    ("icon_32x32@2x.png",   32,  2),
    ("icon_128x128.png",    128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png",    256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png",    512, 1),
    ("icon_512x512@2x.png", 512, 2),
]

try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (filename, pointSize, scale) in sizes {
    let pixelSize = pointSize * scale
    let config = NSImage.SymbolConfiguration(pointSize: pointSize * 0.7, weight: .regular)
    guard let symbol = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        print("Failed to create symbol")
        exit(1)
    }

    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    image.lockFocus()
    NSColor.white.setFill()

    // Draw symbol centered
    let symbolSize = symbol.size
    let x = (pixelSize - symbolSize.width) / 2
    let y = (pixelSize - symbolSize.height) / 2
    symbol.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to render \(filename)")
        exit(1)
    }

    let filePath = (iconsetPath as NSString).appendingPathComponent(filename)
    try! png.write(to: URL(fileURLWithPath: filePath))
}

print("Iconset created at \(iconsetPath)")
