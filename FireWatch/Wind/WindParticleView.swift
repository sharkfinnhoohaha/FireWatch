import AppKit
import MapKit

// Animated wind-flow overlay: thousands of particles advected through the
// baked velocity field and drawn as fading trails. Port of the web app's
// canvas particle engine (app/components/particles.ts) to AppKit.
//
// The view rides ABOVE the MKMapView as a click-through subview — deliberately
// outside MapKit's overlay/renderer system, whose tiled per-frame redraw is the
// wrong tool for a full-screen animation. Particles live in geographic
// coordinates and are re-projected to the screen each frame (via a per-frame
// affine derived from the map's visible rect), so they stay locked to the map.

/// The field to advect through, plus colour mapping. Port of FieldSpec.
struct WindFieldSpec {
    /// Velocity field the particles are advected through (km/h components).
    let sampler: WindSampler
    /// Speed (km/h) mapping to the top colour, when `colorScalar` is absent.
    let scaleKmh: Double
    /// Optional scalar used to COLOUR particles instead of advection speed —
    /// e.g. the model↔vane disagreement magnitude, or analysis confidence.
    let colorScalar: ((_ lon: Double, _ lat: Double, _ vec: WindVec) -> Double)?
    /// Value (same units as colorScalar) mapping to the top colour.
    let colorScale: Double?
}

/// Wind-speed colour ramp, port of app/lib/colormap.ts (stops are mph).
enum WindColorRamp {
    private static let stops: [(v: Double, r: Double, g: Double, b: Double)] = [
        (0, 60, 78, 112),
        (5, 44, 127, 184),
        (10, 65, 182, 196),
        (15, 120, 198, 121),
        (20, 194, 230, 110),
        (25, 254, 217, 118),
        (30, 253, 141, 60),
        (40, 240, 59, 32),
        (55, 189, 0, 38),
    ]

    static func speedColor(mph: Double) -> (r: Double, g: Double, b: Double) {
        if mph <= stops[0].v { return (stops[0].r, stops[0].g, stops[0].b) }
        let last = stops[stops.count - 1]
        if mph >= last.v { return (last.r, last.g, last.b) }
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if mph <= b.v {
                let f = (mph - a.v) / (b.v - a.v)
                return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
            }
        }
        return (last.r, last.g, last.b)
    }

    /// Normalized ramp: t in [0,1] across the full colour range.
    static func rampColor(_ t: Double) -> (r: Double, g: Double, b: Double) {
        speedColor(mph: max(0, min(1, t)) * stops[stops.count - 1].v)
    }
}

final class WindParticleView: NSView {
    private struct Particle {
        var lon = 0.0
        var lat = 0.0
        var age = 0.0
        var life = 0.0
    }

    // Options mirroring the web DEFAULTS.
    private let particleCount = 2_800
    private let speedScale = 0.12 // geographic step per second per (km/h)
    private let fade = 0.07 // alpha removed from trails each frame
    private let strokeWidth: CGFloat = 1.3

    private weak var mapView: MKMapView?
    private let bbox: GeoBBox
    private var spec: WindFieldSpec?
    private var particles: [Particle] = []
    private var buffer: CGContext?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var running = false
    private var lastMapMovement: CFTimeInterval = 0
    private var clearPending = true

    init(mapView: MKMapView, bbox: GeoBBox) {
        self.mapView = mapView
        self.bbox = bbox
        super.init(frame: mapView.bounds)
        wantsLayer = true
        layer?.contentsGravity = .resize
        seed()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The overlay is presentation-only: every event falls through to the map.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setField(_ spec: WindFieldSpec) {
        self.spec = spec
        clearPending = true
    }

    func start() {
        guard !running else { return }
        running = true
        lastTick = CACurrentMediaTime()
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stop(clearTrails: Bool) {
        running = false
        link?.invalidate()
        link = nil
        if clearTrails {
            clearBuffer()
            publish()
        }
    }

    /// Called while the map is panning/zooming: trails are cleared each frame
    /// during interaction so they never smear against the moving basemap.
    func noteMapMovement() {
        lastMapMovement = CACurrentMediaTime()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            link?.invalidate()
            link = nil
            running = false
        }
    }

    override func layout() {
        super.layout()
        rebuildBufferIfNeeded()
    }

    // MARK: - Simulation

    private func seed() {
        particles = (0..<particleCount).map { _ in
            var p = Particle()
            respawn(&p)
            p.age = Double.random(in: 0..<max(p.life, 0.01)) // desynchronize lifetimes
            return p
        }
    }

    private func respawn(_ p: inout Particle) {
        p.lon = Double.random(in: bbox.west...bbox.east)
        p.lat = Double.random(in: bbox.south...bbox.north)
        p.age = 0
        p.life = Double.random(in: 1.4...4.2)
    }

    @objc private func tick(_ sender: CADisplayLink) {
        guard running, let spec, let map = mapView, let ctx = buffer,
              bounds.width > 1, bounds.height > 1 else { return }
        let now = CACurrentMediaTime()
        var dt = now - lastTick
        lastTick = now
        if !(dt > 0) { dt = 0.016 }
        dt = min(dt, 0.05)

        guard let transform = mapPointToViewTransform(map) else { return }

        // While interacting, clear fully each frame so trails don't smear;
        // otherwise erase a little alpha for the fading-trail look.
        let moving = now - lastMapMovement < 0.15
        if clearPending || moving {
            clearBuffer()
            clearPending = false
        } else {
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(fade)))
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
            ctx.restoreGState()
        }

