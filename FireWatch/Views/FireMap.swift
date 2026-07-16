import SwiftUI
import MapKit

private enum ConsoleColor {
    static let obsidian = Color(red: 0.027, green: 0.067, blue: 0.102)
    static let instrument = Color(red: 0.192, green: 0.718, blue: 0.847)
    static let vane = Color(red: 0.949, green: 0.831, blue: 0.278)
    static let dispatch = Color(red: 0.259, green: 0.910, blue: 0.878)
    static let fire = Color(red: 1.0, green: 0.353, blue: 0.310)
    static let uncertainty = Color(red: 0.898, green: 0.294, blue: 0.569)
}

struct FireMap: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            ContributorMapView(state: state).ignoresSafeArea()
            Color.black.opacity(0.08).allowsHitTesting(false)

            VStack(spacing: 0) {
                CommandStrip(state: state)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                Spacer()
            }

            HStack(spacing: 0) {
                Spacer()
                ContextDeck(state: state)
                    .frame(width: 326)
                    .padding(.trailing, 14)
                    .padding(.top, 70)
                    .padding(.bottom, 14)
            }
        }
        .background(ConsoleColor.obsidian)
        .preferredColorScheme(.dark)
    }
}

private struct CommandStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "scope").foregroundStyle(ConsoleColor.dispatch)
                Text("CONTRIBUTOR / SOCAL").tracking(1.2).foregroundStyle(.white)
            }
            divider
            metric("WFIGS", state.filteredIncidents.count, ConsoleColor.fire)
            metric("CAD", state.dispatchSignals.count, ConsoleColor.dispatch)
            metric("CAM", state.cameras.count, ConsoleColor.instrument)
            metric("IR", state.hotspots.count, .orange)
            Spacer(minLength: 10)
            layerToggle("wind", "Wind", $state.showWind, ConsoleColor.vane)
            layerToggle("video.fill", "Cameras", $state.showCameras, ConsoleColor.instrument)
            layerToggle("dot.radiowaves.left.and.right", "CAD", $state.showDispatch, ConsoleColor.dispatch)
            layerToggle("flame.fill", "IR", $state.showHotspots, .orange)
            layerToggle("map.fill", "Perimeters", $state.showPerimeters, ConsoleColor.fire)
            divider
            Circle().fill(state.failures.isEmpty ? .green : .orange).frame(width: 7, height: 7)
            Text(state.lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "OFFLINE")
                .foregroundStyle(.secondary)
            Button { Task { await state.refresh(force: true) } } label: {
                Image(systemName: state.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(.plain).disabled(state.isRefreshing)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 11).frame(height: 42)
        .background(ConsoleColor.obsidian.opacity(0.91), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(ConsoleColor.instrument.opacity(0.25)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 4) { Text(value.formatted()).foregroundStyle(color); Text(label).foregroundStyle(.secondary) }
    }
    private func layerToggle(_ icon: String, _ label: String, _ value: Binding<Bool>, _ tint: Color) -> some View {
        Toggle(isOn: value) { Label(label, systemImage: icon).labelStyle(.iconOnly) }
            .toggleStyle(ConsoleToggleStyle(tint: tint)).help(label)
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.13)).frame(width: 1, height: 18) }
}

private struct ConsoleToggleStyle: ToggleStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label.foregroundStyle(configuration.isOn ? tint : .secondary)
                .frame(width: 25, height: 25)
                .background(configuration.isOn ? tint.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain)
    }
}

