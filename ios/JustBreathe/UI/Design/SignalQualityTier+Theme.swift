import SwiftUI

/// UI presentation mapping for `SignalQualityTier` (defined in
/// `Metrics/ECGQualityCompute.swift`, which stays UI-framework-free like
/// every other file in that directory). Shared by every surface that
/// renders this tier — the BLE nav pill dot, the BLE connection sheet's
/// signal quality card.
extension SignalQualityTier {
    var color: Color {
        switch self {
        case .good: return Theme.accent
        case .okay: return Theme.rsa
        case .poor: return Theme.warn
        }
    }

    var label: String {
        switch self {
        case .good: return "GOOD"
        case .okay: return "OKAY"
        case .poor: return "POOR"
        }
    }
}
