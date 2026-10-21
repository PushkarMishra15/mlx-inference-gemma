import MLXLMCommon
import SwiftUI

struct ContentView: View {
    enum Mode: String, CaseIterable {
        case chat = "Chat"
        case stressTest = "Stress Test"
    }

    let chat: ChatModel
    let monitor: SystemMonitor
    let stressTest: StressTest
    @State private var prompt = ""
    @State private var mode: Mode = .chat

    var body: some View {
        VStack(spacing: 0) {
            StatsPanel(monitor: monitor,
                       tokensPerSecond: stressTest.isRunning ? stressTest.currentTokensPerSecond : chat.tokensPerSecond)
            Divider()
            if chat.isLoaded {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            if chat.isLoaded && mode == .stressTest {
                StressTestView(chat: chat, monitor: monitor, test: stressTest)
            } else {
                content
                Divider()
                inputBar
            }
        }
        .frame(minWidth: 520, minHeight: 600)
        .onAppear {
            if stressTest.isRunning { mode = .stressTest }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch chat.loadState {
        case .idle:
            VStack(spacing: 12) {
                Text(ChatModel.configuration.name).font(.headline)
                Text("About 8.9 GB is downloaded the first time.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Load Model") { Task { await chat.load() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading(let progress, let downloaded, let total):
            VStack(spacing: 12) {
                ProgressView(value: progress)
                    .frame(maxWidth: 300)
                Group {
                    if total == 0 {
                        Text("Starting download…")
                    } else if progress < 1 {
                        Text("Downloading… \(Int(progress * 100))%  (\(gigabytes(downloaded)) of \(gigabytes(total)))")
                    } else {
                        Text("Loading weights into memory…")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text("Failed to load model").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await chat.load() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            messageList
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: chat.messages.last?.text) {
                if let id = chat.messages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await chat.clearChat() }
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!chat.isLoaded || chat.messages.isEmpty)

            TextField("Message Gemma…", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(send)
                .disabled(!chat.isLoaded)

            if chat.isGenerating {
                Button("Stop", action: chat.stop)
            } else {
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!chat.isLoaded || stressTest.isRunning
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private func send() {
        chat.send(prompt)
        prompt = ""
    }

    private func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text.isEmpty ? "…" : message.text)
                .textSelection(.enabled)
                .padding(10)
                .background(message.role == .user ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

struct StatsPanel: View {
    let monitor: SystemMonitor
    let tokensPerSecond: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Stat(title: "System RAM",
                     value: "\(gb(monitor.usedRAM)) / \(gb(monitor.totalRAM))",
                     fraction: Double(monitor.usedRAM) / Double(max(monitor.totalRAM, 1)))
                Stat(title: "App memory", value: gb(monitor.appMemory), fraction: nil)
                Stat(title: "MLX (GPU)", value: "\(gb(UInt64(monitor.mlxActiveMemory))) · peak \(gb(UInt64(monitor.mlxPeakMemory)))", fraction: nil)
                Stat(title: "CPU", value: "\(Int(monitor.totalCPU * 100))%", fraction: monitor.totalCPU)
                if tokensPerSecond > 0 {
                    Stat(title: "Speed", value: String(format: "%.1f tok/s", tokensPerSecond), fraction: nil)
                }
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(monitor.coreUsage.enumerated()), id: \.offset) { index, usage in
                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(usage > 0.8 ? Color.red : usage > 0.5 ? Color.orange : Color.green)
                                    .frame(height: geo.size.height * usage)
                            }
                        }
                        .frame(height: 30)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
                        Text("\(index)").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.easeOut(duration: 0.3), value: monitor.coreUsage)
        }
        .padding()
        .font(.caption)
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }
}

private struct Stat: View {
    let title: String
    let value: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().bold()
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1)).frame(width: 90)
            }
        }
    }
}

#Preview {
    ContentView(chat: ChatModel(), monitor: SystemMonitor(), stressTest: StressTest())
}
