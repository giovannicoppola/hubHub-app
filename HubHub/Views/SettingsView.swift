import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: StatsStore
    @State private var tokenDraft = ""
    @State private var showToken = false
    @State private var tokenSaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await store.runSnapshot() }
                    } label: {
                        Label("Run snapshot Action now", systemImage: "arrow.clockwise")
                    }
                    .disabled(!store.hasToken || store.status.isBusy)

                    Button {
                        Task { await store.refresh(force: true) }
                    } label: {
                        Label("Reload stats file", systemImage: "arrow.down.circle")
                    }
                    .disabled(store.status.isBusy)
                } header: {
                    Text("Refresh")
                } footer: {
                    Text(refreshFooter)
                }

                Section("Show counts") {
                    ForEach(Metric.allCases) { metric in
                        Toggle(isOn: Binding(
                            get: { store.visibleMetrics.contains(metric) },
                            set: { _ in store.toggleMetric(metric) }
                        )) {
                            Label("\(metric.emoji) \(metric.label)", systemImage: metric.symbol)
                                .labelStyle(.titleOnly)
                        }
                    }
                }

                Section {
                    Picker("Sort by", selection: Binding(get: { store.sort }, set: store.setSort)) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { store.changedOnlyOnLaunch },
                        set: store.setChangedOnlyOnLaunch
                    )) {
                        Text("Open showing changed repos only")
                    }
                } header: {
                    Text("List")
                } footer: {
                    Text("Matches the workflow's ⌥ preferences: which counts appear, how repos are ordered, and whether launching filters down to what moved.")
                }

                Section {
                    TextField("Owner", text: $store.config.owner)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Repo", text: $store.config.repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Branch", text: $store.config.branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Latest stats path", text: $store.config.latestPath, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                    TextField("History series path", text: $store.config.seriesPath, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                    TextField("Workflow file", text: $store.config.workflowFile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Data repository")
                } footer: {
                    Text("The repo whose Action writes the stats files — not the repos being measured.")
                }

                Section {
                    HStack {
                        if showToken {
                            TextField("Personal access token", text: $tokenDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Personal access token", text: $tokenDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showToken ? "Hide token" : "Show token")
                    }
                    Button("Save token") {
                        tokenSaved = store.saveToken(tokenDraft)
                        tokenDraft = ""
                    }
                    if tokenSaved || store.hasToken {
                        Label(
                            store.hasToken ? "Token saved in Keychain." : "Token removed.",
                            systemImage: store.hasToken ? "checkmark.circle" : "trash"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Access token")
                } footer: {
                    Text("Only needed to run the Action from the phone, and to read a private data repo. Fine-grained: Contents Read and Actions Read and Write on \(store.config.owner)/\(store.config.repo). Classic: repo + workflow. Stored on this device only, in the Keychain.")
                }

                Section("Snapshot") {
                    LabeledContent("Repositories", value: "\(store.latest.repos.count)")
                    LabeledContent("Downloads", value: store.totals.downloads.grouped)
                    LabeledContent("Open issues", value: "\(store.totals.issues)")
                    LabeledContent("Stars", value: store.totals.stars.grouped)
                    LabeledContent("Taken", value: store.latest.current.isEmpty ? "—" : store.latest.current)
                    LabeledContent("Compared to", value: store.latest.previous.isEmpty ? "—" : store.latest.previous)
                    if let url = URL(string: "https://github.com/\(store.config.owner)/\(store.config.repo)/actions/workflows/\(store.config.workflowFile)") {
                        Link("Action history on GitHub", destination: url)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var refreshFooter: String {
        var lines = [store.provenance]
        if store.isStale {
            lines.append("That is more than a day old — the scheduled Action may not have run.")
        }
        if !store.hasToken {
            lines.append("Add a token below to run the Action from here.")
        }
        return lines.joined(separator: " ")
    }
}
