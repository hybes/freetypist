import SwiftUI

struct SetupView: View {
    @ObservedObject private var setup = SetupState.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var models = LocalModelManager.shared
    @ObservedObject private var engine = LocalInferenceService.shared
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var isTestingModel = false
    @State private var modelTestMessage: String?
    @State private var modelTestError: String?
    @State private var modelTestTask: Task<Void, Never>?
    let onFinish: () -> Void

    private var engineReady: Bool {
        engine.isServerRunning && models.activeModelPath() != nil && engine.currentLoadedModelPath == models.activeModelPath()
    }
    private var modelChecked: Bool { engineReady && setup.verifiedModelID == models.selectedModel.id }
    private var canContinue: Bool {
        switch setup.step {
        case .welcome: true
        case .model: modelChecked || setup.useBasicCompletions
        case .accessibility: permissions.isReady || setup.playgroundOnly
        case .tryTyping: setup.didAcceptCompletion && (engineReady || setup.useBasicCompletions) && (permissions.isReady || setup.playgroundOnly)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 26) {
                ForEach(SetupStep.allCases, id: \.rawValue) { step in
                    Text("\(step.rawValue + 1). \(step.title)")
                        .font(.system(size: 13, weight: step == setup.step ? .semibold : .regular))
                        .foregroundStyle(step == setup.step ? Color.accentColor : Color.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            Group {
                switch setup.step {
                case .welcome: welcome
                case .model: modelSetup
                case .accessibility: accessibilitySetup
                case .tryTyping: typingCheck
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            Divider()
            HStack {
                if setup.step != .welcome {
                    Button("Back") { setup.step = SetupStep(rawValue: setup.step.rawValue - 1)! }
                }
                Spacer()
                if setup.step == .tryTyping {
                    Button("Finish without testing") {
                        if setup.finish(skipTypingTest: true) { onFinish() }
                    }
                    .disabled(!(engineReady || setup.useBasicCompletions) || !(permissions.isReady || setup.playgroundOnly))
                }
                Button(setup.step == .welcome ? "Get Started" : (setup.step == .tryTyping ? "Finish Setup" : "Continue")) {
                    if setup.step == .tryTyping {
                        if setup.finish() { onFinish() }
                    } else { setup.step = SetupStep(rawValue: setup.step.rawValue + 1)! }
                }
                .buttonStyle(.borderedProminent).disabled(!canContinue)
            }.padding(20)
        }
        .frame(width: 820, height: 680)
        .onAppear { permissions.startMonitoring() }
        .onChange(of: models.selectedModel) { _, model in
            setup.verifiedModelID = nil
            setup.useBasicCompletions = false
            modelTestMessage = nil; modelTestError = nil
            modelTestTask?.cancel(); isTestingModel = false
            if settings.activeProvider == .localEmbedded, let path = models.activeModelPath() { engine.startServer(for: path) }
            else if settings.activeProvider == .localEmbedded { engine.stopServer(reason: "Choose Download to set up this model") }
        }
        .onDisappear { modelTestTask?.cancel() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up FreeTypist").font(.largeTitle.weight(.semibold))
            Text("Get a local writing model ready, allow access to other apps, then try a completion. Your writing stays on this Mac.")
                .font(.title3).foregroundColor(.secondary)
            Divider().padding(.vertical, 8)
            Text("Writing defaults").font(.headline)
            Toggle("Enable inline completions", isOn: $settings.isEnabled)
            Toggle("Suggest spelling and contraction fixes", isOn: $settings.showSuggestedTypoFixes)
            Toggle("Enable emoji shortcuts, such as :rocket: → 🚀", isOn: $settings.enableEmojiSuggestions)
            Text("You can adjust writing style, abbreviations and per-app rules later in Settings.").font(.callout).foregroundColor(.secondary)
            Spacer()
            Text("Only the text around your cursor is needed for suggestions. Optional clipboard and surrounding-window context are off for new installations; you can enable them in General.")
                .font(.callout).foregroundColor(.secondary)
        }
    }

    private var modelSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your local AI").font(.largeTitle.weight(.semibold))
            Text("Recommended for this \(SystemResourceMonitor.shared.totalSystemMemoryGB) GB Mac: \(models.recommendedModel.displayName). It balances memory use and response time for short writing suggestions.")
                .foregroundColor(.secondary)
            Picker("Local model", selection: $models.selectedModel) {
                ForEach(models.availableModels) { model in
                    Text(model.displayName + (model.id == models.recommendedModel.id ? " · Recommended" : "")).tag(model)
                }
            }.disabled(models.isDownloading || isTestingModel)
            if models.selectedModel.id != models.recommendedModel.id {
                Button("Use Recommended Model") { models.selectedModel = models.recommendedModel }
                    .disabled(models.isDownloading || isTestingModel)
            }
            Text("Download once, then use it offline. The model stays on your Mac between app updates. No API key or account is needed.")
                .font(.callout).foregroundColor(.secondary)
            Divider()
            if models.isDownloading {
                ProgressView(value: models.downloadProgress)
                Text(models.downloadStatusMessage).font(.callout).foregroundColor(.secondary)
                Button("Cancel Download") { models.cancelDownload() }
            } else if models.isModelDownloaded(models.selectedModel) {
                Text(engineReady ? "\(models.selectedModel.name) is running on this Mac." : engine.serverStatus).font(.callout)
                if !engineReady {
                    Button(engine.isStarting ? "Loading Model…" : "Start Local Model") { startModel() }
                        .disabled(engine.isStarting)
                }
                Button(isTestingModel ? "Testing Model…" : "Test Local Model") { testModel() }
                    .disabled(!engineReady || isTestingModel)
            } else {
                Button("Download \(models.selectedModel.name) (\(models.selectedModel.sizeText))") {
                    settings.activeProvider = .localEmbedded
                    setup.useBasicCompletions = false
                    models.startDownload(model: models.selectedModel)
                }.buttonStyle(.borderedProminent)
            }
            if let error = models.downloadError { Text(error).foregroundColor(.red).font(.callout) }
            if let error = modelTestError { Text(error).foregroundColor(.red).font(.callout) }
            if let message = modelTestMessage { Text(message).foregroundColor(.green).font(.callout) }
            else if modelChecked { Text("This model has passed the local generation check.").foregroundColor(.green).font(.callout) }
            Spacer()
            Toggle("Use basic completions for now; set up AI later", isOn: $setup.useBasicCompletions)
                .disabled(models.isDownloading || isTestingModel)
            if setup.useBasicCompletions {
                Text("The built-in predictor and shortcuts work without a model. AI generation will be available after you download one.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var accessibilitySetup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Use FreeTypist in other apps").font(.largeTitle.weight(.semibold))
                PermissionsView()
                Toggle("Use only the Playground for now", isOn: $setup.playgroundOnly)
                if setup.playgroundOnly && !permissions.isReady {
                    Text("Suggestions will work inside FreeTypist. Come back to Setup to enable them in other apps.")
                        .font(.callout).foregroundColor(.secondary)
                }
            }
        }
    }

    private var typingCheck: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try a completion").font(.title.weight(.semibold))
            Text("Click in the text below and press Tab to accept a suggestion. Option–Tab accepts one word; Escape dismisses it.")
                .foregroundColor(.secondary).font(.callout)
            PlaygroundView(isSetup: true, onAccepted: { setup.didAcceptCompletion = true })
            Text(setup.didAcceptCompletion
                 ? (permissions.isReady ? "Completion accepted. Next, try typing in TextEdit using the menu-bar app." : "Completion accepted. The Playground is ready; allow Accessibility in Setup to use suggestions in other apps.")
                 : "This checks typing inside FreeTypist. Accessibility access is needed to use suggestions in TextEdit and other apps.")
                .font(.callout).foregroundColor(setup.didAcceptCompletion ? .green : .secondary)
            if !engineReady && !setup.useBasicCompletions {
                HStack {
                    Text("The local model is not running.").font(.callout).foregroundColor(.secondary)
                    Button("Check Local AI") { setup.step = .model }
                }
            }
            if !permissions.isReady && !setup.playgroundOnly {
                Button("Check Accessibility Access") { setup.step = .accessibility }
            }
        }
    }

    private func startModel() {
        settings.activeProvider = .localEmbedded
        if let path = models.activeModelPath() { engine.startServer(for: path) }
    }

    private func testModel() {
        guard engineReady else { return }
        let modelID = models.selectedModel.id
        isTestingModel = true; modelTestError = nil; modelTestMessage = nil
        modelTestTask = Task { @MainActor in
            defer { if models.selectedModel.id == modelID { isTestingModel = false } }
            let suite = "com.freetypist.setup-check.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let testSettings = AppSettings(defaults: defaults)
            testSettings.personalizationStrength = .off
            do {
                let result = try await EmbeddedLocalProvider(allowFallback: false).complete(
                    context: PromptContext(precedingText: "Thank you for ", maxWords: 4), settings: testSettings)
                try Task.checkCancellation()
                guard models.selectedModel.id == modelID, engineReady else { return }
                setup.verifiedModelID = modelID
                setup.useBasicCompletions = false
                modelTestMessage = "Local AI responded in \(result.latencyMs) ms: “\(result.text.trimmingCharacters(in: .whitespacesAndNewlines))”"
            } catch is CancellationError { }
            catch { if models.selectedModel.id == modelID { modelTestError = error.localizedDescription } }
        }
    }
}
