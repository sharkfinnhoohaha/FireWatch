import XCTest
import CoreLocation
import MapKit
@testable import FireWatch

final class FireWatchTests: XCTestCase {
    func testMultiPolygonDecoding() throws {
        let data = #"{"features":[{"properties":{},"geometry":{"type":"MultiPolygon","coordinates":[[[[-120,35],[-121,35],[-120,36],[-120,35]]],[[[-119,34],[-118,34],[-119,35],[-119,34]]]]}}]}"#.data(using: .utf8)!
        let value = try JSONDecoder().decode(GeoJSONFeatureCollection<PerimeterFeature>.self, from: data)
        XCTAssertEqual(value.features.first?.outerRings.count, 2)
    }

    @MainActor func testGrowthDiff() {
        let old = incident(id: "A", acres: 100)
        let new = incident(id: "A", acres: 130)
        let changes = DiffEngine.changes(previous: [old], current: [new], home: CLLocation(latitude: 34.3705, longitude: -119.2290), radius: 60)
        XCTAssertEqual(changes.first?.kind, .grew(percent: 30))
    }

    func testWildCADSignalDecoding() throws {
        let data = #"[{"data":[{"ic":"LPCC","date":"2026-07-14T18:31:19.306","name":"RIDGE","type":"Smoke Check","uuid":"signal-1","acres":"2.5","inc_num":"CA-LPF-1","latitude":"34.25","longitude":"-119.42","resources":["E31",null],"webComment":"checking","fire_status":"{\"contain\":null}"}]}]"#.data(using: .utf8)!
        let value = try JSONDecoder().decode([WildCADEnvelope].self, from: data)
        XCTAssertEqual(value.first?.data.first?.name, "RIDGE")
        XCTAssertEqual(value.first?.data.first?.resources?.compactMap { $0 }.count, 1)
    }

    func testCameraCatalogDecoding() throws {
        let data = #"{"features":[{"attributes":{"FID":7,"Webcam_Nam":"Test Camera","ID":"Axis-Test","Latitude":34.2,"Longitide":-119.3,"Link":"https://example.com/image","Owner_Link":"https://alertwest.live/"},"geometry":{"x":-119.3,"y":34.2}}]}"#.data(using: .utf8)!
        let value = try JSONDecoder().decode(CameraArcGISResponse.self, from: data)
        XCTAssertEqual(value.features.first?.attributes.webcamName, "Test Camera")
        XCTAssertEqual(value.features.first?.geometry?.x, -119.3)
    }

    func testMeteorologicalWindBearingIsConvertedFromToFlowDirection() {
        let fromNorth = WindMath.flowComponents(speedMPH: 10, directionFromDegrees: 0)
        XCTAssertEqual(fromNorth.east, 0, accuracy: 0.0001)
        XCTAssertEqual(fromNorth.north, -10, accuracy: 0.0001)

        let fromEast = WindMath.flowComponents(speedMPH: 10, directionFromDegrees: 90)
        XCTAssertEqual(fromEast.east, -10, accuracy: 0.0001)
        XCTAssertEqual(fromEast.north, 0, accuracy: 0.0001)

        let fromSouth = WindMath.flowComponents(speedMPH: 10, directionFromDegrees: 180)
        XCTAssertEqual(fromSouth.north, 10, accuracy: 0.0001)

        let fromWest = WindMath.flowComponents(speedMPH: 10, directionFromDegrees: 270)
        XCTAssertEqual(fromWest.east, 10, accuracy: 0.0001)
    }

    func testHotspotMapIdentityDoesNotChangeAsObservationAges() throws {
        let freshData = #"{"properties":{"frp":4.2,"confidence":"high","hours_old":1},"geometry":{"coordinates":[-118.25,34.05]}}"#.data(using: .utf8)!
        let agedData = #"{"properties":{"frp":4.2,"confidence":"high","hours_old":2},"geometry":{"coordinates":[-118.25,34.05]}}"#.data(using: .utf8)!
        let fresh = try JSONDecoder().decode(HotspotFeature.self, from: freshData)
        let aged = try JSONDecoder().decode(HotspotFeature.self, from: agedData)

        XCTAssertEqual(fresh.stableMapID, aged.stableMapID)
    }

    // The static WindMapOverlay stroke test was retired with the overlay: wind
    // rendering moved to the display-linked WindParticleView, and the analysis
    // behind it is covered by WindPipelineTests and WindDataTests.

    func testCoincidentClusterPointsCannotTriggerRunawayZoom() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 34.2, longitude: -118.3)
        let mapRect = try XCTUnwrap(clusterMapRect(for: [coordinate, coordinate]))
        let minimumSpan = MKMapPointsPerMeterAtLatitude(coordinate.latitude) * 8_000

        XCTAssertGreaterThanOrEqual(mapRect.width, minimumSpan)
        XCTAssertGreaterThanOrEqual(mapRect.height, minimumSpan)
    }

    @MainActor func testSelectionsRemainMutuallyExclusive() {
        let state = AppState()

        state.selectSignal("signal")
        XCTAssertEqual(state.selectedSignalID, "signal")
        XCTAssertNil(state.selectedIncidentID)
        XCTAssertNil(state.selectedCameraID)

        state.selectIncident("incident")
        XCTAssertEqual(state.selectedIncidentID, "incident")
        XCTAssertNil(state.selectedSignalID)
        XCTAssertNil(state.selectedCameraID)

        state.selectCamera("camera")
        XCTAssertEqual(state.selectedCameraID, "camera")
        XCTAssertNil(state.selectedSignalID)
        XCTAssertNil(state.selectedIncidentID)

        state.clearSelection()
        XCTAssertNil(state.selectedCameraID)
        XCTAssertNil(state.selectedSignalID)
        XCTAssertNil(state.selectedIncidentID)
    }

    private func incident(id: String, acres: Double) -> IncidentFeature {
        IncidentFeature(properties: .init(incidentName: "Test", incidentSize: acres, percentContained: 10, fireDiscoveryDateTime: nil, incidentTypeCategory: "WF", pooCounty: "Ventura", pooCity: nil, pooState: "US-CA", modifiedOnDateTime: nil, totalIncidentPersonnel: nil, fireCause: nil, irwinID: id), geometry: .init(coordinates: [-119.2290, 34.3705]))
    }

}
