import Foundation
import CoreLocation
import UserNotifications

struct FireChange: Equatable {
    enum Kind: Equatable { case new, grew(percent: Int), containmentDropped(from: Int, to: Int) }
    let incident: IncidentFeature
    let kind: Kind
    let distanceMiles: Double
}

enum DiffEngine {
    static func changes(previous: [IncidentFeature], current: [IncidentFeature], home: CLLocation, radius: Double) -> [FireChange] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return current.compactMap { incident in
            guard incident.isWildfire, let distance = incident.distanceMiles(from: home), distance <= radius else { return nil }
            guard let old = previousByID[incident.id] else {
                return FireChange(incident: incident, kind: .new, distanceMiles: distance)
            }
            if let before = old.properties?.incidentSize, before > 0,
               let now = incident.properties?.incidentSize, now > before * 1.25 {
                return FireChange(incident: incident, kind: .grew(percent: Int(((now / before) - 1) * 100)), distanceMiles: distance)
            }
            if let before = old.properties?.percentContained,
               let now = incident.properties?.percentContained, now < before {
                return FireChange(incident: incident, kind: .containmentDropped(from: Int(before), to: Int(now)), distanceMiles: distance)
            }
            return nil
        }
    }

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notify(changes: [FireChange], newAlerts: [NWSAlertFeature]) async {
        let center = UNUserNotificationCenter.current()
        for change in changes {
            let content = UNMutableNotificationContent()
            let acres = change.incident.properties?.incidentSize ?? 0
            switch change.kind {
            case .new:
                content.title = "New fire: \(change.incident.name)"
                content.body = "\(acres.formatted(.number.precision(.fractionLength(0)))) ac, \(change.distanceMiles.formatted(.number.precision(.fractionLength(0)))) mi away"
            case .grew(let percent):
                content.title = "\(change.incident.name) grew \(percent)%"
                content.body = "Now \(acres.formatted(.number.precision(.fractionLength(0)))) acres"
            case .containmentDropped(let before, let now):
                content.title = "Containment dropped: \(change.incident.name)"
                content.body = "\(before)% to \(now)% contained"
            }
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "fire-\(change.incident.id)-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
        }
        for alert in newAlerts where alert.isEvacuation {
            let content = UNMutableNotificationContent()
            content.title = alert.properties.event ?? "Evacuation alert"
            content.body = alert.properties.areaDesc ?? "California"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            try? await center.add(UNNotificationRequest(identifier: "alert-\(alert.id)", content: content, trigger: nil))
        }
    }
}
