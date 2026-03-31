//
//  OnboardingView.swift
//  Pull Notch
//
//  Created by amania on 2026/03/30.
//

import Observation
import SwiftUI

struct OnboardingView: View {
    @Bindable var onboardingModel: OnboardingModel
    let requestAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Pull Notch")
                .font(.system(size: 28, weight: .bold))

            Text("MediaRemote ベースで現在再生中を読み取り、ノッチに表示します。Automation 設定は使いません。")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Label("現在再生中の曲名を取得", systemImage: "music.note")
                Label("アーティスト名と再生状態を表示", systemImage: "waveform")
                Label("対応アプリ名も診断欄に表示", systemImage: "app.connected.to.app.below.fill")
            }
            .font(.system(size: 14, weight: .medium))

            statusCard
            diagnosticsCard

            VStack(spacing: 12) {
                Button(action: requestAccess) {
                    Text(primaryButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if onboardingModel.phase == .failed {
                    Button("あとで") {
                        NSApp.hide(nil)
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
        .frame(width: 440, height: 460)
        .background(
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.09, blue: 0.12), Color(red: 0.12, green: 0.13, blue: 0.17)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(statusMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.system(size: 13, weight: .semibold))
            diagnosticRow("Bundle ID", onboardingModel.bundleIdentifier)
            diagnosticRow("MediaRemote Probe", onboardingModel.lastMediaRemoteProbe)
            diagnosticRow("Source App", onboardingModel.lastSourceApp ?? "unknown")
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var primaryButtonTitle: String {
        switch onboardingModel.phase {
        case .intro:
            return "Now Playing を確認"
        case .requestingAccess:
            return "確認中..."
        case .failed:
            return "もう一度試す"
        case .ready:
            return "完了"
        }
    }

    private var statusTitle: String {
        switch onboardingModel.phase {
        case .intro:
            return "MediaRemote から現在再生中を読み取ります"
        case .requestingAccess:
            return "ローカルの Now Playing 情報を確認しています"
        case .failed:
            return "MediaRemote から取得できませんでした"
        case .ready:
            return "準備完了"
        }
    }

    private var statusMessage: String {
        switch onboardingModel.phase {
        case .intro:
            return "ボタンを押すと、その場で現在再生中のメタデータ取得を確認します。"
        case .requestingAccess:
            return "再生中のアプリ名とメタデータが取得できるかを確認しています。"
        case .failed:
            return "再生中のメディアがないか、MediaRemote 取得に失敗しました。Apple Music やブラウザで再生した状態でもう一度試してください。"
        case .ready:
            return "取得に成功しました。以後はノッチに現在再生中を表示します。"
        }
    }
}

#Preview {
    OnboardingView(onboardingModel: OnboardingModel(), requestAccess: {})
}
