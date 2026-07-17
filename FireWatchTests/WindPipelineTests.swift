import XCTest
@testable import FireWatch

// Ports of the finn-watchduty wind pipeline tests:
//   app/lib/pipeline/__tests__/airmass.test.ts
//   app/lib/pipeline/__tests__/heightNormalize.test.ts
//   app/lib/pipeline/__tests__/smoke.test.ts
// Values and assertions are kept identical so the Swift port stays verifiably
// faithful to the web implementation.

final class WindPipelineTests: XCTestCase {

    // MARK: - Air-mass rule (airmass.test.ts)

    func testClassifyAirMassSplitsOnInversionBaseUnknownWhenDataMissing() {
        XCTAssertEqual(classifyAirMass(elevationM: 50, inversionBaseM: 400), .below)
        XCTAssertEqual(classifyAirMass(elevationM: 800, inversionBaseM: 400), .above)
        XCTAssertEqual(classifyAirMass(elevationM: nil, inversionBaseM: 400), .unknown)
        XCTAssertEqual(classifyAirMass(elevationM: 800, inversionBaseM: nil), .unknown)
    }

    func testAirMassRuleForbidsOnlyStrictBelowVsAbovePairings() {
        XCTAssertFalse(canCorrect(obs: .below, cell: .above))
        XCTAssertFalse(canCorrect(obs: .above, cell: .below))
        XCTAssertTrue(canCorrect(obs: .below, cell: .below))
        XCTAssertTrue(canCorrect(obs: .above, cell: .above))
        // Unknown is permissive: no evidence of a boundary to respect.
        XCTAssertTrue(canCorrect(obs: .unknown, cell: .above))
        XCTAssertTrue(canCorrect(obs: .below, cell: .unknown))
    }

    /// A plateau terrain at 800 m everywhere: any cell is "above" a 400 m inversion.
    private var terrain800: TerrainGrid {
        TerrainGrid(lons: [-119.2, -118.3], lats: [33.88, 34.34], z: [800, 800, 800, 800])
    }

    private let inversion400: InversionModel = { _, _ in 400 }

    /// A coastal station sitting in marine-layer fog: low elevation, light wind.
    private func foggyStation() -> WindObservation {
        let s = WindObservation(
            id: "FOG", name: "Coastal fog", lon: -118.6, lat: 34.1,
            speedKmh: 2, dirDeg: 270, ageMin: 0, network: "Mesonet",
            elevationM: 50, speed10Kmh: 2, analysisWeight: 1
        )
        return tagStation(s, inversion: inversion400)
    }

    /// Isolate the air-mass rule from vertical decorrelation by making the
    /// vertical length effectively infinite; only the rule should block the
    /// cross-boundary obs.
    private func isolatedConfig() -> WindPipelineConfig {
        var cfg = WindPipelineConfig.standard
        cfg.analysis.decorrelationKm = 100
        cfg.analysis.decorrelationVerticalM = 1e12
        cfg.analysis.backgroundError = 0.5
        return cfg
    }

    private let steadyBackground: WindSampler = { _, _ in WindVec(u: 10, v: 0) }

    func testBelowInversionFoggyObsDoesNotAlterAboveInversionCell() {
        let fog = foggyStation()
        XCTAssertEqual(fog.airMass, .below)

        let proj = makeProjector(lon0: -118.7, lat0: 34.1)
        let withRule = analyzeField(
            background: steadyBackground, stations: [fog], proj: proj,
            cfg: isolatedConfig(), terrain: terrain800, inversion: inversion400
        )
        // The cell at the foggy station's location represents 800 m terrain
        // (above). The rule must block the below-inversion obs, leaving the
        // background intact.
        let c = withRule.corrected(fog.lon, fog.lat)
        XCTAssertEqual(c.u, 10, accuracy: 1e-6,
                       "above-inversion cell should keep the background (10), got \(c.u)")

        // Control: with no inversion model the same obs DOES drag the cell
        // down, confirming the test would fail without the rule.
        let noRule = analyzeField(
            background: steadyBackground, stations: [fog], proj: proj,
            cfg: isolatedConfig(), terrain: terrain800, inversion: nil
        )
        let c2 = noRule.corrected(fog.lon, fog.lat)
        XCTAssertLessThan(c2.u, 6,
                          "without the rule the foggy obs should drag the cell well below 10, got \(c2.u)")
    }

