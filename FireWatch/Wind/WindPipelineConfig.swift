import Foundation

// Central, tunable configuration for the wind analysis pipeline.
// Port of app/lib/pipeline/config.ts — defaults match the web implementation
// exactly so the two stay comparable field for field.

/// Which background field the analysis corrects toward.
enum BackgroundSource: String, Equatable, Sendable {
    case rtma, hrrr, openmeteo
}

/// Whether the rendered layer represents sustained wind or peak gust.
enum AveragingTarget: String, Equatable, Sendable {
    case sustained, gust
}

/// Per-network anemometer measurement heights, metres above ground.
struct NetworkHeights: Equatable, Sendable {
    var raws = 6.1 // 20 ft, NWS RAWS standard
    var asos = 10.0 // 33 ft, ASOS/AWOS standard
    var cwop = 10.0 // documented fallback when metadata missing
    var utility = 10.0 // per-station tower height overrides this
    var standard = 10.0 // used when a station's network cannot be classified
}

/// Per-network native averaging periods, seconds, for harmonization.
struct NetworkAveraging: Equatable, Sendable {
    /// ASOS sustained wind: 2-minute average.
    var asosSustainedSec = 120.0
    /// ASOS gust: 5-second peak.
    var asosGustSec = 5.0
    /// RAWS: 10-minute average, reported hourly.
    var rawsSec = 600.0
    /// Utility tower telemetry, commonly near 5-minute.
    var utilitySec = 300.0
    /// CWOP varies widely; documented assumption.
    var cwopSec = 300.0
    /// Target averaging period the analysis harmonizes to, seconds.
    var targetSec = 120.0
}

struct QCConfig: Equatable, Sendable {
    /// Reject if 10 m speed exceeds this hard ceiling, km/h (gross error).
    var maxSpeedKmh = 240.0
    /// Reject negative or non-finite speeds (always on; here for documentation).
    var rejectNonFinite = true
    /// Buddy check: neighbour search radius, km.
    var buddyRadiusKm = 25.0
    /// Buddy check: minimum neighbours required to evaluate (else skip, not reject).
    var buddyMinNeighbours = 3
    /// Buddy check: reject if station deviates from the buddy median by more than
    /// this many km/h AND by more than buddyTolFactor times the buddy spread.
    var buddyTolKmh = 25.0
    var buddyTolFactor = 3.0
    /// Persistence/sanity: reject if the reading is older than this, minutes.
    var maxAgeMin = 240.0
}

struct AnalysisConfig: Equatable, Sendable {
    /// Horizontal decorrelation length, km (e-folding of the OI weight).
    var decorrelationKm = 18.0
    /// Vertical decorrelation length, m: shortens influence across elevation.
    var decorrelationVerticalM = 400.0
    /// Extra decorrelation tightening factor applied across a ridgeline crest.
    var ridgePenalty = 2.0
    /// Background error term in the OI denominator (relaxes to background where
    /// obs are sparse). Larger means the field trusts the background more.
    var backgroundError = 0.5
    /// Confidence saturation constant: effective obs weight at which confidence
    /// reaches roughly half.
    var confidenceHalfWeight = 1.0
    /// Mixed-layer depth scale, m: confidence decays within this distance of the
    /// inversion base (the boundary is where the blend is least trustworthy).
    var inversionUncertaintyM = 150.0
}

struct TemporalConfig: Equatable, Sendable {
    /// Half-window around the analysis time within which obs are admitted, min.
    var windowMin = 120.0
    /// Time-decay e-folding, minutes: older obs are weighted lower.
    var decayMin = 45.0
    /// RAWS hourly obs are treated as a low-frequency anchor, not a
    /// high-frequency input; their analysis weight is multiplied by this (0..1).
    var anchorWeight = 0.6
}

/// Roughness length z0 fallback per network, metres, when land cover lookup is
/// unavailable. Derived from WRF/HRRR roughness tables for typical siting.
struct RoughnessFallback: Equatable, Sendable {
    var raws = 0.1 // open shrubland/grass ridge siting
    var asos = 0.03 // airport short grass
    var cwop = 0.4 // suburban, roughest assumption
    var utility = 0.1
    var standard = 0.1
}

struct WindPipelineConfig: Equatable, Sendable {
    var background: BackgroundSource = .openmeteo
    var averaging: AveragingTarget = .sustained
    var heights = NetworkHeights()
    var periods = NetworkAveraging()
    var qc = QCConfig()
    var analysis = AnalysisConfig()
    var temporal = TemporalConfig()
    var roughnessFallbackM = RoughnessFallback()
    /// Inversion base elevation used by the air-mass tagger, metres. Stands in
    /// for an HRRR-derived value until the vertical profile is wired. Typical
    /// Southern California marine-layer top.
    var inversionBaseM = 500.0

    /// Default configuration, mirroring the web pipeline's DEFAULT_CONFIG.
    static let standard = WindPipelineConfig()

    /// Convenience matching the web loadConfig behaviour: targeting gusts moves
    /// the harmonization target to the 5-second peak duration.
    static func standard(averaging: AveragingTarget) -> WindPipelineConfig {
        var cfg = WindPipelineConfig()
        cfg.averaging = averaging
        cfg.periods.targetSec = averaging == .gust ? 5.0 : 120.0
        return cfg
    }
}