        ctx.setLineCap(.round)
        ctx.setLineWidth(strokeWidth)
        let colorDenom = (spec.colorScalar != nil ? (spec.colorScale ?? spec.scaleKmh) : spec.scaleKmh)
        let denom = colorDenom == 0 ? 1 : colorDenom
        let cullRect = bounds.insetBy(dx: -60, dy: -60)

        for index in particles.indices {
            var p = particles[index]
            let lon0 = p.lon
            let lat0 = p.lat
            let vec = spec.sampler(lon0, lat0)
            let sp = hypot(vec.u, vec.v)
            // Colour by the scalar field if given, else by speed. Sampled at
            // the pre-move position so colour and motion stay consistent.
            let colorVal = spec.colorScalar?(lon0, lat0, vec) ?? sp

            let a = transform.apply(to: MKMapPoint(CLLocationCoordinate2D(latitude: lat0, longitude: lon0)))
            let dLat = 1 / 110.57
            let dLon = 1 / (111.32 * cos(lat0 * .pi / 180))
            let step = dt * speedScale
            p.lon += vec.u * step * dLon
            p.lat += vec.v * step * dLat
            p.age += dt
            let b = transform.apply(to: MKMapPoint(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)))

            if cullRect.contains(a) || cullRect.contains(b) {
                let t = min(colorVal / denom, 1)
                let c = WindColorRamp.rampColor(t)
                ctx.setStrokeColor(CGColor(
                    srgbRed: CGFloat(c.r / 255),
                    green: CGFloat(c.g / 255),
                    blue: CGFloat(c.b / 255),
                    alpha: CGFloat(0.55 + 0.45 * t)
                ))
                ctx.beginPath()
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
            }

            if p.age > p.life ||
                p.lon < bbox.west || p.lon > bbox.east ||
                p.lat < bbox.south || p.lat > bbox.north {
                respawn(&p)
            }
            particles[index] = p
        }

        publish()
    }

    // MARK: - Projection

    /// Exact MKMapPoint→view affine for the current camera (pitch 0), derived
    /// from three corner correspondences of the visible map rect. Three
    /// MKMapView conversions per frame instead of two per particle.
    private struct MapTransform {
        let a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
        func apply(to point: MKMapPoint) -> CGPoint {
            CGPoint(
                x: a * point.x + c * point.y + tx,
                y: b * point.x + d * point.y + ty
            )
        }
    }

    private func mapPointToViewTransform(_ map: MKMapView) -> MapTransform? {
        let rect = map.visibleMapRect
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }
        let p1 = MKMapPoint(x: rect.minX, y: rect.minY)
        let p2 = MKMapPoint(x: rect.maxX, y: rect.minY)
        let p3 = MKMapPoint(x: rect.minX, y: rect.maxY)
        let v1 = map.convert(p1.coordinate, toPointTo: self)
        let v2 = map.convert(p2.coordinate, toPointTo: self)
        let v3 = map.convert(p3.coordinate, toPointTo: self)
        guard v1.x.isFinite, v1.y.isFinite, v2.x.isFinite, v2.y.isFinite,
              v3.x.isFinite, v3.y.isFinite else { return nil }
        let w = rect.size.width
        let h = rect.size.height
        let a = (Double(v2.x) - Double(v1.x)) / w
        let b = (Double(v2.y) - Double(v1.y)) / w
        let c = (Double(v3.x) - Double(v1.x)) / h
        let d = (Double(v3.y) - Double(v1.y)) / h
        let tx = Double(v1.x) - a * rect.origin.x - c * rect.origin.y
        let ty = Double(v1.y) - b * rect.origin.x - d * rect.origin.y
        return MapTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    // MARK: - Trail buffer

    /// The accumulation buffer is kept at 1x logical resolution: trails are
    /// soft glows, and a 1x buffer keeps the per-frame image publish cheap.
    private func rebuildBufferIfNeeded() {
        let width = Int(bounds.width.rounded())
        let height = Int(bounds.height.rounded())
        guard width > 1, height > 1 else { return }
        if let buffer, buffer.width == width, buffer.height == height { return }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        // Flip so top-left view coordinates (isFlipped) draw upright in the image.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        buffer = ctx
        clearPending = true
    }

    private func clearBuffer() {
        guard let ctx = buffer else { return }
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.setFillColor(.clear)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        ctx.restoreGState()
    }

    private func publish() {
        guard let image = buffer?.makeImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}
