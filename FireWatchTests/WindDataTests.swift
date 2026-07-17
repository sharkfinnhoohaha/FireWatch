import XCTest
@testable import FireWatch

// Tests for the wind data layer: Synoptic payload parsing, spatial decimation,
// NWS unit handling, and the baked-field construction the renderer consumes.

final class WindDataTests: XCTestCase {

    // MARK: - Synoptic parsing

    private let synopticFixture = """
    {
      "STATION": [
        {
          "STID": "TPGC1",
          "NAME": "TOPANGA",
          "ELEVATION": "2100",
          "LONGITUDE": "-118.599",
          "LATITUDE": "34.084",
          "MNET_ID": "2",
          "OBSERVATIONS": {
            "wind_speed_value_1": { "value": 18.5, "date_time": "2026-07-15T21:50:00Z" },
            "wind_direction_value_1": { "value": 250 },
            "wind_gust_value_1": { "value": 30.2 },
            "air_temp_value_1": { "value": 24.5 }
          }
        },
        {
          "STID": "STALE1",
          "NAME": "Stale personal station",
          "ELEVATION": 500,
          "LONGITUDE": -118.7,
          "LATITUDE": 34.2,
          "MNET_ID": "65",
          "OBSERVATIONS": {
            "wind_speed_value_1": { "value": 5, "date_time": "2026-07-15T14:00:00Z" }
          }
        },
        {
          "STID": "NOWIND",
          "NAME": "No wind sensor",
          "LONGITUDE": "-118.8",
          "LATITUDE": "34.3",
          "MNET_ID": "65",
          "OBSERVATIONS": {}
        }
      ]
    }
    """

    func testSynopticParsingReadsStringsNumbersAndGatesStaleVanes() throws {
        // "Now" is 22:00Z: TPGC1 is 10 minutes old (kept); STALE1 is 8 hours old
        // (dropped by the max-age gate); NOWIND has no wind sensor (dropped).
        let now = ISO8601DateFormatter().date(from: "2026-07-15T22:00:00Z")!
        let parsed = try WindDataService.parseSynopticStations(
            data: Data(synopticFixture.utf8), now: now
        )
        XCTAssertEqual(parsed.count, 1)
        let vane = try XCTUnwrap(parsed.first)
        XCTAssertEqual(vane.id, "TPGC1")
        XCTAssertEqual(vane.network, "RAWS") // MNET_ID 2
        XCTAssertEqual(vane.lon, -118.599, accuracy: 1e-9) // string coordinate
        XCTAssertEqual(vane.speedKmh, 18.5, accuracy: 1e-9)
        XCTAssertEqual(vane.dirDeg ?? .nan, 250, accuracy: 1e-9)
        XCTAssertEqual(vane.gustKmh ?? .nan, 30.2, accuracy: 1e-9)
        XCTAssertEqual(vane.ageMin, 10, accuracy: 0.5)
        // Synoptic ELEVATION is feet: 2100 ft = 640.08 m.
        XCTAssertEqual(vane.elevationM ?? .nan, 2_100 * 0.3048, accuracy: 1e-6)
    }

    func testSynopticParsingSortsRAWSAheadOfOtherNetworks() throws {
        let json = """
        { "STATION": [
          { "STID": "P1", "NAME": "Personal", "LONGITUDE": -118.5, "LATITUDE": 34.1, "MNET_ID": "65",
            "OBSERVATIONS": { "wind_speed_value_1": { "value": 4, "date_time": "2026-07-15T21:59:00Z" } } },
          { "STID": "R1", "NAME": "Raws", "LONGITUDE": -118.6, "LATITUDE": 34.2, "MNET_ID": "2",
            "OBSERVATIONS": { "wind_speed_value_1": { "value": 9, "date_time": "2026-07-15T21:59:00Z" } } }
        ] }
        """
        let now = ISO8601DateFormatter().date(from: "2026-07-15T22:00:00Z")!
        let parsed = try WindDataService.parseSynopticStations(data: Data(json.utf8), now: now)
        XCTAssertEqual(parsed.map(\.id), ["R1", "P1"], "RAWS should win the decimation tiebreak")
    }

    // MARK: - Decimation

    private func obs(_ id: String, lon: Double, lat: Double, network: String = "RAWS") -> WindObservation {
        WindObservation(id: id, name: id, lon: lon, lat: lat, speedKmh: 10, network: network)
    }

    func testDecimationEnforcesSpacingAndCap() {
        // B sits ~1 km east of A (dropped at 5 km spacing); C sits ~20 km away (kept).
        let a = obs("A", lon: -118.60, lat: 34.10)
        let b = obs("B", lon: -118.59, lat: 34.10, network: "CWOP/personal")
        let c = obs("C", lon: -118.38, lat: 34.10)
        XCTAssertEqual(
            WindDataService.decimate([a, b, c], minKm: 5, cap: 10, centerLat: 34.1).map(\.id),
            ["A", "C"]
        )
        XCTAssertEqual(
            WindDataService.decimate([a, b, c], minKm: 5, cap: 1, centerLat: 34.1).map(\.id),
            ["A"]
        )
    }

    // MARK: - NWS unit handling

