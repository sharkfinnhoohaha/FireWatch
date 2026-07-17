import Foundation

// Step 4: height normalization. Port of app/lib/pipeline/heightNormalize.ts.
//
// Stations measure wind at different anemometer heights (RAWS at 6.1 m, ASOS at
// 10 m, CWOP and utility towers vary), so their raw speeds are not comparable
// and must not be blended as-is. We normalize every observation to a common
// 10 m reference using the neutral logarithmic wind profile:
//
//     u_10 = u_meas * ln(10 / z0) / ln(z_meas / z0)
//
// where z0 is the aerodynamic roughness length at the site. The neutral
// assumption holds in the high-wind, well-mixed regime that matters most for
// fire spread; it degrades across stable inversions, which is handled
// separately by the air-mass tagging step (see WindAirMass.swift). This module
// is pure math with no I/O so it is cheap to unit test.

/// Reference height all observations are normalized to, metres.
let referenceHeightM = 10.0

/// Neutral log-profile scaling factor from a measurement height to 10 m.
///
/// Returns ln(10 / z0) / ln(z_meas / z0). Guards the degenerate cases where the
/// measurement height equals the roughness length (log of 1 is 0) or inputs are
/// non-physical, returning 1 (no change) so a bad height never amplifies a gust
/// into a hazardously wrong reading.
func logProfileFactor(measHeightM: Double, z0M: Double) -> Double {
    guard measHeightM > 0, z0M > 0 else { return 1 }
    if measHeightM <= z0M { return 1 } // below the roughness sublayer: do not extrapolate
    let denom = log(measHeightM / z0M)
    if abs(denom) < 1e-9 { return 1 }
    return log(referenceHeightM / z0M) / denom
}

/// Normalize a single speed (any units) from z_meas to 10 m.
func normalizeSpeed(_ speed: Double, measHeightM: Double, z0M: Double) -> Double {
    speed * logProfileFactor(measHeightM: measHeightM, z0M: z0M)
}

/// Resolve the anemometer measurement height for a station. Prefers an explicit
/// per-station height (utility tower height, CWOP metadata) when present on the
/// record, then the per-network default, then the global default.
func measurementHeight(
    _ station: WindObservation,
    kind: NetworkKind,
    cfg: WindPipelineConfig
) -> Double {
    if let h = station.measHeightM, h > 0 { return h }
    switch kind {
    case .raws: return cfg.heights.raws
    case .asos: return cfg.heights.asos
    case .cwop: return cfg.heights.cwop
    case .utility: return cfg.heights.utility
    case .standard: return cfg.heights.standard
    }
}

/// Return a copy of the station with speed and gust normalized to 10 m, plus the
/// height and roughness used recorded for transparency. Direction is unchanged.
func normalizeStation(
    _ station: WindObservation,
    z0M: Double,
    cfg: WindPipelineConfig
) -> WindObservation {
    let kind = classifyNetwork(station.network)
    let measHeightM = measurementHeight(station, kind: kind, cfg: cfg)
    let factor = logProfileFactor(measHeightM: measHeightM, z0M: z0M)
    var out = station
    out.measHeightM = measHeightM
    out.roughnessZ0 = z0M
    out.speed10Kmh = station.speedKmh * factor
    out.gust10Kmh = station.gustKmh.map { $0 * factor }
    return out
}
