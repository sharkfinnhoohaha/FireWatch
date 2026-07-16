import Foundation

// Observation enrichment orchestrator: the obs-space half of the pipeline.
// Port of app/lib/pipeline/enrich.ts.
//
// Runs the per-station stages in spec order: quality control (3), height
// normalization to 10 m (4), temporal harmonization (5), and air-mass tagging
// (6). The result is a set of observations that are comparable, height-matched,
// time-weighted, and tagged with their air mass, ready for the spatial analysis
// (7) and confidence (8) stages in WindAnalysis.swift.
//
// This stage is pure given its inputs (no network I/O), so it runs identically
// in the app and in the unit tests.

struct EnrichResult {
    /// QC-passed, normalized, harmonized, air-mass-tagged observations.
    var stations: [WindObservation]
    /// Stations dropped by QC, with reasons.
    var rejected: [RejectedObservation]
    /// Stations admitted by QC but dropped by the temporal window.
    var outsideWindow: Int
}

struct EnrichOptions {
    var terrain: TerrainGrid?
    var inversion: InversionModel
    var roughness: RoughnessProvider?
    var qc: QCContext

    init(
        terrain: TerrainGrid? = nil,
        inversion: @escaping InversionModel,
        roughness: RoughnessProvider? = nil,
        qc: QCContext = QCContext()
    ) {
        self.terrain = terrain
        self.inversion = inversion
        self.roughness = roughness
        self.qc = qc
    }
}

/// Assign each station an elevation: keep a reported value, else sample terrain.
private func assignElevation(_ s: WindObservation, terrain: TerrainGrid?) -> WindObservation {
    if s.elevationM != nil { return s }
    guard let terrain else { return s }
    let sample = elevationSampler(grid: terrain)
    var out = s
    out.elevationM = sample(s.lon, s.lat)
    return out
}

func enrichObservations(
    _ raw: [WindObservation],
    cfg: WindPipelineConfig,
    opts: EnrichOptions
) -> EnrichResult {
    let roughness = opts.roughness ?? fallbackRoughness(cfg)

    // Elevation first, so QC neighbours and later stages all see it.
    let located = raw.map { assignElevation($0, terrain: opts.terrain) }

    // 3. Quality control. Failing stations are dropped, not down-weighted.
    let qcResult = runQC(located, cfg: cfg, ctx: opts.qc)

    // 4. Height normalization to 10 m via the neutral log profile.
    let normalized = qcResult.kept.map { s -> WindObservation in
        let kind = classifyNetwork(s.network)
        let z0 = roughness(s.lon, s.lat, kind)
        return normalizeStation(s, z0M: z0, cfg: cfg)
    }

    // 5. Temporal harmonization and time-decay weighting (drops out-of-window).
    var outsideWindow = 0
    var harmonized: [WindObservation] = []
    for s in normalized {
        guard let h = harmonizeStation(s, cfg: cfg) else {
            outsideWindow += 1
            continue
        }
        harmonized.append(h)
    }

    // 6. Air-mass tagging relative to the local inversion base.
    let tagged = harmonized.map { tagStation($0, inversion: opts.inversion) }

    return EnrichResult(stations: tagged, rejected: qcResult.rejected, outsideWindow: outsideWindow)
}
