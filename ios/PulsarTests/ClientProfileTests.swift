import XCTest
@testable import Pulsar

final class ClientProfileTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "ClientProfileTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: "ClientProfileTests")
        return d
    }

    // MARK: Store round-trip

    func testStoreLoadReturnsEmptyProfileWhenNothingSaved() {
        let store = ClientProfileStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), ClientProfile())
    }

    func testStoreSaveThenLoadRoundTrips() {
        let defaults = makeDefaults()
        let store = ClientProfileStore(defaults: defaults)
        var profile = ClientProfile()
        profile.phone = "5551234567"
        profile.email = "a@b.com"
        profile.ageRange = "25–34"
        profile.gender = "Female"
        profile.goals = ["Improve sleep", "Reduce anxiety"]
        profile.practices = ["Breathwork"]
        profile.devices = ["Oura Ring", "Just this app"]

        store.save(profile)
        XCTAssertEqual(ClientProfileStore(defaults: defaults).load(), profile)
    }

    // MARK: Phone validation

    func testPhoneValidation() {
        XCTAssertFalse(OnboardingValidation.isValidPhone(""))
        XCTAssertFalse(OnboardingValidation.isValidPhone("12345"))       // 5 digits
        XCTAssertTrue(OnboardingValidation.isValidPhone("5551234"))       // 7 digits
        XCTAssertTrue(OnboardingValidation.isValidPhone("(555) 123-4567")) // digits ≥ 7 after stripping
    }

    // MARK: Email validation

    func testEmailValidation() {
        XCTAssertFalse(OnboardingValidation.isValidEmail(""))
        XCTAssertFalse(OnboardingValidation.isValidEmail("nope"))
        XCTAssertFalse(OnboardingValidation.isValidEmail("a@b"))
        XCTAssertFalse(OnboardingValidation.isValidEmail("a@b."))
        XCTAssertTrue(OnboardingValidation.isValidEmail("a@b.com"))
        XCTAssertTrue(OnboardingValidation.isValidEmail("First.Last@Example.co.uk"))
    }
}
