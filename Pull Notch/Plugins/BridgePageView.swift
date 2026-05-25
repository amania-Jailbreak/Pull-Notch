import Foundation
import SwiftUI

struct BridgePageView: View {
    let payload: BridgePagePayload

    @State private var textValues: [String: String] = [:]
    @State private var postingElementID: String?
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let elements = payload.elements, !elements.isEmpty {
                ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                    elementView(element)
                }
            } else {
                legacyContent
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    @ViewBuilder
    private var legacyContent: some View {
        if let symbolName = payload.symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }

        if let headline = payload.headline, !headline.isEmpty {
            Text(headline)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
        }

        if let subheadline = payload.subheadline, !subheadline.isEmpty {
            Text(subheadline)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }

        if let body = payload.body, !body.isEmpty {
            Text(body)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }

        if let footnote = payload.footnote, !footnote.isEmpty {
            Text(footnote)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func elementView(_ element: BridgePageElementPayload) -> some View {
        switch element.type.lowercased() {
        case "text":
            if let text = element.text ?? element.label, !text.isEmpty {
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "headline":
            if let text = element.text ?? element.title, !text.isEmpty {
                Text(text)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "footnote":
            if let text = element.text ?? element.label, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "progress":
            progressElement(element)
        case "textfield", "text-field", "text_field":
            textFieldElement(element)
        case "button":
            buttonElement(element)
        case "spacer":
            Spacer(minLength: 0)
        default:
            EmptyView()
        }
    }

    private func progressElement(_ element: BridgePageElementPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = element.label ?? element.text, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.1))

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.86))
                        .frame(width: proxy.size.width * clampedProgress(element.value))
                }
            }
            .frame(height: 7)
        }
    }

    private func textFieldElement(_ element: BridgePageElementPayload) -> some View {
        let id = element.id ?? element.placeholder ?? "text"

        return VStack(alignment: .leading, spacing: 6) {
            if let label = element.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            TextField(element.placeholder ?? "Text", text: binding(for: id))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
    }

    private func buttonElement(_ element: BridgePageElementPayload) -> some View {
        let id = element.id ?? element.title ?? element.postURL ?? UUID().uuidString
        let isPosting = postingElementID == id

        return Button {
            Task { await post(element, elementID: id) }
        } label: {
            HStack(spacing: 7) {
                if isPosting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else if let systemName = element.systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .semibold))
                }

                Text(element.title ?? element.label ?? "POST")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .disabled(isPosting || validatedPostURL(element.postURL) == nil)
        .opacity(validatedPostURL(element.postURL) == nil ? 0.45 : 1)
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { textValues[id, default: ""] },
            set: { textValues[id] = $0 }
        )
    }

    private func post(_ element: BridgePageElementPayload, elementID: String) async {
        guard let url = validatedPostURL(element.postURL) else {
            statusMessage = "Invalid POST URL"
            return
        }

        postingElementID = elementID
        defer { postingElementID = nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: resolvedBody(for: element))

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            statusMessage = (200..<300).contains(statusCode) ? "POST sent" : "POST failed (HTTP \(statusCode))"
        } catch {
            statusMessage = "POST failed: \(error.localizedDescription)"
        }
    }

    private func resolvedBody(for element: BridgePageElementPayload) -> [String: String] {
        guard let body = element.body else { return textValues }

        return body.reduce(into: [:]) { result, item in
            if item.value.hasPrefix("$") {
                let key = String(item.value.dropFirst())
                result[item.key] = textValues[key, default: ""]
            } else {
                result[item.key] = item.value
            }
        }
    }

    private func validatedPostURL(_ rawValue: String?) -> URL? {
        guard
            let rawValue,
            let url = URL(string: rawValue),
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased()
        else {
            return nil
        }

        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) { return url }
        return nil
    }

    private func clampedProgress(_ value: Double?) -> CGFloat {
        CGFloat(min(max(value ?? 0, 0), 1))
    }
}
