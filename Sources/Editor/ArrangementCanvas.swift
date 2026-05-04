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

                // Chain icon between placed display and anchor
                if let chainPoint = computeChainPoint(layout: layout) {
                    chainButton(at: chainPoint, action: { coordinator.unchainPlacement() })
                }

                // Chain icons between existing adjacent displays
                existingChainIcons(layout: layout)

                // Direction indicators (only when there are pending displays to place)
                if case .anchorSelected(let anchorId) = coordinator.phase,
                   !coordinator.pendingDisplays.isEmpty {
                    DirectionIndicators(coordinator: coordinator, anchorId: anchorId, layout: layout)
                }

                // Display picker (when multiple pending displays available)
                if case .pickingDisplay(let anchorId, let position) = coordinator.phase {
                    DisplayPicker(
                        coordinator: coordinator,
                        anchorId: anchorId,
                        position: position,
                        layout: layout
                    )
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
        let isBeingFinetuned: Bool = {
            if case .finetuning(_, let id) = coordinator.phase { return id == display.id }
            return false
        }()
        let isSelected: Bool = {
            if case .anchorSelected(let id) = coordinator.phase { return id == display.id }
            return isBeingFinetuned
        }()

        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.blue.opacity(0.25) : Color(white: 0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.blue.opacity(0.8) : Color.white.opacity(0.3),
                        lineWidth: 1
                    )
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
            .contentShape(Rectangle())
            .onTapGesture {
                guard !display.isBuiltin else { return }
                coordinator.handleDisplayTap(display.id)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard case .finetuning(let config, let editId) = coordinator.phase,
                              editId == display.id else { return }
                        let isVerticalDrag = (config.position == .left || config.position == .right)
                        let delta: CGFloat = isVerticalDrag ? value.translation.height : value.translation.width
                        let pixelDelta = Int(delta / layout.scale)
                        let snapped = ((dragStartOffset + pixelDelta) / 5) * 5
                        coordinator.updateOffset(snapped)
                    }
                    .onEnded { _ in
                        guard case .finetuning = coordinator.phase else { return }
                        dragStartOffset = coordinator.currentOffset
                    }
            )
            .position(x: rect.midX, y: rect.midY)
            .shadow(color: isSelected ? .blue.opacity(0.3) : .clear, radius: 10)
            .onChange(of: isBeingFinetuned) { _, finetuning in
                if finetuning { dragStartOffset = coordinator.currentOffset }
            }
    }

    // MARK: - Placed Display Block

    @ViewBuilder
    private func placedDisplayBlock(rect: CGRect, layout: ScaledLayout) -> some View {
        let config = currentConfig!
        let isVerticalDrag = (config.position == .left || config.position == .right)
        let displayName = coordinator.activePending?.name ?? ""

        RoundedRectangle(cornerRadius: 6)
            .fill(Color.blue.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.blue.opacity(0.8), lineWidth: 2)
            )
            .overlay(
                VStack(spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.blue.opacity(0.9))
                        .lineLimit(1)
                    Button(action: { coordinator.cycleRotation() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(.blue.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(4)
            )
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .onTapGesture { coordinator.confirmPlacement() }
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
            .position(x: rect.midX, y: rect.midY)
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

    // MARK: - Chain Buttons

    @ViewBuilder
    private func chainButton(at point: CGPoint, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color.yellow.opacity(0.4))
                .frame(width: 20, height: 20)
                .background(Color.yellow.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .position(x: point.x, y: point.y)
        .transition(.scale.combined(with: .opacity))
    }

    /// Chain icons between existing adjacent displays in the arrangement.
    @ViewBuilder
    private func existingChainIcons(layout: ScaledLayout) -> some View {
        let pairs = coordinator.adjacentPairs()
        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
            if let point = computeExistingChainPoint(pair: pair, layout: layout) {
                chainButton(at: point, action: {
                    coordinator.unchainExistingDisplay(pair.displayB)
                })
            }
        }
    }

    private func computeExistingChainPoint(pair: PlacementCoordinator.AdjacentPair, layout: ScaledLayout) -> CGPoint? {
        guard let displayA = coordinator.arrangement.first(where: { $0.id == pair.displayA }),
              let displayB = coordinator.arrangement.first(where: { $0.id == pair.displayB })
        else { return nil }

        let rectA = scaledRect(for: displayA, layout: layout)
        let rectB = scaledRect(for: displayB, layout: layout)

        switch pair.edge {
        case .above:
            // B is above A → shared edge at A.minY / B.maxY
            let y = rectA.minY
            let overlapLeft = max(rectA.minX, rectB.minX)
            let overlapRight = min(rectA.maxX, rectB.maxX)
            guard overlapRight > overlapLeft else { return nil }
            return CGPoint(x: (overlapLeft + overlapRight) / 2, y: y)
        case .below:
            let y = rectA.maxY
            let overlapLeft = max(rectA.minX, rectB.minX)
            let overlapRight = min(rectA.maxX, rectB.maxX)
            guard overlapRight > overlapLeft else { return nil }
            return CGPoint(x: (overlapLeft + overlapRight) / 2, y: y)
        case .left:
            let x = rectA.minX
            let overlapTop = max(rectA.minY, rectB.minY)
            let overlapBottom = min(rectA.maxY, rectB.maxY)
            guard overlapBottom > overlapTop else { return nil }
            return CGPoint(x: x, y: (overlapTop + overlapBottom) / 2)
        case .right:
            let x = rectA.maxX
            let overlapTop = max(rectA.minY, rectB.minY)
            let overlapBottom = min(rectA.maxY, rectB.maxY)
            guard overlapBottom > overlapTop else { return nil }
            return CGPoint(x: x, y: (overlapTop + overlapBottom) / 2)
        }
    }

    // Chain point for the placed display ↔ anchor
    private func computeChainPoint(layout: ScaledLayout) -> CGPoint? {
        guard let config = currentConfig,
              let anchor = coordinator.arrangement.first(where: { $0.id == config.anchorName }),
              let placedRect = computePlacedRect(layout: layout)
        else { return nil }

        let anchorRect = scaledRect(for: anchor, layout: layout)

        switch config.position {
        case .left:
            let x = anchorRect.minX
            let overlapTop = max(placedRect.minY, anchorRect.minY)
            let overlapBottom = min(placedRect.maxY, anchorRect.maxY)
            guard overlapBottom > overlapTop else { return nil }
            return CGPoint(x: x, y: (overlapTop + overlapBottom) / 2)
        case .right:
            let x = anchorRect.maxX
            let overlapTop = max(placedRect.minY, anchorRect.minY)
            let overlapBottom = min(placedRect.maxY, anchorRect.maxY)
            guard overlapBottom > overlapTop else { return nil }
            return CGPoint(x: x, y: (overlapTop + overlapBottom) / 2)
        case .above:
            let y = anchorRect.minY
            let overlapLeft = max(placedRect.minX, anchorRect.minX)
            let overlapRight = min(placedRect.maxX, anchorRect.maxX)
            guard overlapRight > overlapLeft else { return nil }
            return CGPoint(x: (overlapLeft + overlapRight) / 2, y: y)
        case .below:
            let y = anchorRect.maxY
            let overlapLeft = max(placedRect.minX, anchorRect.minX)
            let overlapRight = min(placedRect.maxX, anchorRect.maxX)
            guard overlapRight > overlapLeft else { return nil }
            return CGPoint(x: (overlapLeft + overlapRight) / 2, y: y)
        }
    }

    private var currentConfig: PlacementConfig? {
        switch coordinator.phase {
        case .placed(let c): return c
        default: return nil
        }
    }
}