    func testAboveInversionObsDoesCorrectAboveInversionCell() {
        let ridge = tagStation(
            WindObservation(
                id: "RDG", name: "Ridge", lon: -118.6, lat: 34.1,
                speedKmh: 2, dirDeg: 270, ageMin: 0, network: "RAWS",
                elevationM: 800, speed10Kmh: 2, analysisWeight: 1
            ),
            inversion: inversion400
        )
        XCTAssertEqual(ridge.airMass, .above)

        let proj = makeProjector(lon0: -118.7, lat0: 34.1)
        let out = analyzeField(
            background: steadyBackground, stations: [ridge], proj: proj,
            cfg: isolatedConfig(), terrain: terrain800, inversion: inversion400
        )
        let c = out.corrected(ridge.lon, ridge.lat)
        XCTAssertLessThan(c.u, 6, "same-air-mass obs should correct the cell, got \(c.u)")
    }

    func testConfidenceIsLowerNearInversionBaseThanFarAboveIt() {
        let ridge = tagStation(
            WindObservation(
                id: "RDG", name: "Ridge", lon: -118.6, lat: 34.1,
                speedKmh: 12, dirDeg: 270, ageMin: 0, network: "RAWS",
                elevationM: 800, speed10Kmh: 12, analysisWeight: 1
            ),
            inversion: inversion400
        )
        // Two plateaus: one right at the inversion (400 m), one well above (1200 m).
        let nearInv = TerrainGrid(lons: terrain800.lons, lats: terrain800.lats, z: [400, 400, 400, 400])
        let wellAbove = TerrainGrid(lons: terrain800.lons, lats: terrain800.lats, z: [1200, 1200, 1200, 1200])
        let cfg = isolatedConfig()
        let proj = makeProjector(lon0: -118.7, lat0: 34.1)
        let near = analyzeField(
            background: steadyBackground, stations: [ridge], proj: proj,
            cfg: cfg, terrain: nearInv, inversion: inversion400
        )
        let far = analyzeField(
            background: steadyBackground, stations: [ridge], proj: proj,
            cfg: cfg, terrain: wellAbove, inversion: inversion400
        )
        XCTAssertLessThan(
            near.confidence(-118.6, 34.1), far.confidence(-118.6, 34.1),
            "confidence should be suppressed near the inversion boundary"
        )
    }

    // MARK: - Height normalization (heightNormalize.test.ts)

    func testFactorIsExactlyOneAtReferenceHeightRegardlessOfZ0() {
        XCTAssertEqual(logProfileFactor(measHeightM: referenceHeightM, z0M: 0.1), 1, accuracy: 1e-9)
        XCTAssertEqual(logProfileFactor(measHeightM: referenceHeightM, z0M: 0.03), 1, accuracy: 1e-9)
    }

    func testRAWSOverOpenShrublandMatchesHandComputation() {
        // u_10 = u_meas * ln(10/z0) / ln(z_meas/z0)
        let expected = log(10 / 0.1) / log(6.1 / 0.1) // ~1.12023
        XCTAssertEqual(logProfileFactor(measHeightM: 6.1, z0M: 0.1), expected, accuracy: 1e-9)
        XCTAssertEqual(normalizeSpeed(20, measHeightM: 6.1, z0M: 0.1), 20 * expected, accuracy: 1e-9)
        // Normalizing a below-10 m anemometer scales the speed up.
        XCTAssertGreaterThan(logProfileFactor(measHeightM: 6.1, z0M: 0.1), 1)
    }

