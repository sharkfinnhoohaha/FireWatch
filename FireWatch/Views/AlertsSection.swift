import SwiftUI

struct AlertsSection: View {
    let alerts: [NWSAlertFeature]
    var body: some View {
        if !alerts.isEmpty {
            Section("Fire-weather alerts") {
                ForEach(alerts) { alert in
                    HStack(alignment: .top) {
                        Image(systemName: alert.isEvacuation ? "exclamationmark.triangle.fill" : "wind")
                            .foregroundStyle(alert.isEvacuation ? .red : .orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(alert.properties.event ?? "Fire-weather alert").font(.headline)
                            Text(alert.properties.areaDesc ?? "California").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let end = alert.properties.ends ?? alert.properties.expires { Text("Until \(end.formatted(date: .abbreviated, time: .shortened))").font(.caption2) }
                        }
                    }.padding(.vertical, 3)
                }
            }
        }
    }
}
