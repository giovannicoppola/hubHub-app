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

Two ways, chosen in **Settings → Source**.

### This phone (default)

The app reads the counts straight from the GitHub API and keeps the history on the device. Two
requests per repo, so a normal account is a few seconds. Nothing to set up but a token — no
repo, no Action, no secret.

The history is one `history.json` in Application Support, in the same shape as the Action's
`github-stats-history.json`, so the two are interchangeable. It keeps daily detail for a year
and then one snapshot a month.

### GitHub Action

A scheduled Action collects the counts and commits them; the app just reads the files. Worth it
for a large account, for snapshots that accrue while the app is closed, or to share one history
with the Mac.

| File | Size | When it's read |
| --- | --- | --- |
| `gitVault-notes/hubhub/github-stats-latest.json` | ~45 KB | Every launch — the list and its deltas |
| `gitVault-notes/hubhub/github-stats-series.json` | ~350 KB after a year | First time you open a chart |

Both are written by `gitVault-notes/hubhub/snapshot_stats.py` in the private **gitVault** repo,
from `.github/workflows/snapshot-stats.yml` there. The archival `github-stats-history.json` is
never downloaded by the app.

**Why a private vault and not the public workflow repo:** `/user/repos` lists private
repositories too — 47 of them here — so publishing the counts would publish their names. The
counts are harmless; the repo list is not.

### Importing your Alfred history

The `alfred-hubHub` workflow has been writing a snapshot to its cache folder every time it ran,
in the same shape this app uses. Both modes can fold that in, so the charts start with years in
them instead of one point:

- **This phone** — copy `myGitHistory.json` to the phone (AirDrop, or iCloud Drive), then
  **Settings → History → Import Alfred history…**
- **GitHub Action** — run `import_alfred_history.py` in the data repo, then regenerate

```bash
# on the Mac, in gitVault-notes/hubhub/
python3 import_alfred_history.py --dry-run   # says what it would add
python3 import_alfred_history.py
python3 snapshot_stats.py                    # regenerate latest + series
```

The workflow's file lives at:

```
~/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/alfred-hubhub/myGitHistory.json
```

It is a union, not a conversion — existing snapshots win, so importing twice changes nothing.
Snapshots from before the workflow tracked all five counts carry only downloads; those stay
partial rather than being padded with zeros, so a star chart begins when stars were first
recorded instead of "starting at 0" and jumping.

### Either way

- **Offline first.** The last snapshot is cached on the phone. A failed refresh shows an error
  and leaves the list you already had — it never blanks it.
- **Deltas are between snapshots, not between launches.** The list header always names both
  dates, because a `+14` from a week-old snapshot means something different from today's.
- **A repo in its first snapshot has no delta at all**, which is not the same as no change, and
  the row says nothing rather than `0`.
- **A repo that can't be read is left out, not written down as zero.** A fabricated `0` would
  show as a delta of −3,294 and then "recover" tomorrow. The list footer says how many were
  skipped. If more than a quarter of the account fails, nothing is saved at all — that is
  systemic, and writing it to history would corrupt every delta after it.
- **The two modes keep separate histories**, so switching never shows one mode's numbers under
  the other's snapshot dates.
- **Every snapshot is kept; only the chart is thinned** — daily detail for a year, then one
  point a month. Retention shapes what is plotted, not what is stored, so importing a four-year
  archive does not quietly destroy three years of it.

## Requirements

- Mac with Xcode 15+ (iOS 17+)
- A GitHub personal access token on the phone:
  - **This phone** mode — reads your repositories. Fine-grained: Contents **Read** on all
    repositories. Classic: `repo`.
  - **GitHub Action** mode — reads the data repo and runs its Action. Fine-grained: Contents
    **Read** + Actions **Read and write** on `giovannicoppola/gitVault`. Classic: `repo` +
    `workflow`. Also needs the `snapshot-stats.yml` Action and a `HUBHUB_PAT` secret there.
  - The same token the **Dann Farm Inventory** app uses covers Action mode. Paste it into both;
    each app keeps its own Keychain entry.

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
series gaps, the local history (recording, pruning, JSON round-trip), the collector against a
fake GitHub (pagination, every-asset download totals, `subscribers_count` vs the stars alias,
progress, skipped repos, the abort threshold), the Alfred import (partial snapshots, idempotence,
not overwriting collected data, chart thinning), and the store end to end in both modes — offline
cache, missing files, malformed responses, mode switching and the persisted preferences.

`RealAlfredHistoryTests` runs the importer against the actual workflow cache on this Mac and
skips when it is not there, the way the renovation app's `ReportParityTests` runs against the
real vault.

`HubHubUITests` drives the real app: drilling into a repo draws its chart, the Issues tab really
drops repos with no open issues, search narrows the list. They skip when the simulator has no
cached snapshot, so seed one first:

```bash
python3 scripts/seed-simulator.py --days 60
```

That reads the real counts from `gitVault/gitVault-notes/hubhub/` and walks them backwards to
give the charts something to draw before the Action has run for a week.

## First launch

1. Open **Settings**, paste your PAT → **Save token**
2. Pull to refresh on the Repos tab (or **Read the counts now**)

That is the whole setup in **This phone** mode. For **GitHub Action** mode, switch Source first
and confirm owner / repo / paths — by default `giovannicoppola/gitVault` on `main`.

## Notes

- Downloads count every asset of every release. The Alfred workflow counted `assets[0]` only, so
  a release with both a `.zip` and a `.dmg` was undercounted there.
- Watchers come from `subscribers_count` on the repo endpoint, not `watchers_count` on the list
  endpoint — the latter is an alias for stars, which is what made the workflow's watcher column
  wrong twice.
- The chart's y-axis fits the data rather than starting at zero. Downloads that climb 3,227 →
  3,294 over two months are a flat line on a zero-based axis.
- Keep the PAT only on your phone; it is stored `WhenUnlockedThisDeviceOnly` and never leaves it.
