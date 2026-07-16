import SwiftUI

struct DetailPanel: View {
    let incident: IncidentFeature
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            row("Name", incident.name)
            row("Type", incident.isWildfire ? "Wildfire" : incident.isPrescribed ? "Prescribed fire" : incident.properties?.incidentTypeCategory ?? "—")
            row("Size", incident.properties?.incidentSize.map { "\($0.formatted(.number.precision(.fractionLength(0)))) acres" } ?? "—")
            row("Contained", incident.properties?.percentContained.map { "\(Int($0))%" } ?? "—")
            row("County", incident.properties?.pooCounty ?? "—")
            row("City", incident.properties?.pooCity ?? "—")
            row("Discovered", incident.discoveryDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            row("Updated", incident.modifiedDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            row("Personnel", incident.properties?.totalIncidentPersonnel.map(String.init) ?? "—")
            row("Cause", incident.properties?.fireCause ?? "—")
            row("From Ventura", incident.distanceMiles(from: AppState.home).map { "\($0.formatted(.number.precision(.fractionLength(1)))) miles" } ?? "—")
        }.padding().frame(width: 330)
    }
    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}
