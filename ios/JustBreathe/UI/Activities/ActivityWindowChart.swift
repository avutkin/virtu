import Charts
import SwiftUI

/// A single metric's before/during/after time series for one activity, with
/// the peak-during point marked and recovery (retention + return-to-baseline)
/// surfaced in the 10-min-after window. Purpose-built for an activity's
/// arbitrary past [start, end] span (not a reuse of MetricsChartsView's
/// day/now-anchored MetricChartCard).
struct ActivityWindowChart: View {
    let def:       ActivityMetricDef
    let color:     Color
    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    let stats:     ActivityMetricStats

    private struct Pt: Identifiable {
        let id:   Int
        let date: Date
        let val:  Double
    }

    private var windowStart: Date { startedAt.addingTimeInterval(-300) }
    private var windowEnd:   Date { endedAt.addingTimeInterval(600) }

    /// Buckets to ~120 points regardless of activity length.
    private var bucketed: [Pt] {
        let span = windowEnd.timeIntervalSince(windowStart)
        guard span > 0 else { return [] }
        let bucketSeconds = max(span / 120, 1)
        var sums:   [Int: Double] = [:]
        var counts: [Int: Int]    = [:]
        for pt in points {
            guard let v = def.extract(pt) else { continue }
            let key = Int(pt.timestamp.timeIntervalSince(windowStart) / bucketSeconds)
            sums[key]   = (sums[key]   ?? 0) + v
            counts[key] = (counts[key] ?? 0) + 1
        }
        return sums.keys.sorted().map { key in
            let date = windowStart.addingTimeInterval(Double(key) * bucketSeconds + bucketSeconds / 2)
            return Pt(id: key, date: date, val: sums[key]! / Double(counts[key]!))
        }
    }

    private func pctText(_ p: Double?) -> String? {
        p.map { String(format: "%+.0f%%", $0) }
    }

    private var returnDate: Date? {
        stats.timeToBaselineSeconds.map { endedAt.addingTimeInterval($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(def.label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                if !def.techLabel.isEmpty {
                    Text(def.techLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                if !def.unit.isEmpty {
                    Text(def.unit)
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
                .frame(height: 120)
            } else {
                Chart {
                    // Phase bands
                    RectangleMark(xStart: .value("bs", windowStart), xEnd: .value("be", startedAt))
                        .foregroundStyle(Theme.dim.opacity(0.06))
                    RectangleMark(xStart: .value("ds", startedAt), xEnd: .value("de", endedAt))
                        .foregroundStyle(color.opacity(0.08))
                    RectangleMark(xStart: .value("as", endedAt), xEnd: .value("ae", windowEnd))
                        .foregroundStyle(Theme.dim.opacity(0.06))

                    // Start / end rules
                    RuleMark(x: .value("start", startedAt))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("START").font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                    RuleMark(x: .value("end", endedAt))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.5))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("END").font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                        }

                    // Phase-average reference lines
                    if let b = stats.baseline {
                        RuleMark(y: .value("before avg", b))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Theme.dim.opacity(0.5))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.1f", b)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                            }
                    }
                    if let d = stats.duringMean {
                        RuleMark(y: .value("during avg", d))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .foregroundStyle(color.opacity(0.9))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                HStack(spacing: 3) {
                                    if let p = pctText(stats.avgUpliftPct) {
                                        Text(p).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(color)
                                    }
                                    Text(String(format: "%.1f", d)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                                }
                            }
                    }
                    if let a = stats.afterMean {
                        RuleMark(y: .value("after avg", a))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .foregroundStyle(Theme.dim.opacity(0.5))
                            .annotation(position: .bottom, alignment: .trailing, spacing: 2) {
                                HStack(spacing: 3) {
                                    if let held = stats.retainedPct {
                                        Text(String(format: "%.0f%% held", max(0, min(held, 999))))
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Theme.dim)
                                    }
                                    Text(String(format: "%.1f", a)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.dim)
                                }
                            }
                    }

                    // The line
                    ForEach(pts) { pt in
                        LineMark(x: .value("time", pt.date), y: .value(def.label, pt.val))
                            .foregroundStyle(color)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }

                    // Peak dot (halo + point) with uplift annotation — snapped
                    // onto the drawn (bucketed) line so it sits on the curve
                    // rather than floating at the raw sample value.
                    if let pd = stats.peakDate,
                       let onLine = pts.min(by: {
                           abs($0.date.timeIntervalSince(pd)) < abs($1.date.timeIntervalSince(pd))
                       }) {
                        PointMark(x: .value("peak time", onLine.date), y: .value("peak", onLine.val))
                            .symbolSize(160)
                            .foregroundStyle(color.opacity(0.25))
                        PointMark(x: .value("peak time", onLine.date), y: .value("peak", onLine.val))
                            .symbolSize(60)
                            .foregroundStyle(color)
                            .annotation(position: .top, spacing: 3) {
                                if let p = stats.peakUpliftPct {
                                    Text(String(format: "%@ %+.0f%%", p >= 0 ? "▲" : "▼", p))
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(p >= 0 ? Theme.accent : Theme.warn)
                                }
                            }
                    }

                    // Return-to-baseline marker in the after window
                    if let rd = returnDate, let b = stats.baseline {
                        PointMark(x: .value("return", rd), y: .value("baseline", b))
                            .symbolSize(40)
                            .foregroundStyle(Theme.dim)
                            .annotation(position: .bottom, spacing: 2) {
                                let secs = stats.timeToBaselineSeconds ?? 0
                                Text(secs < 60 ? "↩ <1m" : String(format: "↩ ~%.0fm", secs / 60))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                            }
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
                .frame(height: 120)
            }
        }
        .cardStyle()
    }
}
