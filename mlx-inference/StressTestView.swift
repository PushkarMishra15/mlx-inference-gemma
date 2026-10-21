import Charts
import MLXLMCommon
import SwiftUI

struct StressTestView: View {
    let chat: ChatModel
    let monitor: SystemMonitor
    @Bindable var test: StressTest
    @State private var selectedSecond: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                if !test.samples.isEmpty {
                    liveStats
                    speedChart
                }
                if !test.isRunning, test.finalInfo != nil || test.statusMessage != nil {
                    summary
                }
                if !test.story.isEmpty {
                    Text("Story").font(.headline)
                    Text(test.story)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Story length", selection: $test.targetWords) {
                    ForEach(StressTest.wordOptions, id: \.self) { words in
                        Text("\(words) words").tag(words)
                    }
                }
                .frame(maxWidth: 260)
                .disabled(test.isRunning)

                Spacer()

                if test.isRunning {
                    Button("Stop", role: .destructive) { test.stop() }
                } else {
                    Button("Start Stress Test") {
                        if let container = chat.container {
                            test.start(container: container, monitor: monitor)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chat.container == nil || chat.isGenerating)
                }
            }
            Text(backgroundNote)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backgroundNote: String {
        #if os(macOS)
        "Keeps running if you close this window. Quitting the app (⌘Q) stops it."
        #else
        "iOS doesn't allow GPU work in the background, so keep the app open. The screen stays awake during the test."
        #endif
    }

    private var liveStats: some View {
        let columns = [GridItem(.adaptive(minimum: 120), alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            StatTile(title: "Elapsed", value: duration(test.elapsed))
            StatTile(title: "Words", value: "\(test.wordCount) / \(test.targetWords)")
            StatTile(title: "Speed now", value: String(format: "%.1f tok/s", test.currentTokensPerSecond))
            StatTile(title: "Peak speed", value: String(format: "%.1f tok/s", test.peakTokensPerSecond))
            StatTile(title: "Peak app memory", value: String(format: "%.2f GB", Double(test.peakAppMemory) / 1_073_741_824))
            VStack(alignment: .leading, spacing: 2) {
                Text("Thermal state").font(.caption).foregroundStyle(.secondary)
                ThermalBadge(state: test.samples.last?.thermalState ?? .nominal)
            }
        }
    }

    private var speedChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tokens per second").font(.headline)
            Chart {
                ForEach(test.samples) { sample in
                    LineMark(
                        x: .value("Second", sample.second),
                        y: .value("Tokens/s", sample.tokensPerSecond)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }
                if let selected = selectedSample {
                    RuleMark(x: .value("Second", selected.second))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(duration(selected.second)).bold()
                                Text(String(format: "%.1f tok/s", selected.tokensPerSecond))
                                Text("CPU \(Int(selected.cpu * 100))%")
                                Text("Thermal: \(selected.thermalState.label)")
                            }
                            .font(.caption2)
                            .padding(6)
                            .background(.background, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                        }
                }
            }
            .chartXSelection(value: $selectedSecond)
            .chartXAxisLabel("Seconds")
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel()
                }
            }
            .frame(height: 200)
        }
    }

    private var selectedSample: StressTest.Sample? {
        guard let selectedSecond else { return nil }
        return test.samples.min { abs($0.second - selectedSecond) < abs($1.second - selectedSecond) }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Result: \(test.statusMessage ?? "")").font(.headline)
            if let info = test.finalInfo {
                Text("\(info.generationTokenCount) tokens in \(String(format: "%.1f", info.generateTime)) s · average \(String(format: "%.1f", info.tokensPerSecond)) tok/s")
                Text("Prompt: \(info.promptTokenCount) tokens at \(String(format: "%.1f", info.promptTokensPerSecond)) tok/s")
            }
            if let drop = test.speedDrop {
                Text(String(format: "Speed first 20%%: %.1f tok/s → last 20%%: %.1f tok/s (%@%.0f%%)",
                            drop.start, drop.end, drop.percent >= 0 ? "−" : "+", abs(drop.percent)))
                Text(throttlingVerdict(drop.percent))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Worst thermal state:")
                ThermalBadge(state: test.worstThermalState)
            }
            if let file = test.resultFile {
                ShareLink(item: file) {
                    Label("Export samples (CSV)", systemImage: "square.and.arrow.up")
                }
            }
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func throttlingVerdict(_ dropPercent: Double) -> String {
        switch dropPercent {
        case ..<5: "No meaningful slowdown: no sign of throttling."
        case ..<15: "Mild slowdown: possible light throttling."
        default: "Significant slowdown: likely thermal throttling."
        }
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).bold().monospacedDigit()
        }
    }
}

struct ThermalBadge: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        Label(state.label, systemImage: icon)
            .font(.callout.bold())
            .foregroundStyle(color)
    }

    private var icon: String {
        switch state {
        case .nominal: "checkmark.circle.fill"
        case .fair: "thermometer.medium"
        case .serious: "exclamationmark.triangle.fill"
        default: "flame.fill"
        }
    }

    private var color: Color {
        switch state {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
    }
}
