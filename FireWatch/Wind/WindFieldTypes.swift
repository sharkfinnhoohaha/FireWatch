import Foundation

// Shared domain types for the wind analysis pipeline.
//
// Port of app/lib/types.ts from the finn-watchduty proof of concept. The
// pipeline works in km/h internally (matching the web implementation and its
// hand-computed test values); convert to mph at the UI edge.

/// A 2-D wind vector in geographic components (km/h). u = eastward, v = northward.
struct WindVec: Equatable, Sendable {
    var u: Double
    var v: Double
}

struct GeoBBox: Equatable, Sendable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double
}

/// Which side of the inversion a point sits on.
enum AirMass: String, Equatable, Sendable {
    case below, above, unknown
}

/// Quality-control outcome for an observation that passed QC.
struct QCVerdict: Equatable, Sendable {
    var passed: Bool
    var flags: [String]
    var reason: String?

    init(passed: Bool, flags: [String], reason: String? = nil) {
        self.passed = passed
        self.flags = flags
        self.reason = reason
    }
}

/// A single ground-truth observation — a Watch Duty "weather vane".
/// Port of `Station` (types.ts); enrichment fields are optional and additive.
struct WindObservation: Equatable, Sendable {
    var id: String
    var name: String
    var lon: Double
    var lat: Double
    /// Sustained wind speed, km/h.
    var speedKmh: Double
    /// Meteorological direction the wind blows FROM, degrees (0 = N, 90 = E).
    /// Nil when the observation is calm/variable (no resolvable direction).
    var dirDeg: Double?
    /// Gust, km/h, if reported.
    var gustKmh: Double?
    /// Air temperature, °C, if reported.
    var tempC: Double?
    /// Timestamp of the observation, when known.
    var observedAt: Date?
    /// Minutes since the observation was taken.
    var ageMin: Double
    /// Network/kind label for the vane (e.g. "RAWS", "Airport ASOS", "Mesonet").
    var network: String?

    // ---- pipeline enrichment (all optional, additive) ----------------------

    /// Station elevation, metres above sea level, when known.
    var elevationM: Double?
    /// Anemometer measurement height used for normalization, metres AGL.
    var measHeightM: Double?
    /// Aerodynamic roughness length z0 at the site, metres.
    var roughnessZ0: Double?
    /// Wind speed normalized to 10 m via the neutral log profile, km/h.
    var speed10Kmh: Double?
    /// Gust normalized to 10 m, km/h, when a gust is reported.
    var gust10Kmh: Double?
    /// Position relative to the local inversion base.
    var airMass: AirMass?
    /// Inversion base elevation used when tagging this obs, metres.
    var inversionBaseM: Double?
    /// Combined analysis weight (time decay times anchor factor), 0..1+.
    var analysisWeight: Double?
    /// True when this obs is a low-frequency anchor (e.g. RAWS hourly).
    var isAnchor: Bool?
    /// Quality-control outcome for observations that passed QC.
    var qc: QCVerdict?

    init(
        id: String,
        name: String,
        lon: Double,
        lat: Double,
        speedKmh: Double,
        dirDeg: Double? = nil,
        gustKmh: Double? = nil,
        tempC: Double? = nil,
        observedAt: Date? = nil,
        ageMin: Double = 0,
        network: String? = nil,
        elevationM: Double? = nil,
        measHeightM: Double? = nil,
        roughnessZ0: Double? = nil,
        speed10Kmh: Double? = nil,
        gust10Kmh: Double? = nil,
        airMass: AirMass? = nil,
        inversionBaseM: Double? = nil,
        analysisWeight: Double? = nil,
        isAnchor: Bool? = nil,
        qc: QCVerdict? = nil
    ) {
        self.id = id
        self.name = name
        self.lon = lon
        self.lat = lat
        self.speedKmh = speedKmh
        self.dirDeg = dirDeg
        self.gustKmh = gustKmh
        self.tempC = tempC
        self.observedAt = observedAt
        self.ageMin = ageMin
        self.network = network
        self.elevationM = elevationM
        self.measHeightM = measHeightM
        self.roughnessZ0 = roughnessZ0
        self.speed10Kmh = speed10Kmh
        self.gust10Kmh = gust10Kmh
        self.airMass = airMass
        self.inversionBaseM = inversionBaseM
        self.analysisWeight = analysisWeight
        self.isAnchor = isAnchor
        self.qc = qc
    }
}

/// A station rejected by quality control, with the reason, for logging/UI.
struct RejectedObservation: Equatable, Sendable {
    var id: String
    var name: String
    var lon: Double
    var lat: Double
    var reason: String
    var flags: [String]
}

/// Coarse background field sampled from a weather model.
/// Row-major: index = latIndex * lons.count + lonIndex. Speeds in km/h.
struct ModelWindGrid: Equatable, Sendable {
    var lons: [Double] // ascending longitudes
    var lats: [Double] // ascending latitudes
    var u: [Double]
    var v: [Double]
}

/// Terrain elevation sampled on a grid, metres above sea level. Row-major.
struct TerrainGrid: Equatable, Sendable {
    var lons: [Double]
    var lats: [Double]
    var z: [Double]
}

/// Co-registered confidence field on the same layout as ModelWindGrid, 0..1.
struct WindConfidenceGrid: Equatable, Sendable {
    var lons: [Double]
    var lats: [Double]
    var c: [Double]
}

/// Samples a velocity (km/h) at a geographic coordinate.
typealias WindSampler = (_ lon: Double, _ lat: Double) -> WindVec

/// Local equirectangular projection to kilometres about an anchor point.
typealias GeoProjector = (_ lon: Double, _ lat: Double) -> (x: Double, y: Double)

/// An inversion model returns the inversion base elevation (m ASL) at a point,
/// or nil when no capping inversion is present (well-mixed column).
typealias InversionModel = (_ lon: Double, _ lat: Double) -> Double?
