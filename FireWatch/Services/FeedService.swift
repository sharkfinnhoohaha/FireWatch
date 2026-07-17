import Foundation

struct FeedFailures: Sendable, Equatable {
    var incidents: String?
    var perimeters: String?
    var hotspots: String?
    var alerts: String?
    var cameras: String?
    var dispatch: String?
    var wind: String?
    var isEmpty: Bool { incidents == nil && perimeters == nil && hotspots == nil && alerts == nil && cameras == nil && dispatch == nil && wind == nil }
}

struct RefreshSnapshot: Sendable {
    var incidents: [IncidentFeature]?
    var perimeters: [PerimeterFeature]?
    var hotspots: [HotspotFeature]?
    var alerts: [NWSAlertFeature]?
    var cameras: [AlertCamera]?
    var dispatchSignals: [DispatchSignal]?
    var wind: WindSnapshot?
    var windField: WindFieldData?
    var staleSources: [String] = []
    var failures = FeedFailures()
}

enum FeedService {
    private static let incidentBase = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_Current/FeatureServer/0/query"
    private static let perimeterBase = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query"
    private static let hotspotBase = "https://services9.arcgis.com/RHVPKKiFTONKtxq3/arcgis/rest/services/Satellite_VIIRS_Thermal_Hotspots_and_Fire_Activity/FeatureServer/0/query"
    private static let alertURL = "https://api.weather.gov/alerts/active?area=CA"
    private static let cameraBase = "https://services.arcgis.com/Zs2aNLFN00jrS4gG/ArcGIS/rest/services/Alert_Wildfire_Cameras/FeatureServer/0/query"
    private static let wildCADBase = "https://snknmqmon6.execute-api.us-west-2.amazonaws.com/centers"

    private enum Outcome: Sendable {
        case incidents(Result<[IncidentFeature], ErrorBox>)
        case perimeters(Result<[PerimeterFeature], ErrorBox>)
        case hotspots(Result<[HotspotFeature], ErrorBox>)
        case alerts(Result<[NWSAlertFeature], ErrorBox>)
        case cameras(Result<[AlertCamera], ErrorBox>)
        case dispatch(Result<[DispatchSignal], ErrorBox>)
        case wind(Result<WindFieldBundle, ErrorBox>)
    }

    struct ErrorBox: Error, Sendable { let message: String }

    static func refresh(allStates: Bool, force: Bool = false) async -> RefreshSnapshot {
        await SourceDataCache.shared.beginRefresh()
        return await withTaskGroup(of: Outcome.self, returning: RefreshSnapshot.self) { group in
            group.addTask {
                do { return .incidents(.success(try await fetchIncidents(allStates: allStates, force: force))) }
                catch { return .incidents(.failure(ErrorBox(message: error.localizedDescription))) }
            }
            group.addTask {
                do { return .perimeters(.success(try await fetchPerimeters(allStates: allStates, force: force))) }
                catch { return .perimeters(.failure(ErrorBox(message: error.localizedDescription))) }
            }
            group.addTask {
                do { return .hotspots(.success(try await fetchHotspots(allStates: allStates, force: force))) }
                catch { return .hotspots(.failure(ErrorBox(message: error.localizedDescription))) }
            }
            group.addTask {
                do { return .alerts(.success(try await fetchAlerts(force: force))) }
                catch { return .alerts(.failure(ErrorBox(message: error.localizedDescription))) }
            }
            group.addTask {
                do { return .cameras(.success(try await fetchCameras(force: force))) }
                catch { return .cameras(.failure(ErrorBox(message: error.localizedDescription))) }
            }
            group.addTask {
                do { return .dispatch(.success(try await fetchDispatchSignals(force: force))) }
                catch { return .dispatch(.failure(ErrorBox(message: error.localizedDescription))) }
            }
            group.addTask {
                do { return .wind(.success(try await WindFieldEngine.refresh(force: force))) }
                catch { return .wind(.failure(ErrorBox(message: error.localizedDescription))) }
            }
            var snapshot = RefreshSnapshot()
            for await outcome in group {
                switch outcome {
                case .incidents(.success(let value)): snapshot.incidents = value
                case .incidents(.failure(let error)): snapshot.failures.incidents = error.message
                case .perimeters(.success(let value)): snapshot.perimeters = value
                case .perimeters(.failure(let error)): snapshot.failures.perimeters = error.message
                case .hotspots(.success(let value)): snapshot.hotspots = value
                case .hotspots(.failure(let error)): snapshot.failures.hotspots = error.message
                case .alerts(.success(let value)): snapshot.alerts = value
                case .alerts(.failure(let error)): snapshot.failures.alerts = error.message
                case .cameras(.success(let value)): snapshot.cameras = value
                case .cameras(.failure(let error)): snapshot.failures.cameras = error.message
                case .dispatch(.success(let value)): snapshot.dispatchSignals = value
                case .dispatch(.failure(let error)): snapshot.failures.dispatch = error.message
                case .wind(.success(let value)):
                    snapshot.wind = value.legacy
                    snapshot.windField = value.field
                case .wind(.failure(let error)): snapshot.failures.wind = error.message
                }
            }
            snapshot.staleSources = await SourceDataCache.shared.currentStaleHosts()
            return snapshot
        }
    }

