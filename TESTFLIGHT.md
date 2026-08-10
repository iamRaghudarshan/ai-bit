# Getting AI Tube onto your iPhone via TestFlight

Everything that can be automated is. What is left are the steps only you can do,
because they need your Apple account.

**Time: about 30 minutes, once.** After that a release is `git tag v1.0.1 &&
git push origin v1.0.1`.

---

## What is already reusable from SafeNest

You ship SafeNest to TestFlight from this same Apple account, so most of the
hard part is done:

| Thing | Reusable? |
|---|---|
| Apple Developer account (~$99/yr) | **Yes** — already paid for |
| Team ID `P57Y6ND67Y` | **Yes** |
| Distribution certificate (`distribution.p12`) | **Yes** — certificates are per *team* |
| `APPLE_ID` / `APPLE_APP_PASSWORD` | **Yes** — same values as SafeNest's secrets |
| Provisioning profile | **No** — profiles are per *bundle id*. AI Tube needs its own. |
| App Store Connect app record | **No** — every app needs its own. |

So there are exactly two new things to create in Apple's portals.

AI Tube's bundle id is **`aitube.raghudarshan.online`**, following SafeNest's
convention. It is set in `ios/Runner.xcodeproj/project.pbxproj` and
`ios/ExportOptions.plist`; if you change one you must change both, and the CI
job fails early on purpose if they disagree.

---

## 1. Register the App ID

<https://developer.apple.com/account/resources/identifiers/list>

- **+** → **App IDs** → **App**
- Description: `AI Tube`
- Bundle ID: **Explicit** → `aitube.raghudarshan.online`
- Capabilities: leave everything off. Background audio and Picture-in-Picture
  are declared in `Info.plist` (`UIBackgroundModes`) and need no entitlement.
- Register.

## 2. Create the provisioning profile

<https://developer.apple.com/account/resources/profiles/list>

- **+** → Distribution → **App Store Connect** → Continue
- App ID: `aitube.raghudarshan.online`
- Certificate: pick your existing **Apple Distribution** certificate — the same
  one SafeNest uses. Do not create a new one; a second certificate does not
  break anything but there is a limit of two and they expire together.
- Name it exactly **`AITube AppStore`** — this string must match
  `ios/ExportOptions.plist`.
- Generate, then **Download**.

## 3. Create the app in App Store Connect

<https://appstoreconnect.apple.com/apps>

- **+** → **New App**
- Platform: iOS
- Name: `AI Tube` (must be unique across the whole App Store — if taken, use
  something like `AI Tube Personal`; the name here does not have to match the
  app's on-device name)
- Primary language, then Bundle ID: `aitube.raghudarshan.online`
- SKU: `aitube` (any private string)
- Create.

You never submit this for review. TestFlight builds install without review for
you and up to 100 internal testers.

## 4. Push the code to GitHub

The repository is already initialised and committed locally. Create an **empty
private** repo (`ai-tube`) at <https://github.com/new>, then:

```bash
cd "D:/AI TUBE"
git remote add origin https://github.com/iamRaghudarshan/ai-tube.git
git push -u origin main
```

**Private matters.** This app violates YouTube's Terms of Service; a public repo
is an invitation for a takedown request.

## 5. Add the secrets

Repo → Settings → Secrets and variables → Actions → **New repository secret**.

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | `P57Y6ND67Y` |
| `APPLE_ID` | the Apple ID email that owns the developer account |
| `APPLE_APP_PASSWORD` | app-specific password from <https://appleid.apple.com> → Sign-In and Security → App-Specific Passwords |
| `IOS_CERT_PASSWORD` | contents of `D:\AI PRO\apple-signing\p12-password.txt` |
| `IOS_CERT_P12_BASE64` | see below |
| `IOS_PROFILE_BASE64` | see below |

Generate the two base64 values in PowerShell:

```powershell
# Certificate — the same file SafeNest uses
[Convert]::ToBase64String([IO.File]::ReadAllBytes("D:\AI PRO\apple-signing\distribution.p12")) |
  Set-Clipboard
# paste into IOS_CERT_P12_BASE64

# The NEW profile you downloaded in step 2
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$HOME\Downloads\AITube_AppStore.mobileprovision")) |
  Set-Clipboard
# paste into IOS_PROFILE_BASE64
```

If `APPLE_ID` / `APPLE_APP_PASSWORD` already exist on the SafeNest repo, use the
identical values — secrets do not carry across repositories.

## 6. Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

Watch it under the repo's **Actions** tab. It takes 15–25 minutes: analyze,
tests, signing, archive, upload.

Then in App Store Connect → your app → **TestFlight**, the build appears after
5–15 minutes of Apple processing. Add yourself as an internal tester, install
**TestFlight** from the App Store on your iPhone, and the build shows up there.

Builds expire after **90 days**. Push a new tag to refresh.

---

## When it fails

**"No valid code signing certificates were found"** — almost never about
certificates. Check the `security find-identity` output printed before the build
step; if that list is empty the keychain search list is the cause, and that is
exactly what the `list-keychains` line in the workflow exists to prevent.

**"Provisioning profile doesn't match the bundle identifier"** — the workflow
checks this *before* archiving and fails with both values printed. Make the
profile's App ID, `ExportOptions.plist`, and `project.pbxproj` agree.

**"No suitable application records were found"** — step 3 was skipped, or the
bundle id in App Store Connect differs by a character.

**Upload rejected for a duplicate build number** — build number comes from
`github.run_number`, which always increases, so this only happens if you re-run
an old job. Push a new tag instead.

**The job never starts, no logs** — Actions minutes exhausted. macOS runners
bill at 10× the Linux rate. Check billing; that is what stopped SafeNest's iOS
builds once.

**Apple's upload service is down** — the `.ipa` is kept as a run artifact for 14
days. Download it and upload by hand with Transporter from any Mac, or re-push
the tag later.

---

## Two things TestFlight will not fix

Neither is a bug, and neither goes away on a real device:

- **Video plays at 360p.** YouTube no longer serves a combined video+audio
  stream above that, and a single-URL player cannot recombine separate tracks.
  Audio is full quality. See the README.
- **There is no sign-in**, so no subscriptions and no account playlists. The
  feed approximates recommendations from local watch history.
