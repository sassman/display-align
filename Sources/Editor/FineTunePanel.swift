import SwiftUI

struct FineTunePanel: View {
    @ObservedObject var coordinator: PlacementCoordinator

    var body: some View {
        HStack(spacing: 24) {
            alignmentControl
            offsetControl
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Alignment Segmented Control

    @ViewBuilder
    private var alignmentControl: some View {
        VStack(spacing: 6) {
            Text("ALIGN")
                .font(.system(size: 10, weight: .medium))
                .tracking(1)
                .foregroundColor(.white.opacity(0.35))

            HStack(spacing: 0) {
                ForEach(alignmentOptions, id: \.rawValue) { option in
                    Button(action: { coordinator.updateAlignment(option) }) {
                        Text(label(for: option))
                            .font(.system(size: 11))
                            .foregroundColor(isActive(option) ? .blue : .white.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isActive(option) ? Color.blue.opacity(0.3) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    // MARK: - Offset Input

    @ViewBuilder
    private var offsetControl: some View {
        VStack(spacing: 6) {
            Text("OFFSET")
                .font(.system(size: 10, weight: .medium))
                .tracking(1)
                .foregroundColor(.white.opacity(0.35))

            HStack(spacing: 4) {
                TextField("0", text: offsetBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 60)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .multilineTextAlignment(.center)

                Text("px")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    // MARK: - Helpers

    private var alignmentOptions: [FlexibleDisplay.Alignment] {
        guard let config = currentConfig else { return [] }
        switch config.position {
        case .left, .right:
            return [.top, .center, .bottom]
        case .above, .below:
            return [.left_edge, .center, .right_edge]
        }
    }

    private func label(for align: FlexibleDisplay.Alignment) -> String {
        switch align {
        case .top: return "Top"
        case .center: return "Center"
        case .bottom: return "Bottom"
        case .left_edge: return "Left"
        case .right_edge: return "Right"
        }
    }

    private func isActive(_ align: FlexibleDisplay.Alignment) -> Bool {
        currentConfig?.align == align
    }

    private var offsetBinding: Binding<String> {
        Binding(
            get: { String(currentConfig?.offset ?? 0) },
            set: { newValue in
                if let value = Int(newValue) {
                    coordinator.updateOffset(value)
                }
            }
        )
    }

    private var currentConfig: PlacementConfig? {
        switch coordinator.phase {
        case .placed(let c), .previewing(let c, _): return c
        default: return nil
        }
    }
}
