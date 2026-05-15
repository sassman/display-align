import SwiftUI

struct DirectionIndicators: View {
    @ObservedObject var coordinator: PlacementCoordinator
    let anchorId: String
    let layout: ArrangementCanvas.ScaledLayout

    var body: some View {
        let freeEdges = coordinator.freeEdges(for: anchorId)
        let anchor = coordinator.arrangement.first(where: { $0.id == anchorId })

        if let anchor = anchor {
            let rect = CGRect(
                x: CGFloat(anchor.x) * layout.scale + layout.offsetX,
                y: CGFloat(anchor.y) * layout.scale + layout.offsetY,
                width: CGFloat(anchor.width) * layout.scale,
                height: CGFloat(anchor.height) * layout.scale
            )

            ForEach(freeEdges, id: \.rawValue) { edge in
                let pos = indicatorPosition(edge: edge, rect: rect)

                Button(action: { coordinator.placeDisplay(position: edge) }) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                        Circle()
                            .strokeBorder(
                                Color.blue.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                        Text(glyph(edge))
                            .font(.system(size: 14))
                            .foregroundColor(.blue.opacity(0.8))
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .position(x: pos.x, y: pos.y)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func indicatorPosition(edge: FlexibleDisplay.Position, rect: CGRect) -> CGPoint {
        switch edge {
        case .above: return CGPoint(x: rect.midX, y: rect.minY - 24)
        case .below: return CGPoint(x: rect.midX, y: rect.maxY + 24)
        case .left: return CGPoint(x: rect.minX - 24, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX + 24, y: rect.midY)
        }
    }

    private func glyph(_ edge: FlexibleDisplay.Position) -> String {
        switch edge {
        case .above: return "↑"
        case .below: return "↓"
        case .left: return "←"
        case .right: return "→"
        }
    }
}
