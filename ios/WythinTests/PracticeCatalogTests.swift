import XCTest
@testable import Wythin

final class PracticeCatalogTests: XCTestCase {

    // MARK: Subtype invariant

    /// Every practice's subtype must be a real member of its activityType's
    /// subtypes, so logging a practice always produces a valid ActivityLog and
    /// the prefilled logger sheet lands on a selectable subtype.
    func testEveryPracticeSubtypeIsAValidActivitySubtype() {
        for practice in PracticeCatalog.practices {
            guard let subtype = practice.subtype else { continue }
            XCTAssertTrue(
                practice.activityType.subtypes.contains(subtype),
                "\(practice.id): subtype '\(subtype)' is not a member of \(practice.activityType.rawValue).subtypes"
            )
        }
    }

    // MARK: Referential integrity

    func testEveryPracticeReferencesAKnownTeacher() {
        for practice in PracticeCatalog.practices {
            XCTAssertNotNil(
                PracticeCatalog.teacher(practice.teacherID),
                "\(practice.id): unknown teacherID '\(practice.teacherID)'"
            )
        }
    }

    func testPracticeAndTeacherIDsAreUnique() {
        let practiceIDs = PracticeCatalog.practices.map(\.id)
        XCTAssertEqual(practiceIDs.count, Set(practiceIDs).count, "duplicate practice id")
        let teacherIDs = PracticeCatalog.teachers.map(\.id)
        XCTAssertEqual(teacherIDs.count, Set(teacherIDs).count, "duplicate teacher id")
    }

    // MARK: Art

    func testEveryArtHasTwoColourStops() {
        for practice in PracticeCatalog.practices {
            XCTAssertEqual(practice.art.hexStops.count, 2, "\(practice.id): art needs two hex stops")
        }
        for teacher in PracticeCatalog.teachers {
            XCTAssertEqual(teacher.art.hexStops.count, 2, "\(teacher.id): art needs two hex stops")
        }
    }

    // MARK: Starred / featured

    func testExactlyOneStarredResonancePractice() {
        let starred = PracticeCatalog.starred
        XCTAssertEqual(starred.count, 1)
        XCTAssertEqual(starred.first?.id, "resonance")
        XCTAssertEqual(starred.first?.kind, .biofeedback(.resonance))
    }

    // MARK: Lookups

    func testPracticesInCategoryReturnsOnlyThatCategory() {
        for category in PracticeCategory.allCases {
            let inCat = PracticeCatalog.practices(in: category)
            XCTAssertTrue(inCat.allSatisfy { $0.category == category })
        }
    }

    func testPracticesByTeacherReturnsOnlyThatTeacher() {
        for teacher in PracticeCatalog.teachers {
            let byTeacher = PracticeCatalog.practices(byTeacher: teacher.id)
            XCTAssertTrue(byTeacher.allSatisfy { $0.teacherID == teacher.id })
        }
    }

    func testEveryCategoryHasAtLeastOnePractice() {
        for category in PracticeCategory.allCases {
            XCTAssertFalse(PracticeCatalog.practices(in: category).isEmpty,
                           "\(category.rawValue) has no practices")
        }
    }
}
