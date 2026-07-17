import Foundation

// Step 6 (support): inversion base height. Port of app/lib/pipeline/inversion.ts.
//
// The air-mass rule needs the elevation of the temperature inversion that caps
// the boundary layer (the marine-layer top, on the California coast). The
// rigorous source is the HRRR vertical temperature profile sampled at the
// observation location. That GRIB profile fetch is an external integration;
// until it is wired we use a configured constant that stands in for a typical
// marine-layer top. The InversionModel closure is the seam where the HRRR
// profile lookup slots in.

/// Constant inversion base from config. Stands in for an HRRR-derived value.
func fixedInversion(_ cfg: WindPipelineConfig) -> InversionModel {
    { _, _ in cfg.inversionBaseM }
}

/// HRRR-profile inversion model.
///
/// STUB: deriving the inversion base from the HRRR vertical temperature profile
/// is not wired in this pass. When integrated, this would fetch the column at
/// (lon, lat), find the lowest height where dT/dz > 0, and return that elevation
/// (or nil if the column is well mixed). For now it defers to the configured
/// constant so the air-mass rule is fully functional and testable.
func hrrrInversion(_ cfg: WindPipelineConfig) -> InversionModel {
    let fixed = fixedInversion(cfg)
    return { lon, lat in fixed(lon, lat) }
}
