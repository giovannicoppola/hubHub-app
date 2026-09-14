import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: StatsStore

    var body: some View {
        TabView(selection: $store.selectedTab) {
            RepoListView(mode: .all)
                .statusBar()
                .tabItem { Label("Repos", systemImage: "square.stack.3d.up") }
                .tag(AppTab.repos)

            RepoListView(mode: .issues)
                .statusBar()
                .tabItem { Label("Issues", systemImage: "exclamationmark.triangle") }
                .badge(store.latest.repos.reduce(0) { $0 + $1.issues })
                .tag(AppTab.issues)

            SettingsView()
                .statusBar()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .task {
            // Offline first: the cached snapshot is already on screen, and the
            // network is only worth touching if it is stale or missing.
            await store.refresh()
        }
    }
}

extension View {
    /// Sync state above the tab bar, on every tab — an error that is only
    /// reachable from Settings is an error nobody reads.
    func statusBar() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { SyncBar() }
    }
}

struct SyncBar: View {
    @EnvironmentObject private var store: StatsStore

    var body: some View {
        if let message = store.status.errorMessage {
            bar {
                Label {
                    Text(message)
                        .font(.footnote)
                        .lineLimit(3)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                Spacer(minLength: 8)
                if let url = store.lastRunURL {
                    Link("Run", destination: url)
                        .font(.footnote)
                }
                Button("Dismiss") { store.dismissError() }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else if let message = store.status.progressMessage {
            bar {
                if let fraction = store.status.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let url = store.lastRunURL {
                    Link("View on GitHub", destination: url)
                        .font(.footnote)
                }
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
