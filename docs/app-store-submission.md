# hubHub — App Store submission runbook

Everything needed to take this repo from source to a review submission. Modelled on the Aeye
runbook (`alfred-aeye/ios/docs/app-store-submission.md`), which has been through it.

Current release target: **1.0.0 (build 2)**, set as `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
in `project.yml`.

**Status: submitted 23 September 2026 (10:42 UTC). Waiting for Review.** Review submission
`741a38fb-3a4a-47f1-bef8-49a0ab6bb698`.

---

## 0. The real risks

**1. App Review has no GitHub token (Guideline 2.1, App Completeness). Handled.**
Without a token every screen is empty. **Settings → Sample data → Use sample data** fills the app
with a made-up account: eight invented repos, a year of history, deltas, issues. It ships in
Release builds, and the empty list offers **See it with sample data** as a one-tap way in. The list
header says *Sample data — not real repositories* the whole time. Saving a token turns it off.

The review notes (template below) point at it. Do not hand over a real token.

**2. GitHub's name and marks (Guideline 5.2.1).**
The app reads GitHub's public API with the user's own token, which is ordinary. Keep it that way:

- "GitHub" only as plain text describing the service. It is **not** in the app name, the
  subtitle, or the keywords. Apple rejects other companies' trademarks in keywords.
- The in-app disclaimer is in **Settings → About**: not affiliated with GitHub, Inc. or Alfred.
  The same section links the privacy policy and support.
- **Check the icon.** It is a hand-drawn cat face. It is not the Octocat, but a reviewer (or
  GitHub) could read it as one. If review raises it, change the icon rather than argue.

**3. GitHub Action mode is Debug-only.**
`DataSource.available` is `[.direct]` in Release. Action mode depends on `snapshot_stats.py` and a
data repo that exist only in the private gitVault. A store build offering it would show everyone,
review included, a 404 and a private repo's name. Your own Debug installs keep it.
**Consequence:** a TestFlight/App Store install on your own phone is direct mode only.

---

## 1. Apple Developer setup

Team `VDG762YNX9`. Only one identifier, and no App Groups or capabilities:

| Kind | Identifier |
|------|-----------|
| App ID | `com.giovannicoppola.hubhub` |

**Status: done.** `scripts/archive.sh` on 22 September 2026 created the *iOS Team Store
Provisioning Profile: com.giovannicoppola.hubhub* through `-allowProvisioningUpdates`.

---

## 2. App Store Connect record

App Store Connect → **Apps** → **+** → New App.

| Field | Value |
|-------|-------|
| Platform | iOS |
| Name | hubHub (fallback if taken: *hubHub — Repo Stats*) |
| Primary language | English (U.S.) |
| Bundle ID | `com.giovannicoppola.hubhub` |
| SKU | `hubhub-ios-001` |
| User access | Full |

Then:

- **Category**: Primary Developer Tools, secondary Utilities
- **Price**: Free
- **Age rating**: 4+ (answer "No" throughout)
- **Privacy policy URL**: `https://giovannicoppola.github.io/alfred-hubHub/ios/privacy.html`
  (**required**, and the same URL is linked from Settings → About)
- **Support URL**: `https://github.com/giovannicoppola/alfred-hubHub/issues`
- **Marketing URL**: `https://github.com/giovannicoppola/alfred-hubHub#iphone-app`

**Privacy page status: live.** GitHub Pages was turned on 22 September 2026 for the public
**alfred-hubHub** repo, serving `main` → `/docs`, and the URL returned 200. The source is
`docs/ios/privacy.html` there. Edit and push it to change the published policy.

Listing copy is in [`app-store-metadata.md`](app-store-metadata.md).

### Setting it all through the API

Everything in this section except App Privacy was set with the App Store Connect API, not by
hand, and can be again:

```bash
export ASC_KEY_ID=PCLQ5K922S ASC_ISSUER_ID=...
python3 scripts/asc_metadata.py      # text category rights age review build price availability
python3 scripts/asc_screenshots.py   # docs/appstore/*.png -> the 6.9" slot
```

