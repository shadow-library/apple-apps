# Release checklist: Novel Forge and Memoir

What a store release needs from the owner, in the order it is done. The code builds and tests without any of it; every item here is a decision,
an account step or a check on real devices that no agent can make. Tick each item and note the answer given, so the next release can reuse it.

| Run | Value |
| --- | ----- |
| Date | |
| Commit | |
| Marketing version and build number | |
| Signed by (team id) | |

## 1. Build variables, archive and export

Store-build options are environment variables read when the workspace is generated (see Store builds in the README). One generation serves both
apps, and a variable left out on the next generation goes back to its development default, so set them all every time.

| Variable | Store value | Notes |
| -------- | ----------- | ----- |
| `TUIST_DEVELOPMENT_TEAM` | the team id | Without it the iCloud, push, keychain-sharing and HealthKit capabilities are not emitted |
| `TUIST_MARKETING_VERSION` | e.g. `1.0.0` | The version App Store Connect shows |
| `TUIST_BUILD_NUMBER` | one higher than the last upload of that version | App Store Connect refuses a build number it has seen |
| `TUIST_USES_NON_EXEMPT_ENCRYPTION` | `true` or `false`, from section 3 | Unset, every upload stops to ask the export-compliance question |
| `TUIST_UNRESTRICTED` | unset | Set to `1` only for a Novel Forge build App Review has accepted with unrestricted writing (section 3) |

- [ ] Generate and check the options:

  ```sh
  export TUIST_DEVELOPMENT_TEAM=ABCDE12345 TUIST_MARKETING_VERSION=1.0.0 TUIST_BUILD_NUMBER=1 TUIST_USES_NON_EXEMPT_ENCRYPTION=false
  mise run bootstrap
  mise run check:build-options
  mise run lint
  ```

- [ ] Archive each app for each platform it ships on. In Xcode: pick the scheme, the destination "Any iOS Device" or "Any Mac", then Product >
  Archive, and Organizer's Distribute App > App Store Connect. From the command line, with the team's account signed in to Xcode (signing is
  automatic):

  ```sh
  xcodebuild archive -workspace ShadowLibrary.xcworkspace -scheme NovelForge -configuration Release \
    -destination 'generic/platform=iOS' -archivePath ~/Archives/NovelForge-iOS.xcarchive -allowProvisioningUpdates
  xcodebuild archive -workspace ShadowLibrary.xcworkspace -scheme NovelForge -configuration Release \
    -destination 'generic/platform=macOS' -archivePath ~/Archives/NovelForge-macOS.xcarchive -allowProvisioningUpdates
  xcodebuild -exportArchive -archivePath ~/Archives/NovelForge-iOS.xcarchive -exportOptionsPlist ExportOptions.plist \
    -exportPath ~/Archives/NovelForge-iOS -allowProvisioningUpdates
  ```

  Repeat with `-scheme Memoir`. `ExportOptions.plist` (kept outside the repository) sets `method` to `app-store-connect`, `destination` to
  `upload` (or `export` to upload by hand) and `teamID`.
- [ ] Check the push entitlement of an exported build. Every configuration carries `aps-environment` `development`, so development-signed Release
  builds work; export re-signs with the distribution profile, which must turn it into `production`:
  `codesign -d --entitlements - <exported app>` shows `aps-environment` (`com.apple.developer.aps-environment` on the Mac) as `production`.
- [ ] The build number goes up by one for every upload, and the workspace is generated again before each archive.

## 2. Apple Developer and App Store Connect

- [ ] App IDs: `com.shadow.apps.novelforge` and `com.shadow.apps.memoir`, one App ID each for iPhone, iPad and Mac (one target builds all three,
  so one App Store Connect record per app carries both the iOS and the macOS platform). Automatic signing registers the App IDs; check that each
  has iCloud with CloudKit, Push Notifications and, for Memoir, HealthKit.
- [ ] iCloud containers `iCloud.com.shadow.apps.novelforge` and `iCloud.com.shadow.apps.memoir`, assigned to their App IDs. The keychain group
  `<team id>.com.shadow.apps.shared` needs no registration.
- [ ] CloudKit schema. `CKZoneClient` has never run against the service. Run the sync sections of both hardware checklists in the development
  environment until the `VaultObject` record type exists with its `path`, `size`, `bytes` and `parts` fields, then deploy the schema to Production
  in CloudKit Console for both containers. Its layout is frozen once deployed (`CloudKitRecordLayout`).
