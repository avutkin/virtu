import Charts
import SwiftUI

/// A single metric's before/during/after time series for one activity.
/// Not a reuse of MetricsChartsView's MetricChartCard — that view is built
/// around a fixed TimeWindow (30m/2h/24h) anchored to "now" or a full
/// calendar day, which doesn't fit an activity's arbitrary past
/// [start, end] span of variable length. This is a smaller, purpose-built
/// chart for exactly that case.
struct ActivityWindowChart: View {
    let title:     String   // consumer name, e.g. "Harmony"
    let techLabel: String   // e.g. "DFA α1"
    let unit:      String
    let color:     Color    // activityTypeEnum.color — tints the "during" band
    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    let extract:   (MetricsHistoryPoint) -> Double?

    private struct Pt: Identifiable {
        let id:   Int
        let date: Date
        let val:  Double
    }

    private var windowStart: Date { startedAt.addingTimeInterval(-300) }
    private var windowEnd:   Date { endedAt.addingTimeInterval(600) }

    /// Buckets to ~120 points regardless of activity length, same density
    /// target as MetricsChartsView's TimeWindow.bucketSeconds convention.
    private var bucketed: [Pt] {
        let span = windowEnd.timeIntervalSince(windowStart)
        guard span > 0 else { return [] }
        let bucketSeconds = max(span / 120, 1)
        var sums:   [Int: Double] = [:]
        var counts: [Int: Int]    = [:]
        for pt in points {
            guard let v = extract(pt) else { continue }
            let key = Int(pt.timestamp.timeIntervalSince(windowStart) / bucketSeconds)
            sums[key]   = (sums[key]   ?? 0) + v
            counts[key] = (counts[key] ?? 0) + 1
        }
        return sums.keys.sorted().map { key in
            let date = windowStart.addingTimeInterval(Double(key) * bucketSeconds + bucketSeconds / 2)
            return Pt(id: key, date: date, val: sums[key]! / Double(counts[key]!))
        }
    }

    private func average(from start: Date, to end: Date) -> Double? {
        let vals = points.filter { $0.timestamp >= start && $0.timestamp < end }.compactMap(extract)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    private var beforeAvg: Double? { average(from: windowStart, to: startedAt) }
    private var duringAvg: Double? { average(from: startedAt, to: endedAt) }
    private var afterAvg:  Double? { average(from: endedAt, to: windowEnd) }

    /// % difference vs the before-phase average — nil if there's no before
    /// average to compare against, or it's exactly zero.
    private func percentVsBefore(_ avg: Double?) -> Double? {
        guard let avg, let base = beforeAvg, base != 0 else { return nil }
        return (avg - base) / base * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                if !techLabel.isEmpty {
                    Text(techLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }

            let pts = bucketed
            if pts.isEmpty {
                HStack {
                    Spacer()
                    Text("No data")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                }
                .frame(height: 110)
            } else {
                Chart {
                    RectangleMark(
                        xStart: .value("before start", windowStart),
                        xEnd:   .value("before end",   startedAt)
                    )
                    .foregroundStyle(Theme.dim.opacity(0.06))

                    RectangleMark(
                        xStart: .value("during start", startedAt),
                        xEnd:   .value("during end",   endedAt)
                    )
                    .foregroundStyle(color.opacity(0.08))

                    RectangleMark(
                        xStart: .value("after start", endedAt),
                        xEnd:   .value("after end",   windowEnd)
                    )
                    .foregroundStyle(Theme.dim.opacity(0.06))

                    RuleMark(x: .value("start", startedAt))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("START")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }

                    RuleMark(x: .value("end", endedAt))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("END")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }

                    if let avg = beforeAvg {
                        RuleMark(y: .value("before avg", avg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Theme.dim.opacity(0.5))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.1f", avg))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                            }
                    }

                    if let avg = duringAvg {
                        RuleMark(y: .value("during avg", avg))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .foregroundStyle(color.opacity(0.9))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                HStack(spacing: 3) {
                                    if let pct = percentVsBefore(avg) {
                                        Text(String(format: "%+.0f%%", pct))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(color)
                                    }
                                    Text(String(format: "%.1f", avg))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(Theme.dim)
                                }
                            }
                    }

                    if let avg = afterAvg {
                        RuleMark(y: .value("after avg", avg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .foregroundStyle(Theme.dim.opacity(0.5))
                            .annotation(position: .bottom, alignment: .trailing, spacing: 2) {
                                HStack(spacing: 3) {
                                    if let pct = percentVsBefore(avg) {
                                        Text(String(format: "%+.0f%%", pct))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Theme.dim)
                                    }
                                    Text(String(format: "%.1f", avg))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(Theme.dim)
                                }
                            }
                    }

                    ForEach(pts) { pt in
                        LineMark(
                            x: .value("time", pt.date),
                            y: .value(title, pt.val)
                        )
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartXScale(domain: windowStart...windowEnd)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(Theme.border)
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(Theme.border)
                        AxisValueLabel()
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(height: 110)
            }
        }
        .cardStyle()
    }
}
