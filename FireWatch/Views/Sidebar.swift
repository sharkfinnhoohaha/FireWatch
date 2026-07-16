import SwiftUI

private enum SidebarSelection: Hashable {
    case signal(String)
    case incident(String)
}

private enum SidebarPalette {
    static let background = Color(red: 0.055, green: 0.063, blue: 0.078)
    static let chrome = Color(red: 0.072, green: 0.082, blue: 0.098)
}

struct Sidebar: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            scopePicker
            List(selection: sidebarSelection) {
                AlertsSection(alerts: state.alerts)
                if state.showDispatch {
                    Section("\(state.filteredSignals.count) dispatch signals") {
                        ForEach(state.filteredSignals.prefix(80)) { signal in
                            DispatchRow(signal: signal)
                                .tag(SidebarSelection.signal(signal.id))
                        }
                    }
                }
                Section("\(state.filteredIncidents.count) incidents") {
                    ForEach(state.filteredIncidents) { incident in
                        IncidentRow(incident: incident)
                            .tag(SidebarSelection.incident(incident.id))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SidebarPalette.background)
            .searchable(text: $state.searchText, prompt: "Fire or county")
            StatusFooter(state: state)
        }
        .background(SidebarPalette.background)
        .navigationTitle("FireWatch / Intel")
        .toolbar { ToolbarItem { filterMenu } }
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding {
            if let id = state.selectedSignalID { return .signal(id) }
            if let id = state.selectedIncidentID { return .incident(id) }
            return nil
        } set: { selection in
            switch selection {
            case .signal(let id): state.selectSignal(id)
            case .incident(let id): state.selectIncident(id)
            case nil: state.clearSelection()
            }
        }
    }

    private var scopePicker: some View {
        Picker("Incident scope", selection: Binding(get: { state.scope }, set: { state.scope = $0 })) {
            ForEach(IncidentScope.allCases) { scope in Text(scope.label).tag(scope) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(8)
        .background(SidebarPalette.chrome)
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Wildfires", isOn: Binding(get: { state.showWildfires }, set: { state.showWildfires = $0 }))
            Toggle("Prescribed", isOn: Binding(get: { state.showPrescribed }, set: { state.showPrescribed = $0 }))
            Toggle("Nationwide", isOn: Binding(get: { state.allStates }, set: { state.allStates = $0; Task { await state.refresh() } }))
            Divider()
            Picker("Sort", selection: Binding(get: { state.sort }, set: { state.sort = $0 })) {
                ForEach(IncidentSort.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Picker("Refresh", selection: Binding(get: { state.refreshSeconds }, set: { state.refreshSeconds = $0; state.restartTimer() })) {
                Text("Every minute").tag(60); Text("Every 2 minutes").tag(120); Text("Every 5 minutes").tag(300); Text("Off").tag(0)
            }
            Stepper("Notification radius: \(Int(state.notificationRadius)) mi", value: Binding(get: { state.notificationRadius }, set: { state.notificationRadius = $0 }), in: 10...3_000, step: 10)
        } label: { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
    }
}

private struct DispatchRow: View {
    let signal: DispatchSignal
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(signal.isUnconfirmed ? .gray : .cyan)
                Text(signal.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer()
                if let acres = signal.acres { Text("\(acres.formatted(.number.precision(.fractionLength(0)))) ac").foregroundStyle(.secondary) }
            }
            HStack {
                Text(signal.type.uppercased()).foregroundStyle(signal.isUnconfirmed ? Color.secondary : Color.cyan)
                Spacer()
                Text(signal.center)
                if let date = signal.reportedAt { Text(date, format: .relative(presentation: .numeric)) }
            }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
}

private struct IncidentRow: View {
    let incident: IncidentFeature
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(incident.name).font(.headline)
                Spacer()
                Text(acresText).monospacedDigit()
            }
            HStack {
                Text(locationText)
                Spacer()
                if let distance = incident.distanceMiles(from: AppState.home) { Text("\(distance, format: .number.precision(.fractionLength(0))) mi") }
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let containment = incident.properties?.percentContained {
                    ProgressView(value: containment, total: 100).tint(containment >= 80 ? .green : .red)
                    Text("\(Int(containment))%").font(.caption2).monospacedDigit()
                } else { Text("Containment —").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if let updated = incident.modifiedDate { Text(updated, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 4)
    }
    private var statusColor: Color {
        if incident.isPrescribed { return .orange }
        if (incident.properties?.percentContained ?? 0) >= 80 { return .green }
        return incident.isWildfire ? .red : .gray
    }
    private var locationText: String {
        let place = incident.properties?.pooCounty ?? incident.properties?.pooCity ?? "Unknown location"
        let state = incident.properties?.pooState?.replacingOccurrences(of: "US-", with: "")
        return [place, state].compactMap { $0 }.joined(separator: " · ")
    }
    private var acresText: String {
        guard let acres = incident.properties?.incidentSize else { return "— ac" }
        return acres >= 1_000 ? "\((acres / 1_000).formatted(.number.precision(.fractionLength(1))))k ac" : "\(acres.formatted(.number.precision(.fractionLength(0)))) ac"
    }
}

private struct StatusFooter: View {
    let state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if state.isRefreshing { ProgressView().controlSize(.small) }
                Text(status).lineLimit(1)
                if state.isShowingCachedData { Text("STALE").foregroundStyle(.orange).bold() }
            }
            Text("WFIGS / WildCAD / ALERT / Open-Meteo / NASA / NWS · Personal situational-awareness tool — not an official alerting service.")
                .lineLimit(2)
            if !state.failures.isEmpty { Text(failureText).foregroundStyle(.orange).lineLimit(2) }
        }.font(.caption2).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(SidebarPalette.chrome)
    }
    private var status: String { "Updated \(state.lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "—") · \(state.incidents.count) incidents" }
    private var failureText: String {
        [("WFIGS", state.failures.incidents), ("perimeters", state.failures.perimeters), ("VIIRS", state.failures.hotspots), ("NWS", state.failures.alerts), ("WildCAD", state.failures.dispatch), ("cameras", state.failures.cameras), ("wind", state.failures.wind)]
            .compactMap { $0.1 == nil ? nil : $0.0 }.joined(separator: ", ") + " unavailable"
    }
}