private struct ContextDeck: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                selectedContext
                deckSection("WIND ASSIMILATION", icon: "wind") { windControls }
                deckSection("MODEL ↔ VANE", icon: "arrow.left.and.right") { stationTable }
                deckSection("SOURCE HEALTH", icon: "waveform.path.ecg") { sourceHealth }
                Text("Situational awareness only · verify through agency and Watch Duty contributor channels")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(13)
        }
        .background(ConsoleColor.obsidian.opacity(0.93), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ConsoleColor.instrument.opacity(0.28)))
        .shadow(color: .black.opacity(0.55), radius: 22, y: 8)
    }

    @ViewBuilder private var selectedContext: some View {
        if let camera = state.cameras.first(where: { $0.id == state.selectedCameraID }) {
            deckSection("LIVE CAMERA", icon: "video.fill") { CameraContext(camera: camera) }
        } else if let signal = state.dispatchSignals.first(where: { $0.id == state.selectedSignalID }) {
            deckSection("DISPATCH SIGNAL · UNVERIFIED", icon: "dot.radiowaves.left.and.right") { DispatchContext(signal: signal) }
        } else if let incident = state.incidents.first(where: { $0.id == state.selectedIncidentID }) {
            deckSection("WFIGS INCIDENT", icon: "flame.fill") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(incident.name.uppercased()).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    DetailPanel(incident: incident).frame(minHeight: 116)
                }
            }
        }
    }

    private var windControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(WindDisplayMode.allCases) { mode in
                    Button(mode.label) { state.windMode = mode }
                        .buttonStyle(ModeButtonStyle(active: state.windMode == mode))
                }
            }
            HStack { Text("VANE INFLUENCE"); Spacer(); Text("\(Int(state.vaneInfluenceMiles)) MI").foregroundStyle(ConsoleColor.vane) }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
            Slider(value: $state.vaneInfluenceMiles, in: 5...80, step: 5).tint(ConsoleColor.vane)
            HStack {
                Label("FLOW", systemImage: "wind").foregroundStyle(state.showWind ? ConsoleColor.vane : .secondary)
                Spacer()
                Toggle("VANES", isOn: $state.showStations).toggleStyle(.switch).controlSize(.mini)
            }.font(.system(size: 9, weight: .semibold, design: .monospaced))
            Text(state.windMode == .model ? "10 M MODEL · ARROWS POINT TOWARD FLOW" : "HEURISTIC NWS OBS ADJUSTMENT · NOT A FORECAST")
                .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private var stationTable: some View {
        VStack(spacing: 7) {
            HStack { Text("STATION"); Spacer(); Text("MODEL"); Text("VANE"); Text("Δ") }
                .foregroundStyle(.secondary)
            ForEach(state.weatherStations) { station in
                let model = nearestModel(to: station.coordinate)
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 1) { Text(station.id); Text(station.name).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Text(model.map { "\(Int($0.speedMPH))" } ?? "—")
                    Text("\(Int(station.speedMPH))").foregroundStyle(ConsoleColor.vane)
                    Text(model.map { "\(Int(abs($0.speedMPH - station.speedMPH)))" } ?? "—").foregroundStyle(ConsoleColor.uncertainty)
                }
            }
            if state.weatherStations.isEmpty { Text("NWS station observations unavailable").foregroundStyle(.secondary) }
        }.font(.system(size: 9, weight: .medium, design: .monospaced))
    }

    private var sourceHealth: some View {
        VStack(spacing: 7) {
            source("WFIGS", state.failures.incidents, state.isSourceStale("services3.arcgis.com"), "\(state.incidents.count)")
            source("WILDCAD-E", state.failures.dispatch, state.isSourceStale("execute-api"), "\(state.dispatchSignals.count)")
            source("ALERT CAM", state.failures.cameras, state.isSourceStale("services.arcgis.com"), "\(state.cameras.count)")
            source("OPEN-METEO", state.failures.wind, state.isSourceStale("open-meteo"), "\(state.windSamples.count)")
            source("NWS / VIIRS", state.failures.alerts ?? state.failures.hotspots, state.isSourceStale("weather.gov") || state.isSourceStale("services9.arcgis.com"), "LIVE")
        }.font(.system(size: 9, weight: .semibold, design: .monospaced))
    }

    private func source(_ name: String, _ failure: String?, _ stale: Bool, _ value: String) -> some View {
        let healthy = failure == nil && !stale
        return HStack {
            Circle().fill(healthy ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(name); Spacer()
            Text(failure != nil ? "DEGRADED" : stale ? "STALE CACHE" : value).foregroundStyle(healthy ? Color.secondary : Color.orange)
        }
    }
    private func nearestModel(to coordinate: CLLocationCoordinate2D) -> WindSample? {
        state.windSamples.min { distance($0.coordinate, coordinate) < distance($1.coordinate, coordinate) }
    }
    private func deckSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(0.8).foregroundStyle(ConsoleColor.instrument)
            content()
        }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.08)))
    }
}

private struct ModeButtonStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 8, weight: .semibold, design: .monospaced)).lineLimit(1)
            .padding(.horizontal, 6).frame(height: 24)
            .foregroundStyle(active ? ConsoleColor.obsidian : .secondary)
            .background(active ? ConsoleColor.vane : .white.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct CameraContext: View {
    @Environment(\.openURL) private var openURL
    let camera: AlertCamera
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let url = camera.imageURL {
                    CachedCameraImage(url: url, placeholder: AnyView(cameraPlaceholder))
                } else { cameraPlaceholder }
            }.frame(height: 142).clipped().background(.black).overlay(alignment: .topLeading) { Text("PUBLIC FEED").font(.system(size: 8, weight: .bold, design: .monospaced)).padding(5).background(ConsoleColor.instrument).foregroundStyle(.black) }
            Text(camera.name.uppercased()).font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(camera.owner ?? "ALERT wildfire network").font(.caption).foregroundStyle(.secondary)
            Button("OPEN LIVE VIEWER ↗") { openURL(camera.viewerURL ?? URL(string: "https://alertwest.live/")!) }.buttonStyle(.borderedProminent).tint(ConsoleColor.instrument)
        }
    }
    private var cameraPlaceholder: some View { ZStack { Color.black; Image(systemName: "video.slash.fill").font(.largeTitle).foregroundStyle(.secondary); Text("PREVIEW UNAVAILABLE · OPEN LIVE").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 70) } }
}

private struct CachedCameraImage: View {
    let url: URL
    let placeholder: AnyView
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { placeholder }
        }
        .task(id: url) {
            guard let data = try? await FeedService.fetchCameraImage(url), !Task.isCancelled else { return }
            image = NSImage(data: data)
        }
    }
}

