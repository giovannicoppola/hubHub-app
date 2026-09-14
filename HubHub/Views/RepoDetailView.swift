import Charts
import SwiftUI

struct RepoDetailView: View {
    let repo: RepoStats
    @EnvironmentObject private var store: StatsStore
    @State private var metric: Metric = .downloads
    @State private var loadingHistory = false
    /// Held rather than recomputed: `chart`, `yDomain` and `chartFooter` each
    /// need it, and SwiftUI asks for all three on every redraw.
    @State private var points: [StatsSeries.Point] = []

    var body: some View {
        List {
            Section {
                Picker("Metric", selection: $metric) {
                    ForEach(Metric.allCases) { option in
                        // Five spelled-out names truncate to "Downlo…" in a
                        // segmented control; the emoji are the same ones the
                        // list rows use, and the Now section spells them out.
                        Text(option.emoji)
                            .accessibilityLabel(option.label)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))

                chart
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("History")
            } footer: {
                Text(chartFooter)
            }

            Section("Now") {
                ForEach(Metric.allCases) { option in
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(repo.value(option).grouped)
                                .monospacedDigit()
                            if let delta = repo.delta(option), let text = delta.signedDelta {
                                Text(text)
                                    .font(.footnote.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(option.deltaColor(delta))
                            }
                        }
                    } label: {
                        Label(option.label, systemImage: option.symbol)
                    }
                }
            }

            Section {
                if let url = repo.repoURL {
                    Link(destination: url) {
                        Label("Open repository", systemImage: "safari")
                    }
                }
                if let url = repo.issuesURL {
                    Link(destination: url) {
                        Label("Open issues (\(repo.issues))", systemImage: "exclamationmark.bubble")
                    }
                }
            } footer: {
                Text(store.provenance)
            }
        }
        .navigationTitle(repo.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The chart file is fetched the first time a chart is actually
            // looked at, not on launch.
            if store.series.dates.isEmpty {
                loadingHistory = true
                await store.loadSeries()
                loadingHistory = false
            }
            reloadPoints()
        }
        .onChange(of: metric) { _, _ in reloadPoints() }
        .onChange(of: store.series) { _, _ in reloadPoints() }
    }

    private func reloadPoints() {
        points = store.series.points(repo: repo.name, metric: metric)
    }

    /// The data's own range with a little air, never the 0-based range.
    private var yDomain: ClosedRange<Double> {
        let values = points.map { Double($0.value) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        guard high > low else {
            // A flat line still needs a band to sit in, and a count of 0 must
            // not produce a negative axis.
            let padding = max(1, abs(low) * 0.05)
            return max(0, low - padding)...(high + padding)
        }
        let padding = (high - low) * 0.12
        return max(0, low - padding)...(high + padding)
    }

    @ViewBuilder
    private var chart: some View {
        if points.count > 1 {
            Chart(points) { point in
                // Anchored to the domain floor rather than to zero, so the fill
                // stops at the axis instead of spilling under the date labels.
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Baseline", yDomain.lowerBound),
                    yEnd: .value(metric.label, Double(point.value))
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Date", point.date),
                    y: .value(metric.label, point.value)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.linear)
            }
            // Downloads climb from 3,227 to 3,294 over two months: anchored at
            // zero that trend is a flat line, which is the one thing the chart
            // exists to show. `includesZero: false` is not enough — AreaMark
            // puts its own baseline at zero — so the domain is set outright and
            // the area is clipped to it.
            .chartYScale(domain: yDomain)
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .accessibilityIdentifier("historyChart")
        } else {
            VStack(spacing: 6) {
                if loadingHistory {
                    ProgressView()
                } else {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                Text(loadingHistory ? "Loading history…" : "Not enough history yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var chartFooter: String {
        let count = points.count
        guard count > 1 else {
            return "The chart fills in as the snapshot Action runs — one point per day."
        }
        let first = points[0]
        let change = points[count - 1].value - first.value
        let span = "\(count) snapshots since \(first.date.formatted(date: .abbreviated, time: .omitted))"
        guard let text = change.signedDelta else { return "\(span) · unchanged" }
        return "\(span) · \(text) \(metric.label.lowercased())"
    }
}
