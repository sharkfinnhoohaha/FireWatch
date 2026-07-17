import Foundation

// Step 7: blend as correction, not mean. Step 8: confidence field.
// Port of app/lib/pipeline/analysis.ts.
//
// At each observation we compute the obs-minus-background residual (after QC,
// height normalization, temporal harmonization, and air-mass tagging), then
// interpolate the *correction field* onto the grid with optimal-interpolation /
// 2DVar-style weighting and add it to the background. We never arithmetic-mean
// raw station values.
//
// The weighting is terrain aware: it decorrelates over a horizontal length, and
// faster vertically and across a ridgeline crest (a ridge between two points
// means they are often in different flow regimes). The air-mass rule is hard:
// an obs below the inversion contributes zero weight to a cell above it, and
// vice versa.
//
// Alongside the corrected field we produce a co-registered confidence field:
// high where obs are dense and the boundary layer is well mixed, low where obs
// are sparse, near the inversion, or across an air-mass boundary.

/// Bilinear sampler over a scalar elevation grid, clamped at the edges.
func elevationSampler(grid: TerrainGrid) -> (_ lon: Double, _ lat: Double) -> Double {
    let lons = grid.lons
    let lats = grid.lats
    let z = grid.z
    let nLon = lons.count
    guard nLon >= 1, !lats.isEmpty, z.count == nLon * lats.count else {
        return { _, _ in 0 }
    }
    func lerp(_ p: Double, _ q: Double, _ f: Double) -> Double { p + (q - p) * f }
    return { lon, lat in
        let a = locateOnAxis(lons, lon)
        let b = locateOnAxis(lats, lat)
        let ai1 = min(a.i + 1, nLon - 1)
        let bi1 = min(b.i + 1, lats.count - 1)
        func at(_ i: Int, _ j: Int) -> Double { z[j * nLon + i] }
        return lerp(
            lerp(at(a.i, b.i), at(ai1, b.i), a.f),
            lerp(at(a.i, bi1), at(ai1, bi1), a.f),
            b.f
        )
    }
}

private struct PreparedObs {
    let x: Double
    let y: Double
    let lon: Double
    let lat: Double
    let ru: Double
    let rv: Double
    let w0: Double
    let elevationM: Double?
    let airMass: AirMass
}

struct WindAnalysisField {
    /// Background field after downscaling (corrects toward this).
    let background: WindSampler
    /// Corrected wind: background + interpolated, air-mass-aware correction.
    let corrected: WindSampler
    /// Correction increment alone (corrected minus background).
    let correction: WindSampler
    /// Confidence in [0,1], co-registered with the corrected field.
    let confidence: (_ lon: Double, _ lat: Double) -> Double
}

/// Observation velocity from the 10 m-normalized speed and direction.
private func obsVec(_ s: WindObservation) -> WindVec {
    let speed = s.speed10Kmh ?? s.speedKmh
    return WindVectors.toVec(speedKmh: speed, dirFromDeg: s.dirDeg ?? 0)
}