    static func fetchIncidents(allStates: Bool, force: Bool = false) async throws -> [IncidentFeature] {
        let fields = "IncidentName,IncidentSize,PercentContained,FireDiscoveryDateTime,IncidentTypeCategory,POOCounty,POOCity,POOState,ModifiedOnDateTime_dt,TotalIncidentPersonnel,FireCause,IrwinID"
        let baseItems = ["where": allStates ? "1=1" : "POOState='US-CA'", "outFields": fields, "f": "geojson"]
        return try await pagedFeatures(base: incidentBase, query: baseItems, pageSize: 2_000, maxAge: 90, staleAge: 86_400, force: force)
    }

    static func fetchPerimeters(allStates: Bool, force: Bool = false) async throws -> [PerimeterFeature] {
        let fields = "poly_IncidentName,poly_GISAcres,attr_PercentContained,attr_IncidentTypeCategory"
        let items = ["where": allStates ? "1=1" : "attr_POOState='US-CA'", "outFields": fields, "f": "geojson", "geometryPrecision": "4"]
        return try await pagedFeatures(base: perimeterBase, query: items, pageSize: 2_000, maxAge: 300, staleAge: 86_400, force: force)
    }

    static func fetchHotspots(allStates: Bool, force: Bool = false) async throws -> [HotspotFeature] {
        var items = ["where": "hours_old<=24", "outFields": "frp,confidence,hours_old", "f": "geojson", "resultRecordCount": "8000"]
        if !allStates {
            items.merge(["geometry": "-124.6,32.4,-113.9,42.1", "geometryType": "esriGeometryEnvelope", "inSR": "4326", "spatialRel": "esriSpatialRelIntersects"]) { _, new in new }
        }
        let collection: GeoJSONFeatureCollection<HotspotFeature> = try await request(base: hotspotBase, query: items, maxAge: 120, staleAge: 21_600, force: force)
        return collection.features.filter { $0.coordinate != nil }
    }

    static func fetchAlerts(force: Bool = false) async throws -> [NWSAlertFeature] {
        var request = URLRequest(url: URL(string: alertURL)!)
        request.setValue("FireWatch-personal (finlaybennett@gmail.com)", forHTTPHeaderField: "User-Agent")
        let collection: GeoJSONFeatureCollection<NWSAlertFeature> = try await perform(request, maxAge: 60, staleAge: 3_600, force: force)
        let regex = try Regex("red flag|fire weather|evacuation|fire warning").ignoresCase()
        return collection.features.filter { alert in
            guard let event = alert.properties.event else { return false }
            return event.firstMatch(of: regex) != nil
        }
    }

    static func fetchCameras(force: Bool = false) async throws -> [AlertCamera] {
        let response: CameraArcGISResponse = try await request(base: cameraBase, query: [
            "where": "1=1",
            "outFields": "*",
            "returnGeometry": "true",
            "outSR": "4326",
            "resultRecordCount": "5000",
            "f": "json"
        ], maxAge: 86_400, staleAge: 604_800, force: force)
        return response.features.compactMap { feature in
            let attributes = feature.attributes
            guard let latitude = attributes.latitude ?? feature.geometry?.y,
                  let longitude = attributes.longitude ?? feature.geometry?.x,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            let rawID = attributes.id ?? attributes.webcamName ?? attributes.fid.map(String.init) ?? UUID().uuidString
            let imageURL = secureURL(attributes.link)
            var viewerComponents = URLComponents(string: "https://alertwest.live/")!
            viewerComponents.queryItems = [URLQueryItem(name: "camera", value: rawID)]
            let viewerURL = viewerComponents.url ?? secureURL(attributes.ownerLink) ?? URL(string: "https://alertwest.live/")
            return AlertCamera(
                id: rawID,
                name: attributes.webcamName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? rawID,
                coordinate: .init(latitude: latitude, longitude: longitude),
                imageURL: imageURL,
                viewerURL: viewerURL,
                owner: attributes.alertWildfire ?? attributes.calfireUnit
            )
        }
    }