- [ ] App Store Connect records: one per app, with the bundle id above, the name, the primary language, the SKU and both platforms.
- [ ] Display names. The home-screen name is `CFBundleDisplayName`, which `Project.app` sets to the project name, so Novel Forge currently installs
  as "NovelForge" while its screens say "Novel Forge". Decide the name and change it in `Project.app` if it should differ.
- [ ] TestFlight groups per app: an internal group for the team (no review), and an external group whose first build goes through Beta App Review.
  Both apps reach Mac testers through TestFlight for Mac.

## 3. Decisions and checks only the owner can make

### App Privacy labels

Both privacy manifests declare no tracking, no tracking domains and no collected data types; the reasons for their required-reason APIs are in
[`privacy-manifests.md`](privacy-manifests.md). The labels in App Store Connect are the owner's answer and must agree with the manifests and with
what the apps do:

- Neither app has an account, analytics, advertising, crash reporting or a server of the developer's. Nothing reaches the developer.
- AI requests go from the owner's device to the provider the owner chose (Anthropic or OpenRouter), under the owner's own key and only for the
  kinds of data the owner allowed in AI settings; OpenRouter passes a request on to the company that runs the chosen model. In Memoir that can
  include journal text, activity and health data, under their own consents. Whether a provider the owner signs up with themselves counts as the
  developer's third-party partner is the question the labels turn on.
- Sync goes, encrypted on the device, to the storage the owner chose (their iCloud private database, an S3 bucket or a local folder).
- Share Diagnostics hands a zip to the share sheet only when the owner taps it; it holds counts, flags, codes and scrubbed log lines, never content
  or keys. If the owner asks people to send it to a support address, decide whether that is collection.

- [ ] Labels answered for Novel Forge.
- [ ] Labels answered for Memoir.

### Age rating

- [ ] Novel Forge, standard build: the writing comes from the owner's own model provider through standard routes, which the hard line does not
  screen. Answer the questionnaire for AI-generated fiction the author steers.
- [ ] Novel Forge, unrestricted build (only if one ships): the plan asks for the highest rating, the declared-age gate (`AdultConfirmationModel`,
  off by default), a published contact address and the hard line as the filtering method.
- [ ] Memoir: it reads Health (steps, active energy, water, weight, resting heart rate, waist, sleep, workouts), never writes to it, and logs meals,
  money and journal entries. Answer the questionnaire's health and wellness questions accordingly.

### Export compliance

- [ ] Classify the encryption. Both apps encrypt sync data end to end on the device with CryptoKit (ChaChaPoly, HPKE, Curve25519, HKDF, HMAC) in
  `ShadowSync`, besides HTTPS through the system. The answer becomes `TUIST_USES_NON_EXEMPT_ENCRYPTION` (`true` or `false`), written into each
  build as `ITSAppUsesNonExemptEncryption`; any documentation it requires goes to App Store Connect.

### Pages, contact, icons and categories

- [ ] A privacy policy URL and a support URL for each app (App Store Connect requires the privacy policy; Memoir's Health access does too) and a
  contact address. Set them in App Store Connect and in each app's `AppIdentity` (`privacyPolicyURL`, `supportURL`, `contactAddress` in
  `NovelForgeIdentity.swift` and `MemoirIdentity.swift`); About shows a row only for a value that is set. The policy must agree with the About
  screen's "What leaves this device" and with the App Privacy labels.
