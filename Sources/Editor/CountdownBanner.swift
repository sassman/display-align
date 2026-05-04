import SwiftUI

struct CountdownBanner: View {
    let secondsLeft: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("Verify your setup. Auto-closing in")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))

            Text("\(secondsLeft)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 20)
                .contentTransition(.numericText())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
