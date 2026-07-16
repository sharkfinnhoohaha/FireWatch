import Foundation
import CoreLocation

struct GeoJSONFeatureCollection<Feature: Decodable>: Decodable {
    let features: [Feature]
}

struct IncidentFeature: Codable, Identifiable, Hashable, Sendable {
    struct Properties: Codable, Hashable, Sendable {
        let incidentName: String?
        let incidentSize: Double?
        let percentContained: Double?
        let fireDiscoveryDateTime: Double?
        let incidentTypeCategory: String?
        let pooCounty: String?
        let pooCity: String?
        let pooState: String?
        let modifiedOnDateTime: Double?
        let totalIncidentPersonnel: Int?
        let fireCause: String?
        let irwinID: String?

        enum CodingKeys: String, CodingKey {
            case incidentName = "IncidentName"
            case incidentSize = "IncidentSize"
            case percentContained = "PercentContained"
            case fireDiscoveryDateTime = "FireDiscoveryDateTime"
            case incidentTypeCategory = "IncidentTypeCategory"
            case pooCounty = "POOCounty"
            case pooCity = "POOCity"
            case pooState = "POOState"
            case modifiedOnDateTime = "ModifiedOnDateTime_dt"
            case totalIncidentPersonnel = "TotalIncidentPersonnel"
            case fireCause = "FireCause"
            case irwinID = "IrwinID"
        }
    }

    struct PointGeometry: Codable, Hashable, Sendable {
        let coordinates: [Double]?
    }

    let properties: Properties?
    let geometry: PointGeometry?

    var id: String {
        properties?.irwinID ?? "\(properties?.incidentName ?? "Unknown")-\(longitude ?? 0)-\(latitude ?? 0)"
    }
    var name: String { properties?.incidentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Unnamed incident" }
    var latitude: Double? { geometry?.coordinates.flatMap { $0.count >= 2 ? $0[1] : nil } }
    var longitude: Double? { geometry?.coordinates.flatMap { $0.count >= 2 ? $0[0] : nil } }
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var discoveryDate: Date? { properties?.fireDiscoveryDateTime.map { Date(timeIntervalSince1970: $0 / 1_000) } }
    var modifiedDate: Date? { properties?.modifiedOnDateTime.map { Date(timeIntervalSince1970: $0 / 1_000) } }
    var isWildfire: Bool { properties?.incidentTypeCategory == "WF" }
    var isPrescribed: Bool { properties?.incidentTypeCategory == "RX" }

    func distanceMiles(from home: CLLocation) -> Double? {
        guard let latitude, let longitude else { return nil }
        return home.distance(from: CLLocation(latitude: latitude, longitude: longitude)) / 1_609.344
    }
}

struct PerimeterFeature: Decodable, Identifiable, Sendable {
    struct Properties: Decodable, Sendable {
        let name: String?
        let acres: Double?
        let containment: Double?
        let category: String?

        enum CodingKeys: String, CodingKey {
            case name = "poly_IncidentName"
            case acres = "poly_GISAcres"
            case containment = "attr_PercentContained"
            case category = "attr_IncidentTypeCategory"
        }
    }

    struct Geometry: Decodable, Sendable {
        let polygons: [[[[Double]]]]

        enum CodingKeys: String, CodingKey { case type, coordinates }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "Polygon":
                polygons = [try container.decode([[[Double]]].self, forKey: .coordinates)]
            case "MultiPolygon":
                polygons = try container.decode([[[[Double]]]].self, forKey: .coordinates)
            default:
                polygons = []
            }
        }
    }

    let properties: Properties?
    let geometry: Geometry?
    let id = UUID()
    enum CodingKeys: String, CodingKey { case properties, geometry }

    var outerRings: [[CLLocationCoordinate2D]] {
        (geometry?.polygons ?? []).compactMap { polygon in
            guard let outer = polygon.first else { return nil }
            let ring = outer.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
            return ring.count >= 3 ? ring : nil
        }
    }
}

struct HotspotFeature: Decodable, Identifiable, Sendable {
    struct Properties: Decodable, Sendable {
        let frp: Double?
        let confidence: String?
        let hoursOld: Int?
        enum CodingKeys: String, CodingKey { case frp, confidence; case hoursOld = "hours_old" }
    }
    struct Geometry: Decodable, Sendable { let coordinates: [Double]? }
    let properties: Properties?
    let geometry: Geometry?
    let id = UUID()
    enum CodingKeys: String, CodingKey { case properties, geometry }

    var coordinate: CLLocationCoordinate2D? {
        guard let values = geometry?.coordinates, values.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: values[1], longitude: values[0])
    }

    /// ArcGIS does not expose an object ID in the GeoJSON projection used by the
    /// app. Coordinate precision is stable across refreshes, unlike `hours_old`,
    /// so this keeps an installed map annotation anchored while its age changes.
    var stableMapID: String? {
        guard let coordinate else { return nil }
        return "\(Int((coordinate.latitude * 100_000).rounded())):\(Int((coordinate.longitude * 100_000).rounded()))"
    }
}

