# hubHub (iPhone)

<img src="HubHub/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="110" align="right" alt="hubHub icon">

SwiftUI companion to the [alfred-hubHub](https://github.com/giovannicoppola/alfred-hubHub)
workflow: the same downloads / issues / stars / forks / watchers for every repo you own, with
the same day-over-day deltas, on the phone.

## What it does

- **Repos** — every repo with the counts you chose to see, each showing its change since the
  previous snapshot. Sort by downloads (the workflow's default: downloads, then issues), by any
  other count, by name, or by **biggest change**
- **Issues** — repos with open issues, most first, with the issue count pulled to the front of
  the row. Repos with none are dropped, not sorted to the bottom (the workflow's `--i` tag)
- **Changed only** — the `--c` filter, in the ⋯ menu, plus a setting to open that way
- **Search** across repo names from either tab
- **Tap a repo** for its history charted over time — any of the five counts — and links straight
  to the repo or its issues page
- **Settings** — which counts to show, sort order, the data repo, the PAT (Keychain), and a
  button that runs the snapshot Action and waits for it

## How it gets its data

It does not walk the GitHub API from the phone. That would be ~250 requests over a cell
connection every time you opened the app. Instead a scheduled Action in the data repo does the
walking and commits the result, and the app reads two files:

| File | Size | When it's read |
| --- | --- | --- |
| `gitVault-notes/hubhub/github-stats-latest.json` | ~45 KB | Every launch — the list and its deltas |
| `gitVault-notes/hubhub/github-stats-series.json` | ~350 KB after a year | First time you open a chart |

Both are written by `gitVault-notes/hubhub/snapshot_stats.py` in the private **gitVault** repo,
from `.github/workflows/snapshot-stats.yml` there. The archival `github-stats-history.json`
keeps the Alfred workflow's own JSON shape and is never downloaded by the app.

**Why the private vault and not the public workflow repo:** `/user/repos` lists private
repositories too — 47 of them here — so publishing the counts would publish their names. The
counts are harmless; the repo list is not.

Consequences worth knowing:

- **Offline first.** The last snapshot is cached on the phone. A failed or missing fetch shows
  an error and leaves the list you already had — it never blanks it.
- **A token is required**, because the data repo is private. (Against a *public* data repo the
  app falls back to `raw.githubusercontent.com` and needs no token at all — that path is still
  there if you ever point it at one.)
- **Read-only.** The app never writes a file, so there is nothing to conflict and no shas to
  reconcile. Refresh means "ask the Action to run", not "write to the repo".
- **Deltas are between snapshots, not between launches.** The list header always names both
  dates, because a `+14` from a week-old snapshot means something different from today's.
- **A repo in its first snapshot has no delta at all**, which is not the same as no change, and
  the row says nothing rather than `0`.

## Requirements

- Mac with Xcode 15+ (iOS 17+)
- The `snapshot-stats.yml` Action in **gitVault**, and a `HUBHUB_PAT` secret there
- A GitHub personal access token on the phone
  - Fine-grained: Contents **Read**, Actions **Read and write** on `giovannicoppola/gitVault`
  - Classic: `repo` + `workflow`
  - The same token the **Dann Farm Inventory** app uses already covers this — it needs Contents
    read/write and Actions read/write on the same repo. Paste it into both; each app keeps its
    own Keychain entry.

## Open in Xcode

```bash
open HubHub.xcodeproj
```

Select your Team under Signing & Capabilities, plug in an iPhone (or simulator), Run.

Or regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
```

### Tests

```bash
xcodebuild -project HubHub.xcodeproj -scheme HubHub \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

`HubHubTests` covers decoding both data files, delta and "changed" logic, every sort and filter,
series gaps, and the store end to end against a stubbed URL protocol — offline cache, missing
files, malformed responses and the persisted preferences.

`HubHubUITests` drives the real app: drilling into a repo draws its chart, the Issues tab really
drops repos with no open issues, search narrows the list. They skip when the simulator has no
cached snapshot, so seed one first:

```bash
python3 scripts/seed-simulator.py --days 60
```

That reads the real counts from `gitVault/gitVault-notes/hubhub/` and walks them backwards to
give the charts something to draw before the Action has run for a week.

## First launch

1. Open **Settings** and confirm owner / repo / branch — by default `giovannicoppola/gitVault`
   on `main`
2. Paste your PAT → **Save token**
3. Pull to refresh on the Repos tab
4. Optional: **Run snapshot Action now** to take a fresh snapshot without waiting for the daily
   schedule

## Notes

- Downloads count every asset of every release. The Alfred workflow counted `assets[0]` only, so
  a release with both a `.zip` and a `.dmg` was undercounted there.
- Watchers come from `subscribers_count` on the repo endpoint, not `watchers_count` on the list
  endpoint — the latter is an alias for stars, which is what made the workflow's watcher column
  wrong twice.
- The chart's y-axis fits the data rather than starting at zero. Downloads that climb 3,227 →
  3,294 over two months are a flat line on a zero-based axis.
- Keep the PAT only on your phone; it is stored `WhenUnlockedThisDeviceOnly` and never leaves it.
