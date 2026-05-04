import SwiftUI

struct ArrangementCanvas: View {
    @ObservedObject var coordinator: PlacementCoordinator
    let canvasSize: CGSize
    @State private var dragStartOffset: Int = 0

    var body: some View {
        GeometryReader { geometry in
            let layout = computeScaledLayout(in: geometry.size)
            ZStack(alignment: .topLeading) {
                // Existing displays
                ForEach(coordinator.arrangement) { display in
                    displayBlock(for: display, layout: layout)
                }

                // Placed new display
                if let placedRect = computePlacedRect(layout: layout) {
                    placedDisplayBlock(rect: placedRect, layout: layout)
                }

                // Direction indicators
                if case .anchorSelected(let anchorId) = coordinator.phase {
                    DirectionIndicators(coordinator: coordinator, anchorId: anchorId, layout: layout)
                }

                // Crossing guide
                if let guide = computeCrossingGuide(layout: layout) {
                    Path { path in
                        path.move(to: guide.start)
                        path.addLine(to: guide.end)
                    }
                    .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    // MARK: - Layout Computation

    struct ScaledLayout {
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
    }

    private func computeScaledLayout(in size: CGSize) -> ScaledLayout {
        let allDisplays = coordinator.arrangement
        guard !allDisplays.isEmpty else {
            return ScaledLayout(scale: 1, offsetX: 0, offsetY: 0)
        }

        var minX = allDisplays.map(\.x).min()!
        var minY = allDisplays.map(\.y).min()!
        var maxX = allDisplays.map { $0.x + $0.width }.max()!
        var maxY = allDisplays.map { $0.y + $0.height }.max()!

        // Include the placed display in the bounding box if present
        if let placedBounds = computePlacedBounds() {
            minX = min(minX, placedBounds.x)
            minY = min(minY, placedBounds.y)
            maxX = max(maxX, placedBounds.x + placedBounds.w)
            maxY = max(maxY, placedBounds.y + placedBounds.h)
        }

        let bw = CGFloat(maxX - minX)
        let bh = CGFloat(maxY - minY)
        guard bw > 0, bh > 0 else {
            return ScaledLayout(scale: 1, offsetX: size.width / 2, offsetY: size.height / 2)
        }

        let scale = min(size.width * 0.85 / bw, size.height * 0.85 / bh)
        let ox = (size.width - bw * scale) / 2 - CGFloat(minX) * scale
        let oy = (size.height - bh * scale) / 2 - CGFloat(minY) * scale

        return ScaledLayout(scale: scale, offsetX: ox, offsetY: oy)
    }

    /// Returns the placed display's position in real pixels (before scaling), or nil if not placed.
    private func computePlacedBounds() -> (x: Int, y: Int, w: Int, h: Int)? {
        guard let config = currentConfig,
              let anchor = coordinator.arrangement.first(where: { $0.id == config.anchorName })
        else { return nil }

        let w = coordinator.effectiveNewWidth
        let h = coordinator.effectiveNewHeight
        let px: Int
        let py: Int

        switch config.position {
        case .left:
            px = anchor.x - w
            py = alignY(config.align, offset: config.offset, anchor: anchor, height: h)
        case .right:
            px = anchor.x + anchor.width
            py = alignY(config.align, offset: config.offset, anchor: anchor, height: h)
        case .above:
            py = anchor.y - h
            px = alignX(config.align, offset: config.offset, anchor: anchor, width: w)
        case .below:
            py = anchor.y + anchor.height
            px = alignX(config.align, offset: config.offset, anchor: anchor, width: w)
        }

        return (px, py, w, h)
    }

    func scaledRect(for display: CanvasDisplay, layout: ScaledLayout) -> CGRect {
        CGRect(
            x: CGFloat(display.x) * layout.scale + layout.offsetX,
            y: CGFloat(display.y) * layout.scale + layout.offsetY,
            width: CGFloat(display.width) * layout.scale,
            height: CGFloat(display.height) * layout.scale
        )
    }

    // MARK: - Existing Display Block

    @ViewBuilder
    private func displayBlock(for display: CanvasDisplay, layout: ScaledLayout) -> some View {
        let rect = scaledRect(for: display, layout: layout)
        let isSelected: Bool = {
            if case .anchorSelected(let id) = coordinator.phase { return id == display.id }
            return false
        }()

        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.blue.opacity(0.25) : Color(white: 0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.blue.opacity(0.8) : Color.white.opacity(0.3), lineWidth: 1)
            )
            .overlay(
                VStack(spacing: 2) {
                    Text(display.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                    Text("\(display.width)×\(display.height)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(4)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .shadow(color: isSelected ? .blue.opacity(0.3) : .clear, radius: 10)
            .onTapGesture {
                coordinator.selectAnchor(display.id)
            }
    }

    // MARK: - Placed Display Block

    @ViewBuilder
    private func placedDisplayBlock(rect: CGRect, layout: ScaledLayout) -> some View {
        let config = currentConfig!
        let isVerticalDrag = (config.position == .left || config.position == .right)

        RoundedRectangle(cornerRadius: 6)
            .fill(Color.blue.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.blue.opacity(0.8), lineWidth: 2)
            )
            .overlay(
                VStack(spacing: 4) {
                    Text(coordinator.newDisplay.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.blue.opacity(0.9))
                        .lineLimit(1)
                    Button(action: { coordinator.cycleRotation() }) {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.system(size: 10))
                            .foregroundColor(.blue.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(4)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let delta: CGFloat = isVerticalDrag ? value.translation.height : value.translation.width
                        let pixelDelta = Int(delta / layout.scale)
                        let snapped = ((dragStartOffset + pixelDelta) / 5) * 5
                        coordinator.updateOffset(snapped)
                    }
                    .onEnded { _ in
                        dragStartOffset = coordinator.currentOffset
                    }
            )
            .onAppear { dragStartOffset = coordinator.currentOffset }
            .animation(.easeInOut(duration: 0.15), value: coordinator.phase)
    }

    // MARK: - Placement Math

    private func computePlacedRect(layout: ScaledLayout) -> CGRect? {
        guard let config = currentConfig,
              let anchor = coordinator.arrangement.first(where: { $0.id == config.anchorName })
        else { return nil }

        let w = coordinator.effectiveNewWidth
        let h = coordinator.effectiveNewHeight
        let (px, py): (Int, Int)

        switch config.position {
        case .left:
            px = anchor.x - w
            py = alignY(config.align, offset: config.offset, anchor: anchor, height: h)
        case .right:
            px = anchor.x + anchor.width
            py = alignY(config.align, offset: config.offset, anchor: anchor, height: h)
        case .above:
            py = anchor.y - h
            px = alignX(config.align, offset: config.offset, anchor: anchor, width: w)
        case .below:
            py = anchor.y + anchor.height
            px = alignX(config.align, offset: config.offset, anchor: anchor, width: w)
        }

        return CGRect(
            x: CGFloat(px) * layout.scale + layout.offsetX,
            y: CGFloat(py) * layout.scale + layout.offsetY,
            width: CGFloat(w) * layout.scale,
            height: CGFloat(h) * layout.scale
        )
    }

    private func alignY(_ align: FlexibleDisplay.Alignment, offset: Int, anchor: CanvasDisplay, height h: Int) -> Int {
        switch align {
        case .top: return anchor.y + offset
        case .center: return anchor.y + (anchor.height - h) / 2 + offset
        case .bottom: return anchor.y + anchor.height - h + offset
        default: return anchor.y + offset
        }
    }

    private func alignX(_ align: FlexibleDisplay.Alignment, offset: Int, anchor: CanvasDisplay, width w: Int) -> Int {
        switch align {
        case .left_edge: return anchor.x + offset
        case .center: return anchor.x + (anchor.width - w) / 2 + offset
        case .right_edge: return anchor.x + anchor.width - w + offset
        default: return anchor.x + offset
        }
    }

    // MARK: - Crossing Guide

    struct CrossingGuide {
        let start: CGPoint
        let end: CGPoint
    }

    private func computeCrossingGuide(layout: ScaledLayout) -> CrossingGuide? {
        guard let placedRect = computePlacedRect(layout: layout),
              let config = currentConfig,
              let anchor = coordinator.arrangement.first(where: { $0.id == config.anchorName })
        else { return nil }

        let anchorRect = scaledRect(for: anchor, layout: layout)

        switch config.position {
        case .left, .right:
            let x = config.position == .left ? anchorRect.minX : anchorRect.maxX
            let overlapTop = max(placedRect.minY, anchorRect.minY)
            let overlapBottom = min(placedRect.maxY, anchorRect.maxY)
            guard overlapBottom > overlapTop else { return nil }
            let midY = (overlapTop + overlapBottom) / 2
            return CrossingGuide(start: CGPoint(x: x - 10, y: midY), end: CGPoint(x: x + 10, y: midY))

        case .above, .below:
            let y = config.position == .above ? anchorRect.minY : anchorRect.maxY
            let overlapLeft = max(placedRect.minX, anchorRect.minX)
            let overlapRight = min(placedRect.maxX, anchorRect.maxX)
            guard overlapRight > overlapLeft else { return nil }
            let midX = (overlapLeft + overlapRight) / 2
            return CrossingGuide(start: CGPoint(x: midX, y: y - 10), end: CGPoint(x: midX, y: y + 10))
        }
    }

    private var currentConfig: PlacementConfig? {
        switch coordinator.phase {
        case .placed(let c), .previewing(let c, _): return c
        default: return nil
        }
    }
}
