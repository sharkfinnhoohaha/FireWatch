import Foundation

// Step 2: terrain downscaling. Port of app/lib/pipeline/downscale.ts.
//
// HRRR/RTMA at km scale do not resolve canyon channeling, gap acceleration, or
// nocturnal drainage flow, which is exactly where a fire-weather wind field
// matters most. The intended downscale is WindNinja, taking the km-scale
// background and a sub-100 m terrain model and producing a terrain-following
// fine field.
//
// WindNinja is a native solver and an out-of-process integration, so it is
// stubbed here behind a clean interface. The pipeline always runs the downscale
// step; today it is the identity (the background passes through unchanged), and
// swapping in WindNinja is a single factory change with no downstream edits.

/// A downscaler refines a coarse background sampler using a terrain model.
typealias Downscaler = (
    _ background: @escaping WindSampler,
    _ terrain: TerrainGrid?,
    _ cfg: WindPipelineConfig
) -> WindSampler

/// Identity downscaler: returns the background unchanged.
let identityDownscaler: Downscaler = { background, _, _ in background }

/// WindNinja downscaler.
///
/// STUB: WindNinja is not invoked in this pass. Returns the background
/// unchanged so the pipeline is complete and correct end to end.
let windNinjaDownscaler: Downscaler = { background, _, _ in background }

/// Select a downscaler. Defaults to identity until WindNinja is wired.
func selectDownscaler(useWindNinja: Bool = false) -> Downscaler {
    useWindNinja ? windNinjaDownscaler : identityDownscaler
}
