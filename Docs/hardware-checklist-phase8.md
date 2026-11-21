# Hardware checklist: iPhone and hand-off

Checks that need real devices and cannot be simulated: continued processing on iPhone, a Mac as the vault's worker, and handing a chapter job between
them. The package suites (`HandOff` in `NovelForgeCoreTests`) and the app tests already cover the logic with fakes; this list covers what only the
system does.

Run the sections in order; each one leaves the devices ready for the next. Write the result of each check in its last column (pass, fail, or what
happened instead), and note anything unexpected below the table.

Timings to keep in mind: a job lease lasts 6 minutes and is renewed every 2; a worker Mac with no window polls sync every 45 seconds; an expired
continued-processing task waits at most 5 seconds for its run to stop; quitting the Mac app waits at most 3 seconds for its runs.

| Run | Value |
| --- | ----- |
| Date | |
| Commit | |
| Mac model and macOS version | |
| iPhone on iOS 26 (model) | |
| iPhone on iOS 27 (model) | |
| Second Mac, if any (model and macOS version) | |
| Sync storage (iCloud or S3) | |

## 1. Signed build, devices and shared sync

Needs an Apple Developer team, an AI provider key, a sync location both devices can reach, a Mac, and an iPhone on iOS 26 and one on iOS 27 (or one
iPhone run through section 4 once per version).

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 1.1 | Export `TUIST_DEVELOPMENT_TEAM`, run `mise run bootstrap`, then build and install Novel Forge on the Mac and on each iPhone. | Builds sign and install with no manual entitlement or Info.plist edits. | |
| 1.2 | Inspect the iPhone app's `Info.plist` (`plutil -p` on the built `.app`). | `BGTaskSchedulerPermittedIdentifiers` holds `com.shadow.apps.novelforge.job.*`; `UIBackgroundModes` holds only `remote-notification`; `ShadowCapabilities` lists the signed capabilities. | |
| 1.3 | On the Mac, turn sync on and create the vault; on each iPhone, join it. | Every device syncs; the sync indicator reads up to date. | |
| 1.4 | Enter the AI provider key on the Mac; wait a minute and open AI settings on the iPhone. | The key reaches the iPhone through iCloud Keychain; if not, enter it there and note it. | |
| 1.5 | Give AI consent for the test novel on the Mac. | Consent syncs; the iPhone does not ask again for that novel. | |
| 1.6 | On the Mac, open Settings, Devices and Worker. | Every device is listed by its name, this Mac first; No Mac runs jobs. | |

## 2. Mac worker mode and login item

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 2.1 | Before turning anything on, open System Settings, General, Login Items. | Novel Forge is not listed: launching the app registered nothing. | |
| 2.2 | Turn on Run Jobs on This Mac. | The Mac is marked Runs Jobs; a menu-bar item appears with "No jobs to run"; Novel Forge now appears in Login Items. | |
| 2.3 | If the page asks to allow Novel Forge in Login Items, tap Open Login Items Settings, allow it, and come back. | System Settings opens on Login Items; back in the app the page reads "Opens when you log in." | |
| 2.4 | On the iPhone, open AI settings, then Devices and Worker. | Read-only page: "Jobs run on" the Mac's name; no switch. | |
| 2.5 | On the Mac, close every Novel Forge window. | The app keeps running; the menu-bar item stays. | |
| 2.6 | Choose Open Novel Forge from the menu-bar item twice. | One library window comes forward; no duplicate window. | |
| 2.7 | Leave the Mac windowless for 10 minutes, then check Activity Monitor's App Nap column. | App Nap reads No. | |
| 2.8 | While no job runs, run `pmset -g assertions`. | Novel Forge holds no idle-sleep assertion (its activity allows idle sleep). | |
| 2.9 | Cmd-drag the menu-bar item out of the menu bar. | Worker mode stays on and jobs keep running; note whether the item comes back on its own or at the next launch. | |
| 2.10 | Log out and back in (or restart) with worker mode on. | Novel Forge opens at login with no window, only the menu-bar item; it picks up queued jobs within about 45 seconds. | |
| 2.11 | Click Novel Forge in the Dock. | A library window opens. | |
| 2.12 | Quit, then launch Novel Forge by hand with worker mode still on. | Only the menu-bar item shows until a Dock click; note whether this is acceptable for a manual launch, and whether windows restore as they were. | |

## 3. Phone and Mac hand-off

The phase's first done-when: a chapter requested on the phone is written by the Mac and approved on the phone. Worker mode stays on (section 2).

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 3.1 | On the iPhone, open the test novel and ask to generate the next chapter. | The phone starts nothing; the chapter's line reads "Waiting for" the Mac's name. | |
| 3.2 | Watch the Mac, windowless. | Within about 45 seconds the run starts; the menu-bar status names the job and its steps as they change. | |
| 3.3 | During the run, run `pmset -g assertions` on the Mac. | Novel Forge holds an assertion preventing idle sleep, released when the run ends. | |
| 3.4 | Watch the iPhone's chapter line during the run. | It names the Mac, the step, and when the lease was renewed. | |
| 3.5 | When the draft lands, open the chapter from Waiting on you on the iPhone and ask for its editorial and continuity reviews in Checks. | The reviews queue for the Mac and run there; their findings reach the phone. | |
| 3.6 | Approve the draft on the iPhone, settle its Story Bible updates and finalize. | The finalize review and the Story Bible refresh run on the Mac; the final chapter and the refreshed Story Bible show on both devices. | |
| 3.7 | Start another chapter from the iPhone; once the Mac runs it, close the Mac's lid for more than 6 minutes. | When the lease lapses, the iPhone offers Run on This Device. | |
| 3.8 | Tap Run on This Device, then open the Mac's lid. | The phone continues the run; the Mac stands down after at most its call in flight; one draft results, with no step written twice. | |
| 3.9 | Start another chapter from the iPhone; mid-run, choose Quit Novel Forge from the Mac's menu-bar item. | The Mac quits within a few seconds; after the next sync the iPhone offers Run on This Device at once, without waiting for the lease. | |
| 3.10 | With a second Mac on the same vault, turn on Run Jobs on This Mac there. | The first Mac turns worker mode off with a notice naming the second; queued jobs now run on the second Mac. | |
| 3.11 | Turn worker mode back on on the first Mac. | The second Mac turns off with the matching notice. | |

