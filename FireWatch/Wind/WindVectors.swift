import Foundation

// Wind vector math and unit helpers. Port of app/lib/wind.ts.
//
// Meteorological convention: wind direction is the compass bearing the wind
// blows FROM. The velocity vector therefore points toward (dir + 180°).

enum WindVectors {
    static let kmhToMph = 0.621371

    /// (speed, direction-from) → velocity components (eastward u, northward v).
    static func toVec(speedKmh: Double, dirFromDeg: Double) -> WindVec {
        let r = dirFromDeg * .pi / 180
        return WindVec(u: -speedKmh * sin(r), v: -speedKmh * cos(r))
    }

    /// Velocity components → speed and meteorological direction-from (0..360°).
    static func toSpeedDir(u: Double, v: Double) -> (speed: Double, dir: Double) {
        let speed = hypot(u, v)
        var dir = atan2(-u, -v) * 180 / .pi
        if dir < 0 { dir += 360 }
        return (speed, dir)
    }

    static func speed(_ v: WindVec) -> Double { hypot(v.u, v.v) }

    private static let compassPoints = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    ]

    /// Nearest 16-point compass label for a direction-from bearing.
    static func compass(_ dirDeg: Double) -> String {
        let normalized = (dirDeg.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let i = Int((normalized / 22.5).rounded()) % 16
        return compassPoints[i]
    }

    /// Smallest absolute angular difference between two bearings (0..180°).
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }
}