private struct DispatchContext: View {
    let signal: DispatchSignal
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(signal.name.uppercased()).font(.system(size: 15, weight: .bold, design: .monospaced))
            HStack { Text(signal.type.uppercased()).foregroundStyle(ConsoleColor.dispatch); Spacer(); Text(signal.center).foregroundStyle(.secondary) }
            if let date = signal.reportedAt { Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock") }
            if let acres = signal.acres { Label("\(acres.formatted()) acres reported", systemImage: "ruler") }
            if !signal.resources.isEmpty { Text("RESOURCES  " + signal.resources.joined(separator: " · ")) }
            if let comment = signal.webComment, !comment.isEmpty { Text(comment).foregroundStyle(.secondary) }
            Text("Early dispatch context. Confirm before contributor action.").foregroundStyle(.orange)
        }.font(.system(size: 10, weight: .medium, design: .monospaced))
    }
}

struct PreparedWindField {
    struct Node {
        let east: Double
        let north: Double
        let speed: Double
        let confidence: Double
        let disagreement: Double
        static let calm = Node(east: 0, north: 0, speed: 0, confidence: 0, disagreement: 0)
    }

    let nodes: [Node]
    private let rows: Int
    private let columns: Int
    private let minLatitude: Double
    private let maxLatitude: Double
    private let minLongitude: Double
    private let maxLongitude: Double

    init(samples: [WindSample], stations: [WeatherStation], mode: WindDisplayMode, influenceMiles: Double) {
        let latitudeKeys = Array(Set(samples.map { Int(($0.coordinate.latitude * 1_000).rounded()) })).sorted()
        let longitudeKeys = Array(Set(samples.map { Int(($0.coordinate.longitude * 1_000).rounded()) })).sorted()
        rows = latitudeKeys.count; columns = longitudeKeys.count
        minLatitude = Double(latitudeKeys.first ?? 0) / 1_000; maxLatitude = Double(latitudeKeys.last ?? 0) / 1_000
        minLongitude = Double(longitudeKeys.first ?? 0) / 1_000; maxLongitude = Double(longitudeKeys.last ?? 0) / 1_000
        var byCoordinate: [String: WindSample] = [:]
        for sample in samples { byCoordinate["\(Int((sample.coordinate.latitude * 1_000).rounded())):\(Int((sample.coordinate.longitude * 1_000).rounded()))"] = sample }
        var result: [Node] = []; result.reserveCapacity(rows * columns)
        for latitudeKey in latitudeKeys {
            for longitudeKey in longitudeKeys {
                guard let sample = byCoordinate["\(latitudeKey):\(longitudeKey)"] else { result.append(.calm); continue }
                let model = WindMath.flowComponents(speedMPH: sample.speedMPH, directionFromDegrees: sample.directionDegrees)
                var residualEast = 0.0, residualNorth = 0.0, weightedDisagreement = 0.0, totalWeight = 0.0
                for station in stations {
                    let age = station.observedAt.map { max(0, Date.now.timeIntervalSince($0)) } ?? 0
                    let freshness = exp(-age / 7_200)
                    let miles = fastDistance(sample.coordinate, station.coordinate)
                    let weight = exp(-pow(miles / max(influenceMiles, 1), 2)) * freshness
                    guard weight > 0.01, let nearest = samples.min(by: { fastDistance($0.coordinate, station.coordinate) < fastDistance($1.coordinate, station.coordinate) }) else { continue }
                    let stationModel = WindMath.flowComponents(speedMPH: nearest.speedMPH, directionFromDegrees: nearest.directionDegrees)
                    let observed = WindMath.flowComponents(speedMPH: station.speedMPH, directionFromDegrees: station.directionDegrees)
                    let deltaEast = observed.east - stationModel.east, deltaNorth = observed.north - stationModel.north
                    residualEast += deltaEast * weight; residualNorth += deltaNorth * weight
                    weightedDisagreement += hypot(deltaEast, deltaNorth) * weight; totalWeight += weight
                }
                let blend = 1 - exp(-totalWeight)
                var east = model.east, north = model.north
                if mode != .model, totalWeight > 0 {
                    east += residualEast / totalWeight * blend
                    north += residualNorth / totalWeight * blend
                }
                let speed = hypot(east, north)
                if speed > 75 { east *= 75 / speed; north *= 75 / speed }
                let nearestStation = stations.map { fastDistance(sample.coordinate, $0.coordinate) }.min() ?? 999
                let confidence = max(0.08, min(1, exp(-nearestStation / max(influenceMiles * 1.7, 1))))
                result.append(Node(east: east, north: north, speed: min(speed, 75), confidence: confidence, disagreement: totalWeight > 0 ? weightedDisagreement / totalWeight : 0))
            }
        }
        nodes = result
    }

    func node(at coordinate: CLLocationCoordinate2D) -> Node {
        guard rows > 0, columns > 0, !nodes.isEmpty else { return .calm }
        guard coordinate.latitude >= minLatitude - 0.3, coordinate.latitude <= maxLatitude + 0.3,
              coordinate.longitude >= minLongitude - 0.3, coordinate.longitude <= maxLongitude + 0.3 else { return .calm }
        let rowFraction = (coordinate.latitude - minLatitude) / max(maxLatitude - minLatitude, 0.001)
        let columnFraction = (coordinate.longitude - minLongitude) / max(maxLongitude - minLongitude, 0.001)
        let row = min(rows - 1, max(0, Int((rowFraction * Double(rows - 1)).rounded())))
        let column = min(columns - 1, max(0, Int((columnFraction * Double(columns - 1)).rounded())))
        return nodes[row * columns + column]
    }

}

