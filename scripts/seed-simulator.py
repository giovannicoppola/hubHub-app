#!/usr/bin/env python3
"""Put a snapshot into the simulator's app cache, for UI work and UI tests.

The app is offline-first: it reads `latest.json` / `series.json` from its
Application Support directory and only then goes to the network. Seeding those
two files means the UI can be worked on — and `HubHubUITests` can run — without
the data repo having been pushed anywhere.

    python3 scripts/seed-simulator.py                     # real counts, today only
    python3 scripts/seed-simulator.py --days 60           # 60 days of back-history

`--days` walks the real counts backwards with plausible daily movement, which is
the only way to see deltas and charts before the Action has run for a week.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import random
import subprocess
import sys

BUNDLE_ID = "com.giovannicoppola.hubhub"
VAULT = os.path.expanduser("~/github/gitVault/gitVault-notes/hubhub")
DEFAULT_HISTORY = os.path.join(VAULT, "github-stats-history.json")
SNAPSHOT_SCRIPT = VAULT


def container(device: str) -> str:
    try:
        path = subprocess.run(
            ["xcrun", "simctl", "get_app_container", device, BUNDLE_ID, "data"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Could not find {BUNDLE_ID} on '{device}'. Build and run it once first.\n{error.stderr}")
    return path


def backfill(base: dict, days: int, today: datetime.date, seed: int) -> dict:
    """Walk the real counts backwards to invent a plausible history."""
    random.seed(seed)
    history: dict = {}
    current = {name: dict(stats) for name, stats in base.items()}
    for back in range(days):
        day = (today - datetime.timedelta(days=back)).strftime("%Y-%m-%d")
        history[day] = {name: dict(stats) for name, stats in current.items()}
        for stats in current.values():
            if stats["myDownloads"] and random.random() < 0.35:
                stats["myDownloads"] = max(0, stats["myDownloads"] - random.randint(1, 4))
            if stats["myStars"] and random.random() < 0.04:
                stats["myStars"] = max(0, stats["myStars"] - 1)
            if random.random() < 0.02:
                stats["myIssues"] = max(0, stats["myIssues"] + random.choice([-1, 1]))
    return history


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", default="booted")
    parser.add_argument("--history", default=DEFAULT_HISTORY, help="real history file to seed from")
    parser.add_argument("--days", type=int, default=1, help="how many days of back-history to invent")
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args()

    sys.path.insert(0, SNAPSHOT_SCRIPT)
    try:
        import snapshot_stats
    except ImportError:
        raise SystemExit(f"Could not import snapshot_stats from {SNAPSHOT_SCRIPT}")

    if not os.path.exists(args.history):
        raise SystemExit(f"No history at {args.history}. Run snapshot_stats.py in gitVault first.")

    real = json.load(open(args.history, encoding="utf-8"))
    urls = real.get("RepoURLs", {})
    dates = sorted(k for k in real if k != "RepoURLs")
    if not dates:
        raise SystemExit(f"{args.history} has no snapshots in it")

    if args.days > 1:
        latest_date = datetime.datetime.strptime(dates[-1], "%Y-%m-%d").date()
        history = backfill(real[dates[-1]], args.days, latest_date, args.seed)
    else:
        history = {date: real[date] for date in dates}
    history["RepoURLs"] = urls

    target = os.path.join(container(args.device), "Library", "Application Support", "HubHub")
    owner = next(iter(urls.values()), "https://github.com/giovannicoppola/x").split("/")[3]

    # Sync mode reads these two.
    snapshot_stats.write_json(os.path.join(target, "latest.json"), snapshot_stats.build_latest(history, urls, owner))
    snapshot_stats.write_json(os.path.join(target, "series.json"), snapshot_stats.build_series(history), compact=True)

    # Direct mode — the default — keeps one LocalHistory file instead, with the
    # counts under their Swift names rather than the workflow's my-prefixed ones.
    metrics = {"downloads": "myDownloads", "issues": "myIssues", "stars": "myStars",
               "forks": "myForks", "watchers": "myWatchers"}
    snapshot_stats.write_json(os.path.join(target, "history.json"), {
        "snapshots": {
            date: {
                name: {key: stats[source] for key, source in metrics.items()}
                for name, stats in snapshot.items()
            }
            for date, snapshot in history.items() if date != "RepoURLs"
        },
        "repoURLs": urls,
        "owner": owner,
    })

    snapshots = len(history) - 1
    print(f"Seeded {snapshots} snapshot{'s' if snapshots != 1 else ''} into {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
