import AppKit
import SwiftUI

struct PermissionsTab: View {
    @State private var granted: [Permission: Bool] = Self.check()

    /// Re-checks permissions when a window comes to the front (for example after you return from
    /// System Settings), instead of a timer that would keep waking the Mac while Settings is closed.
    private let refresh = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { permission in
                    row(permission)
                }
            } footer: {
                Text("""
                Toolbelt asks for a permission only when you first use a feature that needs it. \
                Because Toolbelt isn't signed with a paid Apple developer account, macOS forgets these \
                permissions each time you update it: select Toolbelt in the list, click –, then add it again.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in granted = Self.check() }
    }

    private func row(_ permission: Permission) -> some View {
        let isGranted = granted[permission] ?? false
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 18))
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(permission.title).font(.headline)
                    Spacer()
                    Label(isGranted ? "Allowed" : "Not allowed",
                          systemImage: isGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isGranted ? Color.green : Color.secondary)
                        .font(.callout)
                }
                Text(permission.explanation)
                    .font(.callout)
                Text("Used by: \(permission.usedBy)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(isGranted ? "Open System Settings" : "Allow in System Settings…") {
                    permission.openSettings()
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private static func check() -> [Permission: Bool] {
        Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) })
    }
}
