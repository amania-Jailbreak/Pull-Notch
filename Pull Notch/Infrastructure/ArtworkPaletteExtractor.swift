import AppKit
import Foundation

struct VisualizerArtworkPalette {
    let brightColor: NSColor
    let darkColor: NSColor
}

@MainActor
struct ArtworkPaletteExtractor {
    private let sampleSize = 28

    func palette(from artworkData: Data) -> VisualizerArtworkPalette? {
        guard let image = NSImage(data: artworkData), let colors = dominantColors(from: image) else {
            return nil
        }

        return VisualizerArtworkPalette(
            brightColor: colors.main
                .withSaturation(multiplier: 1.18)
                .withBrightness(multiplier: 1.08)
                .withAlphaComponent(0.98),
            darkColor: colors.secondary
                .withSaturation(multiplier: 1.12)
                .withBrightness(multiplier: 0.9)
                .withAlphaComponent(0.9)
        )
    }

    private func dominantColors(from image: NSImage) -> (main: NSColor, secondary: NSColor)? {
        guard
            let reduced = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: sampleSize,
                pixelsHigh: sampleSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: reduced)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var buckets: [ColorBucketKey: ColorBucket] = [:]
        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                guard
                    let color = reduced.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    let rgb = color.rgbComponents,
                    let hsb = color.hsbComponents,
                    rgb.alpha > 0.2,
                    hsb.brightness > 0.12
                else {
                    continue
                }

                let key = ColorBucketKey(
                    red: Int((rgb.red * 255).rounded()) / 32,
                    green: Int((rgb.green * 255).rounded()) / 32,
                    blue: Int((rgb.blue * 255).rounded()) / 32
                )
                var bucket = buckets[key] ?? ColorBucket()
                bucket.count += 1
                bucket.red += rgb.red
                bucket.green += rgb.green
                bucket.blue += rgb.blue
                bucket.prominence += (hsb.saturation * 1.9) + (hsb.brightness * 1.1)
                buckets[key] = bucket
            }
        }

        let rankedColors = buckets.values.compactMap { bucket -> RankedColor? in
            guard bucket.count > 0 else { return nil }

            let color = NSColor(
                calibratedRed: bucket.red / CGFloat(bucket.count),
                green: bucket.green / CGFloat(bucket.count),
                blue: bucket.blue / CGFloat(bucket.count),
                alpha: 1
            )
            guard let hsb = color.hsbComponents else { return nil }

            return RankedColor(
                color: color,
                score: bucket.prominence
                    + (CGFloat(bucket.count) * 0.95)
                    + (hsb.saturation * 18)
                    + (hsb.brightness * 10)
            )
        }
        .sorted { $0.score > $1.score }

        guard let mainColor = rankedColors.first?.color else { return nil }
        let secondaryColor = rankedColors.first {
            $0.color.distance(to: mainColor) > 0.24
        }?.color ?? mainColor
        return (mainColor, secondaryColor)
    }
}

private struct ColorBucketKey: Hashable {
    let red: Int
    let green: Int
    let blue: Int
}

private struct ColorBucket {
    var count = 0
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var prominence: CGFloat = 0
}

private struct RankedColor {
    let color: NSColor
    let score: CGFloat
}

private extension NSColor {
    func withSaturation(multiplier: CGFloat) -> NSColor {
        guard let hsb = hsbComponents else { return self }
        return NSColor(
            calibratedHue: hsb.hue,
            saturation: min(1, hsb.saturation * multiplier),
            brightness: hsb.brightness,
            alpha: hsb.alpha
        )
    }

    func withBrightness(multiplier: CGFloat) -> NSColor {
        guard let hsb = hsbComponents else { return self }
        return NSColor(
            calibratedHue: hsb.hue,
            saturation: hsb.saturation,
            brightness: max(0.01, min(1, hsb.brightness * multiplier)),
            alpha: hsb.alpha
        )
    }

    var rgbComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let converted = usingColorSpace(.deviceRGB) else { return nil }
        return (
            converted.redComponent,
            converted.greenComponent,
            converted.blueComponent,
            converted.alphaComponent
        )
    }

    var hsbComponents: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat)? {
        guard let converted = usingColorSpace(.deviceRGB) else { return nil }
        return (
            converted.hueComponent,
            converted.saturationComponent,
            converted.brightnessComponent,
            converted.alphaComponent
        )
    }

    func distance(to other: NSColor) -> CGFloat {
        guard let lhs = rgbComponents, let rhs = other.rgbComponents else { return 0 }
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt((red * red) + (green * green) + (blue * blue))
    }
}