    func testNWSUnitConversions() {
        XCTAssertEqual(WindDataService.speedToKmh(10, unitCode: "wmoUnit:m_s-1") ?? .nan, 36, accuracy: 1e-9)
        XCTAssertEqual(WindDataService.speedToKmh(10, unitCode: "unit:mph") ?? .nan, 16.09344, accuracy: 1e-9)
        XCTAssertEqual(WindDataService.speedToKmh(10, unitCode: "wmoUnit:kt") ?? .nan, 18.52, accuracy: 1e-9)
        XCTAssertEqual(WindDataService.speedToKmh(10, unitCode: "wmoUnit:km_h-1") ?? .nan, 10, accuracy: 1e-9)
        XCTAssertNil(WindDataService.speedToKmh(nil, unitCode: "wmoUnit:km_h-1"))
        XCTAssertEqual(WindDataService.tempToC(50, unitCode: "wmoUnit:degF") ?? .nan, 10, accuracy: 1e-9)
        XCTAssertEqual(WindDataService.tempToC(300.15, unitCode: "wmoUnit:K") ?? .nan, 27, accuracy: 1e-9)
    }

    func testNWSNetworkClassification() {
        XCTAssertEqual(WindDataService.nwsNetwork("KLAX"), "Airport ASOS/AWOS")
        XCTAssertEqual(WindDataService.nwsNetwork("TPGC1"), "RAWS")
        XCTAssertEqual(WindDataService.nwsNetwork("SV"), "Mesonet")
    }

    // MARK: - Baked field

    private func makeFieldData(withModel: Bool) -> WindFieldData {
        let region = WindRegion.socal
        // A uniform 2×2 background: 10 km/h eastward everywhere.
        let model = withModel ? ModelWindGrid(
            lons: [region.bbox.west, region.bbox.east],
            lats: [region.bbox.south, region.bbox.north],
            u: [10, 10, 10, 10],
            v: [0, 0, 0, 0]
        ) : nil
        // One vane near the region centre reporting 25 km/h from due north.
        let vane = WindObservation(
            id: "R1", name: "R1",
            lon: region.centerLon, lat: region.centerLat,
            speedKmh: 25, dirDeg: 0, ageMin: 5, network: "RAWS",
            elevationM: 300, speed10Kmh: 25, airMass: .below, analysisWeight: 1
        )
        return WindFieldData(
            generatedAt: .now,
            region: region,
            stations: [vane],
            rejected: [],
            outsideWindow: 0,
            model: model,
            terrain: nil,
            inversionBaseM: 500,
            obsSource: "TEST",
            warnings: []
        )
    }

    func testBakeProducesFiniteGridsAndModeSpecs() {
        let baked = makeFieldData(withModel: true).bake(influenceKm: 50)
        XCTAssertTrue(baked.modelAvailable)
        XCTAssertEqual(baked.corrected.u.count, baked.corrected.lons.count * baked.corrected.lats.count)
        XCTAssertTrue(baked.corrected.u.allSatisfy(\.isFinite))
        XCTAssertTrue(baked.confidence.c.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(baked.sharedMaxKmh, 0)

        // Model mode samples the raw background: 10 km/h eastward.
        let model = baked.fieldSpec(mode: .model)
        let m = model.sampler(WindRegion.socal.centerLon, WindRegion.socal.centerLat)
        XCTAssertEqual(m.u, 10, accuracy: 1e-6)
        XCTAssertEqual(m.v, 0, accuracy: 1e-6)
        XCTAssertNil(model.colorScalar)

        // Corrected mode bends toward the (stronger, southward) vane near it.
        let corrected = baked.fieldSpec(mode: .corrected)
        let c = corrected.sampler(WindRegion.socal.centerLon, WindRegion.socal.centerLat)
        XCTAssertLessThan(c.v, -1, "north wind (from 0°) should push flow southward near the vane")

        // Disagreement mode colours by the corrected − model gap.
        let disagreement = baked.fieldSpec(mode: .disagreement)
        let scalar = try? XCTUnwrap(disagreement.colorScalar)
        XCTAssertNotNil(scalar)
        if let scalar {
            let gap = scalar(WindRegion.socal.centerLon, WindRegion.socal.centerLat, c)
            XCTAssertGreaterThan(gap, 1, "gap near the vane should be well above zero")
        }

        // Confidence mode colours in [0,1].
        let confidence = baked.fieldSpec(mode: .confidence)
        if let scalar = confidence.colorScalar {
            let value = scalar(WindRegion.socal.centerLon, WindRegion.socal.centerLat, c)
            XCTAssertTrue(value >= 0 && value <= 1)
        } else {
            XCTFail("confidence mode should provide a colour scalar")
        }
    }

    func testDisagreementFallsBackToCorrectedWithoutModel() {
        let baked = makeFieldData(withModel: false).bake(influenceKm: 50)
        XCTAssertFalse(baked.modelAvailable)
        let spec = baked.fieldSpec(mode: .disagreement)
        XCTAssertNil(spec.colorScalar, "no model means the gap view is meaningless — fall back to corrected")
    }

    func testLegacySnapshotConvertsToMph() {
        let field = makeFieldData(withModel: true)
        let legacy = WindFieldEngine.legacySnapshot(from: field)
        XCTAssertEqual(legacy.samples.count, 4)
        // 10 km/h eastward = 6.21371 mph, direction-from 270°.
        let sample = legacy.samples[0]
        XCTAssertEqual(sample.speedMPH, 6.21371, accuracy: 1e-4)
        XCTAssertEqual(sample.directionDegrees, 270, accuracy: 1e-6)
        let station = try? XCTUnwrap(legacy.stations.first)
        XCTAssertEqual(station?.speedMPH ?? .nan, 25 * 0.621371, accuracy: 1e-4)
    }
}
