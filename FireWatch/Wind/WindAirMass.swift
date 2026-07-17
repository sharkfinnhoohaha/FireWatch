import Foundation

// Step 6: vertical / air-mass tagging and the air-mass rule.
// Port of app/lib/pipeline/airmass.ts.
//
// This is the highest-priority correctness fix. A surface blend that ignores
// vertical structure will average a coastal station sitting in marine-layer fog
// with a ridge-top station above the inversion, producing a field that is wrong
// in both places. We tag each observation, and each grid cell, with its
// position relative to the local inversion base, and enforce a hard rule: an
// observation below the inversion must not correct a cell above it, and vice
// versa.
//
// This module is pure logic with no I/O, so the rule is cheap to unit test.

/// Classify an elevation relative to an inversion base. A nil elevation or a
/// nil inversion base (well-mixed column, no cap) yields .unknown, which the
/// rule treats permissively: an unknown obs may correct any cell, since we have
/// no evidence of an air-mass boundary to respect.
func classifyAirMass(elevationM: Double?, inversionBaseM: Double?) -> AirMass {
    guard let elevationM, let inversionBaseM else { return .unknown }
    return elevationM < inversionBaseM ? .below : .above
}

/// The air-mass rule: may an observation in air mass `obs` correct a grid cell
/// in air mass `cell`?
///
/// Allowed when they are in the same air mass, or when either side is unknown
/// (no evidence of a boundary). Forbidden only when one is strictly below and
/// the other strictly above: the marine-layer-fog vs above-inversion case.
func canCorrect(obs: AirMass, cell: AirMass) -> Bool {
    if obs == .unknown || cell == .unknown { return true }
    return obs == cell
}

/// Tag a station with its elevation-relative air mass using an inversion model.
func tagStation(_ station: WindObservation, inversion: InversionModel) -> WindObservation {
    let inversionBaseM = inversion(station.lon, station.lat)
    var out = station
    out.inversionBaseM = inversionBaseM
    out.airMass = classifyAirMass(elevationM: station.elevationM, inversionBaseM: inversionBaseM)
    return out
}
