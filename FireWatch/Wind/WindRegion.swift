import Foundation

// The analysis region for the wind field. Port of app/data/region.ts, retargeted
// from the web demo's Santa Monica Mountains bbox to FireWatch's SoCal console
// coverage (the same box the previous Open-Meteo grid used).
//
// DATA SOURCE NOTE
// Watch Duty's weather-vane markers come from Synoptic Data (the aggregator
// behind MesoWest): RAWS, CWOP/personal stations, and DOT/mesonets. The
// faithful way to reproduce them is the Synoptic stations/latest API over this
// bbox (set a token — see WindCredentials). With no token we approximate the
// network with the keyless NWS api.weather.gov feed, which re-serves many of
// the same RAWS and mesonet stations.

struct WindRegion: Sendable {
    let name: String
    let bbox: GeoBBox
    /// Coarse model background grid (Open-Meteo points = lon × lat).
    let modelGrid: GridSpec
    /// Terrain elevation grid (Open-Meteo elevation points = lon × lat).
    let terrainGrid: GridSpec
    /// Vanes to poll from the keyless NWS feed when no Synoptic token is set.
    /// The Synoptic path ignores this list and returns the full bbox network.
    let nwsStationIds: [String]
    /// Spatial thinning floor for the Synoptic network, km. Wider than the web
    /// demo's 2.2 km because this bbox is roughly ten times the area.
    let synopticMinSpacingKm: Double
    /// Cap on live vanes so the analysis and particle advection stay cheap.
    let synopticMaxStations: Int

    var centerLat: Double { (bbox.south + bbox.north) / 2 }
    var centerLon: Double { (bbox.west + bbox.east) / 2 }

    /// FireWatch's operating region: the Southern California console box.
    static let socal = WindRegion(
        name: "Southern California",
        bbox: GeoBBox(west: -120.75, south: 33.25, east: -117.25, north: 35.75),
        modelGrid: GridSpec(lon: 15, lat: 11),
        terrainGrid: GridSpec(lon: 18, lat: 12),
        nwsStationIds: [
            // Ridge-top & canyon RAWS — the interior vanes Watch Duty shows.
            "TPGC1", // Topanga (ridge above Topanga/Calabasas)
            "CEEC1", // Cheeseboro (hilltop, Agoura Hills)
            "MBUC1", // Malibu Hills (interior crest)
            "LCBC1", // Leo Carrillo (western coastal tip)
            // DOT / mesonet sites bracketing the ranges.
            "SV", // Simi Valley — Cochran
            "TO", // Thousand Oaks — Moorpark Rd
            "ER", // El Rio — Rio Mesa
        ],
        synopticMinSpacingKm: 8,
        synopticMaxStations: 96
    )
}
