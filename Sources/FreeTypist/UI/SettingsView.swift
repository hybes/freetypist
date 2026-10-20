import SwiftUI

public struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var stats = StatsManager.shared
    @ObservedObject var modelManager = LocalModelManager.shared
    @ObservedObject var inferenceService = LocalInferenceService.shared
    @ObservedObject var learningEngine = LearningEngine.shared
    @ObservedObject var resourceMonitor = SystemResourceMonitor.shared
    @ObservedObject var cotypistMigrator = CotypistMigrator.shared
    @ObservedObject var appUpdater = AppUpdater.shared

    @State private var selectedTab: Int = 0
    @State private var newDictKey: String = ""
    @State private var newDictValue: String = ""
    @State private var newAppBundleId: String = ""
    @State private var newAppName: String = ""
    @State private var statsRange: StatsTimeRange = .last14Days
    @State private var statsMetric: StatsMetricType = .words
    @State private var historySearchQuery: String = ""
    @State private var historySelectedAppFilter: String = "All"

    public init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: min(max(initialTab, 0), 4))
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            PlaygroundView()
                .tabItem {
                    Label("Playground", systemImage: "character.cursor.ibeam")
                }
                .tag(0)

            generalTab
                .tabItem {
                    Label("General", systemImage: "slider.horizontal.3")
                }
                .tag(1)

            writingStyleTab
                .tabItem {
                    Label("Writing Style", systemImage: "text.quote")
                }
                .tag(2)

            appRulesTab
                .tabItem {
                    Label("App Rules", systemImage: "app.badge.checkmark")
                }
                .tag(3)

            analyticsAndHistoryTab
                .tabItem {
                    Label("Analytics & History", systemImage: "chart.bar.xaxis")
                }
                .tag(4)
        }
        .frame(width: 800, height: 610)
        .padding(8)
    }

    // MARK: - Cotypist Migration Card
    private var cotypistMigrationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)

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
                    Text("Import your completion statistics, preferences, and per-app rules from Cotypist.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    _ = cotypistMigrator.migrateAllFromCotypist(includeDatabaseKeychainUnlock: true)
                }) {
                    if cotypistMigrator.isMigrating {
                        Text("Importing...")
                    } else if cotypistMigrator.hasCompletedInteractiveImport {
                        Text("Imported ✓")
                    } else {
                        Text("Import from Cotypist")
                    }
                }
                .buttonStyle(.borderedProminent)
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
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Tab 1: General
    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CotypistStatusView(showWhenInactive: true)
                PermissionsView()
                HStack {
                    Text("Run the guided setup to choose a local model and check typing.").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Setup FreeTypist…") { MenuBarController.shared.openSetup() }
                }

                if cotypistMigrator.isCotypistInstalled {
                    cotypistMigrationCard
                }

                // 1. Core Writing & Correction Controls
                VStack(alignment: .leading, spacing: 12) {
                    Text("Completions & Autocorrect")
                        .font(.headline)

                    HStack(spacing: 24) {
                        Toggle("Enable inline completions", isOn: $settings.isEnabled)
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
                        Toggle("Use surrounding window & clipboard context", isOn: Binding(
                            get: { settings.readSurroundingWindowText && settings.useClipboardContext && settings.trackCrossAppContext },
                            set: { enabled in
                                settings.readSurroundingWindowText = enabled
                                settings.useClipboardContext = enabled
                                settings.trackCrossAppContext = enabled
                                settings.trackMultiClipboardHistory = enabled
                            }
                        ))
                            .font(.caption)
                    }

                    Divider()
                    HStack(spacing: 20) {
                        Toggle("Suggest :emoji: shortcuts", isOn: $settings.enableEmojiSuggestions)
                        Toggle("Convert emoticons such as :-)", isOn: $settings.suggestEmojiFromEmoticons)
                        Picker("Skin tone", selection: $settings.preferredEmojiSkinTone) {
                            ForEach(EmojiSkinTone.allCases) { tone in
                                Text(tone.rawValue).tag(tone)
                            }
                        }
                        .frame(width: 190)
                    }
                    .font(.caption)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))

                // 2. Local AI Model Selection
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local AI Model")
                                .font(.headline)
                            Text("Runs 100% locally on your Mac (\(resourceMonitor.cpuChipName), \(resourceMonitor.totalSystemMemoryGB) GB RAM).")
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
                        .frame(width: 250)
                        .onChange(of: modelManager.selectedModel) { _, newModel in
                            if let path = modelManager.downloadedModelPaths[newModel.id] {
                                inferenceService.startServer(for: path)
                            } else {
                                inferenceService.stopServer(reason: "Selected model is not downloaded")
                            }
                        }
                    }

                    if !modelManager.isModelDownloaded(modelManager.selectedModel) {
                        VStack(alignment: .leading, spacing: 8) {
                            if modelManager.isDownloading {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ProgressView(value: modelManager.downloadProgress)
                                            .progressViewStyle(.linear)
                                        Text(modelManager.downloadStatusMessage)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                    }
                                    Button("Cancel") {
                                        modelManager.cancelDownload()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            } else {
                                HStack(spacing: 12) {
                                    Text("Using built-in instant predictor & autocorrect. Download \(modelManager.selectedModel.name) for local neural generation.")
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

                                if !modelManager.downloadStatusMessage.isEmpty {
                                    Text(modelManager.downloadStatusMessage)
                                        .font(.caption)
                                        .foregroundColor(
                                            modelManager.downloadStatusMessage.lowercased().contains("fail") || modelManager.downloadStatusMessage.lowercased().contains("error")
                                                ? .red
                                                : .secondary
                                        )
                                }
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
                                Button(inferenceService.isStarting ? "Loading Model…" : "Start Engine") {
                                    inferenceService.startServer(for: path)
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .disabled(inferenceService.isStarting)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("App Updates").font(.headline)
                        Text("FreeTypist \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Signed updates from type.cnnct.uk")
                            .font(.caption).foregroundColor(.secondary)
                        Toggle("Check for updates automatically", isOn: Binding(
                            get: { appUpdater.automaticallyChecksForUpdates },
                            set: { appUpdater.setAutomaticChecks($0) }
                        ))
                        .disabled(appUpdater.controller == nil)
                    }
                    Spacer()
                    Button("Check for Updates…") { appUpdater.checkForUpdates() }
                        .disabled(!appUpdater.canCheckForUpdates)
                }
                .padding(14)
            }
            .padding(14)
        }
    }

    // MARK: - Tab 2: Writing Style & Abbreviations
    private var writingStyleTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Writing Style & Tone")
                                .font(.headline)
                            Text("Choose how FreeTypist phrases your completions.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
                    }

                    TextEditor(text: $settings.personaDescription)
                        .font(.system(size: 12.5))
                        .frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))

                    HStack(spacing: 24) {
                        Toggle("Adapt to my accepted completions over time", isOn: $settings.recordWritingForPersonalization)
                            .font(.caption)
                        Spacer()
                        Button("Reset Default Prompt") {
                            settings.personaDescription = "Write in a friendly, professional and empathetic voice. Keep your sentences short, concise and readable."
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

                // Abbreviations & Shortcuts
                VStack(alignment: .leading, spacing: 8) {
                    Text("Abbreviations & Shortcuts")
                        .font(.headline)
                    Text("Automatically expand common shorthand as you type.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(settings.personalDictionary.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                HStack {
                                    Text(key)
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(value)
                                        .font(.system(size: 12))
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
                    .frame(height: 180)

                    HStack(spacing: 8) {
                        TextField("Shortcut (e.g. lmk)", text: $newDictKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
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
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newDictKey.isEmpty || newDictValue.isEmpty)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
            .padding(14)
        }
    }

    // MARK: - Tab 3: Per-App Rules
    private var appRulesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-App Behavior & Exclusions")
                .font(.headline)
            Text("Customize tone for specific apps, or pause completions in password managers and sensitive apps.")
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
                        settings.mergeImportedAppRule(AppRule(bundleIdentifier: bundle, appName: name, isExcluded: false))
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

    // MARK: - Tab 4: Analytics & History
    private var analyticsAndHistoryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                        subtitle: "Based on typing 40 words per minute",
                        icon: "clock.badge.checkmark",
                        color: .green
                    )
                    statCard(
                        title: "Active Streak",
                        value: "\(stats.currentStreakDays) \(stats.currentStreakDays == 1 ? "day" : "days")",
                        subtitle: "\(stats.todayWordsSaved) words today",
                        icon: "flame.fill",
                        color: .orange
                    )
                    statCard(
                        title: "Memory Footprint",
                        value: String(format: "%.0f MB", resourceMonitor.appMemoryMB),
                        subtitle: "\(stats.acceptanceRatePercentage)% acceptance rate",
                        icon: "memorychip",
                        color: .purple
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Daily Activity")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Picker("", selection: $statsMetric) {
                            ForEach(StatsMetricType.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)

                        Picker("", selection: $statsRange) {
                            ForEach(StatsTimeRange.allCases) { r in
                                Text(r.rawValue).tag(r)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }

                    let records = stats.records(for: statsRange)
                    let peakValue = records.map { metricValue(for: $0) }.max() ?? 0
                    let maxVal = max(1, peakValue)

                    if peakValue == 0 {
                        Text("No activity in this period.").font(.caption).foregroundColor(.secondary)
                    } else if records.count > 14 {
                        Text("Peak: \(peakValue) \(statsMetric.rawValue.lowercased())")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    HStack(alignment: .bottom, spacing: records.count > 30 ? 1 : 4) {
                        ForEach(records) { rec in
                            let val = metricValue(for: rec)
                            let barHeight = max(6, CGFloat(val) / CGFloat(maxVal) * 100.0)
                            VStack(spacing: 3) {
                                if records.count <= 14 {
                                    Text("\(val)")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(val > 0 ? Color.accentColor : Color.secondary.opacity(0.15))
                                    .frame(maxWidth: 22, minHeight: 6, maxHeight: barHeight)
                                if records.count <= 14 {
                                    Text(String(rec.dateString.suffix(2)))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .help("\(rec.dateString): \(val) \(statsMetric.rawValue.lowercased())")
                            .accessibilityLabel("\(rec.dateString): \(val) \(statsMetric.rawValue.lowercased())")
                        }
                    }
                    .frame(height: 130)
                    .padding(.top, 4)
                    if records.count > 14 {
                        HStack {
                            Text(records.first?.dateString ?? "")
                            Spacer()
                            Text(records.last?.dateString ?? "")
                        }
                        .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

                // Learned History Summary
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Learned Writing History")
                                .font(.subheadline)
                                .fontWeight(.semibold)
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

                    ForEach(learningEngine.historyRecords.prefix(8)) { rec in
                        HStack {
                            Text(rec.appName)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                            Text(rec.textUpToCursor + (rec.acceptedCompletion ?? ""))
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
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
