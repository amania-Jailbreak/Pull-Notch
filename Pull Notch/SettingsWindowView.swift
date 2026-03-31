//
//  SettingsWindowView.swift
//  Pull Notch
//
//  Created by Codex.
//

import Observation
import SwiftUI

struct SettingsWindowView: View {
    @Bindable var overlayModel: NotchOverlayModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    VStack(spacing: 10) {
                        ForEach(OverlayFeature.allCases) { feature in
                            settingsToggleRow(feature)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 368, minHeight: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Text("ウィジェットやオーバーレイ機能を個別にオンオフできます。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.gray)
        }
    }

    private func settingsToggleRow(_ feature: OverlayFeature) -> some View {
        Button {
            overlayModel.setFeatureEnabled(feature, isEnabled: !overlayModel.isFeatureEnabled(feature))
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(feature.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Capsule()
                    .fill(overlayModel.isFeatureEnabled(feature) ? Color.white : Color.white.opacity(0.14))
                    .frame(width: 40, height: 24)
                    .overlay(alignment: overlayModel.isFeatureEnabled(feature) ? .trailing : .leading) {
                        Circle()
                            .fill(overlayModel.isFeatureEnabled(feature) ? Color.black : Color.white.opacity(0.82))
                            .frame(width: 16, height: 16)
                            .padding(4)
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsWindowView(overlayModel: NotchOverlayModel())
}
