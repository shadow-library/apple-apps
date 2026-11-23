# Hardware checklist: Memoir on iPhone, iPad and Mac

Checks that need a signed build on real devices and cannot be simulated: onboarding with sync, the store routes on iCloud and on an unrestricted
provider, Apple Health, local notifications, the document camera and Vision, insights against a real provider, the export sheets, deleting the
vault and the exchange-rates service. The package suites (`MemoirKit`, `ShadowKit`) and the Memoir app tests cover the logic with fakes and in-memory stores; this list covers what
only the system does.

Run the sections in order; each one leaves the devices ready for the next. Write the result of each check in its last column (pass, fail, or what
happened instead), and note anything unexpected below the table.

Timings to keep in mind: an app in front uploads 2 seconds after a write and downloads every 45 seconds; a device waiting for the vault's key looks
again every 30 seconds; a Health import reads the last 7 days (a new reader's first sample read reaches back up to a year); at most 60 reminders are
pending at once (iOS keeps 64); a receipt image is at most 3,000 pixels a side and 8 MiB; a blob nothing names is removed from storage 30 days after
it was last named.

The Mac keeps the vault under `~/Library/Containers/com.shadow.apps.memoir/Data/Library/Application Support/com.shadow.apps.memoir/Vaults/`:
`Default/` (main), `Default-activity/` and `Default-health/`.

| Run | Value |
| --- | ----- |
| Date | |
| Commit | |
| iPhone (model and iOS version) | |
| Second iPhone or iPad (model and version) | |
| Mac (model and macOS version) | |
| Sync storage for section 3.2 (S3 or folder) | |
| AI provider | |

## 1. Signed build

Needs an Apple Developer team with HealthKit enabled for `com.shadow.apps.memoir`, the iCloud container `iCloud.com.shadow.apps.memoir`, an iPhone
with a week or more of Health data (steps, active energy, water, weight, resting heart rate, sleep, workouts), a second iOS device, and a Mac.

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1.1 | Export `TUIST_DEVELOPMENT_TEAM`, run `mise run bootstrap`, then build and install Memoir on the iPhone, the second device and the Mac. | Builds sign and install with no manual entitlement or Info.plist edits. | |
| 1.2 | Inspect the iPhone app's `Info.plist` (`plutil -p` on the built `.app`). | `UIBackgroundModes` holds only `remote-notification`; `NSHealthShareUsageDescription` and `NSCameraUsageDescription` are there and `NSHealthUpdateUsageDescription` is not; `ShadowCapabilities` lists `CloudKitContainer`, `PushNotifications`, `SharedKeychainGroup` and `HealthKit` = `YES`. | |
| 1.3 | Inspect the iPhone app's entitlements (`codesign -d --entitlements - Memoir.app`). | `com.apple.developer.healthkit` is present; `com.apple.developer.healthkit.background-delivery` is not. | |
| 1.4 | Inspect the Mac app's `Info.plist` and entitlements. | `ShadowCapabilities.HealthKit` is `NO`; no HealthKit entitlement; the app sandbox is on. | |

## 2. First run and onboarding

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 2.1 | Launch Memoir on the iPhone for the first time, with no sync set up. | Onboarding shows instead of Today; nothing is written until the last step. | |
| 2.2 | Walk the five steps (day, first quest, schedule, strictness, ready); pick a home currency and a time zone other than the device's. | Each step refuses an invalid value inline (a sleep window under 3 or over 14 hours, an anchor without a time); Ready finishes; Today shows the first quest in the chosen zone's day. | |
| 2.3 | Relaunch the app. | Today opens directly; onboarding never comes back. | |
| 2.4 | In Settings, check the home currency. | It is shown and cannot be changed. | |
| 2.5 | Turn sync on with iCloud on the iPhone (Settings, Sync). | The vault is created at iCloud; the indicator reads up to date. | |
| 2.6 | On the second device, launch Memoir for the first time with the same Apple Account. | iCloud attaches on its own; onboarding shows, but Ready waits while sync brings data or the vault's key ("waiting" state). | |
| 2.7 | Give the second device the key (recovery phrase, or the QR exchange with the iPhone). | The first device's data arrives and onboarding gives way to Today with the same quest, zone and home currency; no second first quest exists. | |
| 2.8 | On the Mac, launch and join the same way. | Same as 2.6 and 2.7; the Mac shows the sidebar (Day, Capture, Reflect, Hero, Settings). | |
| 2.9 | Before unlocking the iPhone after a restart, send it a silent push (write on the Mac). Then unlock and open the app. | Nothing crashes; the app opens the vault once the device is unlocked ("Unlock this device to open your data" until then). | |

## 3. Sync routes

### 3.1 iCloud

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 3.1.1 | With Activity off (the default), log a weight with a distinctive value (for example 87.65 kg) and a day of steps on the iPhone. | Both show on the iPhone only; the second device and the Mac never show them. | |
| 3.1.2 | On the Mac, log a weight with another distinctive value. Search the main store: `grep -c '<value>' Default/vault.sqlite*`, then `Default-health/health.sqlite*`. | Zero hits in the main store's files; hits in the health store. | |
| 3.1.3 | In CloudKit Console, list the vault zone's `VaultObject` records by `path`. | No path starts with `stores/health/` or `stores/activity/`. | |
| 3.1.4 | Turn Activity on in Sync Settings on the iPhone. | Steps and workout minutes reach the other devices within a minute; weight and every health-class metric do not. CloudKit now holds `stores/activity/` objects and still no `stores/health/`. | |
| 3.1.5 | Turn Activity off again while the iPhone has activity changes waiting (log steps in airplane mode, turn Activity off, then go online). | Sending activity stops at once (at most one upload in flight lands); the activity records stay on the iPhone; nothing more appears under `stores/activity/`. | |
| 3.1.6 | Check the activity and health store directories' backup flag on the iPhone (Finder or `xattr` on a device backup). | Both are excluded from device backups whether or not Activity syncs. | |

### 3.2 Unrestricted provider (S3 or a folder)

Use a fresh install on a Mac and an iPhone (delete and reinstall Memoir). A first launch attaches iCloud on its own, so either sign those devices
out of iCloud first or disconnect iCloud in Sync Settings before writing anything, and note what the page offers.

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 3.2.1 | Turn sync on with S3 on the Mac, create the vault, and join it from the iPhone. | Both devices sync; the indicator reads up to date. | |
| 3.2.2 | Log a weight, steps and a journal entry on the iPhone. | All three reach the Mac. The bucket holds the primary's objects plus `stores/activity/` and `stores/health/` under the key prefix. | |
| 3.2.3 | Write on the Mac while the iPhone is offline, then bring it online. | Every store catches up; the indicator shows attention only for a store that has a problem, naming its data. | |

### 3.3 Moving a routed vault

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 3.3.1 | In Sync Settings on the Mac, look for Move to Another Storage. | It is not offered; the page says the vault syncs stores a move cannot carry yet. | |

## 4. Apple Health

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 4.1 | On the iPhone, open Body & health and turn on Steps. | The system asks for Steps only; the iPhone becomes the vault's reader ("<name> reads Apple Health for this vault"). | |
| 4.2 | Turn on each other metric in turn, allowing some and denying one. | Each asks for its own type; the denied one shows "No Health data yet" with a link to Health settings, and typing a value still works. | |
| 4.3 | Wait for the import, or tap Read Health now. | The last 7 days fill for every allowed metric, matching the Health app's daily totals (steps, energy, water) and latest values (weight, resting heart rate, waist); sleep and workouts in minutes. | |
| 4.4 | Type your own value for a day Health filled. | Your entry shows; after another import it still wins; clearing it brings the Health value back. | |
| 4.5 | Delete a sample in Health, then reopen Memoir. | That day's imported value updates or disappears. | |
| 4.6 | On the second iOS device, turn on a metric. | It asks before taking over ("Read Health on this device instead?"); after Read here instead, the iPhone stops importing at its next import and what it imported stays. | |
| 4.7 | On the Mac, open Body & health. | "Health data is read on your iPhone or iPad."; no prompt. | |
| 4.8 | Lock the reader and wait for a silent push from a write on the Mac. | No Health read happens in the background (background delivery is off); the next unlock and open imports. | |
| 4.9 | Turn every metric off on the reader. | It gives the role up; another device can turn a metric on without a takeover question. | |

## 5. Reminders

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 5.1 | In Settings, Reminders, on each device, check "Remind me on this device". | On by default on the iPhone only; off on the iPad and the Mac. | |
| 5.2 | Give a quest a reminder with a time and a lead on the iPhone. | Permission is asked once, only now (on, and the plan holds a reminder); denying it shows that in Settings. | |
| 5.3 | Allow it and wait for the reminder. | It fires at start minus lead to the minute, in the account's zone, with the quest's name; an untimed quest's reminder fires at the start of the wake window. | |
| 5.4 | Give a subscription a reminder. | It fires at the start of the wake window on the reminder day, with the amount in the subscription's currency. | |
| 5.5 | Run 5.3 across a daylight-saving change in the account's zone (a reminder the morning after, one inside a skipped hour, one inside a repeated hour). | Each fires at its wall-clock time; one in a skipped hour fires at the transition; one in a repeated hour fires at the earlier instant. | |
| 5.6 | Let a reminder fire, then complete that occurrence on the Mac; wait for the iPhone to sync. | The iPhone removes the delivered notification from Notification Center; a later reminder for an occurrence completed elsewhere is withdrawn before it fires. | |
| 5.7 | Reschedule an occurrence to a later minute on another device. | The iPhone's reminder moves to the new minute. | |
| 5.8 | Turn "Remind me on this device" off on the iPhone. | Every pending request is withdrawn; nothing more fires there. | |
| 5.9 | Create more than 60 reminders in the coming days. | At most 60 are pending; Settings says how many the limit leaves out. | |

## 6. Receipts

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 6.1 | On the iPhone, create an expense and add a receipt with the document camera. | VisionKit's document scanner opens; the scanned page is attached upright. | |
| 6.2 | Add one from the photo library and one from Files on the Mac. | Both attach; a large photo is reduced to at most 3,000 pixels a side; the attached file carries no location metadata (check with `exiftool` after exporting). | |
| 6.3 | Read a receipt with no AI provider connected. | Text is recognised on the device; structuring needs a provider and the receipt-text consent, and nothing is sent before both. | |
| 6.4 | Connect a provider (section 7.1), give the receipt-text consent, and read a receipt in the home currency. | Merchant, date, total and category are offered; the form fills only when you accept; only the recognised text was sent (check the provider's request log if it has one). | |
| 6.5 | Read a receipt in a currency the vault has not enabled. | No total is offered and the form's currency does not change. | |
| 6.6 | Save the expense; open it on the second device. | The receipt viewer downloads the photo (progress, then the image); zoom by pinch and double tap; share as `Receipt.jpg`. | |
| 6.7 | Open the receipt on a device that has not got the vault's key yet. | The viewer says this device lacks the key, not that the image is damaged. | |
| 6.8 | Delete the expense. | The receipt goes with it; Undo is not offered for an expense with a receipt. | |

## 7. Insights

### 7.1 Provider and consent

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 7.1.1 | Enter the AI provider key on the iPhone (Settings, AI). Wait a minute and open AI settings on the Mac. | The key reaches the Mac through iCloud Keychain; if not, enter it there and note it. | |
| 7.1.2 | Ask a question on the Ask screen. | The consent sheet asks for the call first; nothing is sent before it is given. | |
| 7.1.3 | With journal and health consent off, ask a question about your mood and your weight. | The answer uses no journal text and no activity or health data. | |
| 7.1.4 | Turn both consents on and ask again. | The answer may cite them; an answer that read health data is stored in the health store and never syncs over iCloud. | |
| 7.1.5 | Cancel a question while it runs, then Ask again. | It stops; asking again starts a new run; costs are listed per answer and against the caps. | |
| 7.1.6 | Tap a suggestion. | It opens the quest builder or the quest; nothing is applied until you save. | |

### 7.2 Nightly question

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 7.2.1 | Set the nightly question to a minute a few minutes ahead, then leave the app in the background past that minute. | Nothing runs in the background. | |
| 7.2.2 | Bring the app to the front. | The night's question runs once, on this device; another device opened later does not run it again. | |
| 7.2.3 | Set the minute to one already past today. | Setting it does not run tonight's question at once. | |

## 8. Export

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 8.1 | On the iPhone, open Settings, Data and privacy, Export, and build the archive. | The screen says the archive is not encrypted; the archive is offered once built. | |
| 8.2 | Tap Save, choose Files, and save it. | The save sheet saves the zip; returning from the sheet keeps the archive (Save and Share still work). | |
| 8.3 | Tap Share and send it to another app (AirDrop to the Mac). | The share sheet receives the zip whole; after it closes the screen still offers the archive. | |
| 8.4 | Unzip it on the Mac. | `memoir-export.json` (format `com.shadow.apps.memoir.export`, version 1, all three stores, this device's weekly review answers) and `receipts/<blob id>.<ext>` for each receipt image this device holds. | |
| 8.5 | Leave the screen, then check the app's temporary folder (Xcode, Devices, download the container). | No archive remains under `tmp/com.shadow.apps.memoir.exports/`. | |
| 8.6 | Build an archive, force-quit the app, restart the phone, and launch Memoir before unlocking (from a notification), then after unlocking. | The leftover archive is removed at the next launch that can reach it; nothing crashes before unlock. | |

## 9. Vault deletion

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 9.1 | On the iPhone, open Settings, Data and privacy, Delete vault. | Two statements, the typed word `DELETE` and a last answer are asked; Stop here clears the statements. | |
| 9.2 | Delete. | An alert says what happened; onboarding shows; every pending and delivered Memoir notification is gone; Settings shows sync off. | |
| 9.3 | Check the other devices and the storage. | They keep every record; iCloud (or S3) still holds the vault's objects, all three stores included; nothing at the provider was deleted. | |
| 9.4 | Check what stays on the iPhone. | The AI provider key, the vault's ring keys and sync credentials stay in the keychain; the Health and notification permissions stay; "Remind me on this device", the weight unit and the Health metric choices are reset. | |
| 9.5 | Turn sync on again to the same storage on the iPhone. | It finds the vault and joins it with the key already held; the data comes back and onboarding gives way. | |

## 10. Team-less build

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 10.1 | Unset `TUIST_DEVELOPMENT_TEAM`, run `mise run bootstrap`, and build the Mac app and the iOS Simulator app. | Both build with no signing team; no iCloud, push, keychain-sharing or HealthKit entitlement is emitted. | |
| 10.2 | Launch the Mac app and complete onboarding. | The vault opens and works on its own; the sync indicator says "Sync needs a signed build". | |
| 10.3 | Open Body & health in the iOS Simulator. | "This build of Memoir can’t read Apple Health. Type your metrics by hand." | |

## 11. Exchange rates

Needs a network and a home currency other than the expenses' (a euro vault spending in kroner, say). Compare each rate with the European Central
Bank's reference rates for that day (`https://api.frankfurter.dev/v2/providers/ecb/rates?date=<day>&base=NOK&quotes=EUR`).

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 11.1 | With Settings, Money, "Fetch exchange rates" on, add an expense in kroner dated a past weekday. | Within seconds it shows its euro amount at that day's rate (rounded to eight places) and joins the month's total; "Rate pending" goes. | |
| 11.2 | Add one dated a Saturday, and one dated today before 16:00 in Frankfurt. | Saturday's converts at Friday's rate at once; today's stays "Rate pending" until the day's rate is published (asked again within the hour while the app is open). | |
| 11.3 | Watch the traffic with a proxy (Proxyman or Charles) while adding one. | Only `GET api.frankfurter.dev/v2/providers/ecb/rates` with `date`, `base` and `quotes` leaves; no amount, note, merchant or vault id. | |
| 11.4 | Turn "Fetch exchange rates" off on the iPhone; add another expense in kroner. | No request leaves; the expense stays "Rate pending". The setting is per device: the Mac still fills it if it is open with the setting on. | |
| 11.5 | Long-press the pending row (or open it and tap Enter the rate), type `0,0875` in a German locale and save. | It converts at the rate you entered, the detail says so and its history shows "Rate you entered added"; turning fetching on again never replaces it. | |
| 11.6 | Enter a rate on one device while the other, offline, has the same expense pending; bring the other online with fetching on. | Both converge on the rate you entered; the fetched rate is recorded for the day but not used for that expense. | |
| 11.7 | Add a subscription in kroner with no krone expense yet. | Its monthly cost shows "≈ … a month" within seconds, at yesterday's rate. | |
| 11.8 | Turn on airplane mode, add a krone expense, then turn it off with the app open. | Nothing blocks the form; the expense converts within a few minutes (the retry waits 1, 2, 4… minutes, at most an hour). | |
| 11.9 | Open the demo. | No request leaves (11.3's proxy stays quiet); the demo's Settings show no "Fetch exchange rates". | |

## Known follow-ups

Open behaviour that these checks may run into; none blocks these checks.

- A vault that syncs its activity and health stores cannot move to another storage yet: a move would carry only the main store.
- Stopping a route waits for a download pass in flight to finish; the engine's halt has no unit test of its own.
- Every write and each midnight rebuilds and compares all derived rows (about 2.8 s in a debug build for two years of data); an incremental diff and
  a release-build measurement are pending.
- The money reads and an expense's history decode the whole command log on each change they follow.
- `quest.deleteLog` names no expected log and replay never reverts the hero trail, so a synced Undo can delete another device's newer log and a
  re-completion grants XP twice (the reference has the same flaw).
- Replay accepts a `quest.update` schedule change on a locked day; a device that has not seen the lock can change today's plan.
- The home currency is first-writer only in the app; the settings record lets a later write replace it until a new registry version fixes it.
- Inactive quests cannot be reactivated from the app, though the reference promises it.
- Tapping a reminder opens the app without taking it to the quest or subscription.
- A delivered reminder stays when its quest's reminder was turned off before completion, when its subscription is deleted or paused, and for a missed
  occurrence; an overdue cycle left unconfirmed is never reminded again.
- A command that replay refuses after a merge shows no "changed on another device" notice, except a withdrawn purchase on the Hero screen.
- An insight run that iOS suspends in the background resumes at a later launch rather than finishing in the background; the hero trail is rewritten
  whole when it changes.
- Journal entries keep no draft; quest thresholds are not shown in the metrics read; a side quest's stat is not on its record.
- Two iPhones both report the generic name "iPhone", so the Health reader's name can be ambiguous; a designation that arrives just after this device
  claimed the role can clear a metric just turned on.
- A blob part left half-written or a blob nothing names on this device is never swept locally; a large blob on a provider without put-if-absent
  restarts from its first part after a failure and holds text changes back meanwhile; a blob whose local file is permanently unreadable stays waiting.
- Releasing a blob compares peers' applied points without the base a peer adopted; that corner of the safety argument is still open.
- Key floors are recorded per store directory; key rotation will need to revisit them with routes.
- Coming back's choices push in place on iPhone rather than switching to the tab that owns them.
- The vault noun ("vault", "library") is passed to the shell untranslated.
- Subscription writes and category archiving live in the app rather than in `MemoirCore`; a deleted subscription is removed, not deleted outright as
  the reference does.

## Needs a decision

These need the owner before release; the build works without them.

- HealthKit entitlement for the team and App ID, and on-device runs with a signing team.
- Purpose strings: the HealthKit and camera wording in `Apps/Memoir/Project.swift` is a draft.
- A privacy policy URL, which Health requires for distribution.
- Health background delivery: off now, so Health is read only when the app opens.
- The monthly entry-cap note (100 a month, shown from 80%), kept from the reference's plan tiers that Memoir does not have.
- Onboarding stands in front of an empty vault; the plan opened on Today. Keep the gate, or make it a dismissable sheet.
- Deleting the vault removes it only from this device; deleting it at the provider needs a sync-kernel rule for deleting a whole vault. Also confirm
  that the AI settings, sync records and ring keys stay.
- AI provider keys for end-to-end insights and receipt structuring, and whether running the nightly question only at the next foreground is enough.
- Whether a timed quest's reminder should fire outside the wake window (it does now).
- The iCloud container `iCloud.com.shadow.apps.memoir` for the team.
