import SwiftUI

struct RepoListView: View {
    enum Mode {
        /// Every repo, with the sort and "changed only" controls.
        case all
        /// Only repos with open issues, most first — the workflow's `--i` tag,
        /// where tapping a row goes to the issues page rather than the repo.
        case issues

        var title: String { self == .all ? "hubHub" : "Issues" }
    }

    let mode: Mode
    @EnvironmentObject private var store: StatsStore

    var body: some View {
        NavigationStack {
            List {
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { repo in
                            NavigationLink(value: repo) {
                                RepoRow(repo: repo, emphasise: mode == .issues ? .issues : nil)
                            }
                            .accessibilityIdentifier("repoRow")
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            if store.usingSample {
                                Label("Sample data — not real repositories", systemImage: "sparkles")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .accessibilityIdentifier("sampleBadge")
                            }
                            Text(countSummary)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(store.provenance)
                        }
                        .textCase(nil)
                        .accessibilityIdentifier("listHeader")
                    } footer: {
                        Text(footer)
                    }
                } else {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySymbol)
                    } description: {
                        Text(emptyMessage)
                    } actions: {
                        if store.latest.repos.isEmpty, store.hasToken {
                            Button("Read the counts now") { Task { await store.refresh(force: true) } }
                        } else if store.latest.repos.isEmpty {
                            Button("Add a token") { store.selectedTab = .settings }
                            Button("See it with sample data") { store.setUsingSample(true) }
                                .accessibilityIdentifier("trySample")
                        } else if store.changedOnly, mode == .all {
                            Button("Show all repos") { store.setChangedOnly(false) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(mode.title)
            .navigationDestination(for: RepoStats.self) { RepoDetailView(repo: $0) }
            .searchable(text: $store.search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter repos")
            .refreshable { await store.refresh(force: true) }
            .toolbar { toolbar }
        }
    }

    private var rows: [RepoStats] {
        mode == .all ? store.repos : store.issueQueue
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if mode == .all {
                    Picker("Sort by", selection: Binding(get: { store.sort }, set: store.setSort)) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    Divider()
                    Toggle(isOn: Binding(get: { store.changedOnly }, set: store.setChangedOnly)) {
                        Label("Changed only (\(store.changedCount))", systemImage: "arrow.up.arrow.down")
                    }
                    Divider()
                    Menu("Show counts") {
                        ForEach(Metric.allCases) { metric in
                            Button {
                                store.toggleMetric(metric)
                            } label: {
                                Label(
                                    metric.label,
                                    systemImage: store.visibleMetrics.contains(metric) ? "checkmark" : ""
                                )
                            }
                        }
                    }
                    Divider()
                }
                Button {
                    Task { await store.refresh(force: true) }
                } label: {
                    Label(
                        store.source == .direct ? "Read the counts now" : "Refresh from GitHub",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!store.hasToken || store.status.isBusy || store.usingSample)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// How many repos are on screen, and out of how many — the first thing you
    /// want to know while typing a search.
    private var countSummary: String {
        let shown = rows.count
        let total = mode == .all
            ? store.latest.repos.count
            : store.latest.repos.filter { $0.issues > 0 }.count
        let query = store.search.trimmingCharacters(in: .whitespacesAndNewlines)

        if !query.isEmpty {
            return "\(shown) of \(total) \(noun(total)) matching “\(query)”"
        }
        if mode == .all, store.changedOnly {
            return "\(shown) of \(total) \(noun(total)) changed"
        }
        if mode == .issues {
            return "\(total) \(noun(total)) with open issues"
        }
        return "\(total) \(noun(total))"
    }

    private func noun(_ count: Int) -> String { count == 1 ? "repo" : "repos" }

    private var footer: String {
        // The counts moved to the header; this is the totals behind them.
        var line = mode == .issues
            ? "\(store.totals.issues) open issues in total"
            : "\(store.totals.downloads.grouped) downloads · \(store.totals.stars.grouped) stars in total"
        // Fewer rows than usual should never be silent.
        if !store.skipped.isEmpty {
            line += "\n\(store.skipped.count) repo\(store.skipped.count == 1 ? "" : "s") could not be read this time."
        }
        return line
    }

    private var emptyTitle: String {
        if store.latest.repos.isEmpty { return "No stats yet" }
        if mode == .issues { return "No open issues" }
        if store.changedOnly { return "Nothing changed" }
        return "No matches"
    }

    private var emptySymbol: String {
        if store.latest.repos.isEmpty { return "icloud.slash" }
        if mode == .issues { return "checkmark.circle" }
        return "magnifyingglass"
    }

    private var emptyMessage: String {
        if store.latest.repos.isEmpty {
            guard store.hasToken else {
                return "Add a GitHub token in Settings, then pull to refresh."
            }
            return store.source == .direct
                ? "Read your repositories to collect your first set of counts."
                : "Run the snapshot Action to collect your first set of counts."
        }
        if mode == .issues { return "Nothing is open across your repositories." }
        if store.changedOnly { return "No counts moved between \(store.latest.previous) and \(store.latest.current)." }
        return "No repository matches “\(store.search)”."
    }
}

/// One repo: name, then a wrapping row of the counts you asked to see, each
/// with its change since the previous snapshot.
struct RepoRow: View {
    let repo: RepoStats
    /// Pulled to the front and coloured, for the Issues tab.
    var emphasise: Metric?

    @EnvironmentObject private var store: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(repo.name)
                .font(.body.weight(.medium))
                .lineLimit(1)

            FlowLayout(spacing: 8) {
                ForEach(metrics) { metric in
                    MetricChip(
                        metric: metric,
                        value: repo.value(metric),
                        delta: repo.delta(metric),
                        prominent: metric == emphasise
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var metrics: [Metric] {
        // The Issues tab always shows the issue count, whatever the Settings
        // toggles say — hiding it there would empty the tab of its point.
        var wanted = Metric.allCases.filter { store.visibleMetrics.contains($0) }
        if let emphasise {
            wanted.removeAll { $0 == emphasise }
            wanted.insert(emphasise, at: 0)
        }
        return wanted
    }
}

struct MetricChip: View {
    let metric: Metric
    let value: Int
    let delta: Int?
    var prominent = false

    var body: some View {
        HStack(spacing: 3) {
            Text(metric.emoji)
                .font(.caption2)
                // A repo with no forks and no watchers shows three zero chips;
                // fading them keeps the counts that matter readable.
                .opacity(value == 0 && !prominent ? 0.45 : 1)
            Text(value.grouped)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(prominent ? Color.primary : .secondary)
                .opacity(value == 0 && !prominent ? 0.55 : 1)
            if let delta, let text = delta.signedDelta {
                Text(text)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(metric.deltaColor(delta))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(prominent ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.10))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var text = "\(metric.label): \(value.grouped)"
        if let delta, delta != 0 {
            text += ", \(delta > 0 ? "up" : "down") \(abs(delta).grouped)"
        }
        return text
    }
}
