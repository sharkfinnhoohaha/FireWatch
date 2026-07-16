import Foundation

// Orchestrates a wind-field refresh: observations (Synoptic or NWS), the
// Open-Meteo model background, and the terrain grid run concurrently; the obs
// pipeline enriches (QC → height → temporal → air mass); the analysis is then
// BAKED onto fine grids so the particle renderer samples bilinearly instead of
// re-evaluating the station accumulate per particle per frame. (This implements
// the web audit's "recommended next": precompute the corrected field onto a
// grid so hundreds of vanes stay cheap.)
//
// Port of the orchestration in app/api/wind/route.ts plus the sampler/mode
// construction in app/components/WindMap.tsx.

/// Immutable result of one wind refresh (network + enrichment). Baking to a
/// renderable field happens separately so slider changes never refetch.
struct WindFieldData: Sendable {
    let generatedAt: Date
    let region: WindRegion
    /// QC-passed, height-normalized, harmonized, air-mass-tagged observations.
    let stations: [WindObservation]
    let rejected: [RejectedObservation]
    let outsideWindow: Int
    /// Coarse model background grid (km/h). Nil when Open-Meteo was down; the
    /// bake then falls back to an observations-only IDW background.
    let model: ModelWindGrid?
    let terrain: TerrainGrid?
    let inversionBaseM: Double
    /// "SYNOPTIC" or "NWS" — which provider produced the vanes.
    let obsSource: String
    let warnings: [String]

    /// Bake the analysis onto fine sampling grids. `influenceKm` drives the
    /// OI horizontal decorrelation length (the deck's vane-influence slider).
    func bake(influenceKm: Double) -> BakedWindField {
        var cfg = WindPipelineConfig.standard
        cfg.analysis.decorrelationKm = max(influenceKm, 1)
        cfg.inversionBaseM = inversionBaseM

        let proj = makeProjector(lon0: region.centerLon, lat0: region.centerLat)
        let rawBackground: WindSampler = model.map { modelSampler(grid: $0) }
            ?? idwSampler(stations: stations, proj: proj)
        // The downscale step is always run so wiring WindNinja later needs no
        // edit here (identity today).
        let background = selectDownscaler()(rawBackground, terrain, cfg)
        let inversion = fixedInversion(cfg)
        let analysis = analyzeField(
            background: background,
            stations: stations,
            proj: proj,
            cfg: cfg,
            terrain: terrain,
            inversion: inversion
        )

        // Bake corrected/difference/confidence onto a fine grid (~9 km cells),
        // comfortably finer than both the model grid and the decorrelation floor.
        let axes = buildAxes(bbox: region.bbox, spec: GridSpec(lon: 36, lat: 26))
        let cells = axes.lons.count * axes.lats.count
        var correctedU = [Double](repeating: 0, count: cells)
        var correctedV = [Double](repeating: 0, count: cells)
        var differenceU = [Double](repeating: 0, count: cells)
        var differenceV = [Double](repeating: 0, count: cells)
        var confidenceValues = [Double](repeating: 0, count: cells)
        for j in 0..<axes.lats.count {
            for i in 0..<axes.lons.count {
                let lon = axes.lons[i]
                let lat = axes.lats[j]
                let index = j * axes.lons.count + i
                let c = analysis.corrected(lon, lat)
                let d = analysis.correction(lon, lat)
                correctedU[index] = c.u
                correctedV[index] = c.v
                differenceU[index] = d.u
                differenceV[index] = d.v
                confidenceValues[index] = analysis.confidence(lon, lat)
            }
        }
        let correctedGrid = ModelWindGrid(lons: axes.lons, lats: axes.lats, u: correctedU, v: correctedV)
        let differenceGrid = ModelWindGrid(lons: axes.lons, lats: axes.lats, u: differenceU, v: differenceV)
        let confidenceGrid = WindConfidenceGrid(lons: axes.lons, lats: axes.lats, c: confidenceValues)

        // Shared colour scale: the larger of the background and corrected 95th
        // percentiles, so Model and Corrected read on the same ramp.
        let sharedMax = max(
            estimateMaxSpeed(sampler: background, bbox: region.bbox),
            estimateMaxSpeed(sampler: modelSampler(grid: correctedGrid), bbox: region.bbox),
            1
        )
        let maxDiff = max(
            estimateMaxSpeed(sampler: modelSampler(grid: differenceGrid), bbox: region.bbox),
            0.5
        )

        return BakedWindField(
            bbox: region.bbox,
            model: model,
            corrected: correctedGrid,
            confidence: confidenceGrid,
            sharedMaxKmh: sharedMax,
            maxDiffKmh: maxDiff,
            modelAvailable: model != nil
        )
    }
}

/// Renderable field set: everything the particle layer needs, all grid-backed.
struct BakedWindField: Sendable {
    let bbox: GeoBBox
    let model: ModelWindGrid?
    let corrected: ModelWindGrid
    let confidence: WindConfidenceGrid
    let sharedMaxKmh: Double
    let maxDiffKmh: Double
    let modelAvailable: Bool