/// Build the corrected field and its confidence field from enriched stations and
/// a (possibly downscaled) background. `terrain` and `inversion` enable the
/// vertical / air-mass weighting; with neither, the analysis degrades gracefully
/// to a horizontal terrain-blind correction.
func analyzeField(
    background: @escaping WindSampler,
    stations: [WindObservation],
    proj: @escaping GeoProjector,
    cfg: WindPipelineConfig,
    terrain: TerrainGrid? = nil,
    inversion: InversionModel? = nil
) -> WindAnalysisField {
    let a = cfg.analysis
    let L2 = a.decorrelationKm * a.decorrelationKm
    let Lz2 = a.decorrelationVerticalM * a.decorrelationVerticalM
    let terrainAt: ((Double, Double) -> Double)? = terrain.map { elevationSampler(grid: $0) }

    // Precompute each obs residual against the background and its analysis weight.
    let obs: [PreparedObs] = stations.map { s in
        let p = proj(s.lon, s.lat)
        let b = background(s.lon, s.lat)
        let o = obsVec(s)
        return PreparedObs(
            x: p.x,
            y: p.y,
            lon: s.lon,
            lat: s.lat,
            ru: o.u - b.u,
            rv: o.v - b.v,
            w0: s.analysisWeight ?? 1,
            elevationM: s.elevationM,
            airMass: s.airMass ?? .unknown
        )
    }

    func cellAirMass(_ lon: Double, _ lat: Double, _ cellElev: Double?) -> AirMass {
        guard let inversion else { return .unknown }
        return classifyAirMass(elevationM: cellElev, inversionBaseM: inversion(lon, lat))
    }

    // True when a ridge crest sits between the obs and the cell, sampled at the
    // path midpoint. A ridge between two points decorrelates the flow, so we
    // tighten the weight by the configured penalty when one is detected.
    func ridgeBetween(
        _ aLon: Double, _ aLat: Double, _ aElev: Double?,
        _ bLon: Double, _ bLat: Double, _ bElev: Double?
    ) -> Bool {
        guard let terrainAt, let aElev, let bElev else { return false }
        let midElev = terrainAt((aLon + bLon) / 2, (aLat + bLat) / 2)
        let higher = max(aElev, bElev)
        // A crest at least 50 m above the higher endpoint counts as a ridge.
        return midElev > higher + 50
    }

    func accumulate(_ lon: Double, _ lat: Double) -> (su: Double, sv: Double, sw: Double) {
        let cellElev = terrainAt.map { $0(lon, lat) }
        let cellAir = cellAirMass(lon, lat, cellElev)
        let p = proj(lon, lat)
        var su = 0.0, sv = 0.0, sw = 0.0
        for o in obs {
            // Air-mass rule: skip obs that may not correct this cell.
            if !canCorrect(obs: o.airMass, cell: cellAir) { continue }
            let d2 = (o.x - p.x) * (o.x - p.x) + (o.y - p.y) * (o.y - p.y)
            var w = o.w0 * exp(-d2 / L2)
            if let cellElev, let oElev = o.elevationM {
                let dz = oElev - cellElev
                w *= exp(-(dz * dz) / Lz2)
                if ridgeBetween(o.lon, o.lat, oElev, lon, lat, cellElev) {
                    w /= a.ridgePenalty
                }
            }
            su += w * o.ru
            sv += w * o.rv
            sw += w
        }
        return (su, sv, sw)
    }

    let corrected: WindSampler = { lon, lat in
        let b = background(lon, lat)
        if obs.isEmpty { return b }
        let (su, sv, sw) = accumulate(lon, lat)
        let denom = sw + a.backgroundError
        return WindVec(u: b.u + su / denom, v: b.v + sv / denom)
    }

    let correction: WindSampler = { lon, lat in
        if obs.isEmpty { return WindVec(u: 0, v: 0) }
        let (su, sv, sw) = accumulate(lon, lat)
        let denom = sw + a.backgroundError
        return WindVec(u: su / denom, v: sv / denom)
    }

    let confidence: (Double, Double) -> Double = { lon, lat in
        let (_, _, sw) = accumulate(lon, lat)
        // Obs density term: rises from 0 (no nearby usable obs) toward 1.
        let dens = sw / (sw + a.confidenceHalfWeight)
        // Mixed-layer term: low near the inversion base (the boundary is where
        // the blend is least trustworthy), 1 well away from it or no inversion.
        var mixed = 1.0
        if let inversion, let terrainAt {
            if let base = inversion(lon, lat) {
                let dz = terrainAt(lon, lat) - base
                mixed = 1 - exp(-(dz * dz) / (a.inversionUncertaintyM * a.inversionUncertaintyM))
            }
        }
        return max(0, min(1, dens * mixed))
    }

    return WindAnalysisField(
        background: background,
        corrected: corrected,
        correction: correction,
        confidence: confidence
    )
}

/// Sample a confidence field onto a grid, co-registered with the model grid.
func buildConfidenceGrid(
    confidence: (_ lon: Double, _ lat: Double) -> Double,
    lons: [Double],
    lats: [Double]
) -> WindConfidenceGrid {
    var c = [Double](repeating: 0, count: lons.count * lats.count)
    for j in 0..<lats.count {
        for i in 0..<lons.count {
            c[j * lons.count + i] = confidence(lons[i], lats[j])
        }
    }
    return WindConfidenceGrid(lons: lons, lats: lats, c: c)
}