final class WindMapOverlay: NSObject, MKOverlay {
    struct Stroke {
        let points: [MKMapPoint]
        let mapRect: MKMapRect
        let speed: Double
        let confidence: Double
        let disagreement: Double
        let phase: Double
    }

    let field: PreparedWindField
    let strokes: [Stroke]
    let mode: WindDisplayMode
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(samples: [WindSample], stations: [WeatherStation], mode: WindDisplayMode, influenceMiles: Double) {
        field = PreparedWindField(samples: samples, stations: stations, mode: mode, influenceMiles: influenceMiles)
        self.mode = mode
        let latitudes = samples.map { $0.coordinate.latitude }
        let longitudes = samples.map { $0.coordinate.longitude }
        let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: (latitudes.max() ?? 35.75) + 0.3, longitude: (longitudes.min() ?? -120.75) - 0.3))
        let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: (latitudes.min() ?? 33.25) - 0.3, longitude: (longitudes.max() ?? -117.25) + 0.3))
        boundingMapRect = MKMapRect(x: min(northWest.x, southEast.x), y: min(northWest.y, southEast.y), width: abs(southEast.x - northWest.x), height: abs(southEast.y - northWest.y))
        coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        strokes = Self.makeStrokes(field: field, bounds: boundingMapRect)
        super.init()
    }

    private static func makeStrokes(field: PreparedWindField, bounds: MKMapRect) -> [Stroke] {
        var strokes: [Stroke] = []
        strokes.reserveCapacity(240)
        for index in 0..<240 {
            let phase = pseudo(index * 7)
            var point = MKMapPoint(
                x: bounds.minX + pseudo(index * 17 + 3) * bounds.width,
                y: bounds.minY + pseudo(index * 31 + 11) * bounds.height
            )
            let travel = phase * 20
            for _ in 0..<Int(travel) { point = advance(point, field: field, scale: 1) }
            point = advance(point, field: field, scale: travel - floor(travel))
            point = wrapped(point, in: bounds)

            var points = [point]
            var speed = 0.0
            var confidence = 0.0
            var disagreement = 0.0
            for _ in 0..<7 {
                let node = field.node(at: point.coordinate)
                guard node.speed > 0.1 else { break }
                speed += node.speed
                confidence += node.confidence
                disagreement += node.disagreement
                point = advance(point, node: node, scale: 1)
                points.append(point)
            }
            guard points.count >= 2 else { continue }
            let sampleCount = Double(points.count - 1)
            var mapRect = MKMapRect.null
            for point in points {
                mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            strokes.append(Stroke(
                points: points,
                mapRect: mapRect,
                speed: speed / sampleCount,
                confidence: confidence / sampleCount,
                disagreement: disagreement / sampleCount,
                phase: phase
            ))
        }
        return strokes
    }

    private static func advance(_ point: MKMapPoint, field: PreparedWindField, scale: Double) -> MKMapPoint {
        advance(point, node: field.node(at: point.coordinate), scale: scale)
    }

    private static func advance(_ point: MKMapPoint, node: PreparedWindField.Node, scale: Double) -> MKMapPoint {
        let pointsPerMile = MKMapPointsPerMeterAtLatitude(point.coordinate.latitude) * 1_609.344
        return MKMapPoint(
            x: point.x + node.east * 0.018 * pointsPerMile * scale,
            y: point.y - node.north * 0.018 * pointsPerMile * scale
        )
    }

    private static func wrapped(_ point: MKMapPoint, in bounds: MKMapRect) -> MKMapPoint {
        MKMapPoint(
            x: bounds.minX + positiveRemainder(point.x - bounds.minX, bounds.width),
            y: bounds.minY + positiveRemainder(point.y - bounds.minY, bounds.height)
        )
    }

    private static func positiveRemainder(_ value: Double, _ divisor: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: divisor)
        return result < 0 ? result + divisor : result
    }

    private static func pseudo(_ seed: Int) -> Double {
        abs(sin(Double(seed) * 12.9898) * 43_758.5453).truncatingRemainder(dividingBy: 1)
    }
}

private final class WindMapRenderer: MKOverlayRenderer {
    private let wind: WindMapOverlay

