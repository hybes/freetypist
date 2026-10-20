import Foundation
import Combine

enum SetupStep: Int, CaseIterable {
    case welcome, model, accessibility, tryTyping
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .model: "Local AI"
        case .accessibility: "Accessibility"
        case .tryTyping: "Try it"
        }
    }
}

@MainActor
final class SetupState: ObservableObject {
    static let shared = SetupState()
    @Published var step: SetupStep { didSet { defaults.set(step.rawValue, forKey: "ft_setupStep") } }
    @Published private(set) var isCompleted: Bool
    @Published var useBasicCompletions: Bool { didSet { defaults.set(useBasicCompletions, forKey: "ft_setupBasicMode") } }
    @Published var playgroundOnly: Bool { didSet { defaults.set(playgroundOnly, forKey: "ft_setupPlaygroundOnly") } }
    @Published var didAcceptCompletion = false
    @Published var verifiedModelID: String? { didSet { defaults.set(verifiedModelID, forKey: "ft_setupVerifiedModelID") } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppStorage.defaults) {
        self.defaults = defaults
        self.step = SetupStep(rawValue: defaults.integer(forKey: "ft_setupStep")) ?? .welcome
        self.isCompleted = defaults.integer(forKey: "ft_setupVersion") >= 1
        self.useBasicCompletions = defaults.bool(forKey: "ft_setupBasicMode")
        self.playgroundOnly = defaults.bool(forKey: "ft_setupPlaygroundOnly")
        self.verifiedModelID = defaults.string(forKey: "ft_setupVerifiedModelID")
    }

    @discardableResult func finish(skipTypingTest: Bool = false) -> Bool {
        guard didAcceptCompletion || skipTypingTest else { return false }
        defaults.set(1, forKey: "ft_setupVersion")
        defaults.set(didAcceptCompletion, forKey: "ft_setupTypingTestPassed")
        isCompleted = true
        return true
    }
}
