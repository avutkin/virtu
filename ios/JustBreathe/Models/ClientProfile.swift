import Foundation

// MARK: - ClientProfile

/// Profile collected during first-launch onboarding. Stored locally as JSON in
/// UserDefaults (not SwiftData) so it never touches the model schema — the app
/// deletes its SwiftData store on schema mismatch, which would risk HRV data.
struct ClientProfile: Codable, Equatable {
    var phone:     String   = ""
    var email:     String   = ""
    var ageRange:  String?  = nil
    var gender:    String?  = nil
    var goals:     [String] = []
    var practices: [String] = []
    var devices:   [String] = []
}

// MARK: - Validation helpers

enum OnboardingValidation {
    /// Light phone check: at least 7 digits after stripping non-digits.
    static func isValidPhone(_ raw: String) -> Bool {
        raw.filter(\.isNumber).count >= 7
    }

    /// Basic email shape check — good enough to gate a Continue button.
    static func isValidEmail(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        return trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - ClientProfileStore

/// Loads/saves the ClientProfile as JSON under a single UserDefaults key.
struct ClientProfileStore {
    static let key = "clientProfile"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ClientProfile {
        guard let data = defaults.data(forKey: Self.key),
              let profile = try? JSONDecoder().decode(ClientProfile.self, from: data)
        else { return ClientProfile() }
        return profile
    }

    func save(_ profile: ClientProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
