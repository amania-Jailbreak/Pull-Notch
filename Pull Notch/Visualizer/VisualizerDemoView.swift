import SwiftUI

struct VisualizerDemoView: View {
    @State private var analyzer = AudioAnalyzer()
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            DynamicIslandVisualizer(
                metrics: analyzer.metrics,
                state: isExpanded ? .expanded : analyzer.state,
                title: isExpanded ? "Now Playing" : "Listening",
                subtitle: subtitle
            )

            HStack(spacing: 12) {
                Button(analyzer.isRunning ? "Stop" : "Start") {
                    if analyzer.isRunning {
                        analyzer.stop()
                    } else {
                        analyzer.start()
                    }
                }

                Button(isExpanded ? "Collapse" : "Expand") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        isExpanded.toggle()
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(width: 420, height: 260)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.1),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onDisappear {
            analyzer.stop()
        }
    }

    private var subtitle: String {
        switch analyzer.state {
        case .idle:
            return "Idle pulse"
        case .listening:
            return "Listening"
        case .active:
            return "Active"
        case .expanded:
            return "Expanded"
        }
    }
}

#Preview("Dynamic Island Visualizer") {
    VisualizerDemoView()
}