struct NWSAlertFeature: Decodable, Identifiable, Hashable, Sendable {
    struct Properties: Decodable, Hashable, Sendable {
        let event: String?
        let areaDesc: String?
        let severity: String?
        let ends: Date?
        let expires: Date?
    }
    let id: String
    let properties: Properties
    var isEvacuation: Bool { properties.event?.localizedCaseInsensitiveContains("evacuation") == true }
}

// MARK: - Contributor intelligence feeds

struct DispatchSignal: Identifiable, Hashable, Sendable {
    let id: String
    let center: String
    let incidentNumber: String?
    let name: String
    let type: String
    let coordinate: CLLocationCoordinate2D
    let reportedAt: Date?
    let acres: Double?
    let resources: [String]
    let status: String?
    let webComment: String?

    static func == (lhs: DispatchSignal, rhs: DispatchSignal) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isUnconfirmed: Bool {
        type.localizedCaseInsensitiveContains("smoke") || type.localizedCaseInsensitiveContains("false")
    }
}

struct WildCADEnvelope: Decodable, Sendable {
    let data: [WildCADRecord]
}

struct WildCADRecord: Decodable, Sendable {
    let ic: String?
    let date: String?
    let name: String?
    let type: String?
    let uuid: String?
    let acres: String?
    let incNum: String?
    let latitude: String?
    let longitude: String?
    let resources: [String?]?
    let webComment: String?
    let fireStatus: String?

    enum CodingKeys: String, CodingKey {
        case ic, date, name, type, uuid, acres, latitude, longitude, resources
        case incNum = "inc_num"
        case webComment
        case fireStatus = "fire_status"
    }
}

struct AlertCamera: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let imageURL: URL?
    let viewerURL: URL?
    let owner: String?

    static func == (lhs: AlertCamera, rhs: AlertCamera) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct CameraArcGISResponse: Decodable, Sendable {
    struct Feature: Decodable, Sendable {
        struct Attributes: Decodable, Sendable {
            let fid: Int?
            let calfireUnit: String?
            let alertWildfire: String?
            let webcamName: String?
            let id: String?
            let latitude: Double?
            let longitude: Double?
            let link: String?
            let ownerLink: String?

            enum CodingKeys: String, CodingKey {
                case fid = "FID"
                case calfireUnit = "Calfire_Un"
                case alertWildfire = "Alert_Wild"
                case webcamName = "Webcam_Nam"
                case id = "ID"
                case latitude = "Latitude"
                case longitude = "Longitide"
                case link = "Link"
                case ownerLink = "Owner_Link"
            }
        }
        struct Geometry: Decodable, Sendable { let x: Double?; let y: Double? }
        let attributes: Attributes
        let geometry: Geometry?
    }
    let features: [Feature]
}

struct WindSample: Identifiable, Hashable, Sendable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let speedMPH: Double
    let directionDegrees: Double
    let gustMPH: Double?

    static func == (lhs: WindSample, rhs: WindSample) -> Bool { lhs.id == rhs.id && lhs.speedMPH == rhs.speedMPH && lhs.directionDegrees == rhs.directionDegrees }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(speedMPH); hasher.combine(directionDegrees) }
}

struct WeatherStation: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let speedMPH: Double
    let directionDegrees: Double
    let observedAt: Date?

    static func == (lhs: WeatherStation, rhs: WeatherStation) -> Bool { lhs.id == rhs.id && lhs.speedMPH == rhs.speedMPH && lhs.directionDegrees == rhs.directionDegrees }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(speedMPH); hasher.combine(directionDegrees) }
}

struct WindSnapshot: Sendable {
    let samples: [WindSample]
    let stations: [WeatherStation]
}

enum WindMath {
    /// Meteorological bearings describe where wind comes from. Returned values
    /// describe where air moves toward: east-positive and north-positive.
    static func flowComponents(speedMPH: Double, directionFromDegrees: Double) -> (east: Double, north: Double) {
        let radians = directionFromDegrees * .pi / 180
        return (-speedMPH * sin(radians), -speedMPH * cos(radians))
    }
}

struct OpenMeteoWindResponse: Decodable, Sendable {
    struct Current: Decodable, Sendable {
        let windSpeed: Double
        let windDirection: Double
        let windGusts: Double?
        enum CodingKeys: String, CodingKey {
            case windSpeed = "wind_speed_10m"
            case windDirection = "wind_direction_10m"
            case windGusts = "wind_gusts_10m"
        }
    }
    let latitude: Double
    let longitude: Double
    let current: Current
}

struct NWSStationObservation: Decodable, Sendable {
    struct Geometry: Decodable, Sendable { let coordinates: [Double] }
    struct Properties: Decodable, Sendable {
        struct Value: Decodable, Sendable { let value: Double? }
        let timestamp: Date?
        let windDirection: Value
        let windSpeed: Value
    }
    let geometry: Geometry
    let properties: Properties
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