- [ ] Final icons: replace `AppIcon-1024.png` (1024 pixels, also the Mac's 512@2x) and `AppIcon-mac-512.png` in each app's
  `Resources/Assets.xcassets/AppIcon.appiconset`, opaque. The current ones are placeholders from `mise run icons:placeholder`.
- [ ] Categories: the App Store primary and secondary category in App Store Connect, and the Mac's `LSApplicationCategoryType` through
  `Project.app(category:)` (now Novel Forge Productivity, Memoir Lifestyle, both provisional).
- [ ] Purpose strings: the camera wording of both apps and Memoir's Health wording in their `Project.swift` are drafts.

### Notes for App Review

App Review has no key for a model provider, so both apps carry a demo: sample content with answers scripted on the device, no key, nothing sent
anywhere, and the owner's own data untouched. Draft for the review notes, to adjust before sending:

> **Novel Forge.** On first launch the library is empty and shows a welcome. Tap **Try the Demo**. (It is also offered in AI settings and in the
> sheet that opens when an AI action finds no provider, as "Try without a key".) A "Demo" badge appears at the top. Open the sample novel
> *The Salt Clock*, then in Chat ask, for example, "What should happen next?" or "Tell me about the cast"; use Plan next chapter, generate
> chapter 1, approve and finalize it. The first request asks permission to use the novel's text; in the demo that permission says nothing is
> sent. Answers come from a script on the device: no account or key is needed and nothing leaves the device. **Leave Demo** at the top deletes
> everything made in the demo and returns to the empty library.
>
> **Memoir.** On first launch Memoir asks five setup questions (day, first quest, schedule, strictness, ready); answer them with any values. Then
> open Settings from Today's toolbar on iPhone (the sidebar on iPad and Mac) and tap **Try the demo**, or open Ask, which offers it while no
> provider is connected. On the Mac, the Settings window's AI tab offers it at any time. The demo opens a sample week of quests, expenses,
> journal entries and meals; Ask and receipt reading answer from a script on the device, and Health, reminders and sync are off in it. Nothing
> is sent anywhere. **Leave Demo** deletes the demo's data and returns to your own.

The `-ShadowDemo` launch argument enters the demo too, but only for UI tests and local runs; App Review launches the app from the home screen.

- [ ] Notes approved and entered for Novel Forge.
- [ ] Notes approved and entered for Memoir.

### Reviews and device checks still open

- [ ] Phase 0 beta review: a TestFlight build sent to Beta App Review that describes unrestricted writing and entering one's own provider key.
  Record the result here. Until App Review accepts a build containing unrestricted writing, store builds leave `TUIST_UNRESTRICTED` unset.
- [ ] Before any build with `TUIST_UNRESTRICTED=1`: CI never compiles with `SHADOW_UNRESTRICTED`, so run
  `swift test --package-path Packages/NovelForgeKit -Xswiftc -DSHADOW_UNRESTRICTED` and, generated with the variable,
  `tuist test NovelForge --platform macOS --no-selective-testing`.
- [ ] OpenRouter sign-in on a device: Sign in with OpenRouter in AI settings must come back to the app through the custom-scheme callback
  (`com.shadow.apps.<app>://openrouter-sign-in`), which OpenRouter has not been confirmed to accept. If it does not, hide the button; the fallback
  is a flow in which the owner pastes the returned code, which is not built. Pasting an OpenRouter key works either way.
- [ ] Consent wording. The disclosures under-name what is sent and await the owner's approval of new wording: Novel Forge's novel-text disclosure
  leaves out parts of the context it sends (story settings, style instructions, plans, canon state, summaries and drafts, check findings);
  Memoir's journal disclosure implies a reason tag needs journal consent, when it goes under the base insight consent, and its base list leaves
  out some of what insights read; no disclosure mentions scheduled nightly runs or OpenRouter passing requests on. New wording raises the
  disclosure versions, so owners are asked again.
- [ ] [`hardware-checklist-phase8.md`](hardware-checklist-phase8.md): continued processing, the Mac worker and hand-off on real devices.
- [ ] [`hardware-checklist-memoir.md`](hardware-checklist-memoir.md): onboarding with sync, store routes, Health, reminders, receipts, insights,
  export and deletion. Its "Needs a decision" section holds Memoir's other owner decisions (HealthKit for the team, the exchange-rates service,
  Health background delivery and more).

## 4. Known follow-ups that matter for a release

None blocks a TestFlight build; each changes what a reviewer or a first owner may meet.

- Memoir's onboarding offers no demo: on iPhone and iPad App Review must finish the five setup steps before Settings or Ask can offer it (the
  notes above say so). Offering it on the first onboarding step would remove the detour.
- Both apps ask OpenRouter for its model list at launch whenever an OpenRouter key is stored, also while Anthropic is the chosen provider. The
  request carries the key and no content.
- The About screen's keychain line names "storage credentials" among what iCloud Keychain keeps; once a storage provider that signs in with
  OAuth ships (its tokens stay on the device), that line must narrow to S3 keys.
- The Novel Forge app tests cover an isolated draft's summary only while unrestricted writing is unavailable (`AmendSummarizeTests`); add the
  counterpart under `.enabled(if: UnrestrictedWriting.isAvailable)` before an unrestricted build.
- Memoir's Ask screen and nightly question ask only whether a provider's key is stored (`hasUsableProvider`), not whether OpenRouter has a model
  for any pace, so OpenRouter connected without models shows Ask as ready and fails at the call.
- The known follow-ups of [`hardware-checklist-phase8.md`](hardware-checklist-phase8.md) and
  [`hardware-checklist-memoir.md`](hardware-checklist-memoir.md), of which these touch a first owner most: a synced Undo of a quest log can delete
  another device's newer log and grant XP twice; the home currency can be replaced by a later write from another device; tapping a reminder does
  not open its quest; a vault with Activity or Health routes cannot move to another storage; a job run iOS gave no background time keeps its
  lease up to 6 minutes after the app is suspended.
