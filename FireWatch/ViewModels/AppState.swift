import SwiftUI
import MapKit

enum IncidentSort: String, CaseIterable, Identifiable {
    case recentlyUpdated, largest, newest, nearest
    var id: String { rawValue }
    var label: String {
        switch self { case .recentlyUpdated: "Recently updated"; case .largest: "Largest"; case .newest: "Newest"; case .nearest: "Nearest to Ventura" }
    }
}

enum IncidentScope: String, CaseIterable, Identifiable {
    case all, attention, nearby, new
    var id: String { rawValue }
    var label: String {
        switch self { case .all: "All"; case .attention: "Attention"; case .nearby: "Nearby"; case .new: "New" }
    }
}

enum WindDisplayMode: String, CaseIterable, Identifiable {
    case model, corrected, disagreement, confidence
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@MainActor
final class AppState: ObservableObject {
    static let homeCoordinate = CLLocationCoordinate2D(latitude: 34.3705, longitude: -119.2290)
    static let home = CLLocation(latitude: homeCoordinate.latitude, longitude: homeCoordinate.longitude)

    @Published var incidents: [IncidentFeature] = [] { didSet { incidentRevision &+= 1; rebuildIncidentCache() } }
    @Published var perimeters: [PerimeterFeature] = [] { didSet { perimeterRevision &+= 1 } }
    @Published var hotspots: [HotspotFeature] = [] { didSet { hotspotRevision &+= 1 } }
    @Published var alerts: [NWSAlertFeature] = []
    @Published var cameras: [AlertCamera] = [] { didSet { cameraRevision &+= 1 } }
    @Published var dispatchSignals: [DispatchSignal] = [] { didSet { dispatchRevision &+= 1; rebuildSignalCache() } }
    @Published var windSamples: [WindSample] = [] { didSet { windRevision &+= 1 } }
    @Published var weatherStations: [WeatherStation] = [] { didSet { stationRevision &+= 1 } }
    @Published var selectedIncidentID: String?
    @Published var selectedCameraID: String?
    @Published var selectedSignalID: String?
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var failures = FeedFailures()
    @Published var staleSources: [String] = []
    @Published var isShowingCachedData = false
    @Published var searchText = "" { didSet { rebuildIncidentCache(); rebuildSignalCache() } }
    @Published var windMode: WindDisplayMode = .model
    @Published var vaneInfluenceMiles = 30.0 { didSet { rebakeWindField() } }
    private(set) var windFieldData: WindFieldData?
    private(set) var bakedWindField: BakedWindField?
    private(set) var windFieldRevision = 0

    @Published var showWildfires: Bool { didSet { defaults.set(showWildfires, forKey: "showWildfires"); rebuildIncidentCache() } }
    @Published var showPrescribed: Bool { didSet { defaults.set(showPrescribed, forKey: "showPrescribed"); rebuildIncidentCache() } }
    @Published var allStates: Bool { didSet { defaults.set(allStates, forKey: "allStates") } }
    @Published var showPerimeters: Bool { didSet { defaults.set(showPerimeters, forKey: "showPerimeters") } }
    @Published var showHotspots: Bool { didSet { defaults.set(showHotspots, forKey: "showHotspots") } }
    @Published var showCameras: Bool { didSet { defaults.set(showCameras, forKey: "showCameras") } }
    @Published var showDispatch: Bool { didSet { defaults.set(showDispatch, forKey: "showDispatch") } }
    @Published var showWind: Bool { didSet { defaults.set(showWind, forKey: "showWind") } }
    @Published var showStations: Bool { didSet { defaults.set(showStations, forKey: "showStations") } }
    @Published private var sortRaw: String { didSet { defaults.set(sortRaw, forKey: "sort"); rebuildIncidentCache() } }
    @Published private var scopeRaw: String { didSet { defaults.set(scopeRaw, forKey: "incidentScope"); rebuildIncidentCache() } }
    @Published var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }
    @Published var notificationRadius: Double { didSet { defaults.set(notificationRadius, forKey: "notificationRadius"); rebuildIncidentCache() } }
    var cameraLatitude: Double { didSet { defaults.set(cameraLatitude, forKey: "cameraLatitude") } }
    var cameraLongitude: Double { didSet { defaults.set(cameraLongitude, forKey: "cameraLongitude") } }
    var cameraDistance: Double { didSet { defaults.set(cameraDistance, forKey: "cameraDistance") } }
    private var refreshLoop: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    @Published private var filteredIncidentCache: [IncidentFeature] = []
    @Published private var filteredSignalCache: [DispatchSignal] = []
    private var nearbyCache: [IncidentFeature] = []
    private var perimeterFingerprint = 0
    private var hotspotFingerprint = 0
    private var dispatchFingerprint = 0
    private(set) var incidentRevision = 0
    private(set) var incidentFilterRevision = 0
    private(set) var perimeterRevision = 0
    private(set) var hotspotRevision = 0
    private(set) var cameraRevision = 0
    private(set) var dispatchRevision = 0
    private(set) var dispatchFilterRevision = 0
    private(set) var stationRevision = 0
    private(set) var windRevision = 0

