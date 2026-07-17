import Foundation

// Spatial sampling helpers for the wind field: the model-grid sampler, the
// observations-only IDW fallback, the local projector, and difference/scale
// utilities. Port of app/lib/interpolate.ts.

/// Local equirectangular projection to kilometres about an anchor point.
func makeProjector(lon0: Double, lat0: Double) -> GeoProjector {
    let kx = 111.32 * cos(lat0 * .pi / 180)
    let ky = 110.57
    return { lon, lat in ((lon - lon0) * kx, (lat - lat0) * ky) }
}

/// Locate `val` within an ascending axis: lower index and interpolation fraction,
/// clamped at the edges. Hardened for degenerate single-element axes.
func locateOnAxis(_ arr: [Double], _ val: Double) -> (i: Int, f: Double) {
    guard arr.count >= 2 else { return (0, 0) }
    if val <= arr[0] { return (0, 0) }
    if val >= arr[arr.count - 1] { return (arr.count - 2, 1) }
    var i = 0
    while i < arr.count - 1 && arr[i + 1] < val { i += 1 }
    return (i, (val - arr[i]) / (arr[i + 1] - arr[i]))
}

/// Bilinear sampler over the coarse model grid, clamped at the edges.
func modelSampler(grid: ModelWindGrid) -> WindSampler {
    let lons = grid.lons
    let lats = grid.lats
    let u = grid.u
    let v = grid.v
    let nLon = lons.count
    guard nLon >= 1, !lats.isEmpty, u.count == nLon * lats.count, v.count == u.count else {
        return { _, _ in WindVec(u: 0, v: 0) }
    }
    func idx(_ i: Int, _ j: Int) -> Int { j * nLon + i }
    func lerp(_ p: Double, _ q: Double, _ f: Double) -> Double { p + (q - p) * f }

    return { lon, lat in
        let a = locateOnAxis(lons, lon)
        let b = locateOnAxis(lats, lat)
        let ai1 = min(a.i + 1, nLon - 1)
        let bi1 = min(b.i + 1, lats.count - 1)
        func sample(_ g: [Double]) -> Double {
            lerp(
                lerp(g[idx(a.i, b.i)], g[idx(ai1, b.i)], a.f),
                lerp(g[idx(a.i, bi1)], g[idx(ai1, bi1)], a.f),
                b.f
            )
        }
        return WindVec(u: sample(u), v: sample(v))
    }
}

/// Velocity for a station, treating a calm/variable (nil-direction) vane as a
/// zero vector — which is the physically correct contribution to the field.
func stationVec(_ s: WindObservation) -> WindVec {
    WindVectors.toVec(speedKmh: s.speedKmh, dirFromDeg: s.dirDeg ?? 0)
}

/// Inverse-distance-weighted interpolation of the station vectors themselves —
/// the "observations only" reconstruction (no model). Used as the background
/// when no model field is available.
func idwSampler(
    stations: [WindObservation],
    proj: @escaping GeoProjector,
    power: Double = 3,
    smoothingKm: Double = 0.6
) -> WindSampler {
    struct Projected {
        let x: Double
        let y: Double
        let vec: WindVec
    }
    let svs = stations.map { s -> Projected in
        let p = proj(s.lon, s.lat)
        return Projected(x: p.x, y: p.y, vec: stationVec(s))
    }
    let s2 = smoothingKm * smoothingKm
    return { lon, lat in
        if svs.isEmpty { return WindVec(u: 0, v: 0) }
        let p = proj(lon, lat)
        var su = 0.0, sv = 0.0, sw = 0.0
        for s in svs {
            let d2 = (s.x - p.x) * (s.x - p.x) + (s.y - p.y) * (s.y - p.y) + s2
            let w = 1 / pow(d2, power / 2)
            su += w * s.vec.u
            sv += w * s.vec.v
            sw += w
        }
        return WindVec(u: su / sw, v: sv / sw)
    }
}

/// The correction itself: corrected − background.
func differenceSampler(
    background: @escaping WindSampler,
    corrected: @escaping WindSampler
) -> WindSampler {
    { lon, lat in
        let b = background(lon, lat)
        let c = corrected(lon, lat)
        return WindVec(u: c.u - b.u, v: c.v - b.v)
    }
}

/// Robust upper bound on field speed (95th percentile) for colour scaling.
func estimateMaxSpeed(sampler: WindSampler, bbox: GeoBBox, n: Int = 24) -> Double {
    var speeds: [Double] = []
    speeds.reserveCapacity((n + 1) * (n + 1))
    for j in 0...n {
        let lat = bbox.south + (bbox.north - bbox.south) * Double(j) / Double(n)
        for i in 0...n {
            let lon = bbox.west + (bbox.east - bbox.west) * Double(i) / Double(n)
            let s = sampler(lon, lat)
            speeds.append(hypot(s.u, s.v))
        }
    }
    speeds.sort()
    let value = speeds[Int(Double(speeds.count) * 0.95)]
    return value == 0 ? 1 : value
}
