import XCTest
@testable import PicshopCore

final class CropCandidateTests: XCTestCase {
    func testCandidatesKeepTheSubjectWholeAndInside() {
        let subject = PSRect(x: 0.55, y: 0.3, width: 0.2, height: 0.4)
        let crops = CropCandidates.generate(subject: subject, imageAspect: 1.5)
        XCTAssertGreaterThan(crops.count, 5)
        for crop in crops {
            XCTAssertTrue(CropCandidates.contains(crop, subject), "\(crop)")
            XCTAssertGreaterThanOrEqual(crop.minX, -1e-9); XCTAssertLessThanOrEqual(crop.maxX, 1 + 1e-9)
            XCTAssertGreaterThanOrEqual(crop.minY, -1e-9); XCTAssertLessThanOrEqual(crop.maxY, 1 + 1e-9)
        }
    }

    func testShapesAreRight() {
        let crops = CropCandidates.generate(subject: nil, imageAspect: 1.5)
        // A 1:1 crop of a 3:2 picture is two thirds as wide as it is tall, in normalised units.
        XCTAssertTrue(crops.contains { abs(($0.width * 1.5) / $0.height - 1) < 0.01 })
        XCTAssertTrue(crops.contains { abs(($0.width * 1.5) / $0.height - 0.8) < 0.01 })
    }
}
