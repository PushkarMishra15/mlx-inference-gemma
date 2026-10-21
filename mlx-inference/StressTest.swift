import Foundation
import MLXLMCommon
import Observation
#if os(iOS)
import UIKit
#endif

/// Generates a long story while sampling speed, CPU, memory and thermal state every second,
/// so sustained performance and thermal throttling can be measured.
@Observable
final class StressTest {
    struct Sample: Identifiable {
        var id: Int { second }
        let second: Int
        let tokens: Int
        /// Tokens per second over the last few seconds.
        let tokensPerSecond: Double
        let cpu: Double
        let appMemory: UInt64
        let mlxMemory: Int
        let thermalState: ProcessInfo.ThermalState
    }

    static let wordOptions = [500, 1000, 1500, 2000, 3000]

    var targetWords = 1500
    private(set) var isRunning = false
    private(set) var story = ""
    private(set) var samples: [Sample] = []
    private(set) var tokens = 0
    private(set) var finalInfo: GenerateCompletionInfo?
    private(set) var statusMessage: String?
    private(set) var resultFile: URL?

    private var generationTask: Task<Void, Never>?
    private var samplingTask: Task<Void, Never>?
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #endif

    var wordCount: Int { story.split(whereSeparator: \.isWhitespace).count }
    var elapsed: Int { samples.last?.second ?? 0 }
    var currentTokensPerSecond: Double { samples.last?.tokensPerSecond ?? 0 }
    var peakTokensPerSecond: Double { samples.map(\.tokensPerSecond).max() ?? 0 }
    var peakAppMemory: UInt64 { samples.map(\.appMemory).max() ?? 0 }
    var worstThermalState: ProcessInfo.ThermalState {
        samples.map(\.thermalState).max { $0.rawValue < $1.rawValue } ?? ProcessInfo.processInfo.thermalState
    }

    /// Average speed in the first and last 20% of the run; a large drop indicates throttling.
    var speedDrop: (start: Double, end: Double, percent: Double)? {
        let rates = samples.dropFirst(3).map(\.tokensPerSecond)  // skip prompt processing warm-up
        guard rates.count >= 10 else { return nil }
        let slice = max(rates.count / 5, 1)
        let start = rates.prefix(slice).reduce(0, +) / Double(slice)
        let end = rates.suffix(slice).reduce(0, +) / Double(slice)
        guard start > 0 else { return nil }
        return (start, end, (start - end) / start * 100)
    }

    func start(container: ModelContainer, monitor: SystemMonitor) {
        guard !isRunning else { return }
        isRunning = true
        story = ""
        samples = []
        tokens = 0
        finalInfo = nil
        statusMessage = nil
        resultFile = nil
        keepAwake(true)

        let words = targetWords
        let session = ChatSession(
            container,
            // Roughly 1.4 tokens per English word, with headroom so the story isn't cut off.
            generateParameters: GenerateParameters(maxTokens: words * 2 + 200, temperature: 0.8)
        )
        let prompt = """
            Write an original short story of about \(words) words. Give it a title, \
            vivid characters and a clear beginning, middle and end. Write only the story.
            """

        samplingTask = Task {
            var second = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                second += 1
                record(second: second, monitor: monitor)
            }
        }

        generationTask = Task {
            do {
                for try await item in session.streamDetails(to: prompt) {
                    switch item {
                    case .chunk(let text):
                        story += text
                        tokens += 1
                    case .info(let info):
                        finalInfo = info
                    default:
                        break
                    }
                }
                statusMessage = "Finished"
            } catch is CancellationError {
                statusMessage = statusMessage ?? "Stopped"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            finish(monitor: monitor)
        }
    }

    func stop(reason: String = "Stopped") {
        guard isRunning else { return }
        statusMessage = reason
        generationTask?.cancel()
    }

    private func record(second: Int, monitor: SystemMonitor) {
        // Rate over a 5 second window smooths out per-token jitter.
        let window = 5
        let earlier = samples.last { $0.second <= second - window }
        let rate: Double
        if let earlier {
            rate = Double(tokens - earlier.tokens) / Double(second - earlier.second)
        } else {
            rate = Double(tokens) / Double(second)
        }
        samples.append(Sample(
            second: second,
            tokens: tokens,
            tokensPerSecond: rate,
            cpu: monitor.totalCPU,
            appMemory: monitor.appMemory,
            mlxMemory: monitor.mlxActiveMemory,
            thermalState: ProcessInfo.processInfo.thermalState
        ))
    }

    private func finish(monitor: SystemMonitor) {
        samplingTask?.cancel()
        samplingTask = nil
        generationTask = nil
        isRunning = false
        keepAwake(false)
        resultFile = writeCSV()
    }

    /// Keeps the system from napping or sleeping the app while the test runs.
    private func keepAwake(_ awake: Bool) {
        #if os(macOS)
        if awake {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Story generation stress test"
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #elseif os(iOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    private func writeCSV() -> URL? {
        var lines = ["second,tokens,tokens_per_second,cpu_percent,app_memory_gb,mlx_memory_gb,thermal_state"]
        for s in samples {
            lines.append([
                "\(s.second)", "\(s.tokens)", String(format: "%.2f", s.tokensPerSecond),
                String(format: "%.1f", s.cpu * 100),
                String(format: "%.3f", Double(s.appMemory) / 1_073_741_824),
                String(format: "%.3f", Double(s.mlxMemory) / 1_073_741_824),
                s.thermalState.label,
            ].joined(separator: ","))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "stress-test_\(formatter.string(from: .now)).csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
