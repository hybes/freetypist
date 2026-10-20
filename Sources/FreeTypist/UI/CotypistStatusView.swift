import SwiftUI

struct CotypistStatusView: View {
    @ObservedObject var monitor: CotypistMonitor = .shared
    var showWhenInactive = false
    var compact = false

    var body: some View {
        if monitor.isRunning || (showWhenInactive && monitor.isInstalled) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(monitor.isRunning ? "Cotypist is also running" : "Cotypist is not running")
                        .font(.headline)
                    if compact {
                        Spacer()
                        quitButton
                    }
                }
                if monitor.isRunning && !compact {
                    Text("Both apps can show suggestions and handle Tab. Quit Cotypist while you use FreeTypist to avoid conflicting completions.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !compact {
                    HStack {
                        if monitor.isRunning {
                            quitButton
                            Button("Recheck") { monitor.refresh() }
                        }
                        Spacer()
                        Button("Manage Login Items…") { monitor.openLoginItems() }
                    }
                    Text("To keep Cotypist from reopening at login, switch off “Launch automatically at login” in Cotypist’s General settings, or remove it from Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = monitor.actionError { Text(error).font(.callout).foregroundStyle(.red) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill((monitor.isRunning ? Color.orange : Color.primary).opacity(0.06)))
            .onAppear { monitor.startMonitoring() }
        }
    }

    private var quitButton: some View {
        Button(monitor.isQuitting ? "Quitting Cotypist…" : "Quit Cotypist") { monitor.quitCotypist() }
            .buttonStyle(.borderedProminent).disabled(monitor.isQuitting)
    }
}
