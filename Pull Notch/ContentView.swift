//
//  ContentView.swift
//  Pull Notch
//
//  Created by amania on 2026/03/30.
//

import AppKit
import Observation
import SwiftUI

struct ContentView: View {
    @Bindable var overlayModel: NotchOverlayModel

    var body: some View {
        ZStack(alignment: .top) {
            islandShape
        }
        .frame(
            width: overlayModel.panelSize.width,
            height: overlayModel.panelSize.height,
            alignment: .top
        )
        .padding(.top, overlayModel.windowTopInset)
        .background(Color.clear)
    }

    private var islandShape: some View {
        DynamicIslandShape(cornerRadius: 22)
            .fill(
                LinearGradient(
                    colors: [Color.black, Color(red: 0.08, green: 0.08, blue: 0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: overlayModel.visibleWidth, height: overlayModel.currentIslandHeight)
            .overlay(alignment: .top) {
                compactBar
                    .padding(.top, 8)
            }
            .overlay(alignment: .bottom) {
                trackChangeBanner
                    .opacity(overlayModel.showsTrackChange ? 1 : 0)
                    .offset(y: overlayModel.showsTrackChange ? 0 : -8)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            .shadow(color: .black.opacity(0.28), radius: 16, y: 10)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: overlayModel.showsTrackChange)
    }

    private var compactBar: some View {
        HStack(spacing: 12) {
            artworkView
            Spacer(minLength: 0)
            visualizerView
        }
        .padding(.horizontal, 12)
        .frame(width: overlayModel.visibleWidth, height: overlayModel.notchHeight)
    }

    private var artworkView: some View {
        Group {
            if let artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.gray.opacity(0.55), Color.gray.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var artworkImage: NSImage? {
        guard let artworkData = overlayModel.artworkData else {
            return nil
        }

        return NSImage(data: artworkData)
    }

    private var visualizerView: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array([10.0, 16.0, 12.0, 18.0, 9.0].enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.92) : Color.white.opacity(0.6))
                    .frame(width: 4, height: overlayModel.isPlaying ? height : 6)
            }
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var trackChangeBanner: some View {
        if let detailLine = overlayModel.detailLine {
            Text(detailLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    ContentView(overlayModel: previewOverlayModel)
}

private struct DynamicIslandShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private var previewOverlayModel: NotchOverlayModel {
    let overlayModel = NotchOverlayModel()
    overlayModel.updateNowPlaying(
        track: .init(
            title: "Everything in Its Right Place",
            album: "Kid A",
            artist: "Radiohead",
            isPlaying: true,
            appName: "Music",
            artworkData: nil
        )
    )
    return overlayModel
}