`asc_metadata.py` reads the listing from `app-store-metadata.md` and the review notes from the
template at the end of this file, so edit those files rather than the App Store Connect fields.
Both scripts act on whichever iOS version is still editable. Once a version is submitted it is
locked, so they only work again when the next version exists.

Two things the API cannot do:

- **App Privacy** (§3): Apple offers no API for the privacy questionnaire.
- **The first review contact.** Apple will not save review details without a `+`-prefixed phone
  number. Either set `ASC_CONTACT_PHONE` or fill the contact in the UI once; after that the
  script only updates the notes.

App Store Connect gotchas from this run:

- The ASC version was created as **1.0** while the build said **1.0.0**. A build can only be
  selected for a version with exactly the same string, so the version was renamed through the API.
- Apple doesn't create a price schedule or country availability for a new app. Both return 404
  until set, and the script sets them (free; all territories and future ones).
- App Store Connect keeps hard line breaks in review notes, so the script joins each paragraph
  onto one line.

---

## 3. App Privacy (nutrition label)

> **Data Collection: No, we do not collect data from this app.**

This is true: the token stays in the Keychain (`WhenUnlockedThisDeviceOnly`) and the history stays
in Application Support. The only network calls take the user's own token to `api.github.com`.
There are no SDKs, no crash reporter, and no backend.

The machine-readable half is `Config/PrivacyInfo.xcprivacy`. It declares no tracking, no
collected data, and one required-reason API:

| API category | Reason | Why |
|---|---|---|
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | The app's own preferences |

If you add a dependency or start reading file timestamps or disk space, the manifest has to grow
to match. Otherwise the upload gets an ITMS-91053 email.

---

## 4. Screenshots