    /// Build the renderer field spec for a display mode. Mirrors WindMap.tsx:
    /// Disagreement and Confidence advect through the REAL (corrected) wind so
    /// the flow stays meaningful, and only the colour encodes the scalar.
    func fieldSpec(mode: WindDisplayMode) -> WindFieldSpec {
        let correctedSampler = modelSampler(grid: corrected)
        switch mode {
        case .model:
            let sampler = model.map { modelSampler(grid: $0) } ?? correctedSampler
            return WindFieldSpec(sampler: sampler, scaleKmh: sharedMaxKmh, colorScalar: nil, colorScale: nil)
        case .corrected:
            return WindFieldSpec(sampler: correctedSampler, scaleKmh: sharedMaxKmh, colorScalar: nil, colorScale: nil)
        case .confidence:
            let grid = TerrainGrid(lons: confidence.lons, lats: confidence.lats, z: confidence.c)
            let sample = elevationSampler(grid: grid)
            return WindFieldSpec(
                sampler: correctedSampler,
                scaleKmh: sharedMaxKmh,
                colorScalar: { lon, lat, _ in sample(lon, lat) },
                colorScale: 1
            )
        case .disagreement:
            // With no model background, corrected − model is ~0 everywhere and
            // meaningless — fall back to the corrected view (same as web).
            guard let model else {
                return WindFieldSpec(sampler: correctedSampler, scaleKmh: sharedMaxKmh, colorScalar: nil, colorScale: nil)
            }
            let backgroundSampler = modelSampler(grid: model)
            return WindFieldSpec(
                sampler: correctedSampler,
                scaleKmh: sharedMaxKmh,
                // The advection vec is already the corrected wind here, so reuse
                // it: the gap is corrected − model.
                colorScalar: { lon, lat, vec in
                    let b = backgroundSampler(lon, lat)
                    return hypot(vec.u - b.u, vec.v - b.v)
                },
                colorScale: maxDiffKmh
            )
        }
    }
}

/// One refresh result: the analysis-ready field data plus the legacy
/// WindSnapshot shape the existing UI (deck table, source health) consumes.
struct WindFieldBundle: Sendable {
    let field: WindFieldData
    let legacy: WindSnapshot
}

enum WindFieldEngine {
    /// Full refresh: observations + background + terrain → enriched field data.
    /// Throws only when no usable observations AND no background are available.
    static func refresh(force: Bool) async throws -> WindFieldBundle {
        let region = WindRegion.socal
        let cfg = WindPipelineConfig.standard

        async let backgroundTask = try? WindDataService.fetchBackgroundGrid(region: region, force: force)
        async let terrainTask = try? WindDataService.fetchTerrainGrid(region: region, force: force)

        var warnings: [String] = []
        var obsSource = "NWS"
        var raw: [WindObservation] = []
        if let token = WindCredentials.synopticToken() {
            do {
                raw = try await WindDataService.fetchSynopticStations(region: region, token: token, force: force)
                obsSource = "SYNOPTIC"
            } catch {
                warnings.append("Synoptic failed (\(error.localizedDescription.prefix(40))) — fell back to NWS")
            }
        }
        if raw.isEmpty {
            let nws = await WindDataService.fetchNWSStations(region: region, force: force)
            raw = nws.stations
            warnings.append(contentsOf: nws.warnings)
            obsSource = "NWS"
        }

        let model = await backgroundTask
        let terrain = await terrainTask
        if model == nil { warnings.append("background unavailable — corrected field falls back to observations only") }
        if terrain == nil { warnings.append("terrain unavailable — air-mass rule and ridge weighting disabled this cycle") }
        guard !(raw.isEmpty && model == nil) else {
            throw FeedService.ErrorBox(message: "wind upstreams unavailable (no vanes, no model)")
        }

        let enriched = enrichObservations(
            raw,
            cfg: cfg,
            opts: EnrichOptions(
                terrain: terrain,
                inversion: fixedInversion(cfg),
                qc: QCContext(log: { message in print("[wind-qc] \(message)") })
            )
        )
        if !enriched.rejected.isEmpty { warnings.append("\(enriched.rejected.count) vane(s) rejected by QC") }
        if enriched.outsideWindow > 0 { warnings.append("\(enriched.outsideWindow) vane(s) outside the analysis window") }

        let field = WindFieldData(
            generatedAt: .now,
            region: region,
            stations: enriched.stations,
            rejected: enriched.rejected,
            outsideWindow: enriched.outsideWindow,
            model: model,
            terrain: terrain,
            inversionBaseM: cfg.inversionBaseM,
            obsSource: obsSource,
            warnings: warnings
        )
        return WindFieldBundle(field: field, legacy: legacySnapshot(from: field))
    }

    /// Derive the legacy WindSnapshot (mph) that the existing deck table,
    /// station annotations, and source-health rows consume.
    static func legacySnapshot(from field: WindFieldData) -> WindSnapshot {
        var samples: [WindSample] = []
        if let model = field.model {
            samples.reserveCapacity(model.u.count)
            for j in 0..<model.lats.count {
                for i in 0..<model.lons.count {
                    let index = j * model.lons.count + i
                    let sd = WindVectors.toSpeedDir(u: model.u[index], v: model.v[index])
                    samples.append(WindSample(
                        id: "\(model.lats[j]),\(model.lons[i])",
                        coordinate: .init(latitude: model.lats[j], longitude: model.lons[i]),
                        speedMPH: sd.speed * WindVectors.kmhToMph,
                        directionDegrees: sd.dir,
                        gustMPH: nil
                    ))
                }
            }
        }
        let stations = field.stations.map { obs in
            WeatherStation(
                id: obs.id,
                name: obs.name,
                coordinate: .init(latitude: obs.lat, longitude: obs.lon),
                speedMPH: obs.speedKmh * WindVectors.kmhToMph,
                directionDegrees: obs.dirDeg ?? 0,
                observedAt: obs.observedAt
            )
        }
        return WindSnapshot(samples: samples, stations: stations)
    }
}
