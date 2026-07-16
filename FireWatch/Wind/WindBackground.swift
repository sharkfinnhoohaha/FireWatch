import Foundation

// Step 1 (pure parts): background grid geometry. Port of the pure pieces of
// app/lib/pipeline/background.ts. The network fetchers (Open-Meteo; RTMA/HRRR
// when wired) live in FeedService — this module stays I/O-free so it is fully
// unit-testable and reusable.

/// Grid resolution: number of points along each axis.
struct GridSpec: Equatable, Sendable {
    var lon: Int
    var lat: Int
}

/// Build ascending lon/lat axes spanning the bbox at the requested resolution.
func buildAxes(bbox: GeoBBox, spec: GridSpec) -> (lons: [Double], lats: [Double]) {
    var lons: [Double] = []
    var lats: [Double] = []
    lons.reserveCapacity(spec.lon)
    lats.reserveCapacity(spec.lat)
    for i in 0..<spec.lon {
        lons.append(bbox.west + (bbox.east - bbox.west) * Double(i) / Double(max(spec.lon - 1, 1)))
    }
    for j in 0..<spec.lat {
        lats.append(bbox.south + (bbox.north - bbox.south) * Double(j) / Double(max(spec.lat - 1, 1)))
    }
    return (lons, lats)
}