`docs/appstore/`, all **1320 × 2868** (6.9"). App Store Connect also accepts these for the 6.5"
slot.

| File | Screen |
|---|---|
| `01-repos.png` | The list with deltas |
| `02-chart-downloads.png` | A year of downloads for one repo |
| `03-chart-stars.png` | The same repo's stars |
| `04-issues.png` | Repos with open issues |

These are shot from the **sample account**, so no real repository name (public or private) can
appear in the listing. The *Sample data* label is visible in the list shot; that is honest and
acceptable. There is no Settings shot: UI tests run the Debug build, and its Source picker shows
the Action mode that the store build does not have.

Regenerate:

```bash
DEV=<iPhone 16 Pro Max simulator id>
xcrun simctl ui $DEV appearance light
xcrun simctl status_bar $DEV override --time 9:41 --dataNetwork wifi --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
TEST_RUNNER_HUBHUB_SHOTS=appstore xcodebuild -project HubHub.xcodeproj -scheme HubHub \
  -destination "platform=iOS Simulator,id=$DEV" -resultBundlePath /tmp/store.xcresult \
  -only-testing:HubHubUITests/ScreenshotTests/testCaptureAppStoreScreens test
python3 scripts/export-screenshots.py --full /tmp/store.xcresult docs/appstore
```

`--full` matters: without it the exporter halves the images for the README, and App Store Connect
rejects any size that is not an exact device size.

---

## 5. Build and upload

```bash
./scripts/archive.sh            # archive + export -> build/export/HubHub.ipa
./scripts/archive.sh --upload   # ...then validate and upload to App Store Connect
```

Upload uses the same App Store Connect API key as Aeye:

```bash
export ASC_KEY_ID=PCLQ5K922S
export ASC_ISSUER_ID=...   # top of Users and Access → Integrations → App Store Connect API
# key: ~/.appstoreconnect/private_keys/AuthKey_PCLQ5K922S.p8 (already on this Mac)
```

The ASC app record (§2) has to exist first, or `altool` rejects the bundle ID with *no suitable
application record*. Processing takes about 5–15 minutes.

Export compliance is answered in the bundle: `ITSAppUsesNonExemptEncryption = NO`, set through
`project.yml`. The app only uses HTTPS through URLSession, which is exempt.

**Last verified archive: 22 September 2026, 1.0.0 (1).** Signed `Apple Distribution: Giovanni
Coppola (VDG762YNX9)` against *iOS Team Store Provisioning Profile: com.giovannicoppola.hubhub*,
`get-task-allow` false, `PrivacyInfo.xcprivacy` in the bundle, category and encryption keys in
Info.plist.

**Uploaded 22 September 2026**: 1.0.0 (1), delivery `0bcb1fc5-2e94-4d09-85e5-2979e87d2537`.
**Build 1 was universal by mistake** (see below) and was replaced by **build 2**, uploaded
23 September 2026, delivery `c4fd733f-f883-4408-a3ce-39754217acf2`. Builds 1 and 2 are both used,
so a resubmission needs `CURRENT_PROJECT_VERSION: "3"`.

**Set iPhone-only on the target, not only on the project.** XcodeGen gives an iOS application
target `TARGETED_DEVICE_FAMILY = "1,2"`, which overrides the project-level `"1"`. Build 1 therefore
shipped as universal, and App Store Connect required 13" iPad screenshots before review.
`project.yml` now sets `"1"` on the `HubHub` target. To check an export, look for
`UIDeviceFamily = [1]` in its Info.plist.

The ASC record is *hubHub — Repo Stats* (Apple ID 6815015600).

**Do not ignore the orientation warning.** "All interface orientations must be supported unless
the app requires full screen" looks like it is only about iPad, but an iPhone-only app still runs on
iPad, and App Store validation rejects the bundle with a 409 over it. `project.yml` therefore lists
all four orientations, upside-down included (Face ID iPhones never rotate upside down anyway).
Hit and fixed on 22 September 2026.

`altool` exits 0 even when it fails, so `archive.sh` checks its output instead. Before that change
the script announced "Uploaded" right after a rejection.

---

## 6. Before hitting Submit

- [x] Sample data in Release, reachable from Settings and the empty list (§0)
- [x] Disclaimer, privacy link, and support link in Settings → About
- [x] Action mode hidden in Release (§0.3)
- [x] Privacy manifest, export compliance, and category in the bundle
- [x] 6.9" screenshots generated (§4)
- [x] Signed archive and export verified (§5)
- [x] Pages enabled on alfred-hubHub and the privacy URL returns 200 (§2)
- [x] App Store Connect record created (§2): Apple ID 6815015600, SKU `hubhub-ios-001`
- [x] App Privacy answered "No data collected" (§3)
- [x] Build uploaded: 1.0.0 (2), 23 September 2026 (iPhone-only; build 1 was universal)
- [x] Build 2 processed and attached to 1.0.0
- [x] Review notes, contact, and "sign-in not required" saved
- [x] **Submitted 23 September 2026**: Waiting for Review
- [ ] Version/build bumped for any resubmission (build numbers cannot repeat)

## Review notes template

Paste into App Store Connect → *App Review Information* → *Notes*, and turn off "Sign-in
required":

> hubHub is a read-only viewer for the download, issue, star, fork, and watcher counts of the
> user's own GitHub repositories. It has no backend and no account of its own. The user pastes a
> GitHub personal access token, which is stored in the iPhone Keychain and sent only to
> api.github.com to read that user's own repositories. Nothing is collected, sent to us, or shared.
>
> To see the app fully populated without a GitHub account, open the Settings tab and turn on
> "Use sample data" (or tap "See it with sample data" on the empty Repos screen). Every screen then
> shows a made-up account of eight repositories with a year of history, labelled as sample data.
> Tap any repository to see its chart. No account of any kind is needed to review the app.
>
> hubHub is an independent app and is not affiliated with, endorsed by, or sponsored by GitHub,
> Inc. "GitHub" appears only as plain text naming the service the user's own data comes from.