    init() {
        let defaults = UserDefaults.standard
        showWildfires = defaults.object(forKey: "showWildfires") as? Bool ?? true
        showPrescribed = defaults.object(forKey: "showPrescribed") as? Bool ?? true
        allStates = defaults.object(forKey: "allStates") as? Bool ?? false
        showPerimeters = defaults.object(forKey: "showPerimeters") as? Bool ?? true
        showHotspots = defaults.object(forKey: "showHotspots") as? Bool ?? true
        showCameras = defaults.object(forKey: "showCameras") as? Bool ?? true
        showDispatch = defaults.object(forKey: "showDispatch") as? Bool ?? true
        showWind = defaults.object(forKey: "showWind") as? Bool ?? false
        showStations = defaults.object(forKey: "showStations") as? Bool ?? true
        sortRaw = defaults.string(forKey: "sort") ?? IncidentSort.recentlyUpdated.rawValue
        scopeRaw = defaults.string(forKey: "incidentScope") ?? IncidentScope.all.rawValue
        refreshSeconds = defaults.object(forKey: "refreshSeconds") as? Int ?? 120
        notificationRadius = defaults.object(forKey: "notificationRadius") as? Double ?? 60
        if defaults.integer(forKey: "mapPerformanceDefaultsVersion") < 1 {
            cameraLatitude = Self.homeCoordinate.latitude
            cameraLongitude = Self.homeCoordinate.longitude
            cameraDistance = 480_000
            defaults.set(1, forKey: "mapPerformanceDefaultsVersion")
        } else {
            cameraLatitude = defaults.object(forKey: "cameraLatitude") as? Double ?? Self.homeCoordinate.latitude
            cameraLongitude = defaults.object(forKey: "cameraLongitude") as? Double ?? Self.homeCoordinate.longitude
            cameraDistance = defaults.object(forKey: "cameraDistance") as? Double ?? 480_000
        }
        rebuildIncidentCache()
        rebuildSignalCache()
    }

    var sort: IncidentSort {
        get { IncidentSort(rawValue: sortRaw) ?? .recentlyUpdated }
        set { sortRaw = newValue.rawValue }
    }

    var scope: IncidentScope {
        get { IncidentScope(rawValue: scopeRaw) ?? .all }
        set { scopeRaw = newValue.rawValue }
    }

    var filteredIncidents: [IncidentFeature] {
        filteredIncidentCache
    }

