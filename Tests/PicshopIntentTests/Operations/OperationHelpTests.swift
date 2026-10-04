import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W2 (§8.9): what the help sheet lists.
final class OperationHelpTests: XCTestCase {
    func testSectionsFollowTheCatalogsCategoriesWithTwoSentencesPerOperation() {
        let sections = OperationHelp.sections(domain: .photo, language: .fr)
        XCTAssertFalse(sections.isEmpty)
        XCTAssertEqual(Set(sections.map(\.title)).count, sections.count, "one section per category")
        let specs = OperationCatalog.shared.specs(in: .photo).filter { !OperationGate.disabled().contains($0.id) }
        var expectedOrder: [OpCategory] = []
        for spec in specs where !expectedOrder.contains(spec.category) { expectedOrder.append(spec.category) }
        XCTAssertEqual(sections.map(\.title), expectedOrder.map { OperationHelp.categoryTitle($0, language: .fr) })
        let items = sections.flatMap(\.items)
        for spec in specs {
            let said = items.filter { $0.title == spec.title.fr }
            XCTAssertEqual(said.count, 2, "\(spec.id)")
            for item in said { XCTAssertTrue(spec.examples.contains { $0.say == item.say && $0.role == .positive }, item.say) }
        }
        XCTAssertTrue(sections.contains { $0.title == "Masques et sélection" })
    }

    func testTheLanguageAskedComesFirst() {
        let english = OperationHelp.sections(domain: .photo, language: .en).flatMap(\.items)
        let maskAdjust = english.filter { $0.title == "Mask adjustment" }
        XCTAssertEqual(maskAdjust.count, 2)
        let spec = OperationCatalog.shared.spec("maskAdjust")!
        for item in maskAdjust { XCTAssertEqual(spec.examples.first { $0.say == item.say }?.language, .en, item.say) }
        XCTAssertFalse(OperationHelp.sections(domain: .video, language: .fr).isEmpty)
        XCTAssertFalse(OperationHelp.sections(domain: .pdf, language: .en).isEmpty)
    }
}
