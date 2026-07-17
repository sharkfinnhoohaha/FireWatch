import Foundation

// Ground-truth vanes and model grids for the wind pipeline. Port of the network
// half of finn-watchduty: fetchFromSynoptic / fetchFromNws (app/api/wind/route.ts),
// openMeteoBackground (pipeline/background.ts), and fetchElevationGrid
// (pipeline/terrain.ts). All requests flow through FeedService.performData so
// they share the app's TTL cache, request coalescing, and stale fallback.

enum WindDataService {
    static let userAgent = "FireWatch-personal (finlaybennett@gmail.com)"
    /// Older than this and a vane is treated as offline rather than drawn as if
    /// it were live — a real hazard on a fire map.
    static let maxAgeMin = 240.0

    // MARK: - Unit handling (port of route.ts toKmh/toC)
    // NWS reports wind in km/h and temp in °C today, but the unitCode is part of
    // the payload and can change per station — respect it rather than assume.

    static func speedToKmh(_ value: Double?, unitCode: String?) -> Double? {
        guard let value else { return nil }
        guard let unitCode else { return value }
        if unitCode.contains("m_s") { return value * 3.6 }
        if unitCode.contains("mile") || unitCode.contains("mph") { return value * 1.609344 }
        if unitCode.contains("knot") || unitCode.contains("kt") { return value * 1.852 }
        return value // km_h-1 (default)
    }

    static func tempToC(_ value: Double?, unitCode: String?) -> Double? {
        guard let value else { return nil }
        guard let unitCode else { return value }
        if unitCode.contains("degF") { return (value - 32) * 5 / 9 }
        if unitCode.contains("K") { return value - 273.15 }
        return value // degC (default)
    }

    /// Coarse network label for an NWS station, inferred from its id.
    static func nwsNetwork(_ id: String) -> String {
        if id.count == 4, id.hasPrefix("K"),
           id.dropFirst().allSatisfy({ $0.isUppercase && $0.isLetter }) {
            return "Airport ASOS/AWOS"
        }
        if id.hasSuffix("C1") { return "RAWS" }
        return "Mesonet"
    }

    // MARK: - Synoptic (Watch Duty's actual vane provider)

    /// One bbox query returns every vane Watch Duty would draw (RAWS,
    /// CWOP/personal, mesonet). Enabled when a token is configured.
    static func fetchSynopticStations(
        region: WindRegion,
        token: String,
        force: Bool
    ) async throws -> [WindObservation] {
        var components = URLComponents(string: "https://api.synopticdata.com/v2/stations/latest")!
        components.queryItems = [
            URLQueryItem(name: "bbox", value: "\(region.bbox.west),\(region.bbox.south),\(region.bbox.east),\(region.bbox.north)"),
            URLQueryItem(name: "vars", value: "wind_speed,wind_direction,wind_gust,air_temp"),
            URLQueryItem(name: "status", value: "active"),
            URLQueryItem(name: "units", value: "metric,speed|kph,temp|C"),
            URLQueryItem(name: "within", value: "120"),
            URLQueryItem(name: "token", value: token),
        ]
        let data = try await FeedService.performData(
            URLRequest(url: components.url!), maxAge: 60, staleAge: 1_800, force: force
        )
        let parsed = try parseSynopticStations(data: data, now: .now)
        return decimate(
            parsed,
            minKm: region.synopticMinSpacingKm,
            cap: region.synopticMaxStations,
            centerLat: region.centerLat
        )
    }

