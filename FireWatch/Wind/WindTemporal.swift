import Foundation

// Step 5: temporal harmonization. Port of app/lib/pipeline/temporal.ts.
//
// Stations report at different cadences and over different averaging periods:
// ASOS gives a 2-minute sustained wind plus a 5-second gust, RAWS gives a
// 10-minute average once an hour, utility towers report near 5-minute, and CWOP
// varies. Blending them as-if-equal mixes incompatible quantities. This stage:
//
//   1. Admits only obs within a configurable window around the analysis time.
//   2. Weights obs by age with an exponential time decay (older counts less).
//   3. Harmonizes the averaging period to a single target (sustained or gust)
//      using a Durst-style gust-factor curve.
//   4. Treats RAWS hourly obs as a low-frequency anchor (a slowly-varying bias
//      reference), not a high-frequency input, by down-weighting them.

/// Durst-style gust-factor curve: ratio of the speed averaged over `sec` to the
/// mean hourly (3600 s) speed. Values approximate the Durst (1960) / ESDU
/// curve; shorter durations resolve higher peaks.
private let durstCurve: [(sec: Double, g: Double)] = [
    (1, 1.61),
    (3, 1.55),
    (5, 1.52),
    (10, 1.43),
    (60, 1.18),
    (120, 1.12),
    (600, 1.06),
    (3600, 1.0),
]

func gustFactor(sec: Double) -> Double {
    if sec <= durstCurve[0].sec { return durstCurve[0].g }
    let last = durstCurve[durstCurve.count - 1]
    if sec >= last.sec { return last.g }
    for i in 0..<(durstCurve.count - 1) {
        let a = durstCurve[i]
        let b = durstCurve[i + 1]
        if sec <= b.sec {
            // Interpolate in log(sec), where the curve is closer to linear.
            let f = (log(sec) - log(a.sec)) / (log(b.sec) - log(a.sec))
            return a.g + (b.g - a.g) * f
        }
    }
    return last.g
}

/// Native averaging period (seconds) for a network family.
func nativePeriodSec(kind: NetworkKind, cfg: WindPipelineConfig) -> Double {
    switch kind {
    case .asos: return cfg.periods.asosSustainedSec
    case .raws: return cfg.periods.rawsSec
    case .utility: return cfg.periods.utilitySec
    case .cwop: return cfg.periods.cwopSec
    case .standard: return cfg.periods.targetSec
    }
}

/// Convert a speed from a source averaging period to the target period.
func harmonizePeriod(speed: Double, sourceSec: Double, targetSec: Double) -> Double {
    guard speed > 0 else { return speed }
    return speed * (gustFactor(sec: targetSec) / gustFactor(sec: sourceSec))
}

/// Exponential time-decay weight in [0,1] for an obs `relAgeMin` from analysis.
func timeDecayWeight(relAgeMin: Double, cfg: WindPipelineConfig) -> Double {
    exp(-abs(relAgeMin) / cfg.temporal.decayMin)
}

/// Harmonize one station to the analysis time and target averaging period, and
/// assign its combined analysis weight. Operates on the 10 m-normalized speed
/// (speed10Kmh) produced by the height step; if that is absent it falls back to
/// the raw speed. Returns nil when the obs falls outside the analysis window.
func harmonizeStation(
    _ station: WindObservation,
    cfg: WindPipelineConfig
) -> WindObservation? {
    if station.ageMin > cfg.temporal.windowMin { return nil }

    let kind = classifyNetwork(station.network)
    let sourceSec = nativePeriodSec(kind: kind, cfg: cfg)
    let targetSec = cfg.periods.targetSec

    let base10 = station.speed10Kmh ?? station.speedKmh
    let harmonized: Double
    if cfg.averaging == .gust {
        // Prefer a reported gust (already a short-duration peak); else
        // synthesize a gust from the sustained speed via the gust-factor curve.
        if let gust10 = station.gust10Kmh {
            harmonized = harmonizePeriod(speed: gust10, sourceSec: cfg.periods.asosGustSec, targetSec: targetSec)
        } else {
            harmonized = harmonizePeriod(speed: base10, sourceSec: sourceSec, targetSec: targetSec)
        }
    } else {
        harmonized = harmonizePeriod(speed: base10, sourceSec: sourceSec, targetSec: targetSec)
    }

    // RAWS hourly is a low-frequency anchor, not a high-frequency input.
    let isAnchor = kind == .raws
    let decay = timeDecayWeight(relAgeMin: station.ageMin, cfg: cfg)

    var out = station
    out.speed10Kmh = harmonized
    out.isAnchor = isAnchor
    out.analysisWeight = decay * (isAnchor ? cfg.temporal.anchorWeight : 1)
    return out
}