    override init(overlay: MKOverlay) {
        wind = overlay as! WindMapOverlay
        super.init(overlay: overlay)
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool { mapRect.intersects(wind.boundingMapRect) }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard mapRect.intersects(wind.boundingMapRect), !wind.strokes.isEmpty else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let drawRect = mapRect.insetBy(dx: -mapRect.width * 0.08, dy: -mapRect.height * 0.08)
        for (index, stroke) in wind.strokes.enumerated() where stroke.mapRect.intersects(drawRect) {
            let converted = stroke.points.map(point(for:))
            guard let start = converted.first, let end = converted.last, converted.count >= 2 else { continue }
            let previous = converted[converted.count - 2]
            let path = CGMutablePath(); path.move(to: start)
            for point in converted.dropFirst() { path.addLine(to: point) }
            let color: NSColor
            switch wind.mode {
            case .disagreement:
                color = NSColor(calibratedHue: max(0, 0.94 - min(stroke.disagreement / 18, 1) * 0.12), saturation: 0.82, brightness: 1, alpha: (0.3 + stroke.confidence * 0.58) * (0.8 + stroke.phase * 0.2))
            case .confidence:
                color = NSColor(calibratedHue: 0.49, saturation: 0.7, brightness: 0.65 + stroke.confidence * 0.35, alpha: (0.3 + stroke.confidence * 0.58) * (0.8 + stroke.phase * 0.2))
            default:
                color = NSColor(calibratedHue: max(0.02, 0.55 - min(stroke.speed / 35, 1) * 0.48), saturation: 0.82, brightness: 1, alpha: (0.3 + stroke.confidence * 0.58) * (0.8 + stroke.phase * 0.2))
            }
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth((1.15 + min(stroke.speed / 24, 1.0)) / max(zoomScale, 0.000_001))
            context.strokePath()
            if index.isMultiple(of: 3), end != previous {
                let angle = atan2(end.y - previous.y, end.x - previous.x)
                let arrowSize = 4.2 / max(zoomScale, 0.000_001)
                let arrow = CGMutablePath(); arrow.move(to: end)
                arrow.addLine(to: CGPoint(x: end.x - cos(angle - 0.48) * arrowSize, y: end.y - sin(angle - 0.48) * arrowSize))
                arrow.move(to: end)
                arrow.addLine(to: CGPoint(x: end.x - cos(angle + 0.48) * arrowSize, y: end.y - sin(angle + 0.48) * arrowSize))
                context.addPath(arrow); context.strokePath()
            }
        }
    }
}

