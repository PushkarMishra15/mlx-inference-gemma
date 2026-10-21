import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
}

@Observable
final class ChatModel {
    enum LoadState: Equatable {
        case idle
        case loading(progress: Double, downloadedBytes: Int64, totalBytes: Int64)
        case loaded
        case failed(String)
    }

    static let configuration = ModelConfiguration(
        id: "mlx-community/gemma-4-e4b-it-8bit",
        extraEOSTokens: ["<turn|>"]
    )

    var loadState: LoadState = .idle
    var messages: [ChatMessage] = []
    var isGenerating = false
    var tokensPerSecond: Double = 0

    private(set) var container: ModelContainer?
    private var session: ChatSession?
    private var generationTask: Task<Void, Never>?

    var isLoaded: Bool { loadState == .loaded }

    func load() async {
        guard session == nil else { return }
        loadState = .loading(progress: 0, downloadedBytes: 0, totalBytes: 0)

        // Keep MLX's buffer cache small so freed memory goes back to the system.
        MLX.Memory.cacheLimit = 512 * 1024 * 1024

        // The hub's Progress doesn't always advance during large file downloads,
        // so measure the bytes landing on disk instead.
        let progressTask = Task {
            let total = await Self.fetchRepoSize()
            while !Task.isCancelled {
                let downloaded = Self.downloadedBytes()
                if case .loading = loadState {
                    let fraction = total > 0 ? min(Double(downloaded) / Double(total), 1) : 0
                    loadState = .loading(progress: fraction, downloadedBytes: downloaded, totalBytes: total)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { progressTask.cancel() }

        do {
            let container = try await #huggingFaceLoadModelContainer(
                configuration: Self.configuration
            )
            self.container = container
            session = ChatSession(
                container,
                generateParameters: GenerateParameters(maxTokens: 2048, temperature: 0.7)
            )
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Total size of the model repo, from the Hugging Face API.
    private static func fetchRepoSize() async -> Int64 {
        struct Info: Decodable {
            struct Sibling: Decodable { let size: Int64? }
            let siblings: [Sibling]
        }
        guard let url = URL(string: "https://huggingface.co/api/models/\(configuration.name)?blobs=true"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let info = try? JSONDecoder().decode(Info.self, from: data)
        else { return 0 }
        return info.siblings.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// Bytes on disk for this model: finished files in the hub cache plus in-flight downloads.
    private static func downloadedBytes() -> Int64 {
        let fm = FileManager.default
        let repoFolder = "models--" + configuration.name.replacingOccurrences(of: "/", with: "--")
        var folders = [fm.temporaryDirectory]
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            folders.append(caches.appending(path: "huggingface/hub/\(repoFolder)/blobs"))
        }
        #if os(macOS)
        folders.append(fm.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub/\(repoFolder)/blobs"))
        #endif

        var total: Int64 = 0
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    func send(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !prompt.isEmpty, !isGenerating else { return }

        messages.append(ChatMessage(role: .user, text: prompt))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let replyIndex = messages.count - 1
        isGenerating = true
        tokensPerSecond = 0

        generationTask = Task {
            let start = Date()
            var chunks = 0
            do {
                for try await chunk in session.streamResponse(to: prompt) {
                    messages[replyIndex].text += chunk
                    chunks += 1
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed > 0 { tokensPerSecond = Double(chunks) / elapsed }
                }
            } catch is CancellationError {
            } catch {
                messages[replyIndex].text += "\n\n[Error: \(error.localizedDescription)]"
            }
            isGenerating = false
        }
    }

    func stop() {
        generationTask?.cancel()
    }

    func clearChat() async {
        stop()
        messages.removeAll()
        await session?.clear()
    }
}
