import SwiftUI

struct PlacementEditorView: View {
    @ObservedObject var coordinator: PlacementCoordinator

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Background
            Color.black.opacity(0.92)

            VStack(spacing: 0) {
                // Header
                header
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                // Canvas
                ArrangementCanvas(
                    coordinator: coordinator,
                    canvasSize: CGSize(width: 660, height: 340)
                )
                .padding(.horizontal, 30)

                Spacer(minLength: 8)

                // Bottom controls
                bottomControls
                    .padding(.bottom, 16)
            }

            // Tap-anywhere to intercept countdown (below window controls)
            if case .previewing = coordinator.phase {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { coordinator.interceptCountdown() }
            }

            // Window controls (top-right, above intercept overlay)
            windowControls
                .padding(.top, 16)
                .padding(.trailing, 16)
        }
        .frame(width: 720, height: 520)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.2), value: coordinator.phase)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 4) {
            Text("PLACING")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.4))

            Text(coordinator.newDisplay.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.blue)

            Text("\(coordinator.effectiveNewWidth) × \(coordinator.effectiveNewHeight)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.blue.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            Color.blue.opacity(0.2),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    // MARK: - Bottom Controls

    @ViewBuilder
    private var bottomControls: some View {
        switch coordinator.phase {
        case .placed:
            FineTunePanel(coordinator: coordinator)
        case .previewing(_, let seconds):
            CountdownBanner(secondsLeft: seconds)
        default:
            Text(hintText)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
                .padding(.vertical, 12)
        }
    }

    private var hintText: String {
        switch coordinator.phase {
        case .idle:
            return "Click any display to select it as anchor"
        case .anchorSelected:
            return "Click a direction to place \(coordinator.newDisplay.name)"
        default:
            return ""
        }
    }

    // MARK: - Window Controls

    @ViewBuilder
    private var windowControls: some View {
        HStack(spacing: 8) {
            // Green check — placed: start preview, previewing: accept early
            if case .placed = coordinator.phase {
                Button(action: { coordinator.confirmPlacement() }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.green.opacity(0.9))
                        .frame(width: 28, height: 28)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else if case .previewing = coordinator.phase {
                Button(action: { coordinator.acceptPreview() }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.green.opacity(0.9))
                        .frame(width: 28, height: 28)
                        .background(Color.green.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            // Close button — always visible
            Button(action: {
                if case .previewing = coordinator.phase {
                    coordinator.interceptCountdown()
                } else {
                    coordinator.revertPhysicalPreview()
                    PlacementWindow.dismiss()
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
}