    static func fetchDispatchSignals(force: Bool = false) async throws -> [DispatchSignal] {
        // Public WildCAD-E dispatch centers covering California. These are early signals,
        // deliberately kept separate from authoritative WFIGS incidents in the UI.
        let centers = ["CANCIC", "CAYICC", "CAMICC", "CACCCC", "CAMNFC", "CAANCC", "CAOVCC", "CALPCC", "CASBCC", "CAONCC", "CASQCC", "CASDIC", "CARICC", "CASICC", "CAYPCC", "CAPNFC", "CAGVCC", "CASTCC"]
        let batches = await withTaskGroup(of: (String, Result<[WildCADEnvelope], ErrorBox>).self) { group in
            for center in centers {
                group.addTask {
                    do {
                        let value: [WildCADEnvelope] = try await perform(URLRequest(url: URL(string: "\(wildCADBase)/\(center)/incidents")!), maxAge: 30, staleAge: 21_600, force: force)
                        return (center, .success(value))
                    } catch {
                        return (center, .failure(ErrorBox(message: error.localizedDescription)))
                    }
                }
            }
            var result: [(String, Result<[WildCADEnvelope], ErrorBox>)] = []
            for await value in group { result.append(value) }
            return result
        }

        let supportedTypes = ["wildfire", "smoke check", "false alarm", "nonstatistical fire", "prescribed fire"]
        let cutoff = Date.now.addingTimeInterval(-96 * 3_600)
        var signals: [DispatchSignal] = []
        var succeeded = false
        for (center, batch) in batches {
            guard case .success(let envelopes) = batch else { continue }
            succeeded = true
            for record in envelopes.flatMap(\.data) {
                guard let latitude = record.latitude.flatMap(Double.init),
                      let longitude = record.longitude.flatMap(Double.init),
                      (-90...90).contains(latitude), (-180...180).contains(longitude),
                      let type = record.type,
                      supportedTypes.contains(where: { type.localizedCaseInsensitiveContains($0) }) else { continue }
                let reportedAt = wildCADDate(record.date)
                guard reportedAt == nil || reportedAt! >= cutoff else { continue }
                let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Unnamed dispatch"
                signals.append(DispatchSignal(
                    id: record.uuid ?? "\(center)-\(record.incNum ?? name)-\(record.date ?? "")",
                    center: center,
                    incidentNumber: record.incNum,
                    name: name,
                    type: type,
                    coordinate: .init(latitude: latitude, longitude: longitude),
                    reportedAt: reportedAt,
                    acres: record.acres.flatMap(Double.init),
                    resources: record.resources?.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank } ?? [],
                    status: record.fireStatus,
                    webComment: record.webComment
                ))
            }
        }
        guard succeeded else { throw URLError(.cannotConnectToHost) }
        return Array(Dictionary(grouping: signals, by: \.id).compactMap { $0.value.first })
            .sorted { ($0.reportedAt ?? .distantPast) > ($1.reportedAt ?? .distantPast) }
    }

    // Wind observations, model background, and terrain now come from the
    // analysis pipeline: see WindFieldEngine (orchestration), WindDataService
    // (Synoptic / NWS / Open-Meteo fetchers), and FireWatch/Wind/ generally.

    static func fetchCameraImage(_ url: URL) async throws -> Data {
        try await performData(URLRequest(url: url), maxAge: 15, staleAge: 3_600, force: false)
    }

    private static func request<T: Decodable>(base: String, query: [String: String], maxAge: TimeInterval = 0, staleAge: TimeInterval = 0, force: Bool = false) async throws -> T {
        var components = URLComponents(string: base)!
        components.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        return try await perform(URLRequest(url: components.url!), maxAge: maxAge, staleAge: staleAge, force: force)
    }

    private static func pagedFeatures<Feature: Decodable>(base: String, query: [String: String], pageSize: Int, maxAge: TimeInterval, staleAge: TimeInterval, force: Bool) async throws -> [Feature] {
        var result: [Feature] = []
        var offset = 0
        while true {
            var pageQuery = query
            pageQuery["resultOffset"] = String(offset)
            pageQuery["resultRecordCount"] = String(pageSize)
            let page: GeoJSONFeatureCollection<Feature> = try await request(base: base, query: pageQuery, maxAge: maxAge, staleAge: staleAge, force: force)
            result.append(contentsOf: page.features)
            guard page.features.count == pageSize else { return result }
            offset += page.features.count
        }
    }

    private static func perform<T: Decodable>(_ request: URLRequest, maxAge: TimeInterval = 0, staleAge: TimeInterval = 0, force: Bool = false) async throws -> T {
        let data = try await performData(request, maxAge: maxAge, staleAge: staleAge, force: force)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// Internal (not private): the wind data service routes its requests through
    /// the same TTL cache, coalescing, and stale-fallback machinery.
    static func performData(_ request: URLRequest, maxAge: TimeInterval = 0, staleAge: TimeInterval = 0, force: Bool = false) async throws -> Data {
        try await SourceDataCache.shared.data(for: request, maxAge: maxAge, staleAge: staleAge, force: force)
    }

    private static func secureURL(_ string: String?) -> URL? {
        guard var string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        if string.hasPrefix("http://") { string = "https://" + string.dropFirst(7) }
        return URL(string: string)
    }

    private static func wildCADDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        if let value = formatter.date(from: string) { return value }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: string)
    }

    static func loadCachedIncidents() -> [IncidentFeature] {
        guard let data = try? Data(contentsOf: cacheURL),
              let value = try? JSONDecoder().decode([IncidentFeature].self, from: data) else { return [] }
        return value
    }

    static func saveCachedIncidents(_ incidents: [IncidentFeature]) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(incidents).write(to: cacheURL, options: .atomic)
    }

    static var cacheURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("FireWatch", isDirectory: true).appendingPathComponent("incidents.json")
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}

