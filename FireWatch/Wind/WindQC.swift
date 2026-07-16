import Foundation

// Step 3: observation quality control. Port of app/lib/pipeline/qc.ts.
//
// Raw observations, especially CWOP/personal stations, contain gross errors,
// stuck sensors, and badly sited anemometers. We never blend raw values. This
// stage applies, in order:
//
//   1. MADIS QC flags: where a MADIS quality flag is available, respect it and
//      reject anything flagged bad.
//   2. Gross-error / sanity check: non-finite, negative, or absurdly high
//      speeds, and stale readings, are rejected.
//   3. Persistence check: if a prior reading is available, reject implausible
//      jumps (a sensor that leaps from calm to gale between cycles).
//   4. Buddy check: compare each station against its neighbours and reject an
//      outlier that disagrees with the local consensus beyond tolerance.
//
// Failing stations are rejected outright, not silently down-weighted to zero,
// and every rejection is logged with a reason. This module is the only place
// allowed to drop a station for quality reasons.

enum MadisFlag: String, Equatable, Sendable {
    case accepted, suspect, rejected
}

/// Optional external signals QC can consult, injected so QC stays testable.
struct QCContext {
    /// MADIS (or provider) QC verdict for a station, when available.
    var madisFlag: ((WindObservation) -> MadisFlag?)?
    /// Prior accepted 10 m-equivalent speed (km/h) for a station, for the
    /// persistence check. Nil means no history is available.
    var priorSpeedKmh: ((WindObservation) -> Double?)?
    /// Sink for rejection logs; defaults to print.
    var log: ((String) -> Void)?

    init(
        madisFlag: ((WindObservation) -> MadisFlag?)? = nil,
        priorSpeedKmh: ((WindObservation) -> Double?)? = nil,
        log: ((String) -> Void)? = nil
    ) {
        self.madisFlag = madisFlag
        self.priorSpeedKmh = priorSpeedKmh
        self.log = log
    }
}

struct QCResult {
    var kept: [WindObservation]
    var rejected: [RejectedObservation]
}

/// Equirectangular distance between two observations, km.
private func kmBetween(_ a: WindObservation, _ b: WindObservation) -> Double {
    let kx = 111.32 * cos(((a.lat + b.lat) / 2) * .pi / 180)
    let ky = 110.57
    return hypot((a.lon - b.lon) * kx, (a.lat - b.lat) * ky)
}

private func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}

/// Run the QC suite. Returns kept stations (with qc set) and rejections.
func runQC(
    _ stations: [WindObservation],
    cfg: WindPipelineConfig,
    ctx: QCContext = QCContext()
) -> QCResult {
    let log = ctx.log ?? { print("[wind-qc] \($0)") }
    let q = cfg.qc

    func reject(_ s: WindObservation, _ reason: String, _ flags: [String]) -> RejectedObservation {
        log("rejected \(s.id) (\(s.name)): \(reason)")
        return RejectedObservation(id: s.id, name: s.name, lon: s.lon, lat: s.lat, reason: reason, flags: flags)
    }

    var kept: [WindObservation] = []
    var rejected: [RejectedObservation] = []

    // First pass: MADIS flags, gross error, staleness, persistence. Buddy check
    // runs afterward against only the survivors so a bad station cannot poison
    // its neighbours' consensus.
    var survivors: [WindObservation] = []
    for s in stations {
        var flags: [String] = []

        let madis = ctx.madisFlag?(s)
        if madis == .rejected {
            rejected.append(reject(s, "MADIS QC flag: rejected", ["madis:rejected"]))
            continue
        }
        if madis == .suspect { flags.append("madis:suspect") }
        if madis == .accepted { flags.append("madis:accepted") }

        if q.rejectNonFinite && !s.speedKmh.isFinite {
            rejected.append(reject(s, "non-finite speed", flags + ["gross:nonfinite"]))
            continue
        }
        if s.speedKmh < 0 {
            rejected.append(reject(s, "negative speed", flags + ["gross:negative"]))
            continue
        }
        if s.speedKmh > q.maxSpeedKmh {
            rejected.append(reject(
                s,
                "speed \(Int(s.speedKmh.rounded())) km/h exceeds ceiling \(Int(q.maxSpeedKmh))",
                flags + ["gross:ceiling"]
            ))
            continue
        }
        if s.ageMin > q.maxAgeMin {
            rejected.append(reject(s, "stale: \(Int(s.ageMin)) min old", flags + ["sanity:stale"]))
            continue
        }

        if let prior = ctx.priorSpeedKmh?(s), prior.isFinite {
            // A physically implausible jump between cycles: more than 80 km/h
            // change flags a likely sensor fault. Tolerance is intentionally
            // loose; this catches stuck-then-spiking sensors, not normal gusts.
            if abs(s.speedKmh - prior) > 80 {
                rejected.append(reject(
                    s,
                    "persistence: jumped \(Int(abs(s.speedKmh - prior).rounded())) km/h",
                    flags + ["persistence:jump"]
                ))
                continue
            }
        }

        var survivor = s
        survivor.qc = QCVerdict(passed: true, flags: flags)
        survivors.append(survivor)
    }

    // Buddy check against surviving neighbours.
    for s in survivors {
        let neighbours = survivors.filter { $0.id != s.id && kmBetween(s, $0) <= q.buddyRadiusKm }
        if neighbours.count < q.buddyMinNeighbours {
            // Not enough buddies to judge: keep, but record that it was unchecked.
            var out = s
            out.qc = QCVerdict(passed: true, flags: (s.qc?.flags ?? []) + ["buddy:skipped"])
            kept.append(out)
            continue
        }
        let speeds = neighbours.map(\.speedKmh)
        let med = median(speeds)
        let madRaw = median(speeds.map { abs($0 - med) })
        let spread = madRaw == 0 ? 1 : madRaw // MAD, floored
        let dev = abs(s.speedKmh - med)
        if dev > q.buddyTolKmh && dev > q.buddyTolFactor * spread {
            rejected.append(reject(
                s,
                "buddy check: \(Int(s.speedKmh.rounded())) vs local median \(Int(med.rounded())) km/h",
                (s.qc?.flags ?? []) + ["buddy:outlier"]
            ))
            continue
        }
        var out = s
        out.qc = QCVerdict(passed: true, flags: (s.qc?.flags ?? []) + ["buddy:ok"])
        kept.append(out)
    }

    return QCResult(kept: kept, rejected: rejected)
}
