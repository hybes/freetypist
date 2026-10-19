import SwiftUI

public struct PermissionsView: View {
    @State private var isAccessibilityGranted: Bool = AccessibilityService.isAccessibilityGranted()
    @State private var timer: Timer?

    public init() {}

    public var body: some View {
        Group {
            if isAccessibilityGranted {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility Permission Granted")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("FreeTypist is active and ready to suggest inline completions and corrections across macOS.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("System Settings") {
                        AccessibilityService.openSystemSettingsAccessibility()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.green.opacity(0.22), lineWidth: 1)
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility Permission Required")
                                .font(.headline)
                            Text("FreeTypist needs Accessibility access to detect your cursor position and insert inline completions.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        stepRow(number: "1", title: "Open System Settings", detail: "Go to Privacy & Security → Accessibility")
                        stepRow(number: "2", title: "Enable FreeTypist", detail: "Turn on the toggle next to FreeTypist")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                    HStack(spacing: 10) {
                        Button(action: {
                            AccessibilityService.requestAccessibilityPermission()
                        }) {
                            Text("Request Permission")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: {
                            AccessibilityService.openSystemSettingsAccessibility()
                        }) {
                            Text("Open System Settings")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                )
            }
        }
        .onAppear {
            checkPermission()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    checkPermission()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func checkPermission() {
        let granted = AccessibilityService.isAccessibilityGranted()
        if granted != isAccessibilityGranted {
            isAccessibilityGranted = granted
        }
    }

    private func stepRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}
