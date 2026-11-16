// v6.13.0
import XCTest
@testable import AstroTriage

/// AstroBin acquisition CSV (6.13.0): header line, no spaces around commas, numeric filter
/// IDs, one line per night x filter x sub length, light frames only.
final class AstroBinCSVTests: XCTestCase {

    private func frame(_ name: String, target: String? = "M 45", date: String, time: String, filter: String?,
                       exposure: Double?, type: String? = "LIGHT", gain: Int? = 100, binning: String? = "1x1",
                       sensorTemp: Double? = -10, ambient: Double? = nil, bortle: Double? = nil,
                       fwhmPx: Double? = nil) -> ImageEntry {
        var e = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(name).fits"))
        e.target = target; e.date = date; e.time = time; e.filter = filter; e.exposure = exposure
        e.frameType = type; e.gain = gain; e.binning = binning; e.sensorTemp = sensorTemp
        e.ambientTemp = ambient; e.bortleClass = bortle; e.computedFWHM = fwhmPx
        return e
    }

    func testOneLinePerNightFilterAndSubLength() {
        let images = [
            frame("a", date: "2026-11-04", time: "22:10:00", filter: "L", exposure: 180),
            frame("b", date: "2026-11-05", time: "01:30:00", filter: "L", exposure: 180),   // after midnight → same night
            frame("c", date: "2026-11-04", time: "23:00:00", filter: "Ha", exposure: 300),
            frame("d", date: "2026-11-05", time: "22:00:00", filter: "L", exposure: 180),   // next night
            frame("f", date: "2026-11-04", time: "20:00:00", filter: "L", exposure: 5, type: "FLAT"),
            frame("g", date: "2026-11-04", time: "20:00:00", filter: "L", exposure: nil),
        ]
        let groups = AstroBinCSV.groups(from: images)
        XCTAssertEqual(groups.map(\.number), [2, 1, 1], "flats and frames without exposure must not count")

        let csv = AstroBinCSV.csv(groups: groups, object: "M 45", filterIDs: ["L": "4321", "HA": " 77 "])
        XCTAssertEqual(csv, """
        date,filter,number,duration,binning,gain,sensorCooling
        2026-11-04,4321,2,180,1,100,-10
        2026-11-04,77,1,300,1,100,-10
        2026-11-05,4321,1,180,1,100,-10
        """)
        XCTAssertFalse(csv.contains(", "), "AstroBin: no spaces around commas")
    }

    func testFilterWithoutIDLeavesTheCellEmptyAndNamesAreNeverWritten() {
        let groups = AstroBinCSV.groups(from: [
            frame("a", date: "2026-11-04", time: "22:10:00", filter: "Lextr", exposure: 60.5,
                  gain: nil, binning: nil, sensorTemp: nil),
        ])
        let csv = AstroBinCSV.csv(groups: groups, object: nil, filterIDs: ["LEXTR": "abc"])
        XCTAssertEqual(csv, "date,filter,number,duration\n2026-11-04,,1,60.5")
        XCTAssertEqual(AstroBinCSV.filterNames(in: groups, object: nil), ["Lextr"])
    }

    func testOptionalColumnsAndObjectSelection() {
        var a = frame("a", date: "2026-11-04", time: "22:10:00", filter: "L", exposure: 180,
                      ambient: 4.456, bortle: 4.4, fwhmPx: 5.0)
        a.focalLength = 1964; a.pixelSizeMicrons = 3.76          // 0.3949 "/px → 1.97"
        let b = frame("b", target: "NGC 6888", date: "2026-11-04", time: "23:10:00", filter: "L", exposure: 180)
        let groups = AstroBinCSV.groups(from: [a, b])

        let m45 = AstroBinCSV.csv(groups: groups, object: "M 45", filterIDs: [:])
        XCTAssertEqual(m45, """
        date,filter,number,duration,binning,gain,sensorCooling,bortle,meanFwhm,temperature
        2026-11-04,,1,180,1,100,-10,4,1.97,4.46
        """)
        let other = AstroBinCSV.csv(groups: groups, object: "NGC 6888", filterIDs: [:])
        XCTAssertEqual(other, "date,filter,number,duration,binning,gain,sensorCooling\n2026-11-04,,1,180,1,100,-10")
        XCTAssertEqual(AstroBinCSV.csv(groups: groups, object: "M 1", filterIDs: [:]), "")
    }

    func testHelpers() {
        XCTAssertEqual(AstroBinCSV.binningFactor("2x2"), 2)
        XCTAssertNil(AstroBinCSV.binningFactor("8x8"))
        XCTAssertEqual(AstroBinCSV.decimal(0.00012, places: 4), "0.0001")
        XCTAssertEqual(AstroBinCSV.decimal(300, places: 4), "300")
        XCTAssertEqual(AstroBinCSV.decimal(-0.001, places: 2), "0", "no negative zero")
        // Sub lengths that print the same are one line.
        let merged = AstroBinCSV.groups(from: [
            frame("a", date: "2026-11-04", time: "22:10:00", filter: "L", exposure: 300),
            frame("b", date: "2026-11-04", time: "22:20:00", filter: "L", exposure: 299.99999),
        ])
        XCTAssertEqual(merged.map(\.number), [2])
        XCTAssertNil(AstroBinCSV.validFilterID("12a"))
        XCTAssertNil(AstroBinCSV.validFilterID("0"))
        XCTAssertEqual(AstroBinCSV.validFilterID(" 0042 "), "42")
    }
}
