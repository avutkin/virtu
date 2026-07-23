import Foundation

/// Overall "practice impact" scoring, a improved/held/dipped breakdown, and
/// rule-based recommendations — all derived from each metric's benefit-signed
/// uplift (during vs before) and its comparison to the 2-month baseline.
/// Pure and unit-tested; views consume it.
enum ActivityImpact {

    /// 0–100 overall impact. Each metric's benefit-signed uplift % is squashed
    /// to a 0–1 "goodness" with a neutral 0.5 midpoint (no change), saturating
    /// at ±fullMarks, then averaged. `nil` when no metric has a value.
    static func score(uplifts: [Double], fullMarks: Double = 18) -> Int? {
        guard !uplifts.isEmpty, fullMarks > 0 else { return nil }
        let gs = uplifts.map { min(max(0.5 + $0 / (2 * fullMarks), 0), 1) }
        let mean = gs.reduce(0, +) / Double(gs.count)
        return Int((mean * 100).rounded())
    }

    /// Counts of improved / held / dipped, with a small dead-zone (in percent)
    /// around zero that counts as "held".
    static func breakdown(uplifts: [Double], deadZone: Double = 2)
        -> (improved: Int, held: Int, dipped: Int) {
        var up = 0, hold = 0, down = 0
        for u in uplifts {
            if u > deadZone { up += 1 }
            else if u < -deadZone { down += 1 }
            else { hold += 1 }
        }
        return (up, hold, down)
    }
}

/// One metric's session movement, used to build recommendations.
struct MetricMovement {
    let name:   String   // consumer label, e.g. "Conscious Breathing"
    let uplift: Double?  // benefit-signed % during vs before
    let vs2mo:  Double?  // benefit-signed % during vs 2-month baseline
}

struct ActivityRecommendation: Identifiable {
    enum Kind { case keep, watch, trend }
    let id = UUID()
    let kind: Kind
    let text: String
}

extension ActivityImpact {

    /// Factual, deterministic recommendations from the session's movements.
    static func recommendations(_ moves: [MetricMovement]) -> [ActivityRecommendation] {
        var recs: [ActivityRecommendation] = []

        // Keep — the strongest improvers this session.
        let improved = moves
            .compactMap { m -> (String, Double)? in
                guard let u = m.uplift, u > 5 else { return nil }
                return (m.name, u)
            }
            .sorted { $0.1 > $1.1 }
        if let top = improved.first {
            let names = improved.count >= 2
                ? "\(top.0) (+\(pct(top.1))) and \(improved[1].0) (+\(pct(improved[1].1)))"
                : "\(top.0) (+\(pct(top.1)))"
            recs.append(.init(kind: .keep,
                text: "Best gains came from \(names). This session worked — keep the same approach."))
        }

        // Watch — the biggest drop, else the furthest below the 2-month norm.
        let dipped = moves
            .compactMap { m -> (String, Double)? in
                guard let u = m.uplift, u < -3 else { return nil }
                return (m.name, u)
            }
            .sorted { $0.1 < $1.1 }
        let belowNorm = moves
            .compactMap { m -> (String, Double)? in
                guard let v = m.vs2mo, v < -10 else { return nil }
                return (m.name, v)
            }
            .sorted { $0.1 < $1.1 }
        if let d = dipped.first {
            recs.append(.init(kind: .watch,
                text: "\(d.0) slipped \(pct(d.1)) this session — worth watching next time."))
        } else if let b = belowNorm.first {
            recs.append(.init(kind: .watch,
                text: "\(b.0) sat \(pct(b.1)) below your 2-month norm — a little off your usual."))
        }

        // Trend — how many beat the 2-month baseline.
        let compared = moves.filter { $0.vs2mo != nil }.count
        if compared > 0 {
            let beat = moves.filter { ($0.vs2mo ?? 0) > 0 }.count
            recs.append(.init(kind: .trend,
                text: "You beat your 2-month average on \(beat) of \(compared) metrics."))
        }

        return recs
    }

    /// Signed, whole-number percent for copy, e.g. 12.3 → "12%", -7.8 → "-8%".
    private static func pct(_ v: Double) -> String {
        String(format: "%.0f%%", v)
    }
}