    func testTallTowerAboveTenMetresScalesTheSpeedDown() {
        let expected = log(10 / 0.1) / log(30 / 0.1)
        XCTAssertEqual(logProfileFactor(measHeightM: 30, z0M: 0.1), expected, accuracy: 1e-9)
        XCTAssertLessThan(logProfileFactor(measHeightM: 30, z0M: 0.1), 1)
    }

    func testRougherTerrainPullsAReadingFurtherFromTenMetres() {
        let open = logProfileFactor(measHeightM: 6.1, z0M: 0.03)
        let rough = logProfileFactor(measHeightM: 6.1, z0M: 0.4)
        XCTAssertGreaterThan(rough, open, "rougher site needs a larger up-correction")
    }

    func testDegenerateInputsAreGuarded() {
        XCTAssertEqual(logProfileFactor(measHeightM: 0.05, z0M: 0.1), 1, accuracy: 1e-9) // z_meas <= z0
        XCTAssertEqual(logProfileFactor(measHeightM: 0, z0M: 0.1), 1, accuracy: 1e-9)
        XCTAssertEqual(logProfileFactor(measHeightM: 6.1, z0M: 0), 1, accuracy: 1e-9)
    }

    func testMeasurementHeightPrefersPerStationHeightThenNetworkDefault() {
        let base = WindObservation(
            id: "X", name: "X", lon: 0, lat: 0, speedKmh: 10, dirDeg: 0, network: "RAWS"
        )
        // No explicit height: RAWS default 6.1 m.
        XCTAssertEqual(measurementHeight(base, kind: .raws, cfg: .standard), 6.1)
        // Explicit tower height wins (utility station with metadata).
        var tall = base
        tall.measHeightM = 24
        XCTAssertEqual(measurementHeight(tall, kind: .utility, cfg: .standard), 24)
    }

    func testNormalizeStationRecordsHeightAndRoughnessAndScalesGustToo() {
        let s = WindObservation(
            id: "TPGC1", name: "Topanga", lon: -118.6, lat: 34.1,
            speedKmh: 18, dirDeg: 250, gustKmh: 30, tempC: 15,
            ageMin: 10, network: "RAWS"
        )
        let out = normalizeStation(s, z0M: 0.1, cfg: .standard)
        let f = log(10 / 0.1) / log(6.1 / 0.1)
        XCTAssertEqual(out.measHeightM, 6.1)
        XCTAssertEqual(out.roughnessZ0, 0.1)
        XCTAssertEqual(out.speed10Kmh ?? .nan, 18 * f, accuracy: 1e-9)
        XCTAssertEqual(out.gust10Kmh ?? .nan, 30 * f, accuracy: 1e-9)
        // Direction is untouched by height normalization.
        XCTAssertEqual(out.dirDeg, 250)
    }

    // MARK: - End-to-end smoke (smoke.test.ts)

    private let smokeCenter = (lon: -118.7, lat: 34.1)
    private let smokeInversion: InversionModel = { _, _ in 500 }

    /// A moderate terrain plateau below the inversion: cells are "below".
    private var smokeTerrain: TerrainGrid {
        TerrainGrid(
            lons: [-119.2, -118.75, -118.3],
            lats: [33.88, 34.11, 34.34],
            z: [350, 350, 350, 360, 360, 360, 350, 350, 350]
        )
    }

    /// A steady background flow (stands in for the model grid sampler).
    private let smokeBackground: WindSampler = { _, _ in WindVec(u: 12, v: 3) }

