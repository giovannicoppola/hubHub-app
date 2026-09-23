#!/usr/bin/env python3
"""Upload docs/appstore/*.png to the editable version's 6.9" iPhone slot.

    ASC_KEY_ID=… ASC_ISSUER_ID=… python3 scripts/asc_screenshots.py

Refuses to touch a slot that already has screenshots — delete them in App Store
Connect first if you mean to replace them.
"""
import hashlib, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_api import call, editable_version

DISPLAY = "APP_IPHONE_67"  # the 6.7"/6.9" slot; takes 1320 x 2868
SHOTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "appstore")

version = editable_version()
print(f"Version {version['attributes']['versionString']}")
loc = next(l for l in call("GET", f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
           if l["attributes"]["locale"] == "en-US")

sets = call("GET", f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
shot_set = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == DISPLAY), None)
if shot_set:
    existing = call("GET", f"/appScreenshotSets/{shot_set['id']}/appScreenshots")["data"]
    if existing:
        sys.exit(f"{DISPLAY} already has {len(existing)} screenshots; not touching them.")
else:
    shot_set = call("POST", "/appScreenshotSets", {"data": {
        "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": DISPLAY},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}},
    }})["data"]

uploaded = []
for name in sorted(f for f in os.listdir(SHOTS) if f.endswith(".png")):
    blob = open(os.path.join(SHOTS, name), "rb").read()
    shot = call("POST", "/appScreenshots", {"data": {
        "type": "appScreenshots", "attributes": {"fileName": name, "fileSize": len(blob)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": shot_set["id"]}}},
    }})["data"]
    # Apple hands back pre-signed chunk URLs; they take no bearer token.
    for op in shot["attributes"]["uploadOperations"]:
        call(op["method"], op["url"], raw=blob[op["offset"]:op["offset"] + op["length"]],
             headers={h["name"]: h["value"] for h in op["requestHeaders"]})
    call("PATCH", f"/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
         "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
    uploaded.append((name, shot["id"]))
    print(f"  uploaded {name}")

# Apple validates each image after upload; wait for its verdict.
for _ in range(30):
    states = {n: call("GET", f"/appScreenshots/{i}")["data"]["attributes"]["assetDeliveryState"] for n, i in uploaded}
    if all(s["state"] in ("COMPLETE", "FAILED") for s in states.values()):
        break
    time.sleep(5)
for n, s in states.items():
    print(f"  {n}: {s['state']}" + (f" {s.get('errors')}" if s["state"] == "FAILED" else ""))
