import Foundation

// Step 4 (support): aerodynamic roughness length z0 per station.
// Port of app/lib/pipeline/roughness.ts.
//
// The rigorous source is a land-cover dataset (NLCD or the WRF/HRRR roughness
// tables) sampled at the station coordinate. Until that raster lookup is wired
// we fall back to a documented per-network default that reflects typical siting
// (RAWS on open shrubland ridges, ASOS on mown airport grass, CWOP in rougher
// suburban settings).

/// Coarse network family used to pick heights and roughness defaults.
enum NetworkKind: String, Equatable, Sendable {
    case raws, asos, cwop, utility, standard
}

/// Map a free-text network label onto a NetworkKind.
func classifyNetwork(_ network: String?) -> NetworkKind {
    let n = (network ?? "").lowercased()
    if n.contains("raws") { return .raws }
    if n.contains("asos") || n.contains("awos") || n.contains("airport") { return .asos }
    if n.contains("cwop") || n.contains("personal") { return .cwop }
    if n.contains("utility") || n.contains("tower") { return .utility }
    return .standard
}

/// A roughness provider returns z0 (metres) for a coordinate. The default
/// implementation is network-keyed fallbacks; a future NLCD/WRF provider would
/// implement the same signature and read a land-cover raster instead.
typealias RoughnessProvider = (_ lon: Double, _ lat: Double, _ kind: NetworkKind) -> Double

/// Documented per-network fallback provider, sourced from WindPipelineConfig.
func fallbackRoughness(_ cfg: WindPipelineConfig) -> RoughnessProvider {
    let r = cfg.roughnessFallbackM
    return { _, _, kind in
        switch kind {
        case .raws: return r.raws
        case .asos: return r.asos
        case .cwop: return r.cwop
        case .utility: return r.utility
        case .standard: return r.standard
        }
    }
}

/// Land-cover roughness provider (NLCD or WRF/HRRR tables).
///
/// STUB: the raster lookup is not wired in this pass. Returns nil to signal
/// "no land-cover value available", so callers fall back to fallbackRoughness.
func landCoverRoughness() -> (_ lon: Double, _ lat: Double) -> Double? {
    { _, _ in nil }
}