private struct ContributorMapView: NSViewRepresentable {
    @ObservedObject var state: AppState
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(); map.delegate = context.coordinator; map.mapType = .hybrid
        map.pointOfInterestFilter = .excludingAll; map.showsCompass = true; map.showsScale = true
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 5_000, maxCenterCoordinateDistance: 5_000_000)
        for reuseID in [Coordinator.clusterReuseID, Coordinator.incidentReuseID, Coordinator.cameraReuseID, Coordinator.dispatchReuseID, Coordinator.stationReuseID] {
            map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: reuseID)
        }
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.hotspotReuseID)
        map.setCamera(MKMapCamera(lookingAtCenter: .init(latitude: state.cameraLatitude, longitude: state.cameraLongitude), fromDistance: state.cameraDistance, pitch: 0, heading: 0), animated: false)
        return map
    }
    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self; context.coordinator.sync(on: map); context.coordinator.syncSelection(on: map)
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        static let clusterReuseID = "cluster"
        static let incidentReuseID = "incident"
        static let cameraReuseID = "camera"
        static let dispatchReuseID = "dispatch"
        static let stationReuseID = "station"
        static let hotspotReuseID = "hotspot"
        var parent: ContributorMapView
        private var incidentAnnotations: [String: IncidentAnnotation] = [:]
        private var cameraAnnotations: [String: CameraAnnotation] = [:]
        private var signalAnnotations: [String: DispatchAnnotation] = [:]
        private var stationAnnotations: [String: StationAnnotation] = [:]
        private var incidentHashes: [String: Int] = [:]
        private var cameraHashes: [String: Int] = [:]
        private var signalHashes: [String: Int] = [:]
        private var stationHashes: [String: Int] = [:]
        private var hotspots: [String: HotspotAnnotation] = [:]
        private var perimeters: [MKPolygon] = []
        private var windOverlay: WindMapOverlay?
        private var lastIncidentRevision = -1
        private var lastIncidentFilterRevision = -1
        private var lastCameraRevision = -1
        private var lastDispatchRevision = -1
        private var lastDispatchFilterRevision = -1
        private var lastStationRevision = -1
        private var lastHotspotRevision = -1
        private var lastPerimeterRevision = -1
        private var lastWindOverlayRevision = -1
        private var lastWindStationRevision = -1
        private var lastWindMode: WindDisplayMode?
        private var lastWindInfluence = -1.0
        private var camerasVisible = false
        private var dispatchVisible = false
        private var stationsVisible = false
        private var hotspotsVisible = false
        private var perimetersVisible = false
        private var windVisible = false
        init(parent: ContributorMapView) { self.parent = parent }

        func sync(on map: MKMapView) {
            syncIncidents(on: map)
            syncCameras(on: map)
            syncDispatch(on: map)
            syncStations(on: map)
            syncHotspots(on: map)
            syncPerimeters(on: map)
            syncWind(on: map)
        }

        private func syncIncidents(on map: MKMapView) {
            guard lastIncidentRevision != parent.state.incidentRevision || lastIncidentFilterRevision != parent.state.incidentFilterRevision else { return }
            lastIncidentRevision = parent.state.incidentRevision; lastIncidentFilterRevision = parent.state.incidentFilterRevision
            let desired = indexed(parent.state.filteredIncidents.filter { $0.coordinate != nil }, id: \.id)
            for id in Array(incidentAnnotations.keys) where desired[id] == nil {
                if let annotation = incidentAnnotations.removeValue(forKey: id) { map.removeAnnotation(annotation) }; incidentHashes[id] = nil
            }
            for (id, incident) in desired {
                let hash = incident.hashValue
                guard incidentHashes[id] != hash else { continue }
                if let annotation = incidentAnnotations[id] {
                    annotation.update(with: incident)
                    if let view = map.view(for: annotation) as? MKMarkerAnnotationView { configure(view, for: annotation) }
                } else {
                    let annotation = IncidentAnnotation(incident: incident); incidentAnnotations[id] = annotation; map.addAnnotation(annotation)
                }
                incidentHashes[id] = hash
            }
        }

        private func syncCameras(on map: MKMapView) {
            guard lastCameraRevision != parent.state.cameraRevision || camerasVisible != parent.state.showCameras else { return }
            lastCameraRevision = parent.state.cameraRevision; camerasVisible = parent.state.showCameras
            let desired = parent.state.showCameras ? indexed(parent.state.cameras, id: \.id) : [:]
            for id in Array(cameraAnnotations.keys) where desired[id] == nil { if let annotation = cameraAnnotations.removeValue(forKey: id) { map.removeAnnotation(annotation) }; cameraHashes[id] = nil }
            for (id, camera) in desired {
                let hash = cameraFingerprint(camera)
                guard cameraHashes[id] != hash else { continue }
                if let annotation = cameraAnnotations[id] {
                    annotation.update(with: camera)
                } else {
                    let annotation = CameraAnnotation(camera: camera); cameraAnnotations[id] = annotation; map.addAnnotation(annotation)
                }
                cameraHashes[id] = hash
            }
        }

        private func syncDispatch(on map: MKMapView) {
            guard lastDispatchRevision != parent.state.dispatchRevision || lastDispatchFilterRevision != parent.state.dispatchFilterRevision || dispatchVisible != parent.state.showDispatch else { return }
            lastDispatchRevision = parent.state.dispatchRevision; lastDispatchFilterRevision = parent.state.dispatchFilterRevision; dispatchVisible = parent.state.showDispatch
            let desired = parent.state.showDispatch ? indexed(parent.state.filteredSignals, id: \.id) : [:]
            for id in Array(signalAnnotations.keys) where desired[id] == nil { if let annotation = signalAnnotations.removeValue(forKey: id) { map.removeAnnotation(annotation) }; signalHashes[id] = nil }
            for (id, signal) in desired {
                let hash = signalFingerprint(signal)
                guard signalHashes[id] != hash else { continue }
                if let annotation = signalAnnotations[id] {
                    annotation.update(with: signal)
                    if let view = map.view(for: annotation) as? MKMarkerAnnotationView { configure(view, for: annotation) }
                } else {
                    let annotation = DispatchAnnotation(signal: signal); signalAnnotations[id] = annotation; map.addAnnotation(annotation)
                }
                signalHashes[id] = hash
            }
        }

        private func syncStations(on map: MKMapView) {
            guard lastStationRevision != parent.state.stationRevision || stationsVisible != parent.state.showStations else { return }
            lastStationRevision = parent.state.stationRevision; stationsVisible = parent.state.showStations
            let desired = parent.state.showStations ? indexed(parent.state.weatherStations, id: \.id) : [:]
            for id in Array(stationAnnotations.keys) where desired[id] == nil { if let annotation = stationAnnotations.removeValue(forKey: id) { map.removeAnnotation(annotation) }; stationHashes[id] = nil }
            for (id, station) in desired {
                let hash = stationFingerprint(station)
                guard stationHashes[id] != hash else { continue }
                if let annotation = stationAnnotations[id] {
                    annotation.update(with: station)
                } else {
                    let annotation = StationAnnotation(station: station); stationAnnotations[id] = annotation; map.addAnnotation(annotation)
                }
                stationHashes[id] = hash
            }
        }

        private func syncHotspots(on map: MKMapView) {
            guard lastHotspotRevision != parent.state.hotspotRevision || hotspotsVisible != parent.state.showHotspots else { return }
            lastHotspotRevision = parent.state.hotspotRevision; hotspotsVisible = parent.state.showHotspots
            let desired = parent.state.showHotspots ? indexed(parent.state.hotspots.compactMap(HotspotAnnotation.init), id: \.id) : [:]
            for id in Array(hotspots.keys) where desired[id] == nil { if let annotation = hotspots.removeValue(forKey: id) { map.removeAnnotation(annotation) } }
            for (id, annotation) in desired where hotspots[id] == nil { hotspots[id] = annotation; map.addAnnotation(annotation) }
        }

        private func indexed<Value>(_ values: [Value], id: KeyPath<Value, String>) -> [String: Value] {
            var result: [String: Value] = [:]; result.reserveCapacity(values.count)
            for value in values { result[value[keyPath: id]] = value }
            return result
        }

        private func cameraFingerprint(_ camera: AlertCamera) -> Int {
            var hasher = Hasher(); hasher.combine(camera.id); hasher.combine(camera.name); hasher.combine(camera.coordinate.latitude); hasher.combine(camera.coordinate.longitude); hasher.combine(camera.imageURL); hasher.combine(camera.viewerURL); hasher.combine(camera.owner); return hasher.finalize()
        }

        private func signalFingerprint(_ signal: DispatchSignal) -> Int {
            var hasher = Hasher(); hasher.combine(signal.id); hasher.combine(signal.name); hasher.combine(signal.type); hasher.combine(signal.coordinate.latitude); hasher.combine(signal.coordinate.longitude); hasher.combine(signal.reportedAt); hasher.combine(signal.acres); hasher.combine(signal.resources); hasher.combine(signal.status); hasher.combine(signal.webComment); return hasher.finalize()
        }

        private func stationFingerprint(_ station: WeatherStation) -> Int {
            var hasher = Hasher(); hasher.combine(station.id); hasher.combine(station.name); hasher.combine(station.coordinate.latitude); hasher.combine(station.coordinate.longitude); hasher.combine(station.speedMPH); hasher.combine(station.directionDegrees); hasher.combine(station.observedAt); return hasher.finalize()
        }

        private func syncPerimeters(on map: MKMapView) {
            guard lastPerimeterRevision != parent.state.perimeterRevision || perimetersVisible != parent.state.showPerimeters else { return }
            lastPerimeterRevision = parent.state.perimeterRevision; perimetersVisible = parent.state.showPerimeters
            if !perimeters.isEmpty { map.removeOverlays(perimeters) }
            perimeters = parent.state.showPerimeters ? parent.state.perimeters.flatMap(\.outerRings).map { MKPolygon(coordinates: $0, count: $0.count) } : []
            if !perimeters.isEmpty { map.addOverlays(perimeters, level: .aboveRoads) }
        }

        private func syncWind(on map: MKMapView) {
            let needsUpdate = lastWindOverlayRevision != parent.state.windRevision ||
                lastWindStationRevision != parent.state.stationRevision ||
                lastWindMode != parent.state.windMode ||
                lastWindInfluence != parent.state.vaneInfluenceMiles ||
                windVisible != parent.state.showWind
            guard needsUpdate else { return }
            lastWindOverlayRevision = parent.state.windRevision
            lastWindStationRevision = parent.state.stationRevision
            lastWindMode = parent.state.windMode
            lastWindInfluence = parent.state.vaneInfluenceMiles
            windVisible = parent.state.showWind
            if let windOverlay { map.removeOverlay(windOverlay); self.windOverlay = nil }
            guard parent.state.showWind, !parent.state.windSamples.isEmpty else { return }
            let overlay = WindMapOverlay(samples: parent.state.windSamples, stations: parent.state.weatherStations, mode: parent.state.windMode, influenceMiles: parent.state.vaneInfluenceMiles)
            windOverlay = overlay
            map.addOverlay(overlay, level: .aboveRoads)
        }

        func syncSelection(on map: MKMapView) {
            let selected: MKAnnotation? = parent.state.selectedIncidentID.flatMap { incidentAnnotations[$0] } ?? parent.state.selectedCameraID.flatMap { cameraAnnotations[$0] } ?? parent.state.selectedSignalID.flatMap { signalAnnotations[$0] }
            // Map-originated selections are already selected by MapKit. Keep
            // those, and only clear stale selections when state changes.
            // Programmatically selecting a clustered member makes MapKit move
            // the camera to reveal it, so sidebar selections must never call
            // selectAnnotation here.
            for annotation in map.selectedAnnotations where annotation !== selected {
                map.deselectAnnotation(annotation, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.clusterReuseID, for: cluster) as! MKMarkerAnnotationView
                view.markerTintColor = NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.28, alpha: 0.95); view.glyphImage = nil; view.glyphText = cluster.memberAnnotations.count.formatted(); view.clusteringIdentifier = nil; return view
            }
            if let hotspot = annotation as? HotspotAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.hotspotReuseID, for: hotspot); view.frame.size = NSSize(width: 6, height: 6); view.wantsLayer = true; view.layer?.cornerRadius = 3; view.layer?.backgroundColor = NSColor.systemOrange.cgColor; view.clusteringIdentifier = "hotspots"; return view
            }
            guard annotation is IncidentAnnotation || annotation is CameraAnnotation || annotation is DispatchAnnotation || annotation is StationAnnotation else { return nil }
            let reuseID: String
            switch annotation {
            case is IncidentAnnotation: reuseID = Self.incidentReuseID
            case is CameraAnnotation: reuseID = Self.cameraReuseID
            case is DispatchAnnotation: reuseID = Self.dispatchReuseID
            default: reuseID = Self.stationReuseID
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID, for: annotation) as! MKMarkerAnnotationView
            configure(view, for: annotation)
            return view
        }

        private func configure(_ view: MKMarkerAnnotationView, for annotation: MKAnnotation) {
            view.canShowCallout = false; view.titleVisibility = .hidden; view.subtitleVisibility = .hidden; view.glyphText = nil; view.displayPriority = .defaultHigh
            if let item = annotation as? IncidentAnnotation { view.markerTintColor = item.incident.isPrescribed ? .systemOrange : .systemRed; view.glyphImage = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil); view.clusteringIdentifier = "incidents" }
            if annotation is CameraAnnotation { view.markerTintColor = NSColor(calibratedRed: 0.19, green: 0.72, blue: 0.85, alpha: 1); view.glyphImage = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil); view.clusteringIdentifier = "cameras" }
            if let item = annotation as? DispatchAnnotation { view.markerTintColor = item.signal.isUnconfirmed ? .systemGray : NSColor(calibratedRed: 0.26, green: 0.91, blue: 0.88, alpha: 1); view.glyphImage = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil); view.clusteringIdentifier = "dispatch" }
            if annotation is StationAnnotation { view.markerTintColor = NSColor.systemYellow; view.glyphImage = NSImage(systemSymbolName: "location.north.fill", accessibilityDescription: nil); view.clusteringIdentifier = nil; view.displayPriority = .required }
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let item = view.annotation as? IncidentAnnotation { parent.state.selectIncident(item.incident.id) }
            else if let item = view.annotation as? CameraAnnotation { parent.state.selectCamera(item.camera.id) }
            else if let item = view.annotation as? DispatchAnnotation { parent.state.selectSignal(item.signal.id) }
            else if let cluster = view.annotation as? MKClusterAnnotation { zoom(to: cluster, on: mapView) }
        }

        private func zoom(to cluster: MKClusterAnnotation, on mapView: MKMapView) {
            guard let mapRect = clusterMapRect(for: cluster.memberAnnotations.map(\.coordinate)) else { return }
            mapView.setVisibleMapRect(mapRect, edgePadding: NSEdgeInsets(top: 90, left: 70, bottom: 70, right: 360), animated: true)
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is WindMapOverlay { return WindMapRenderer(overlay: overlay) }
            guard let polygon = overlay as? MKPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolygonRenderer(polygon: polygon); renderer.fillColor = NSColor.systemRed.withAlphaComponent(0.14); renderer.strokeColor = NSColor.systemRed.withAlphaComponent(0.9); renderer.lineWidth = 1.2; return renderer
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region; parent.state.cameraLatitude = region.center.latitude; parent.state.cameraLongitude = region.center.longitude; parent.state.cameraDistance = mapView.camera.centerCoordinateDistance
        }
    }
}

