import SwiftUI

@main
struct FireWatchApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
            NavigationSplitView {
                Sidebar(state: state).navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
            } detail: {
                FireMap(state: state)
            }
            .toolbarBackground(Color(red: 0.055, green: 0.063, blue: 0.078), for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .frame(minWidth: 950, minHeight: 620)
            .task { state.start() }
        }
        .defaultSize(width: 1300, height: 800)
        .commands {
            CommandMenu("Contributor") {
                Button("Refresh all feeds") { Task { await state.refresh(force: true) } }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Previous incident") { state.selectAdjacent(offset: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("Next incident") { state.selectAdjacent(offset: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Divider()
                ForEach(Array(IncidentScope.allCases.enumerated()), id: \.element) { index, scope in
                    Button("Show \(scope.label)") { state.scope = scope }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }

        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            Label("\(state.nearbyWildfires.count)", systemImage: "flame.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(state.nearbyWildfires.count) active wildfires within 60 mi").font(.headline)
            Divider()
            if state.nearbyWildfires.isEmpty { Text("No nearby wildfires reported").foregroundStyle(.secondary) }
            ForEach(state.nearbyWildfires.prefix(5)) { incident in
                HStack { Text(incident.name); Spacer(); Text("\(incident.distanceMiles(from: AppState.home) ?? 0, format: .number.precision(.fractionLength(0))) mi").foregroundStyle(.secondary) }
            }
            Divider()
            Button("Open FireWatch") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }.padding().frame(width: 330)
    }
}
