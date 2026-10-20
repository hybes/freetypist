import Foundation
import Combine

@MainActor
final class ReplacementFeedback: ObservableObject {
    static let shared = ReplacementFeedback()
    @Published private(set) var message: String?
    private var expiry: Task<Void, Never>?

    func show(_ message: String) {
        expiry?.cancel()
        self.message = message
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func clear() {
        expiry?.cancel()
        message = nil
    }
}
