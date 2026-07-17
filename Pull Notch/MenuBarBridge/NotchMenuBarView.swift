import SwiftUI

struct NotchMenuBarView: View {
    let items: [MenuBarItemSnapshot]
    let permissionState: MenuBarBridgePermissionState
    let onRequestPermission: () -> Void
    let onPressItem: (MenuBarItemSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch permissionState {
            case .trusted:
                if items.isEmpty {
                    emptyState
                } else {
                    itemStrip
                }
            case .needsAccessibilityPermission:
                permissionView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.075), lineWidth: 1)
                )
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))

            VStack(alignment: .leading, spacing: 2) {
                Text("Menu Bar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        switch permissionState {
        case .trusted:
            return items.isEmpty ? "No menu extras found yet" : "\(items.count) mirrored items"
        case .needsAccessibilityPermission:
            return "Accessibility is required"
        }
    }

    private var itemStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button {
                        onPressItem(item)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.systemImageName)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.08)))

                            Text(item.title)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.74))
                                .lineLimit(1)
                                .frame(width: 58)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(item.ownerName.map { "\(item.title) • \($0)" } ?? item.title)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var permissionView: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))

            Text("Allow Accessibility so Pull Notch can mirror menu bar items.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Open") {
                onRequestPermission()
            }
            .font(.system(size: 11, weight: .bold))
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.92)))
        }
    }

    private var emptyState: some View {
        Text("Menu bar mirroring is ready, but no visible extras were found in this scan.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.52))
            .fixedSize(horizontal: false, vertical: true)
    }
}