private final class IncidentAnnotation: NSObject, MKAnnotation {
    private(set) var incident: IncidentFeature
    @objc dynamic private(set) var coordinate: CLLocationCoordinate2D
    init(incident: IncidentFeature) { self.incident = incident; coordinate = incident.coordinate ?? .init() }
    func update(with incident: IncidentFeature) {
        self.incident = incident
        if let value = incident.coordinate, !sameCoordinate(value, coordinate) { coordinate = value }
    }
}

private final class CameraAnnotation: NSObject, MKAnnotation {
    private(set) var camera: AlertCamera
    @objc dynamic private(set) var coordinate: CLLocationCoordinate2D
    init(camera: AlertCamera) { self.camera = camera; coordinate = camera.coordinate }
    func update(with camera: AlertCamera) { self.camera = camera; if !sameCoordinate(camera.coordinate, coordinate) { coordinate = camera.coordinate } }
}

private final class DispatchAnnotation: NSObject, MKAnnotation {
    private(set) var signal: DispatchSignal
    @objc dynamic private(set) var coordinate: CLLocationCoordinate2D
    init(signal: DispatchSignal) { self.signal = signal; coordinate = signal.coordinate }
    func update(with signal: DispatchSignal) { self.signal = signal; if !sameCoordinate(signal.coordinate, coordinate) { coordinate = signal.coordinate } }
}

