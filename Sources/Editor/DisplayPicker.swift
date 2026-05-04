import SwiftUI

/// Inline picker that appears when multiple pending displays are available.
/// Shows each candidate as a small display block with name and resolution.
struct DisplayPicker: View {
    @ObservedObject var coordinator: PlacementCoordinator
    let anchorId: String
    let position: FlexibleDisplay.Position
    let layout: ArrangementCanvas.ScaledLayout

    var body: some View {
        let pickerPosition = computePickerPosition()

        VStack(spacing: 6) {
            Text("Pick display")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            ForEach(coordinator.pendingDisplays) { pending in
                Button(action: { coordinator.selectPendingForPlacement(pending.id) }) {
                    HStack(spacing: 8) {
                        // Mini display illustration
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                            )
                            .frame(
                                width: miniWidth(pending),
                                height: miniHeight(pending)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(pending.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                            Text("\(pending.width)×\(pending.height)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(white: 0.1).opacity(0.95))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12)
        .frame(width: 180)
        .position(x: pickerPosition.x, y: pickerPosition.y)
        .transition(.scale.combined(with: .opacity))
    }

    /// Scale mini illustration proportionally, max 32px wide.
    private func miniWidth(_ pending: PendingDisplay) -> CGFloat {
        let aspect = CGFloat(pending.width) / CGFloat(pending.height)
        return min(32, 20 * aspect)
    }

    private func miniHeight(_ pending: PendingDisplay) -> CGFloat {
        let aspect = CGFloat(pending.width) / CGFloat(pending.height)
        let w = min(32, 20 * aspect)
        return w / aspect
    }

    /// Position the picker near the direction indicator location.
    private func computePickerPosition() -> CGPoint {
        guard let anchor = coordinator.arrangement.first(where: { $0.id == anchorId }) else {
            return CGPoint(x: 330, y: 170)
        }

        let rect = CGRect(
            x: CGFloat(anchor.x) * layout.scale + layout.offsetX,
            y: CGFloat(anchor.y) * layout.scale + layout.offsetY,
            width: CGFloat(anchor.width) * layout.scale,
            height: CGFloat(anchor.height) * layout.scale
        )

        switch position {
        case .above: return CGPoint(x: rect.midX, y: rect.minY - 60)
        case .below: return CGPoint(x: rect.midX, y: rect.maxY + 60)
        case .left:  return CGPoint(x: rect.minX - 100, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX + 100, y: rect.midY)
        }
    }
}
