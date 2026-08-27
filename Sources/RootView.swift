import SwiftUI
import AppKit

// MARK: - Guest window root

/// Contents of the booth window. Nothing administrative is reachable from here
/// beyond the passcode-gated escape hatch in the corner.
struct BoothRootView: View {
    @ObservedObject var c: BoothController
    @State private var askingPasscode = false
    @State private var entered = ""
    @State private var wrong = false

    var body: some View {
        PhotoboothScreen(c: c)
            .overlay(alignment: .topTrailing) { exitHint }
            .sheet(isPresented: $askingPasscode) { passcodeSheet }
            .onReceive(NotificationCenter.default.publisher(for: .boothRequestedAdmin)) { _ in
                requestAdmin()
            }
    }

    private var exitHint: some View {
        // Deliberately faint: the operator knows it is there, guests do not notice it.
        Button(action: requestAdmin) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.10))
                .padding(14)
        }
        .buttonStyle(.plain)
        .help("Admin console (ESC)")
    }

    private func requestAdmin() {
        if c.settings.adminPasscode.isEmpty {
            c.showAdmin()
        } else {
            entered = ""
            wrong = false
            askingPasscode = true
        }
    }

    private var passcodeSheet: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("Admin passcode")
                .font(.system(size: 14, weight: .semibold))
            SecureField("Passcode", text: $entered)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(submit)
            if wrong {
                Text("Incorrect passcode")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button("Cancel") { askingPasscode = false }
                    .buttonStyle(QuietButtonStyle())
                Button("Unlock", action: submit)
                    .buttonStyle(PrimaryButtonStyle(tint: Color(hex: c.settings.accentHex)))
            }
            .frame(width: 220)
        }
        .padding(26)
        .frame(width: 300)
    }

    private func submit() {
        if entered == c.settings.adminPasscode {
            askingPasscode = false
            c.showAdmin()
        } else {
            wrong = true
            entered = ""
        }
    }
}

// MARK: - Operator window root

struct AdminRootView: View {
    @ObservedObject var c: BoothController

    var body: some View {
        AdminScreen(c: c)
    }
}

extension Notification.Name {
    static let boothRequestedAdmin = Notification.Name("PhotoboothBoothRequestedAdmin")
}