    private func rawStations() -> [WindObservation] {
        func mk(
            _ id: String, _ lon: Double, _ lat: Double,
            _ speedKmh: Double, _ network: String, _ elevationM: Double
        ) -> WindObservation {
            WindObservation(
                id: id, name: id, lon: lon, lat: lat,
                speedKmh: speedKmh, dirDeg: 250, gustKmh: speedKmh * 1.4,
                tempC: 16, ageMin: 10, network: network, elevationM: elevationM
            )
        }
        // A small cluster of consistent obs near the centre, one isolated obs,
        // and one above-inversion obs (kept out of below cells by the rule).
        return [
            mk("R1", -118.62, 34.10, 18, "RAWS", 300),
            mk("R2", -118.66, 34.12, 21, "RAWS", 320),
            mk("A1", -118.60, 34.08, 16, "Airport ASOS/AWOS", 280),
            mk("C1", -118.64, 34.09, 20, "CWOP/personal", 300),
            mk("FAR", -119.10, 33.92, 19, "Mesonet", 300),
            mk("HIGH", -118.63, 34.11, 12, "RAWS", 900),
        ]
    }

    func testPipelineProducesFiniteCorrectedFieldAndValidConfidenceLayer() {
        let proj = makeProjector(lon0: smokeCenter.lon, lat0: smokeCenter.lat)
        let quietQC = QCContext(log: { _ in })
        let enriched = enrichObservations(
            rawStations(), cfg: .standard,
            opts: EnrichOptions(terrain: smokeTerrain, inversion: smokeInversion, qc: quietQC)
        )

        // Every survivor is height-normalized, time-weighted, and air-mass tagged.
        XCTAssertGreaterThanOrEqual(enriched.stations.count, 4,
                                    "most obs should survive QC and the window")
        for s in enriched.stations {
            XCTAssertNotNil(s.speed10Kmh)
            XCTAssertTrue(s.speed10Kmh?.isFinite ?? false)
            XCTAssertNotNil(s.airMass)
            XCTAssertNotNil(s.analysisWeight)
        }

        let analysis = analyzeField(
            background: smokeBackground, stations: enriched.stations, proj: proj,
            cfg: .standard, terrain: smokeTerrain, inversion: smokeInversion
        )

        // Corrected field is finite everywhere we sample it.
        for (lon, lat) in [smokeCenter, (-118.62, 34.1), (-119.0, 33.95)] {
            let v = analysis.corrected(lon, lat)
            XCTAssertTrue(v.u.isFinite && v.v.isFinite, "field finite at \(lon),\(lat)")
        }

        // Confidence layer: co-registered grid, all values in [0,1].
        let grid = buildConfidenceGrid(
            confidence: analysis.confidence,
            lons: smokeTerrain.lons, lats: smokeTerrain.lats
        )
        XCTAssertEqual(grid.c.count, smokeTerrain.lons.count * smokeTerrain.lats.count)
        for c in grid.c {
            XCTAssertTrue(c >= 0 && c <= 1, "confidence \(c) out of range")
        }

        // Confidence is higher inside the obs cluster than in the empty far corner.
        let near = analysis.confidence(-118.63, 34.105)
        let far = analysis.confidence(-119.18, 33.89)
        XCTAssertGreaterThan(near, far,
                             "cluster confidence \(near) should exceed corner \(far)")
    }

    func testCorrectedFieldBendsTowardObsInsideCluster() {
        let proj = makeProjector(lon0: smokeCenter.lon, lat0: smokeCenter.lat)
        let quietQC = QCContext(log: { _ in })
        let enriched = enrichObservations(
            rawStations(), cfg: .standard,
            opts: EnrichOptions(terrain: smokeTerrain, inversion: smokeInversion, qc: quietQC)
        )
        let analysis = analyzeField(
            background: smokeBackground, stations: enriched.stations, proj: proj,
            cfg: .standard, terrain: smokeTerrain, inversion: smokeInversion
        )
        // Cluster obs are stronger than the 12.4 km/h background magnitude, so
        // the corrected speed in the cluster should exceed the background there.
        let bgSpeed = hypot(12.0, 3.0)
        let c = analysis.corrected(-118.63, 34.105)
        XCTAssertGreaterThan(
            hypot(c.u, c.v), bgSpeed,
            "corrected wind in the cluster should rise toward the (stronger) obs"
        )
    }
}