    /// Parse a Synoptic stations/latest payload. Split from the fetch so it is
    /// unit-testable against fixtures. Synoptic values arrive as strings or
    /// numbers depending on the field and network — read both.
    static func parseSynopticStations(data: Data, now: Date) throws -> [WindObservation] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawStations = root["STATION"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        let networks: [String: String] = ["1": "Airport ASOS/AWOS", "2": "RAWS", "65": "CWOP/personal"]
        let iso = ISO8601DateFormatter()

        var parsed: [WindObservation] = []
        for station in rawStations {
            let observations = station["OBSERVATIONS"] as? [String: Any] ?? [:]
            func obsField(_ key: String) -> [String: Any]? { observations[key] as? [String: Any] }
            guard let windSpeed = obsField("wind_speed_value_1"),
                  let speedKmh = looseDouble(windSpeed["value"]) else { continue } // no wind sensor / no recent wind
            guard let lon = looseDouble(station["LONGITUDE"]),
                  let lat = looseDouble(station["LATITUDE"]) else { continue }

            let observedAt = (windSpeed["date_time"] as? String).flatMap { iso.date(from: $0) }
            let ageMin = observedAt.map { max(0, now.timeIntervalSince($0) / 60).rounded() } ?? 0
            if ageMin > maxAgeMin { continue }

            // Synoptic reports ELEVATION in feet; convert to metres for the air-mass rule.
            let elevationM = looseDouble(station["ELEVATION"]).map { $0 * 0.3048 }
            let id = (station["STID"] as? String) ?? String(describing: station["STID"] ?? "unknown")
            let mnet = (station["MNET_ID"] as? String) ?? looseDouble(station["MNET_ID"]).map { String(Int($0)) } ?? ""

            parsed.append(WindObservation(
                id: id,
                name: (station["NAME"] as? String) ?? id,
                lon: lon,
                lat: lat,
                speedKmh: speedKmh,
                dirDeg: obsField("wind_direction_value_1").flatMap { looseDouble($0["value"]) },
                gustKmh: obsField("wind_gust_value_1").flatMap { looseDouble($0["value"]) },
                tempC: obsField("air_temp_value_1").flatMap { looseDouble($0["value"]) },
                observedAt: observedAt,
                ageMin: ageMin,
                network: networks[mnet] ?? "Mesonet",
                elevationM: elevationM
            ))
        }

        // Let the fire-weather RAWS win any spacing tie over a nearby personal
        // station — they're the stations that matter most on a fire map.
        // (Index tiebreak keeps Synoptic's order within each tier: stable sort.)
        return parsed.enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.network == "RAWS" ? 0 : 1
                let r = rhs.element.network == "RAWS" ? 0 : 1
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    /// Accept a JSON value that may be a number or a numeric string.
    static func looseDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Greedy spatial thinning: keep stations ≥ minKm apart, up to `cap`.
    static func decimate(
        _ stations: [WindObservation],
        minKm: Double,
        cap: Int,
        centerLat: Double
    ) -> [WindObservation] {
        var kept: [WindObservation] = []
        let kx = 111.32 * cos(centerLat * .pi / 180)
        let ky = 110.57
        for s in stations {
            if kept.count >= cap { break }
            let ok = kept.allSatisfy { k in
                let dx = (s.lon - k.lon) * kx
                let dy = (s.lat - k.lat) * ky
                return hypot(dx, dy) >= minKm
            }
            if ok { kept.append(s) }
        }
        return kept
    }

    // MARK: - NWS keyless fallback

    private struct NWSLatest: Decodable {
        struct Geometry: Decodable { let coordinates: [Double]? }
        struct Value: Decodable {
            let value: Double?
            let unitCode: String?
        }
        struct Properties: Decodable {
            let stationName: String?
            let timestamp: String?
            let windSpeed: Value?
            let windDirection: Value?
            let windGust: Value?
            let temperature: Value?
        }
        let geometry: Geometry?
        let properties: Properties?
    }

    /// Fetch the latest observation for each configured NWS station — keyless.
    /// A *calm* vane reports speed 0 with a null direction — that is a real,
    /// showable observation, so we keep it. We only drop a vane when the wind
    /// sensor itself reports nothing, or the reading is stale.
    static func fetchNWSStations(
        region: WindRegion,
        force: Bool
    ) async -> (stations: [WindObservation], warnings: [String]) {
        let iso = ISO8601DateFormatter()
        return await withTaskGroup(
            of: (Int, Result<WindObservation, FeedService.ErrorBox>).self
        ) { group in
            for (index, id) in region.nwsStationIds.enumerated() {
                group.addTask {
                    var request = URLRequest(url: URL(string: "https://api.weather.gov/stations/\(id)/observations/latest")!)
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
                    do {
                        let data = try await FeedService.performData(request, maxAge: 60, staleAge: 3_600, force: force)
                        let latest = try JSONDecoder().decode(NWSLatest.self, from: data)
                        guard let coords = latest.geometry?.coordinates, coords.count >= 2,
                              let speedKmh = speedToKmh(latest.properties?.windSpeed?.value,
                                                        unitCode: latest.properties?.windSpeed?.unitCode) else {
                            throw FeedService.ErrorBox(message: "no wind in latest observation")
                        }
                        let observedAt = (latest.properties?.timestamp).flatMap { iso.date(from: $0) }
                        let ageMin = observedAt.map { max(0, Date.now.timeIntervalSince($0) / 60).rounded() } ?? 0
                        if ageMin > maxAgeMin {
                            throw FeedService.ErrorBox(message: "stale (\(Int(ageMin)) min)")
                        }
                        return (index, .success(WindObservation(
                            id: id,
                            name: latest.properties?.stationName ?? id,
                            lon: coords[0],
                            lat: coords[1],
                            speedKmh: speedKmh,
                            dirDeg: latest.properties?.windDirection?.value,
                            gustKmh: speedToKmh(latest.properties?.windGust?.value,
                                                unitCode: latest.properties?.windGust?.unitCode),
                            tempC: tempToC(latest.properties?.temperature?.value,
                                           unitCode: latest.properties?.temperature?.unitCode),
                            observedAt: observedAt,
                            ageMin: ageMin,
                            network: nwsNetwork(id)
                        )))
                    } catch let box as FeedService.ErrorBox {
                        return (index, .failure(box))
                    } catch {
                        return (index, .failure(FeedService.ErrorBox(message: error.localizedDescription)))
                    }
                }
            }
            var results: [(Int, Result<WindObservation, FeedService.ErrorBox>)] = []
            for await value in group { results.append(value) }
            results.sort { $0.0 < $1.0 }

            var stations: [WindObservation] = []
            var warnings: [String] = []
            for (index, result) in results {
                switch result {
                case .success(let station): stations.append(station)
                case .failure(let error):
                    warnings.append("\(region.nwsStationIds[index]): \(error.message.prefix(50))")
                }
            }
            return (stations, warnings)
        }
    }

    // MARK: - Open-Meteo model background (port of openMeteoBackground)

    /// Open-Meteo current 10 m wind over the grid, in km/h (matching the
    /// pipeline's internal unit). Keyless, the working default background.
    static func fetchBackgroundGrid(
        region: WindRegion,
        force: Bool
    ) async throws -> ModelWindGrid {
        let axes = buildAxes(bbox: region.bbox, spec: region.modelGrid)
        var latArr: [String] = []
        var lonArr: [String] = []
        for lat in axes.lats {
            for lon in axes.lons {
                latArr.append(String(format: "%.4f", lat))
                lonArr.append(String(format: "%.4f", lon))
            }
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: latArr.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: lonArr.joined(separator: ",")),
            URLQueryItem(name: "current", value: "wind_speed_10m,wind_direction_10m"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
        ]
        let data = try await FeedService.performData(
            URLRequest(url: components.url!), maxAge: 1_800, staleAge: 21_600, force: force
        )
        let points = try JSONDecoder().decode([OpenMeteoWindResponse].self, from: data)
        guard points.count == latArr.count else { throw URLError(.cannotParseResponse) }
        var u = [Double](repeating: 0, count: points.count)
        var v = [Double](repeating: 0, count: points.count)
        for (k, point) in points.enumerated() {
            let vec = WindVectors.toVec(
                speedKmh: point.current.windSpeed,
                dirFromDeg: point.current.windDirection
            )
            u[k] = vec.u
            v[k] = vec.v
        }
        return ModelWindGrid(lons: axes.lons, lats: axes.lats, u: u, v: v)
    }

    // MARK: - Open-Meteo terrain elevation (port of fetchElevationGrid)

    private struct ElevationResponse: Decodable { let elevation: [Double] }

    /// Fetch a terrain elevation grid over the bbox. Batches to the elevation
    /// API's 100-point-per-call budget. Terrain is static: cached for a week.
    static func fetchTerrainGrid(
        region: WindRegion,
        force: Bool
    ) async throws -> TerrainGrid {
        let axes = buildAxes(bbox: region.bbox, spec: region.terrainGrid)
        var lonArr: [Double] = []
        var latArr: [Double] = []
        for lat in axes.lats {
            for lon in axes.lons {
                lonArr.append(lon)
                latArr.append(lat)
            }
        }
        var z: [Double] = []
        z.reserveCapacity(lonArr.count)
        var start = 0
        while start < lonArr.count {
            let end = min(start + 100, lonArr.count)
            let lats = latArr[start..<end].map { String(format: "%.4f", $0) }.joined(separator: ",")
            let lons = lonArr[start..<end].map { String(format: "%.4f", $0) }.joined(separator: ",")
            var components = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
            components.queryItems = [
                URLQueryItem(name: "latitude", value: lats),
                URLQueryItem(name: "longitude", value: lons),
            ]
            let data = try await FeedService.performData(
                URLRequest(url: components.url!), maxAge: 604_800, staleAge: 2_592_000, force: force
            )
            let response = try JSONDecoder().decode(ElevationResponse.self, from: data)
            guard response.elevation.count == end - start else { throw URLError(.cannotParseResponse) }
            z.append(contentsOf: response.elevation)
            start = end
        }
        return TerrainGrid(lons: axes.lons, lats: axes.lats, z: z)
    }
}