## 4. iOS continued processing

The phase's second done-when: the same chapter written by the phone alone survives the app leaving the screen. Quit Novel Forge on the Mac first, so
nothing else runs the job. Run this section on iOS 26 and on iOS 27, since the app submits the request differently on each.

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 4.1 | On the iPhone, ask for a chapter, tap Run on This Device, and go to the Home Screen at once. | The submission is accepted with no background-mode entry (1.2); the system's progress UI shows "Writing chapter" and its number, the step as its subtitle, and progress that only grows. If the request is refused as not permitted, record it: the capability then needs a background mode. | |
| 4.2 | Leave the phone locked until the run ends. | The run finishes in the background; the draft is there when the app opens; the task ends as successful. | |
| 4.3 | Note how long the progress UI waits before the first output arrives. | The system does not treat the wait before the first token as a stall; if it expires the task, record after how long. | |
| 4.4 | Turn on Low Power Mode and run a chapter in the background. | The run finishes, or the system expires it; record which, and at which step. | |
| 4.5 | Reopen the Mac app (worker mode on). Start a run on the iPhone, go home, and cancel the task from the system UI. | Within 5 seconds the task ends; the iPhone's line offers Resume; the lease is released, so after the next sync the Mac takes the job over. | |
| 4.6 | Tap Resume on the iPhone. | A new progress UI appears for the same attempt; the Mac's run stands down. Quit the Mac app again. | |
| 4.7 | Start runs for two chapters, then go home. | Two progress UIs, each with its own title and progress; both finish. | |
| 4.8 | Let a run's task expire (or cancel it), then tap Resume. | The resumed run is submitted again and shows the progress UI. | |
| 4.9 | Start a run, then swipe the app away in the app switcher. | At the next launch the line offers Resume; after resuming, no step ran twice and its charges are counted once. | |
| 4.10 | Ask for a plan and force-quit the app before the run starts, then launch it. | The plan runs with the in-app "Keep Novel Forge open until this finishes." notice and no system progress UI. | |
| 4.11 | Ask for a new plan after launch, then go home. | That plan gets the system progress UI. | |
| 4.12 | Install a new build over the current one, then cold-launch it; force-quit and cold-launch again. | No crash at launch from registering the task identifier twice. | |
| 4.13 | In Console, follow the Novel Forge process during a run. | The system's background-task log names the task `com.shadow.apps.novelforge.job.` followed by the attempt id; the app logs no "not in the Info.plist wildcard" error. | |

## 5. Team-less build

| # | Step | Expected | Result |
| - | ---- | -------- | ------ |
| 5.1 | Unset `TUIST_DEVELOPMENT_TEAM`, run `mise run bootstrap`, and build the Mac app and the iOS Simulator app. | Both build with no signing team; no iCloud, push or keychain-sharing entitlement is emitted. | |
| 5.2 | Launch the Mac app. | The vault opens; the sync indicator says "Sync needs a signed build" and the sync settings offer nothing to connect. | |
| 5.3 | Turn on Run Jobs on This Mac. | Worker mode turns on and runs jobs; the page says "This build can't open at login". | |
| 5.4 | In the iOS Simulator, start a job with Run on This Device. | The request is refused as unavailable; the line says "Keep Novel Forge open until this finishes." and the run goes on while the app is open. | |

## Known follow-ups

Open behaviour that these checks may run into; none blocks the phase.

- A run that iOS gave no background time (automatic, or its request refused) keeps its lease when the app is suspended, so another device can take
  it over only after the lease lapses, up to 6 minutes. A short background task that interrupts and releases it would close the gap.
- Run progress is tallied in memory: after a relaunch a resumed run's progress starts again, and steps still ahead are counted at their full output
  cap, so progress reads low until they run.
- A run interrupted mid-call leaves that call pending in the chapter's run charges.
- A job line's "last updated … ago" refreshes only when the line is drawn again, not on a timer.
- Try Again and Read Again start the job on the device they are tapped on, an iPhone included; whether a phone should queue them for the worker
  instead is undecided.
- While worker mode is on, a manual launch also opens no window (only a login launch needs that); whether to suppress the window only at login is
  undecided.
- Waiting on you leaves out chat questions and unanswered messages (the chat's tray shows them), and is per novel, not across the library.
- No presence record says when the worker Mac was last seen, so a phone cannot tell a sleeping worker from a running one.
- Writes clear a read-only state GRDB can leave on the connection under load (see `ShadowStore` in the README); the root cause is unreported upstream.
