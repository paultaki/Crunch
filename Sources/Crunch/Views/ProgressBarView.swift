import SwiftUI

struct ProgressBarView: View {
    let completed: Int
    let total: Int
    let onCancel: () -> Void

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    private var percent: Int { Int(progress * 100) }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 6)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.accentColor, .accentColor.opacity(0.5)]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 120, height: 120)
                    .animation(.spring(response: 0.5, dampingFraction: 0.9), value: progress)

                VStack(spacing: 2) {
                    Text("\(percent)%")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(percent)))
                    Text("\(completed) / \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(spacing: 6) {
                Text("Compressing images")
                    .font(.title3.weight(.semibold))
                Text("Keep the window open while we finish up")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
                    .frame(minWidth: 100)
                    .frame(height: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}
