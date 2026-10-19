import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var stats = StatsManager.shared
    @ObservedObject var modelManager = LocalModelManager.shared
    @ObservedObject var inferenceService = LocalInferenceService.shared
    @ObservedObject var learningEngine = LearningEngine.shared
    @ObservedObject var resourceMonitor = SystemResourceMonitor.shared
    @ObservedObject var contextCollector = DeepContextCollector.shared
    @ObservedObject var cotypistMigrator = CotypistMigrator.shared

    @State public var selectedTab = 0
    @State private var showAdvancedEngineSettings = false

    // Dictionary new entry state
    @State private var newDictKey: String = ""
    @State private var newDictValue: String = ""

    // Slash Command new entry state
    @State private var newSlashTrigger: String = ""
    @State private var newSlashExpansion: String = ""

    // Custom style training corpus input
    @State private var customTrainingCorpus: String = ""
    @State private var trainingFeedbackMessage: String?

    // App rule new entry state
    @State private var newAppBundleId: String = ""
    @State private var newAppName: String = ""

    // History search & filter state
    @State private var historySearchQuery: String = ""
    @State private var historySelectedAppFilter: String = "All"

    // Analytics state
    @State private var statsRange: StatsTimeRange = .last30Days
    @State private var statsMetric: StatsMetricType = .words
    @State private var csvExportBanner: String?

    public init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            PlaygroundView()
                .tabItem {
                    Label("Playground", systemImage: "keyboard")
                }
                .tag(0)

            aiAndGeneralTab
                .tabItem {
                    Label("General & AI", systemImage: "cpu")
                }
                .tag(1)

            personalizationTab
                .tabItem {
                    Label("Personalization", systemImage: "brain.head.profile")
                }
                .tag(2)

            historyTab
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(3)

            appRulesTab
                .tabItem {
                    Label("App Rules", systemImage: "app.badge.checkmark")
                }
                .tag(4)

            statsTab
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar.xaxis")
                }
                .tag(5)

            performanceAndSetupTab
                .tabItem {
                    Label("Battery & Setup", systemImage: "bolt.shield")
                }
                .tag(6)
        }
        .frame(width: 820, height: 640)
        .padding(8)
    }

    // MARK: - Reusable Cotypist Migration Card
    private var cotypistMigrationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.indigo)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Migrate from Cotypist")
                            .font(.system(size: 13.5, weight: .semibold))
                        if cotypistMigrator.isCotypistInstalled {
                            Text(String(format: "%.1f MB DB • %d days stats", cotypistMigrator.detectedDatabaseSizeMB, cotypistMigrator.detectedStatsDaysCount))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                                .foregroundColor(.green)
                        }
                    }
                    Text("Import your writing history, learned phrases, per-app rules, and daily completion statistics from Cotypist.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    _ = cotypistMigrator.migrateAllFromCotypist(includeDatabaseKeychainUnlock: true)
                }) {
                    Text(cotypistMigrator.isMigrating ? "Importing..." : "Import from Cotypist")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.small)
                .disabled(cotypistMigrator.isMigrating)
            }

            if let report = cotypistMigrator.lastMigrationReport {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text(report.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.indigo.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.indigo.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Tab 1: General & AI
    private var aiAndGeneralTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if cotypistMigrator.isCotypistInstalled {
                    cotypistMigrationCard
                }

                // 1. Core Writing & Correction Controls
                VStack(alignment: .leading, spacing: 12) {
                    Text("Writing & Autocorrect")
                        .font(.headline)

                    HStack(spacing: 24) {
                        Toggle("Enable inline completions system-wide", isOn: $settings.isEnabled)
                        Toggle("Fix spelling & contractions inline", isOn: $settings.showSuggestedTypoFixes)
                        Toggle("Show word count in menu bar", isOn: $settings.showWordCountInMenuBar)
                            .onChange(of: settings.showWordCountInMenuBar) { _, _ in
                                MenuBarController.shared.rebuildMenu()
                            }
                    }

                    Divider()

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Completion length")
                                .font(.system(size: 13, weight: .medium))
                            Text("How many words FreeTypist suggests at a time.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Picker("", selection: $settings.completionLength) {
                            ForEach(CompletionLengthPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }

                    HStack(spacing: 24) {
                        Toggle("Complete inside existing lines (mid-line)", isOn: $settings.enableMidLineCompletions)
                            .font(.caption)
                        Toggle("Hold back completions when a typo is detected", isOn: $settings.hideCompletionsOnSuspectedTypo)
                            .font(.caption)
                        Toggle("Enable :shortcode: emoji lookup", isOn: $settings.enableEmojiSuggestions)
                            .font(.caption)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

                // 2. Local AI Model Selection
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local AI Model")
                                .font(.headline)
                            Text("Recommended for your Mac (\(resourceMonitor.cpuChipName), \(resourceMonitor.totalSystemMemoryGB) GB RAM): \(modelManager.recommendedModel.name)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Picker("", selection: $modelManager.selectedModel) {
                            ForEach(modelManager.availableModels) { model in
                                let isDownloaded = modelManager.isModelDownloaded(model)
                                Text(isDownloaded ? "\(model.displayName) — Ready" : model.displayName)
                                    .tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 270)
                        .onChange(of: modelManager.selectedModel) { _, newModel in
                            if let path = modelManager.downloadedModelPaths[newModel.id] {
                                inferenceService.startServer(for: path)
                            }
                        }
                    }

                    if !modelManager.isModelDownloaded(modelManager.selectedModel) {
                        HStack(spacing: 12) {
                            if modelManager.isDownloading {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView(value: modelManager.downloadProgress)
                                        .progressViewStyle(.linear)
                                    Text(modelManager.downloadStatusMessage)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Button("Cancel") {
                                    modelManager.cancelDownload()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Text("Using built-in instant predictor & autocorrect. Download \(modelManager.selectedModel.name) for full neural generation.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button(action: {
                                    modelManager.startDownload(model: modelManager.selectedModel)
                                }) {
                                    Text("Download (\(modelManager.selectedModel.sizeText))")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    } else {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(inferenceService.isServerRunning ? Color.green : Color.blue)
                                .frame(width: 8, height: 8)
                            Text(inferenceService.serverStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Reveal Models Folder") {
                                modelManager.revealInFinder()
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)

                            if inferenceService.isServerRunning {
                                Button("Sleep Engine") {
                                    inferenceService.stopServer(reason: "Sleeping (Idle Memory Saver)")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            } else if let path = modelManager.activeModelPath() {
                                Button("Start Engine") {
                                    inferenceService.startServer(for: path)
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

                // 3. Context Awareness (Clean & Simple)
                VStack(alignment: .leading, spacing: 8) {
                    Text("On-Device Context Awareness")
                        .font(.headline)
                    Text("Allow FreeTypist to use surrounding text on your Mac for more relevant suggestions. Everything stays 100% on your device.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 24) {
                        Toggle("Active window & document text", isOn: $settings.readSurroundingWindowText)
                            .font(.caption)
                        Toggle("Recent clipboard text", isOn: $settings.useClipboardContext)
                            .font(.caption)
                        Toggle("Window title & browser domain", isOn: $settings.useWindowEnvironmentContext)
                            .font(.caption)
                        Toggle("Redact API keys & secrets", isOn: $settings.sanitizeSecretsLocally)
                            .font(.caption)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

                // 4. Optional Collapsible Advanced Appearance & Engine Tuning
                DisclosureGroup("Advanced Appearance & Engine Tuning", isExpanded: $showAdvancedEngineSettings) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 20) {
                            HStack(spacing: 8) {
                                Text("Trigger Delay: \(settings.debounceMs) ms")
                                    .font(.caption)
                                    .frame(width: 135, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(settings.debounceMs) },
                                    set: { settings.debounceMs = Int($0) }
                                ), in: 40...400, step: 20)
                            }

                            HStack(spacing: 8) {
                                Text("Ghost Opacity: \(Int(settings.ghostTextOpacity * 100))%")
                                    .font(.caption)
                                    .frame(width: 135, alignment: .leading)
                                Slider(value: $settings.ghostTextOpacity, in: 0.30...0.95, step: 0.05)
                            }
                        }

                        HStack(spacing: 20) {
                            HStack(spacing: 8) {
                                Text(String(format: "Temperature: %.2f", settings.temperature))
                                    .font(.caption)
                                    .frame(width: 135, alignment: .leading)
                                Slider(value: $settings.temperature, in: 0.0...1.0, step: 0.05)
                            }

                            HStack(spacing: 8) {
                                Text("Ghost Color:")
                                    .font(.caption)
                                    .fixedSize()
                                Picker("", selection: $settings.ghostTextColorPreset) {
                                    ForEach(GhostColorPreset.allCases) { preset in
                                        Text(preset.rawValue).tag(preset)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 170)
                            }
                        }

                        HStack(spacing: 18) {
                            HStack(spacing: 6) {
                                Text("Context Window:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                Picker("", selection: $settings.contextWindowSize) {
                                    Text("512 tokens").tag(512)
                                    Text("1024 tokens").tag(1024)
                                    Text("2048 tokens").tag(2048)
                                }
                                .labelsHidden()
                                .frame(width: 115)
                                .controlSize(.small)
                            }

                            HStack(spacing: 6) {
                                Text("GPU Layers:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                Picker("", selection: $settings.gpuLayers) {
                                    Text("All (Metal)").tag(99)
                                    Text("Balanced (16)").tag(16)
                                    Text("CPU Only").tag(0)
                                }
                                .labelsHidden()
                                .frame(width: 120)
                                .controlSize(.small)
                            }

                            HStack(spacing: 6) {
                                Text("KV Cache:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                Picker("", selection: $settings.kvCacheQuantization) {
                                    Text("Q8_0 (Fast)").tag("q8_0")
                                    Text("Q4_0 (Low RAM)").tag("q4_0")
                                    Text("F16 (Full)").tag("f16")
                                }
                                .labelsHidden()
                                .frame(width: 120)
                                .controlSize(.small)
                            }

                            Spacer()
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.subheadline.weight(.medium))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            }
            .padding(14)
        }
    }

    // MARK: - Tab 2: Personalization
    private var personalizationTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Personalize Word Choice")
                                .font(.headline)
                            Text("Adapts completions to your vocabulary, recurring phrases, and writing style.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.personalizationStrength) {
                            ForEach(PersonalizationStrength.allCases) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 270)
                    }

                    Text(settings.personalizationStrength.subtitle)
                        .font(.caption)
                        .foregroundColor(.accentColor)

                    Divider()

                    HStack(spacing: 24) {
                        Toggle("Learn from accepted completions", isOn: $settings.recordWritingForPersonalization)
                            .font(.caption)
                        Toggle("Also learn from completed sentences", isOn: $settings.recordUnacceptedWriting)
                            .font(.caption)
                            .disabled(!settings.recordWritingForPersonalization)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                // Custom AI Instructions Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Writing Style & Tone")
                            .font(.headline)
                        Spacer()
                        Text("Default Tone:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize()
                        Picker("", selection: $settings.selectedTone) {
                            ForEach(TonePreset.allCases) { tone in
                                Text(tone.rawValue).tag(tone)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 195)
                        Button("Reset") {
                            settings.personaDescription = "Write in a friendly, professional and empathetic voice. Keep your sentences short, concise and readable."
                        }
                        .controlSize(.small)
                    }

                    TextEditor(text: $settings.personaDescription)
                        .font(.system(size: 12.5))
                        .frame(height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                // Two-column: Personal Dictionary + Slash Snippets
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Abbreviations & Shortcuts")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(settings.personalDictionary.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    HStack {
                                        Text(key)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                                        Image(systemName: "arrow.right")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(value)
                                            .font(.system(size: 11.5))
                                            .lineLimit(1)
                                        Spacer()
                                        Button(action: {
                                            settings.personalDictionary.removeValue(forKey: key)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.secondary)
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .frame(height: 125)

                        HStack(spacing: 6) {
                            TextField("Shortcut", text: $newDictKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            TextField("Expanded phrase...", text: $newDictValue)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                let k = newDictKey.trimmingCharacters(in: .whitespaces)
                                let v = newDictValue.trimmingCharacters(in: .whitespaces)
                                if !k.isEmpty && !v.isEmpty {
                                    settings.personalDictionary[k] = v
                                    newDictKey = ""
                                    newDictValue = ""
                                }
                            }
                            .controlSize(.small)
                            .disabled(newDictKey.isEmpty || newDictValue.isEmpty)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Slash Snippets (/sig, /lgtm)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Toggle("Enabled", isOn: $settings.enableSlashCommands)
                                .controlSize(.mini)
                        }

                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(settings.slashCommands.sorted(by: { $0.key < $1.key }), id: \.key) { cmd, expansion in
                                    HStack {
                                        Text(cmd)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.14)))
                                        Text(expansion.replacingOccurrences(of: "\n", with: " "))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Button(action: {
                                            settings.slashCommands.removeValue(forKey: cmd)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.secondary)
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .frame(height: 125)

                        HStack(spacing: 6) {
                            TextField("/cmd", text: $newSlashTrigger)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            TextField("Snippet text...", text: $newSlashExpansion)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                var k = newSlashTrigger.trimmingCharacters(in: .whitespaces)
                                let v = newSlashExpansion.trimmingCharacters(in: .whitespaces)
                                if !k.isEmpty && !v.isEmpty {
                                    if !k.hasPrefix("/") { k = "/" + k }
                                    settings.slashCommands[k] = v
                                    newSlashTrigger = ""
                                    newSlashExpansion = ""
                                }
                            }
                            .controlSize(.small)
                            .disabled(newSlashTrigger.isEmpty || newSlashExpansion.isEmpty)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                }

                // Style Sample Trainer
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Train on Writing Sample")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        if let msg = trainingFeedbackMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        Button("Learn Style") {
                            let text = customTrainingCorpus.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            learningEngine.trainOnCustomCorpus(text)
                            customTrainingCorpus = ""
                            trainingFeedbackMessage = "Learned phrases & vocabulary!"
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(customTrainingCorpus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    TextField("Paste sample emails or messages to teach FreeTypist your phrasing...", text: $customTrainingCorpus)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            }
            .padding(14)
        }
    }

    // MARK: - Tab 3: Typing History & Learned Phrases
    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            cotypistMigrationCard

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learned Writing History")
                        .font(.headline)
                    Text("\(learningEngine.historyRecords.count) samples • \(learningEngine.learnedPhrases.count) learned phrases • \(learningEngine.vocabularyCounts.count) vocabulary words")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive, action: {
                    learningEngine.eraseAllHistory()
                }) {
                    Text("Clear History")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                TextField("Search history or phrases...", text: $historySearchQuery)
                    .textFieldStyle(.roundedBorder)

                Text("App:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()

                Picker("", selection: $historySelectedAppFilter) {
                    Text("All Apps (\(learningEngine.historyRecords.count))").tag("All")
                    ForEach(learningEngine.countByApp(), id: \.bundleId) { entry in
                        Text("\(entry.appName) (\(entry.count))").tag(entry.bundleId)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Writing Samples")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredHistoryRecords) { rec in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(rec.appName)
                                            .font(.system(size: 11, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                                        Spacer()
                                        Text(rec.updatedAt, style: .relative)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Button(action: {
                                            learningEngine.deleteRecord(id: rec.id)
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    HStack(spacing: 0) {
                                        Text(rec.textUpToCursor)
                                            .font(.system(size: 12))
                                            .foregroundColor(.primary)
                                        if let acc = rec.acceptedCompletion {
                                            Text(acc)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    .lineLimit(3)
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Learned Phrase Patterns")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(learningEngine.learnedPhrases.prefix(20)) { stat in
                                HStack {
                                    Text(stat.prefix)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text(stat.continuation)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("×\(stat.frequency)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(7)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
                            }
                        }
                    }
                }
                .frame(width: 300)
            }
        }
        .padding(14)
    }

    private var filteredHistoryRecords: [WritingHistoryRecord] {
        learningEngine.historyRecords.filter { rec in
            let matchesApp = (historySelectedAppFilter == "All" || rec.appBundleIdentifier == historySelectedAppFilter)
            guard matchesApp else { return false }
            let q = historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return rec.textUpToCursor.lowercased().contains(q)
                || (rec.acceptedCompletion?.lowercased().contains(q) ?? false)
                || rec.appName.lowercased().contains(q)
        }
    }

    // MARK: - Tab 4: Clean Per-App Rules (No pointless Tone dropdown when Disabled)
    private var appRulesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-App Behavior & Exclusions")
                .font(.headline)
            Text("Customize tone and instructions for specific apps, or pause completions completely in password managers and sensitive apps.")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($settings.appRules) { $rule in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rule.appName)
                                        .font(.system(size: 13.5, weight: .semibold))
                                    Text(rule.bundleIdentifier)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if rule.isExcluded {
                                    Text("Completions Off")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                                } else {
                                    HStack(spacing: 6) {
                                        Text("Tone:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize()

                                        Picker("", selection: Binding(
                                            get: { rule.customTone ?? settings.selectedTone },
                                            set: { rule.customTone = $0 }
                                        )) {
                                            ForEach(TonePreset.allCases) { t in
                                                Text(t.rawValue).tag(t)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(width: 175)
                                        .controlSize(.small)
                                    }
                                }

                                Toggle("Pause in App", isOn: $rule.isExcluded)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)

                                Button(action: {
                                    settings.appRules.removeAll { $0.id == rule.id }
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            if !rule.isExcluded {
                                TextField("Optional custom instructions for \(rule.appName)...", text: $rule.customInstructions)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .font(.system(size: 11.5))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("App Name (e.g. Discord)", text: $newAppName)
                    .textFieldStyle(.roundedBorder)
                TextField("Bundle ID (e.g. com.hnc.Discord)", text: $newAppBundleId)
                    .textFieldStyle(.roundedBorder)
                Button("Add App") {
                    let name = newAppName.trimmingCharacters(in: .whitespaces)
                    let bundle = newAppBundleId.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && !bundle.isEmpty {
                        settings.appRules.append(AppRule(bundleIdentifier: bundle, appName: name, isExcluded: false))
                        newAppName = ""
                        newAppBundleId = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAppName.isEmpty || newAppBundleId.isEmpty)
            }
        }
        .padding(14)
    }

    // MARK: - Tab 5: Analytics
    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("Completion Analytics")
                        .font(.headline)

                    Spacer()

                    Text("Metric:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()

                    Picker("", selection: $statsMetric) {
                        ForEach(StatsMetricType.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230)

                    Text("Range:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()

                    Picker("", selection: $statsRange) {
                        ForEach(StatsTimeRange.allCases) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 135)
                }

                HStack(spacing: 10) {
                    statCard(
                        title: "Words Autocompleted",
                        value: "\(stats.totalWordsSaved)",
                        subtitle: "Daily Avg: \(stats.dailyAverageWords) words",
                        icon: "text.word.spacing",
                        color: .blue
                    )
                    statCard(
                        title: "Estimated Time Saved",
                        value: stats.estimatedTimeSavedFormatted,
                        subtitle: "+\(stats.estimatedWPMBoost) WPM effective boost",
                        icon: "clock.badge.checkmark",
                        color: .green
                    )
                    statCard(
                        title: "Active Streak",
                        value: "\(stats.currentStreakDays) days",
                        subtitle: "\(stats.todayWordsSaved) words today",
                        icon: "flame.fill",
                        color: .orange
                    )
                    statCard(
                        title: "Acceptance Rate",
                        value: "\(stats.acceptanceRatePercentage)%",
                        subtitle: "\(stats.totalCharactersSaved) chars saved",
                        icon: "bolt.horizontal.circle.fill",
                        color: .purple
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Daily Activity (\(statsRange.rawValue) — \(statsMetric.rawValue))")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        if let banner = csvExportBanner {
                            Text(banner)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        Button(action: {
                            let csv = stats.exportCSV()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(csv, forType: .string)
                            csvExportBanner = "Copied CSV to clipboard"
                        }) {
                            Text("Copy CSV")
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    }

                    let records = stats.records(for: statsRange)
                    let maxVal = max(1, records.map { metricValue(for: $0) }.max() ?? 1)

                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(records) { rec in
                            let val = metricValue(for: rec)
                            let barHeight = max(6, CGFloat(val) / CGFloat(maxVal) * 108.0)
                            VStack(spacing: 3) {
                                if records.count <= 14 || val == maxVal {
                                    Text("\(val)")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        LinearGradient(
                                            colors: val > 0 ? [.accentColor, .indigo.opacity(0.75)] : [.secondary.opacity(0.2), .secondary.opacity(0.1)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(maxWidth: 22, minHeight: 6, maxHeight: barHeight)
                                Text(String(rec.dateString.suffix(2)))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 140)
                    .padding(.top, 4)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Top Applications")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        ForEach(stats.appWordsBreakdown.sorted(by: { $0.value > $1.value }).prefix(6), id: \.key) { app, count in
                            HStack {
                                Text(app)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(count) words")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Completion Sources")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        ForEach(stats.sourceBreakdown.sorted(by: { $0.value > $1.value }).prefix(6), id: \.key) { src, count in
                            HStack {
                                Text(src)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(count) words")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(14)
        }
    }

    private func metricValue(for record: DayStatsRecord) -> Int {
        switch statsMetric {
        case .words: return record.wordsSaved
        case .completions: return record.completionsAccepted
        case .characters: return record.charactersSaved
        }
    }

    // MARK: - Tab 6: Battery, Shortcuts & Setup (Full-Width Aligned Cards)
    private var performanceAndSetupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Accessibility Permission Status
                PermissionsView()

                // 2. Live Resource & System Health Banner
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("System Performance & Footprint", systemImage: "gauge.with.dots.needle.33percent")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "Memory: %.1f MB", resourceMonitor.appMemoryMB))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.green)
                    }

                    HStack(spacing: 20) {
                        Label(
                            resourceMonitor.isOnBatteryPower
                                ? "Battery Power (\(resourceMonitor.batteryPercentage)%)"
                                : "AC Power (\(resourceMonitor.batteryPercentage)%)",
                            systemImage: resourceMonitor.isOnBatteryPower ? "battery.75" : "bolt.fill"
                        )
                        .font(.caption)

                        Label(
                            resourceMonitor.isSecureInputActive
                                ? "Secure Input Active (Password field focused)"
                                : "Secure Input: Clear (Shortcuts active)",
                            systemImage: resourceMonitor.isSecureInputActive ? "lock.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundColor(resourceMonitor.isSecureInputActive ? .orange : .secondary)

                        Spacer()
                    }

                    if resourceMonitor.isMacOSInlinePredictionEnabled {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("macOS built-in inline text predictions are enabled and may overlap with FreeTypist.")
                                .font(.caption)
                            Spacer()
                            Button("Turn Off macOS Predictions") {
                                resourceMonitor.disableMacOSInlinePredictions()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                // 3. Battery Power Settings (Full-Width Aligned)
                VStack(alignment: .leading, spacing: 10) {
                    Label("On Battery Power", systemImage: "bolt.batteryblock")
                        .font(.headline)
                    Toggle("Only show completions on demand while on battery power", isOn: $settings.batteryOnlyOnDemand)
                    Toggle("Generate shorter completions on battery to reduce GPU energy use", isOn: $settings.batteryShorterCompletions)
                    HStack {
                        Stepper("Auto-sleep local Metal engine after \(settings.idleEngineSleepMinutes) mins of inactivity", value: $settings.idleEngineSleepMinutes, in: 5...60, step: 5)
                        Spacer()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                // 4. Keyboard Shortcuts & Escape Behavior (Full-Width Aligned)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Keyboard Shortcuts & Escape Behavior", systemImage: "command")
                        .font(.headline)
                    HStack {
                        Text("When pressing Escape while a suggestion is visible:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize()
                        Spacer()
                        Picker("", selection: $settings.escapeBehavior) {
                            ForEach(EscapeKeyBehavior.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 340)
                    }
                    Toggle("Include trailing space when accepting a single word (⌥Tab)", isOn: $settings.includeTrailingSpaceOnWordAccept)
                    Toggle("Include trailing punctuation when accepting a single word", isOn: $settings.includeTrailingPunctuationOnWordAccept)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            }
            .padding(14)
        }
    }

    private func statCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Spacer()
            }
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
