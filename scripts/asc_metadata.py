#!/usr/bin/env python3
"""Push hubHub's App Store Connect metadata for the editable version.

    ASC_KEY_ID=… ASC_ISSUER_ID=… python3 scripts/asc_metadata.py [step …]

Steps (default: all): text category rights age review build price availability

Listing copy comes from docs/app-store-metadata.md and the review notes from the
template in docs/app-store-submission.md, so those files stay the source of truth.
Safe to rerun: every step sets a value rather than appending.

Not possible over the API, so still done by hand in App Store Connect:
the App Privacy questionnaire ("Data Not Collected"), and the review contact
phone number the first time (Apple refuses review details without one).
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from asc_api import APP_ID, call, editable_version

DOCS = os.path.join(HERE, "..", "docs")
meta = open(os.path.join(DOCS, "app-store-metadata.md")).read()
runbook = open(os.path.join(DOCS, "app-store-submission.md")).read()


def block(heading):
    """The fenced block under a `## heading` in app-store-metadata.md."""
    return re.search(rf"## {re.escape(heading)}[^\n]*\n.*?```\n(.*?)\n```", meta, re.S).group(1).strip()


def review_notes():
    """The quoted template, one line per paragraph — App Store Connect keeps hard wraps."""
    quoted = [line[2:] if line.startswith("> ") else "" for line in
              runbook.split("## Review notes template")[1].splitlines() if line.startswith(">")]
    return "\n\n".join(" ".join(p.split("\n")) for p in "\n".join(quoted).strip().split("\n\n"))


def patch(kind, id_, attributes=None, relationships=None):
    data = {"type": kind, "id": id_}
    if attributes:
        data["attributes"] = attributes
    if relationships:
        data["relationships"] = relationships
    return call("PATCH", f"/{kind}/{id_}", {"data": data})


version = editable_version()
vid, vstring = version["id"], version["attributes"]["versionString"]
info = call("GET", f"/apps/{APP_ID}/appInfos")["data"][0]
steps = sys.argv[1:] or ["text", "category", "rights", "age", "review", "build", "price", "availability"]
print(f"Version {vstring}")

if "text" in steps:
    loc = next(l for l in call("GET", f"/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
               if l["attributes"]["locale"] == "en-US")
    patch("appStoreVersionLocalizations", loc["id"], {
        "description": block("Description"),
        "keywords": block("Keywords"),
        "promotionalText": block("Promotional text"),
        "supportUrl": "https://github.com/giovannicoppola/alfred-hubHub/issues",
        "marketingUrl": "https://github.com/giovannicoppola/alfred-hubHub#iphone-app",
    })
    # Subtitle and privacy URL live on the appInfo localization, not the version's.
    info_loc = next(l for l in call("GET", f"/appInfos/{info['id']}/appInfoLocalizations")["data"]
                    if l["attributes"]["locale"] == "en-US")
    patch("appInfoLocalizations", info_loc["id"], {
        "subtitle": block("Subtitle"),
        "privacyPolicyUrl": "https://giovannicoppola.github.io/alfred-hubHub/ios/privacy.html",
    })
    patch("appStoreVersions", vid, {"copyright": block("Copyright")})
    print("  text: description, keywords, promo, subtitle, URLs, copyright")

if "category" in steps:
    patch("appInfos", info["id"], relationships={
        "primaryCategory": {"data": {"type": "appCategories", "id": "DEVELOPER_TOOLS"}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}},
    })
    print("  category: Developer Tools / Utilities")

if "rights" in steps:
    call("PATCH", f"/apps/{APP_ID}", {"data": {"type": "apps", "id": APP_ID,
         "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})
    print("  content rights: no third-party content")

if "age" in steps:
    # One atomic PATCH: Apple rejects a partial questionnaire. Frequency
    # questions take "NONE"; the newer ones are plain booleans.
    frequency = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
                 "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation",
                 "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity",
                 "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic"]
    yes_no = ["advertising", "ageAssurance", "gambling", "healthOrWellnessTopics", "lootBox",
              "messagingAndChat", "parentalControls", "socialMedia",
              # Repo links open in Safari; there is no in-app browser.
              "unrestrictedWebAccess", "userGeneratedContent"]
    patch("ageRatingDeclarations", info["id"], {**{k: "NONE" for k in frequency}, **{k: False for k in yes_no}})
    print("  age rating: nothing to declare (4+)")

if "review" in steps:
    detail = call("GET", f"/appStoreVersions/{vid}/appStoreReviewDetail")["data"]
    attrs = {"notes": review_notes(), "demoAccountRequired": False}
    if detail:
        patch("appStoreReviewDetails", detail["id"], attrs)
    elif os.environ.get("ASC_CONTACT_PHONE"):
        attrs.update(contactFirstName="Giovanni", contactLastName="Coppola",
                     contactEmail="giovannicoppola@gmail.com", contactPhone=os.environ["ASC_CONTACT_PHONE"])
        call("POST", "/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
             "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    else:
        sys.exit("  review: no review details yet — set ASC_CONTACT_PHONE (+1 …) or fill the contact in the UI")
    print("  review: notes (sample data), sign-in not required")

if "build" in steps:
    # Attaching is a separate step from uploading. Take the newest processed
    # build of this version's train.
    builds = call("GET", f"/builds?filter[app]={APP_ID}&filter[preReleaseVersion.version]={vstring}"
                         f"&filter[processingState]=VALID&sort=-uploadedDate&limit=1")["data"]
    if not builds:
        sys.exit(f"  build: no processed build for {vstring} yet")
    patch("appStoreVersions", vid, relationships={"build": {"data": {"type": "builds", "id": builds[0]["id"]}}})
    print(f"  build: {builds[0]['attributes']['version']} attached")

if "price" in steps:
    free = next(p for p in call("GET", f"/apps/{APP_ID}/appPricePoints?filter[territory]=USA&limit=5")["data"]
                if float(p["attributes"]["customerPrice"]) == 0)
    call("POST", "/appPriceSchedules", {
        "data": {"type": "appPriceSchedules", "relationships": {
            "app": {"data": {"type": "apps", "id": APP_ID}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
        "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
    print("  price: free")

if "availability" in steps:
    try:
        call("GET", f"/apps/{APP_ID}/appAvailabilityV2")
        print("  availability: already set; change it in the UI")
    except SystemExit:
        territories = call("GET", "/territories?limit=200")["data"]
        included = [{"type": "territoryAvailabilities", "id": f"${{t{i}}}", "attributes": {"available": True},
                     "relationships": {"territory": {"data": {"type": "territories", "id": t["id"]}}}}
                    for i, t in enumerate(territories)]
        call("POST", "https://api.appstoreconnect.apple.com/v2/appAvailabilities", {
            "data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
                     "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}},
                                       "territoryAvailabilities": {"data": [
                                           {"type": "territoryAvailabilities", "id": x["id"]} for x in included]}}},
            "included": included})
        print(f"  availability: all {len(territories)} territories, and new ones")