private final class StationAnnotation: NSObject, MKAnnotation {
    private(set) var station: WeatherStation
    @objc dynamic private(set) var coordinate: CLLocationCoordinate2D
    init(station: WeatherStation) { self.station = station; coordinate = station.coordinate }
    func update(with station: WeatherStation) { self.station = station; if !sameCoordinate(station.coordinate, coordinate) { coordinate = station.coordinate } }
}
private final class HotspotAnnotation: NSObject, MKAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    init?(feature: HotspotFeature) {
        guard let coordinate = feature.coordinate, let stableMapID = feature.stableMapID else { return nil }
        self.coordinate = coordinate
        id = stableMapID
    }
}

private func distance(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Double {
    fastDistance(lhs, rhs)
}

private func sameCoordinate(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
    lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
}

func clusterMapRect(for coordinates: [CLLocationCoordinate2D], minimumSpanMeters: Double = 8_000) -> MKMapRect? {
    guard let first = coordinates.first else { return nil }
    var mapRect = MKMapRect.null
    for coordinate in coordinates {
        let point = MKMapPoint(coordinate)
        mapRect = mapRect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
    }
    let center = MKMapPoint(x: mapRect.midX, y: mapRect.midY)
    let minimumSpan = MKMapPointsPerMeterAtLatitude(first.latitude) * minimumSpanMeters
    if mapRect.width < minimumSpan {
        mapRect.origin.x = center.x - minimumSpan / 2
        mapRect.size.width = minimumSpan
    }
    if mapRect.height < minimumSpan {
        mapRect.origin.y = center.y - minimumSpan / 2
        mapRect.size.height = minimumSpan
    }
    return mapRect
}

private func fastDistance(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Double {
    let latitude = (lhs.latitude + rhs.latitude) * .pi / 360
    let x = (rhs.longitude - lhs.longitude) * .pi / 180 * cos(latitude)
    let y = (rhs.latitude - lhs.latitude) * .pi / 180
    return sqrt(x * x + y * y) * 3_958.8
}
