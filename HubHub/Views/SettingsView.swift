import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: StatsStore
    @State private var tokenDraft = ""
    @State private var showToken = false
    @State private var tokenSaved = false
    /// A pasted token never triggers Return, and the keyboard covers the tab
    /// bar — without a way to dismiss it there is no way off this screen.
    @FocusState private var editing: Bool
    @State private var importing = false
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            Form {
                if DataSource.available.count > 1 {
                Section {
                    Picker("Counts come from", selection: Binding(get: { store.source }, set: store.setSource)) {
                        ForEach(DataSource.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Source")
                } footer: {
                    Text(store.source.explanation)
                }
                }

                Section {
                    Button {
                        Task { await store.refresh(force: true) }
                    } label: {
                        Label(
                            store.source == .direct ? "Read the counts now" : "Reload stats file",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(store.status.isBusy || store.usingSample || (store.source == .direct && !store.hasToken))

                    if store.source == .sync {
                        Button {
                            Task { await store.runSnapshot() }
                        } label: {
                            Label("Run snapshot Action now", systemImage: "bolt")
                        }
                        .disabled(!store.hasToken || store.status.isBusy)
                    }

                    if let fraction = store.status.fraction {
                        ProgressView(value: fraction)
                    }
                } header: {
                    Text("Refresh")
                } footer: {
                    Text(refreshFooter)
                }

                Section {
                    Toggle(isOn: Binding(get: { store.usingSample }, set: store.setUsingSample)) {
                        Text("Use sample data")
                    }
                    .accessibilityIdentifier("sampleToggle")
                } header: {
                    Text("Sample data")
                } footer: {
                    Text("Fills the app with a made-up account so you can see how it works before adding a token. None of it is real, and saving a token turns it off.")
                }

                if store.source == .direct, !store.usingSample {
                    Section {
                        Button {
                            importing = true
                        } label: {
                            Label("Import Alfred history…", systemImage: "square.and.arrow.down")
                        }
                        if let importResult {
                            Text(importResult)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("History")
                    } footer: {
                        Text("If you have used the alfred-hubHub workflow, it has been saving a snapshot every time it ran. Copy its myGitHistory.json to this phone (AirDrop or iCloud Drive) and pick it here to chart all of it. Importing twice changes nothing.")
                    }
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

                if store.source == .sync {
                Section {
                    TextField("Owner", text: $store.config.owner)
                        .focused($editing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Repo", text: $store.config.repo)
                        .focused($editing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Branch", text: $store.config.branch)
                        .focused($editing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Latest stats path", text: $store.config.latestPath, axis: .vertical)
                        .focused($editing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                    TextField("History series path", text: $store.config.seriesPath, axis: .vertical)
                        .focused($editing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                    TextField("Workflow file", text: $store.config.workflowFile)
                        .focused($editing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Data repository")
                } footer: {
                    Text("The repo whose Action writes the stats files — not the repos being measured.")
                }
                }

                Section {
                    HStack {
                        if showToken {
                            TextField("Personal access token", text: $tokenDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($editing)
                                .submitLabel(.done)
                                .onSubmit { editing = false }
                        } else {
                            SecureField("Personal access token", text: $tokenDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($editing)
                                .submitLabel(.done)
                                .onSubmit { editing = false }
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
                        editing = false
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
                    Text(tokenFooter)
                }

                Section("Snapshot") {
                    LabeledContent("Repositories", value: "\(store.latest.repos.count)")
                    LabeledContent("Downloads", value: store.totals.downloads.grouped)
                    LabeledContent("Open issues", value: "\(store.totals.issues)")
                    LabeledContent("Stars", value: store.totals.stars.grouped)
                    LabeledContent("Taken", value: store.latest.current.isEmpty ? "—" : store.latest.current)
                    LabeledContent("Compared to", value: store.latest.previous.isEmpty ? "—" : store.latest.previous)
                    if !store.skipped.isEmpty {
                        LabeledContent("Could not read", value: "\(store.skipped.count)")
                        Text(store.skipped.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if store.source == .sync,
                       let url = URL(string: "https://github.com/\(store.config.owner)/\(store.config.repo)/actions/workflows/\(store.config.workflowFile)") {
                        Link("Action history on GitHub", destination: url)
                    }
                }

                Section {
                    Link("Privacy policy", destination: AppLinks.privacy)
                    Link("Support and feedback", destination: AppLinks.support)
                    LabeledContent("Version", value: AppLinks.version)
                } header: {
                    Text("About")
                } footer: {
                    Text("hubHub is an independent app. It is not affiliated with, endorsed by, or sponsored by GitHub, Inc. or Alfred. It reads your own repositories' counts with your own token and sends them nowhere.")
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    importResult = store.importAlfredHistory(from: url)
                case .failure(let error):
                    importResult = error.localizedDescription
                }
            }
            // Three ways off the keyboard: a Done button above it, a swipe down
            // the form, and Return.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                        .accessibilityIdentifier("dismissKeyboard")
                }
            }
        }
    }

    private var refreshFooter: String {
        if store.usingSample {
            return "Showing sample data. Turn it off below to read your own repositories."
        }
        var lines = [store.provenance]
        if store.isStale, store.source == .sync {
            lines.append("That is more than a day old — the scheduled Action may not have run.")
        }
        if !store.hasToken {
            lines.append("Add a token below first.")
        }
        if store.source == .direct {
            lines.append("Two requests per repo, so this takes a few seconds.")
        }
        return lines.joined(separator: " ")
    }

    private var tokenFooter: String {
        switch store.source {
        case .direct:
            return "Needs to read your repositories. Fine-grained: Contents Read on all repositories, or Classic: repo. Stored on this device only, in the Keychain, and sent to nowhere but github.com."
        case .sync:
            return "Needs to read the data repo and run its Action. Fine-grained: Contents Read and Actions Read and Write on \(store.config.owner)/\(store.config.repo). Classic: repo + workflow. Stored on this device only, in the Keychain."
        }
    }
}

/// Where the About section points.
enum AppLinks {
    static let privacy = URL(string: "https://giovannicoppola.github.io/alfred-hubHub/ios/privacy.html")!
    static let support = URL(string: "https://github.com/giovannicoppola/alfred-hubHub/issues")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