    private func rebuildIncidentCache() {
        incidentFilterRevision &+= 1
        filteredIncidentCache = incidents.filter { incident in
            (searchText.isEmpty || incident.name.localizedCaseInsensitiveContains(searchText) || (incident.properties?.pooCounty?.localizedCaseInsensitiveContains(searchText) == true)) &&
            ((showWildfires && incident.isWildfire) || (showPrescribed && incident.isPrescribed) || (!incident.isWildfire && !incident.isPrescribed)) &&
            isInCurrentScope(incident)
        }.sorted { lhs, rhs in
            switch sort {
            case .recentlyUpdated: (lhs.modifiedDate ?? .distantPast) > (rhs.modifiedDate ?? .distantPast)
            case .largest: (lhs.properties?.incidentSize ?? 0) > (rhs.properties?.incidentSize ?? 0)
            case .newest: (lhs.discoveryDate ?? .distantPast) > (rhs.discoveryDate ?? .distantPast)
            case .nearest: (lhs.distanceMiles(from: Self.home) ?? .greatestFiniteMagnitude) < (rhs.distanceMiles(from: Self.home) ?? .greatestFiniteMagnitude)
            }
        }
        nearbyCache = incidents.filter { $0.isWildfire && ($0.distanceMiles(from: Self.home) ?? .greatestFiniteMagnitude) <= 60 }
            .sorted { ($0.distanceMiles(from: Self.home) ?? .greatestFiniteMagnitude) < ($1.distanceMiles(from: Self.home) ?? .greatestFiniteMagnitude) }
    }

    var recentlyUpdatedCount: Int { incidents.filter { ($0.modifiedDate ?? .distantPast) > Date.now.addingTimeInterval(-3_600) }.count }
    var needsAttentionCount: Int { incidents.filter(isAttentionIncident).count }
    var unmappableCount: Int { incidents.filter { $0.coordinate == nil }.count }
    var unconfirmedSignalCount: Int { dispatchSignals.filter(\.isUnconfirmed).count }

    var filteredSignals: [DispatchSignal] {
        filteredSignalCache
    }

