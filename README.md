# DisplayAlign

A native macOS menubar app that automatically arranges external monitors when connected. No external dependencies — uses CoreGraphics directly.

## Install

```sh
brew install --cask sassman/tap/display-align
```

Or build from source:

```sh
./bundle.sh
# Installs to ~/Applications/DisplayAlign.app
```

Add to Login Items (System Settings → General → Login Items) for auto-start.

## Config

`~/.config/display-align/config.json`

On first run, the config is seeded with a single stacked display. Edit the file to change behavior — the app reads it on startup and when displays change.

### Stacked (simple)

Displays in `stacked` are centered above the built-in MacBook screen. No further configuration needed.

```json
{
  "stacked": [
    { "name": "DELL P3424WEB", "vendor": 4268, "model": 17092 }
  ],
  "ignored": [],
  "flexible": []
}
```

```
       ┌──────────────────┐
       │  DELL P3424WEB   │
       └──────────────────┘
            ┌────────┐
            │MacBook │
            └────────┘
```

### Flexible (relative positioning)

Displays in `flexible` are placed relative to another display with pixel-precise offset tuning.

| Field | Values | Meaning |
|-------|--------|---------|
| `position` | `above`, `below`, `left`, `right` | Which side of the reference display |
| `relative_to` | `"builtin"` or a display name | The anchor display |
| `align` | `top`, `center`, `bottom` | Which edge of `relative_to` to align against |
| `offset` | integer (pixels) | Shift from the `align` anchor. Positive = down (for left/right) or right (for above/below) |
| `rotation` | `0`, `90`, `270` | Informational (set rotation via System Settings) |

### Example: portrait monitor left of a stacked ultrawide

```json
{
  "stacked": [
    { "name": "DELL P3424WEB", "vendor": 4268, "model": 17092 }
  ],
  "ignored": [],
  "flexible": [
    {
      "name": "LG 27UP850", "vendor": 220, "model": 5531,
      "position": "left",
      "relative_to": "DELL P3424WEB",
      "align": "top",
      "offset": 120,
      "rotation": 90
    }
  ]
}
```

The LG is positioned to the left of the Dell, with its top edge 120px below the Dell's top edge:

```
        DELL P3424WEB (relative_to)
        ┌──────────────────┐  ← align: "top" (offset: 0 would start here)
        │                  │
        │                  │  ← offset: 120 (LG top starts here)
  ┌───┐ │                  │
  │   │ │                  │
  │ L │ │                  │
  │ G │ └──────────────────┘
  │   │      ┌────────┐
  └───┘      │MacBook │
             └────────┘
```

This ensures the mouse travels in a straight horizontal line from the Dell's right portion into the LG at the same Y coordinate. Tune `offset` until the crossing feels right.

### Ignored

Displays in `ignored` are left alone — the app won't move them or prompt about them.

## Unknown displays

When a display is connected that isn't in any list, the app shows a prompt:

- **Stack Above** → adds to `stacked`
- **Ignore** → adds to `ignored`

To change a decision or move a display to `flexible`, edit the config file directly. The menubar menu has an "Open Config..." item for quick access.

## Finding vendor/model IDs

Connect the display and check the prompt — it shows the vendor and model numbers. Or run:

```sh
cat <<'EOF' | swift -
import CoreGraphics
var ids = [CGDirectDisplayID](repeating: 0, count: 8)
var count: UInt32 = 0
CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
for i in 0..<Int(count) {
    let id = ids[i]
    let builtin = CGDisplayIsBuiltin(id) != 0 ? " (builtin)" : ""
    print("Display \(id): vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id))\(builtin)")
}
EOF
```

## Build from source

Requires macOS 14+ and Swift 5.9+.

```sh
swift build -c release
./bundle.sh
```