private actor SourceDataCache {
    static let shared = SourceDataCache()

    private struct Record: Codable, Sendable {
        let fetchedAt: Date
        let data: Data
    }

    private var memory: [String: Record] = [:]
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var lastDiskPrune = Date.distantPast
    private var staleHosts: Set<String> = []
    private let session: URLSession
    private let directory: URL

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1_024 * 1_024, diskCapacity: 192 * 1_024 * 1_024)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: configuration)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = root.appendingPathComponent("FireWatch/SourceCache", isDirectory: true)
    }

    func beginRefresh() { staleHosts.removeAll(keepingCapacity: true) }
    func currentStaleHosts() -> [String] { staleHosts.sorted() }

    func data(for originalRequest: URLRequest, maxAge: TimeInterval, staleAge: TimeInterval, force: Bool) async throws -> Data {
        guard let url = originalRequest.url else { throw URLError(.badURL) }
        let key = stableKey(url.absoluteString)
        let cached = loadRecord(key: key)
        if !force, let cached, Date.now.timeIntervalSince(cached.fetchedAt) <= maxAge {
            return cached.data
        }
        if !force, let active = inFlight[key] { return try await active.value }

        var request = originalRequest
        if force { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let session = session
        let task = Task<Data, Error> {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
            return data
        }
        inFlight[key] = task
        do {
            let data = try await task.value
            inFlight[key] = nil
            store(Record(fetchedAt: .now, data: data), key: key)
            return data
        } catch {
            inFlight[key] = nil
            if let cached, staleAge > 0, Date.now.timeIntervalSince(cached.fetchedAt) <= staleAge {
                if let host = request.url?.host { staleHosts.insert(host) }
                return cached.data
            }
            throw error
        }
    }

    private func loadRecord(key: String) -> Record? {
        if let record = memory[key] { return record }
        let url = directory.appendingPathComponent(key).appendingPathExtension("cache")
        guard let data = try? Data(contentsOf: url), let record = try? PropertyListDecoder().decode(Record.self, from: data) else { return nil }
        memory[key] = record
        return record
    }

    private func store(_ record: Record, key: String) {
        memory[key] = record
        if memory.count > 96, let oldest = memory.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key { memory[oldest] = nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoded = try PropertyListEncoder().encode(record)
            try encoded.write(to: directory.appendingPathComponent(key).appendingPathExtension("cache"), options: .atomic)
            pruneDiskIfNeeded()
        } catch {
            // A disk-cache failure must never block a live feed response.
        }
    }

    private func stableKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    private func pruneDiskIfNeeded() {
        guard Date.now.timeIntervalSince(lastDiskPrune) > 3_600 else { return }
        lastDiskPrune = .now
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        let entries = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var totalBytes = entries.reduce(0) { $0 + $1.1 }
        var totalFiles = entries.count
        for entry in entries where totalBytes > 192 * 1_024 * 1_024 || totalFiles > 384 {
            try? FileManager.default.removeItem(at: entry.0)
            totalBytes -= entry.1; totalFiles -= 1
        }
    }
}