    private func rebuildSignalCache() {
        dispatchFilterRevision &+= 1
        filteredSignalCache = dispatchSignals.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.type.localizedCaseInsensitiveContains(searchText) || $0.center.localizedCaseInsensitiveContains(searchText) }
    }

    func selectIncident(_ id: String?) {
        selectedIncidentID = id
        if id != nil { selectedCameraID = nil; selectedSignalID = nil }
    }

    func selectCamera(_ id: String?) {
        selectedCameraID = id
        if id != nil { selectedIncidentID = nil; selectedSignalID = nil }
    }

    func selectSignal(_ id: String?) {
        selectedSignalID = id
        if id != nil { selectedIncidentID = nil; selectedCameraID = nil }
    }

    func clearSelection() {
        selectedIncidentID = nil
        selectedCameraID = nil
        selectedSignalID = nil
    }

    func selectAdjacent(offset: Int) {
        let items = filteredIncidents
        guard !items.isEmpty else { return }
        guard let selectedIncidentID, let index = items.firstIndex(where: { $0.id == selectedIncidentID }) else {
            selectIncident(items.first?.id)
            return
        }
        selectIncident(items[min(items.count - 1, max(0, index + offset))].id)
    }

    private func isInCurrentScope(_ incident: IncidentFeature) -> Bool {
        switch scope {
        case .all: true
        case .attention: isAttentionIncident(incident)
        case .nearby: (incident.distanceMiles(from: Self.home) ?? .greatestFiniteMagnitude) <= notificationRadius
        case .new: (incident.discoveryDate ?? .distantPast) > Date.now.addingTimeInterval(-86_400)
        }
    }

    private func isAttentionIncident(_ incident: IncidentFeature) -> Bool {
        guard incident.isWildfire else { return false }
        return (incident.properties?.percentContained ?? 0) < 80 &&
            (incident.modifiedDate ?? incident.discoveryDate ?? .distantPast) > Date.now.addingTimeInterval(-86_400)
    }

    var nearbyWildfires: [IncidentFeature] {
        nearbyCache
    }

    func start() {
        guard refreshLoop == nil else { return }
        incidents = FeedService.loadCachedIncidents()
        isShowingCachedData = !incidents.isEmpty
        refreshLoop = Task { [weak self] in
            await DiffEngine.requestAuthorization()
            await self?.refresh()
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = self.refreshSeconds
                if seconds == 0 { try? await Task.sleep(for: .seconds(10)); continue }
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { await self.refresh() }
            }
        }
    }

    func restartTimer() {
        refreshLoop?.cancel()
        refreshLoop = nil
        start()
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let previous = incidents
        let previousAlertIDs = Set(alerts.map(\.id))
        let result = await FeedService.refresh(allStates: allStates, force: force)
        failures = result.failures
        staleSources = result.staleSources
        if let newIncidents = result.incidents {
            let changes = DiffEngine.changes(previous: previous, current: newIncidents, home: Self.home, radius: notificationRadius)
            if incidents != newIncidents { incidents = newIncidents }
            try? FeedService.saveCachedIncidents(newIncidents)
            isShowingCachedData = false
            let newAlerts = (result.alerts ?? []).filter { !previousAlertIDs.contains($0.id) }
            await DiffEngine.notify(changes: changes, newAlerts: newAlerts)
        }
        if let value = result.perimeters {
            let fingerprint = Self.perimeterFingerprint(value)
            if fingerprint != perimeterFingerprint { perimeterFingerprint = fingerprint; perimeters = value }
        }
        if let value = result.hotspots {
            let fingerprint = Self.hotspotFingerprint(value)
            if fingerprint != hotspotFingerprint { hotspotFingerprint = fingerprint; hotspots = value }
        }
        if let value = result.alerts, alerts != value { alerts = value }
        if let value = result.cameras, cameras != value { cameras = value }
        if let value = result.dispatchSignals {
            let fingerprint = Self.dispatchFingerprint(value)
            if fingerprint != dispatchFingerprint { dispatchFingerprint = fingerprint; dispatchSignals = value }
        }
        if let value = result.wind {
            if windSamples != value.samples { windSamples = value.samples }
            if weatherStations != value.stations { weatherStations = value.stations }
        }
        if let field = result.windField {
            windFieldData = field
            rebakeWindField()
        }
        if result.incidents != nil || result.perimeters != nil || result.hotspots != nil || result.alerts != nil || result.cameras != nil || result.dispatchSignals != nil || result.wind != nil { lastUpdated = .now }
        isRefreshing = false
    }

    /// Rebuild the renderable field from the last fetched data. Cheap (pure
    /// math over baked grids), so it runs on every vane-influence change; a
    /// refetch is never needed to re-analyze.
    private func rebakeWindField() {
        bakedWindField = windFieldData?.bake(influenceKm: vaneInfluenceMiles * 1.609344)
        windFieldRevision &+= 1
    }

    func isSourceStale(_ hostFragment: String) -> Bool {
        staleSources.contains { $0.localizedCaseInsensitiveContains(hostFragment) }
    }

    private static func perimeterFingerprint(_ values: [PerimeterFeature]) -> Int {
        var hasher = Hasher(); hasher.combine(values.count)
        for value in values { hasher.combine(value.properties?.name); hasher.combine(value.properties?.acres); hasher.combine(value.outerRings.reduce(0) { $0 + $1.count }) }
        return hasher.finalize()
    }

    private static func hotspotFingerprint(_ values: [HotspotFeature]) -> Int {
        var hasher = Hasher(); hasher.combine(values.count)
        for value in values { hasher.combine(value.coordinate?.latitude); hasher.combine(value.coordinate?.longitude); hasher.combine(value.properties?.hoursOld) }
        return hasher.finalize()
    }

    private static func dispatchFingerprint(_ values: [DispatchSignal]) -> Int {
        var hasher = Hasher(); hasher.combine(values.count)
        for value in values { hasher.combine(value.id); hasher.combine(value.reportedAt); hasher.combine(value.acres); hasher.combine(value.resources) }
        return hasher.finalize()
    }
}
