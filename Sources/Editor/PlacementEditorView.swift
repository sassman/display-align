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

            // Resolution opt-out (top-left) — shown alongside the Save affordance.
            if coordinator.canShowSave {
                rememberResolutionsToggle
                    .padding(.top, 18)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            if let pending = coordinator.activePending {
                Text("PLACING")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.4))

                Text(pending.name)
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
            } else if let finetuned = finetunedDisplay {
                Text("EDITING")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.4))

                Text(finetuned.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.blue)

                Text("\(finetuned.width) × \(finetuned.height)")
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
            } else {
                Text("ARRANGEMENT")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.4))

                Text("Configure")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var finetunedDisplay: CanvasDisplay? {
        if case .finetuning(_, let displayId) = coordinator.phase {
            return coordinator.arrangement.first(where: { $0.id == displayId })
        }
        return nil
    }

    // MARK: - Bottom Controls

    @ViewBuilder
    private var bottomControls: some View {
        switch coordinator.phase {
        case .placed, .finetuning:
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
            return coordinator.rememberResolutions
                ? "Click Save to store this arrangement's layout and resolutions"
                : "Click Save to store this arrangement's layout and clear saved resolutions"
        case .anchorSelected:
            if coordinator.pendingDisplays.isEmpty {
                return "Unchain a display to place it here"
            }
            return "Click a direction to place the display"
        case .pickingDisplay:
            return "Select which display to place"
        default:
            return ""
        }
    }

    // MARK: - Window Controls

    /// Top-left opt-out. On (default) ⇒ Save captures each display's current
    /// mode; off ⇒ Save clears stored resolutions so the arrangement leaves
    /// modes untouched on activate.
    @ViewBuilder
    private var rememberResolutionsToggle: some View {
        Toggle(isOn: $coordinator.rememberResolutions) {
            Text("Remember resolutions")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(.green)
        .fixedSize()
    }

    @ViewBuilder
    private var windowControls: some View {
        HStack(spacing: 8) {
            // Primary action — context-dependent.
            if case .placed = coordinator.phase {
                greenCheckButton(action: { coordinator.confirmPlacement() })
            } else if case .previewing = coordinator.phase {
                greenCheckButton(action: { coordinator.acceptPreview() })
            } else if coordinator.canShowSave {
                // Idle / fine-tuning: explicit, always-enabled Save.
                saveButton
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

    /// Explicit, labeled Save — stores the arrangement's layout + resolutions
    /// into the active profile. Enabled whenever shown (Save-anytime).
    @ViewBuilder
    private var saveButton: some View {
        Button(action: { coordinator.saveToActiveProfile() }) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.green.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.green.opacity(0.2))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private func greenCheckButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
}
