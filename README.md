# Shadow Library — Apple Apps

Monorepo for every Shadow Library app on Apple platforms (iOS, iPadOS, macOS, watchOS, tvOS, visionOS) and the Swift packages they share.

## Requirements

- Xcode 27 (Swift 6.2+)
- [mise](https://mise.jdx.dev) — pins Tuist and runs the repo tasks: `brew install mise`

## Getting started

```sh
mise install          # installs the pinned Tuist
mise run bootstrap    # resolves packages and generates ShadowLibrary.xcworkspace
open ShadowLibrary.xcworkspace
```

Xcode projects and the workspace are generated from Swift manifests and are never committed. Re-run `tuist generate` after changing any
`Project.swift`, `Tuist/Package.swift` or helper; adding or removing source files does not need it, since targets use buildable folders.

To sign for devices, export your team before generating: `export TUIST_DEVELOPMENT_TEAM=ABCDE12345`.

## Layout

```
Apps/                         one folder per app, each with its own Project.swift
  Catalog/                    design-system gallery; also the pipeline's smoke test
  NovelForge/                 Novel Forge for iPhone, iPad and Mac (`.phoneAndMac`); vault opening and the library shell
Packages/
  ShadowKit/                  the shared Swift package (one library product per module)
  NovelForgeKit/              Novel Forge's core (`NovelForgeCore`): domain rules, pipelines, retrieval; no UI
  MemoirKit/                  Memoir's core (`MemoirCore`): calendar, rules, records; no UI
Tuist/
  Package.swift               external + local package dependencies for the apps
  ProjectDescriptionHelpers/  Project.app(...), shared settings, platform presets
  Templates/app/              scaffold used by `mise run new-app`
Tuist.swift  Workspace.swift  mise.toml  .swift-format
```

Bundle identifiers: apps are `com.shadow.apps.<app-name>` (lowercased, test targets add `.tests` / `.uitests`) and shared libraries are `com.shadow.library.<library-name>`.

## Shared modules

| Module               | Purpose                                                                     | Depends on                       |
| -------------------- | --------------------------------------------------------------------------- | -------------------------------- |
| `ShadowCore`         | `ShadowError`, `Logger(category:)`, `HybridLogicalClock`, `TrustedClock`, `UUIDv7Generator`, `derivedID`, `ReplicaID`, `JSONValue`, canonical JSON, HTTP dates | — |
| `ShadowNetworking`   | `APIClient` (async, typed throws), `Endpoint`, middleware, JSON coding, streaming transport and server-sent events, and an OAuth 2.0 client (`OAuth/`) | `ShadowCore` |
| `ShadowKeychain`     | `SecureStore` protocol and `KeychainStore` (data-protection keychain)       | `ShadowCore`                     |
| `ShadowStore`        | SQLite store through GRDB: `VaultStore`, `EntitySchema` and `SchemaRegistry`, `ChangeRecord`, per-field clocks and merge, snapshots, retention, upgrade, `VaultProcessLock` | `ShadowCore`, GRDB |
| `ShadowSync`         | Vault sync through a `StorageProvider` (`LocalFolderProvider`): `SyncEngine`, replica lifecycle, segment codec, encrypted vault files, key ring, recovery | `ShadowCore`, `ShadowStore`, `ShadowKeychain`, GRDB |
| `ShadowSyncS3`       | S3-compatible storage: `S3StorageProvider` (SigV4 signing, ListObjectsV2, conditional puts, DeleteObjects, `probeConditionalWrites()`), `S3Configuration` (endpoint, region, bucket, key prefix, addressing, conditional writes) and `S3Credentials` | `ShadowCore`, `ShadowNetworking`, `ShadowSync` |
| `ShadowSyncOneDrive` | OneDrive storage in the app folder: `OneDriveConfiguration` (Microsoft identity platform v2 sign-in, Graph), `OneDriveStorageProvider` with its delta-fed key index (`OneDriveStateStore`) | `ShadowCore`, `ShadowNetworking`, `ShadowSync` |
| `ShadowSyncGoogleDrive` | Google Drive storage in the app data folder: `GoogleDriveConfiguration` (Google sign-in, Drive v3), `GoogleDriveProvider` and its index store (`GoogleDriveStateStore`) | `ShadowCore`, `ShadowNetworking`, `ShadowSync` |
| `ShadowSyncCloudKit` | iCloud (CloudKit) storage; the only module that imports CloudKit: `CloudKitConfiguration` (container, zone), `CloudKitStorageProvider` with its key index (`CloudKitStateStore`), the `CloudKitZoneClient` seam and its CloudKit implementation `CKZoneClient` | `ShadowCore`, `ShadowSync` |
| `ShadowSyncRuntime`  | Non-UI sync runtime shared by the apps: provider setup, credentials, start-up and scheduling: `SyncLocation` and its store, `FirstUnlockProbe`, keychain credential stores, `VaultSetup`, `SyncStartup` and `SyncPhase` | `ShadowCore`, `ShadowKeychain`, `ShadowNetworking`, `ShadowStore`, `ShadowSync`, `ShadowSyncS3`, `ShadowSyncOneDrive`, `ShadowSyncGoogleDrive`, `ShadowSyncCloudKit` |
| `ShadowText`         | JavaScript semantics ported exactly: `JSText`, `JSString`, `JSNumber` and `String` helpers on UTF-16 code units, `OrderedJSON` with `jsonText`, and `JSRegex` (a backtracking engine for JavaScript patterns with `u` and `i` flags) | `ShadowCore` |
| `ShadowAI`           | `ModelProvider` with `AnthropicProvider` and `OpenRouterProvider`, `ModelCatalog` (task and pace to a model), `RetryingProvider`, structured calls, `Ledger` of model calls and spend, with `Ledger.reconcilePending` pricing OpenRouter calls after the fact | `ShadowCore`, `ShadowNetworking`, `ShadowStore` |
| `ShadowJobs`         | Durable background jobs: synced job and attempt records, derived status, leases, `AttemptRunner` with a local checkpoint | `ShadowCore`, `ShadowStore`      |
| `ShadowDesignSystem` | Tokens, Liquid Glass helpers and native-first SwiftUI components (see below) | —                                |
| `ShadowTestSupport`  | Test targets only: `JSOracle` (JavaScriptCore as a differential oracle) with `TextSamples`, `StubHTTPTransport` and streaming stubs, `InMemorySecureStore`, `InMemoryKeychain`, `InMemoryOAuthTokenStore`, `InMemoryStorageProvider`, `FaultInjectingStorageProvider`, `StorageProviderConformance`, `FakeCloudKitZone`, `ScriptedModelProvider`, `CausalReplicas`, `forAll`/`forAllConcurrently`/`replay` with `SeededGenerator` | `ShadowCore`, `ShadowNetworking`, `ShadowKeychain`, `ShadowStore`, `ShadowSync`, `ShadowSyncCloudKit`, `ShadowAI`, `ShadowText` |

Apps depend on modules through the typed helper, so a typo fails at manifest compile time:

```swift
let project = Project.app(
  name: "Memoir",
  platform: .multiplatform,
  dependencies: [.shared(.networking), .shared(.keychain), .shared(.designSystem)],
  testDependencies: [.shared(.testSupport)]
)
```

`VaultStore.open` on a file sets file protection `completeUntilFirstUserAuthentication` on the vault directory and on the database, `-wal` and `-shm` files, and fails with `StoreError.fileProtection` if it cannot (macOS has no such protection and skips it; in-memory stores are untouched). `SyncEngine.start()` (or `StorageAttachment.attach(_:)`) flags the vault directory as excluded from device backups, `StorageAttachment.detach(_:)` clears it, and a failure there is reported (`SyncEngine.backupExclusionFailure`, a log entry) without failing the attach (attach is idempotent and re-asserted on every start; clearing the flag is eventually consistent on macOS; a vault directory must hold only the vault's own files, the database with its `-wal`, `-shm` and `-journal` files and its process locks such as `<db>-jobs.lock`, or the flag is refused), since the flag is only guidance and the replica self-check carries correctness.

The OAuth client in `ShadowNetworking/OAuth` is the authorization-code flow with PKCE for public clients and has no UI: `OAuthClient.beginAuthorization()` returns the address to open and a pending authorization (verifier and state), `completeAuthorization(callback:pending:)` checks the redirect, the state and any provider error and exchanges the code, and `refresh(_:)` keeps the old refresh token when the server does not rotate it. `OAuthSession` hands out access tokens through an `OAuthTokenStore`: it refreshes ahead of expiry, shares one refresh among concurrent callers, saves rotated tokens before returning them, and after a 401 refreshes once per rejected token (`refreshAfterRejection(of:)`). `invalid_grant` becomes `OAuthError.reauthorizationRequired`. Presenting the system sign-in sheet is the app's job. Client ids and redirect URIs are inputs from the app, never constants.

`RecoveryPhrase` (`ShadowSync/Keys`) encodes a 256-bit `RecoverySecret` as 24 BIP-39 English words (the entropy plus the first 8 bits of its SHA-256 as checksum; no passphrase or seed derivation) and parses them back after NFKD normalisation, lowercasing and whitespace collapsing, throwing `RecoveryPhraseError` (`wrongWordCount`, `unknownWord(position:)`, `badChecksum`); it prints as `RecoveryPhrase(redacted)`. The word list is `RecoveryWordList.swift`, generated and never edited: save `bip-0039/english.txt` from `bitcoin/bips` and run `swift Packages/ShadowKit/Scripts/generate-recovery-word-list.swift <english.txt> Packages/ShadowKit/Sources/ShadowSync/Keys/RecoveryWordList.swift`, which refuses a file whose SHA-256 is not the pinned `2f5eed53…dbda`.

The storage providers (`ShadowSyncS3`, `ShadowSyncOneDrive`, `ShadowSyncGoogleDrive`, `ShadowSyncCloudKit`) are package-level until sync is wired into the app; a vault's folder on OneDrive and Google Drive is a `VaultFolderName` (`ShadowSync`), which both accept.

`S3StorageProvider` signs every request with AWS Signature Version 4 (CryptoKit, the payload hash of the whole body) and keeps a vault under the configuration's key prefix; listings skip objects whose names are not object keys, so foreign files in the bucket are ignored. It reports server time from the `Date` header, never pushes change notices (the app polls), and caps an object at 256 MiB. Put-if-absent is atomic (`If-None-Match: *`) only when the configuration says the endpoint honours it, otherwise a HEAD before the PUT that two racing writers can both pass. `probeConditionalWrites()` answers that question by writing the reserved `.shadow-s3-probe/conditional-writes` object twice; it removes only the object it wrote or one a crashed probe left more than 15 minutes earlier (so another device's probe is left alone), throws when the answer is inconclusive, and the caller keeps a true or false answer with `configuration.withConditionalWrites(_:)`. The credentials need list, get, put and delete on the bucket; without list permission S3 answers a missing object with 403, which reads as `unauthenticated`. The live conformance test runs only when `SHADOW_S3_LIVE_ENDPOINT`, `_REGION`, `_BUCKET`, `_ACCESS_KEY_ID` and `_SECRET_ACCESS_KEY` are set (optional: `_SESSION_TOKEN`, `_PATH_STYLE=1`, `_ALLOW_INSECURE_LOCALHOST=1`); it works under a fresh `shadow-live-tests/<uuid>` prefix and deletes what it wrote.

`OneDriveStorageProvider` keeps a vault as the files of one folder, `Apps/<app>/<vault folder>`, each named by `OneDriveName`: `/` becomes `!` and capitals, `_`, trailing dots and names OneDrive reserves are escaped so names stay distinct on a case-insensitive drive, and a key too long for a OneDrive path is stored under a digest with the key written ahead of its bytes. Listings are answered in key order from an index fed only by the folder's delta feed (saved through `OneDriveStateStore`: `InMemoryOneDriveStateStore` or the JSON `FileOneDriveStateStore`; a 410 rebuilds it), so they may lag but never invent a file. It supports put-if-absent (`conflictBehavior=fail`, simple uploads up to 4 MiB, upload sessions in 320 KiB multiples above that), reports server time from Graph's `Date` header, has a change feed but no change notices, takes objects up to 72 MiB (the largest segment payload plus room for its encryption framing) and deletes through `$batch`. Delta on a folder below the drive root is unverified for work and school accounts; if Graph refuses it, listing fails with a lasting error rather than a sign-in prompt, and `.common` stays the default audience until the live test passes with an organisations account. It needs a transport that refuses redirects, so the bearer token never reaches the download host. A Microsoft app registration (client id and redirect URI) does not exist yet. The live conformance test runs only with `SHADOW_ONEDRIVE_LIVE_CLIENT_ID`, `SHADOW_ONEDRIVE_LIVE_REDIRECT_URI`, `SHADOW_ONEDRIVE_LIVE_REFRESH_TOKEN` and `SHADOW_ONEDRIVE_LIVE_VAULT_FOLDER` (optionally `SHADOW_ONEDRIVE_LIVE_AUDIENCE`) set; it works in a fresh vault folder and deletes it afterwards.

`GoogleDriveProvider` keeps a vault as flat files in the hidden app data folder (scope `drive.appdata`): each file is named by its object key and carries the vault name in an app property, and the provider addresses files by id through an index it keeps from the changes feed and saves through a `GoogleDriveStateStore` (`GoogleDriveFileStateStore`, `InMemoryGoogleDriveStateStore`); a first listing takes the feed's start token and then enumerates the folder, enumerating once more two minutes later to add what Drive's search had not yet shown, and a rejected token rebuilds the index; when the token a rebuild just took is rejected before any page succeeds, the provider reports `unavailable` and rebuilds again only after a backoff (one hour, doubling up to a day, kept across restarts and reset once the feed works). Capabilities: no pushes, a change feed, no atomic put-if-absent (an `ifAbsent` put checks the index after catching up), server time from each write, objects up to 72 MiB (the largest sealed segment, with room to spare), any sync class. Drive allows two files with one name; every device picks the same one, the most recently modified (ties to the smallest file id), for reads, listings and overwrites, and an overwrite updates that file and then deletes the others. Objects up to 5 MiB go up in one multipart request, larger ones in resumable 8 MiB chunks. Sign-in needs a Google OAuth client for the app (NEEDS USER; none is registered yet). The live conformance test runs only with `SHADOW_GOOGLE_DRIVE_CLIENT_ID`, `SHADOW_GOOGLE_DRIVE_REDIRECT_URI`, `SHADOW_GOOGLE_DRIVE_REFRESH_TOKEN` and `SHADOW_GOOGLE_DRIVE_VAULT` set, under a fresh vault name, and deletes what it wrote.

`CloudKitStorageProvider` keeps a vault in one zone of the private database (zone `vault-default` by default), one `VaultObject` record per object, named `o-` and the lowercase SHA-256 of `com.shadow.library.shadowsynccloudkit.record-name`, a zero byte and its key, with `path`, `size` and either `bytes` (up to 512 KiB) or `parts`, a list of assets of up to 16 MiB each that is reassembled and checked against `size` on read; objects are capped at 72 MiB. Listings come in key order from an index kept from the zone's change feed and this device's writes, saved by the caller through a `CloudKitStateStore` (`CloudKitFileStateStore` writes backup-excluded JSON and must live outside the vault directory); an expired change token rebuilds it, and an unreadable file rebuilds it while still counting the zone as seen. The index is bound to the iCloud user record it was read under; another account found on the first call or after a sign-in counts as an account switch. It supports put-if-absent, reports the record's modification date as server time and yields a change notice when a push brings changes. A zone it has never seen is created by the first put; a zone found missing by a request sent while it was known, or an account that signed out or switched, stops every call and shows in `condition()` and `conditionChanges()` until the runtime attaches again (`recreateZone()` only after the user agrees). Behind the `CloudKitZoneClient` seam, `CKZoneClient` reads and writes records and the zone's change feed directly on `CKDatabase` (`desiredKeys` keeps listings from downloading assets) and runs a `CKSyncEngine` only for the database subscription, pushes and account events; `FakeCloudKitZone` (`ShadowTestSupport`) stands in for it in tests. Create a `CKZoneClient` only in builds with the iCloud and push capabilities (without the entitlement CloudKit is reported to raise an exception), and at most one per container in a process, since CloudKit's production environment allows one sync engine per database; a second throws `engineAlreadyRunning`. `CKZoneClient` compiles but has never run: it needs the container, the entitlements and the schema deployed. Not confirmed against the service: that a new record saved over an existing name with `.ifServerRecordUnchanged` fails with `serverRecordChanged`; that saving an existing zone succeeds; that an `.allKeys` overwrite clears a field set to nil (reads use `parts` only when their sizes add up, so a stale field is never read); that the sync engine still reports database changes while told to skip the vault zone; and which error follows the user deleting the app's iCloud data.

`VaultStore.observeReads(_:)` reads again after every commit, local or remote; `observeReads(writingTo:_:)` only after a commit with a statement that wrote to one of the named tables, as GRDB's authorizer names them before the statement runs, so `WITHOUT ROWID` tables count.

`VaultProcessLock` is an exclusive `flock` on `<db>-jobs.lock` beside the database, for work only one process may do on a vault; the kernel drops it when the process ends, so a crash never leaves the vault held. `Ledger.reconcilePending` looks up the cost of pending OpenRouter calls by generation id (bounded batch, retries with backoff, a grace period for calls still in flight) and stops on an authentication failure.

`ShadowJobs` keeps a job (`JobRequest`: key, payload, an app-owned `origin`, the requesting replica) and its attempts as synced records. An attempt has one writer, the replica that started it; another replica's write is refused (`notWriter`). A running attempt holds a lease (`LeaseTerms`: 6 minutes, renewed by a 2 minute heartbeat, checked against a trusted clock and a skew limit). `JobStatus` is derived from the job and its attempts at a lease instant: queued, running, failed, cancelled or succeeded. `AttemptRunner` (one per vault) runs a pipeline of steps: each step's output commits in one transaction with the attempt's checkpoint, which lives in a table local to the device. That commit is a compare-and-set: it holds only while the saved checkpoint is still the one the step ran from, otherwise `checkpointMoved` and the second process stops. `resumeInterrupted` continues this device's attempts from their checkpoints, and a stop mark settles an attempt whose process ended instead of resuming it.

Product cores are depended on the same way, through `ProductModule` (`.product(.novelForgeCore)`), so no dependency is named by a string.

### Sync runtime

`ShadowSyncRuntime` attaches a vault to a storage location, works out where it stands, syncs it on a schedule and reports a status; it has no UI.

- **Location.** `SyncLocation` names the provider (`SyncProviderSettings`: the non-secret settings of iCloud, a local folder with its bookmark, S3, OneDrive or Google Drive), the vault id and a `SyncAccountBinding` (a domain-separated SHA-256 of the account, never the account itself). `SyncLocationStore` keeps it as JSON at `<Application Support>/<bundle id>/Sync/location.json`, refuses a path inside a vault directory and writes atomically. `load()` answers `firstUse`, `turnedOff(reason)` or `attached`: `turnOff()` leaves a `location.json.off` mark beside the file (`disconnected`), a saved location wins over the mark, and a corrupt or oversized file (`unreadable`) or one of a newer format (`newerFormat`) also reads as turned off, so nothing attaches on its own once a location has existed. A refused file is `permissionDenied`; the start-up driver decides whether that is the device lock.
- **Locked device.** `FirstUnlockProbe` answers whether the device has been unlocked since it started, by reading or creating a file protected until first user authentication; `UIApplication.isProtectedDataAvailable` would stop background sync whenever a phone locks. The keychain's `errSecInteractionNotAllowed` is typed: `SecureStoreError.isInteractionNotAllowed`, `KeyRingError.deviceLocked`.
- **Secrets.** `SyncSecureStores.keychain(app:sharedAccessGroup:)` lays out four keychain services under the app's bundle id: `.sync` (ring keys, synced, shared group), `.sync.credentials` (S3 credentials through `S3CredentialStore`, synced, shared group), `.sync.device` (the device marker, this device only) and `.sync.tokens` (OAuth tokens through `KeychainOAuthTokenStore`, this device only, the app's own group). The stores and their errors never show a secret.
- **Setup.** `VaultSetup` discovers a vault by its hint, or by a manifest header when the hint is missing or unreadable; objects outside the vault layout (an S3 probe) do not count. `create()` joins a vault that is already there; otherwise it inserts a new ring key into the keychain first and only then puts `vault.json` if absent, so no device sees a vault whose creator holds no key. A lost race, or a read-back that shows another hint, joins the winner; the unused key stays (keychain items are write-once). `join(_:)` refuses a location whose hint names another vault. On a provider without atomic put-if-absent (Google Drive, S3 without conditional writes) two devices can still both win when each reads its own hint back before the other's overwrite lands; the loser's next evaluation then reports `vaultMismatch`, and what it uploaded under its own vault id stays unreadable to the others. Resetting a vault whose keys are lost everywhere is not here yet: it waits for the decision on deleting outside recorded names.
- **Start-up.** `SyncStartup` (an actor; calls run one at a time) returns a `SyncPhase`: a `VaultStartupState` or `deviceLocked`, `accountUnavailable`, `accountChanged`, `storageRemoved`, `appUpdateRequired`, `detached`, `settingsUnreadable`, `vaultMismatch` or `vaultUnrecognized`. A disconnect reads as `detached`, an unreadable location file as `settingsUnreadable` and a newer one as `appUpdateRequired`. On first use it attaches the automatic provider (iCloud) on its own, creating a vault only when the provider answered that it holds none; every other provider, and turning sync back on, goes through `attach(_:choice:)` with an explicit create or join, and `detach()` turns sync off for good. iCloud, OneDrive and Google Drive attach only with an account binding. A saved location is never replaced: another account, another vault at the location or an empty location stops sync and touches nothing. A device marker that is not a replica id is cleared once the device is unlocked, so the next start re-mints the replica. Vault phases come with a `SyncAttachment` that builds the `ReplicaLifecycle` and `SyncEngine`. `SyncPhase(failure:)` maps a sync call's failure to the phase it causes, and `noteMissingKeys(_:vault:)` feeds the keys a download of the attached vault found missing.
- **Runtime.** `SyncRuntime` (an actor, one per vault store) owns a `SyncStartup`, the `SyncEngine` of the attached vault and the schedule. The app calls `start()` once at launch, `foreground()` and `background()` from the scene phase, `localWrite()` after each committed write and `changeNotice()` for a silent push; `discover(_:)`, `attach(_:choice:)` and `detach()` serve the settings screens, and `shutdown()` ends it. Runs never overlap: attach, detach and discovery wait for the run in flight, and every trigger that arrives during a run joins one follow-up run. The triggered calls return once the runtime is idle, so `background()` can end an iOS background task. A run evaluates the phase when asked (launch, foreground, key check) or when none is known, starts the engine once per attachment (after `.lifecycle(.markerUnavailable)` it evaluates again, which tells a locked keychain from a corrupt marker), downloads, passes the outcome's `missingKeys` to `noteMissingKeys(_:vault:)`, runs the attachment's `RecoverySetup.reconcile()` after a download that applied files or brought a key into the ring (and again after the next download if it failed), uploads only while the store holds pending changes, and compacts and adopts at most hourly on a catch-up run. On `detached`, `accountChanged`, `storageRemoved`, `settingsUnreadable`, `vaultMismatch`, `vaultUnrecognized` or a lost CloudKit zone it drops the engine, stops uploading and returns the vault to device backups (`StorageAttachment.detach`; a store pinned out of backups is left as it is); a locked device, an unavailable account or an app update keeps the exclusion. It listens to the change notices of the attached engine's provider and, for iCloud, to its `CloudKitStorageProvider.conditionChanges()`; after any failure it reads that provider's `condition()`, so an account switch or a deleted zone stops sync even when the notice was missed. `SyncStartup` keeps the attached location's provider for as long as it stays attached, beside one for the latest discovery elsewhere, so looking at another location never makes a second provider for the attached one (two CloudKit providers of one container would share its index state). `shutdown()` lets a run in flight finish, and calls waiting on it return only after it.
- **Schedule.** `SyncScheduler` runs on offsets of the injected `Clock` (`ContinuousClock` by default, never the wall clock), with the intervals of `SyncSchedulePolicy`: sync on launch and foreground, upload 2 s after the last local write, download every 45 s while in front (counted from the last download, so steady writes never postpone it), look for the vault's key every 30 s while waiting for it, and upload once on going to the background, dropping a backoff the device chose so the final upload is never skipped. In the background nothing is timed: a write there, a notice or a push runs at once. A storage `rateLimited(retryAfter:)` holds every trigger, foreground included, until it passes (at most an hour); other transient failures back off from 2 s doubling up to 5 minutes, which a foreground skips.
- **Status.** `statusUpdates()` yields the current `SyncStatus` and then each change in order: `off` (no sync set up, or the user turned it off), `upToDate`, `syncing` (a launch or foreground catch-up, local writes not yet uploaded, or a retry pending; quiet polls do not show it) or `attentionNeeded(SyncAttentionReason)`. Each reason says what it stops through `stops` (`everything`, `uploads`, `downloads(from:)` the named replicas, `nothing`): `quotaFull`, `accountUnavailable`, `accountChanged`, `storageRemoved`, `zoneLost`, `vaultMismatch`, `vaultUnrecognized`, `awaitingKey`, `writingKeyMissing`, `keysMissing(replicas:)` (the replicas whose files are sealed with keys this device lacks), `wrongClock` (uploads stop only while the store stamps with the wrong clock), `appUpdateRequired`, `deviceLocked`, `settingsUnreadable`, `storageUnreachable` (after three failed attempts in a row) and `failed(code:)`. When several apply, the one that stops the most is shown. The library holds no user-facing text; the app words each reason.

### Adding a module

1. Add a target and a `.library` product to `Packages/ShadowKit/Package.swift`, with sources in `Sources/<Module>` and tests in `Tests/<Module>Tests`.
2. Add a case to `SharedModule` in `Tuist/ProjectDescriptionHelpers/SharedModule.swift`.
3. `mise run bootstrap`.

A product module is added the same way: a library product in the product's package, a case in `ProductModule` (`Tuist/ProjectDescriptionHelpers/ProductModule.swift`), and a `.package(path:)` entry in `Tuist/Package.swift` for a new package.

## Memoir core

`Packages/MemoirKit` holds `MemoirCore` (bundle id `com.shadow.library.memoircore`), Memoir's records, rules and derived state; it imports no UI framework and depends on `ShadowCore`, `ShadowStore`, `ShadowSync`, `ShadowText`, `ShadowAI`, `ShadowJobs` and GRDB. `LocalDate` (`Calendar/`) is a civil date held as days since 1970-01-01 (years 0000 to 9999), computed with integer arithmetic only, never `Calendar` or `TimeZone`; it parses and formats `yyyy-MM-dd` and encodes as that string. Its fixtures follow `Packages/MemoirKit/Fixtures/README.md`.

### Memoir calendar

`Calendar/` ports the reference's calendar (`rules/time.ts`, `rules/recurrence.ts` and `finance/subscription-cycle.ts`). The civil-date arithmetic (month arithmetic clamped to the month's end, Monday-anchored weeks, nth weekdays) runs on `LocalDate` in integers, with no `Calendar` or `TimeZone`. `RecurrenceRule` expands daily, weekly, monthly and yearly rules as the reference does: an excepted date keeps its index and so uses up a COUNT slot, and an expansion returns a cursor from which the next window resumes with the same occurrences and indices as a full recomputation. `SubscriptionCycle.advanceDueDate` rebuilds each month-based due date from the billing day. `IssueClock` is the only code that reads Foundation's `TimeZone`, and it runs only while this device issues a command: it gives the UTC offset in force and the local date (`stamp(at:)`), resolves a local minute with the reference's rules (in a fold the earlier instant, in a spring-forward gap the transition), measures local days, and clamps a claimed `performedAt`. Replay never calls it and uses the offsets and dates the commands recorded, so two devices with different tz data agree. The vectors in `Fixtures/calendar/` pass exactly. The zone cases cover 20 zones from 2015 to 2030, and every disagreement between Foundation and ICU sits in `zone-exclusions.json` with its reason (none so far). The native code deliberately differs from the reference in these cases:

- It counts years 0 to 99 as real years, where the reference's `Date.UTC` reads them as 1900 to 1999.
- `RecurrenceRule.init` throws `noWeekdays` for a weekly rule without weekdays and `dayOfMonthOutOfRange` for a monthly day of month below 1. The reference's payload parser (`quest-command.types.ts`) accepts any integer and then produces dates that do not exist.
- `IssueClock.resolve` throws `minuteOfDayOutOfRange` for a minute outside 0 to 1439, where the reference rolls into the neighbouring day.
- `SubscriptionCycle.init` throws `billingDayOutOfRange` outside 1 to 31. The reference relies on its database check, and its function only clamps a day of 32 or more to the month's end.
- `utcOffsetMinutes` and `stamp(at:)` floor an offset with seconds (local mean time, before 1972) to whole minutes, where the reference returns a fraction. `stamp(at:)` takes `issuedOn` from that recorded minute offset, as `MemoirCommand` checks it.
- Expansion and arithmetic stop at 9999-12-31; the reference has no upper bound.

`Commands/` refuses these inputs before they become commands (the billing day through `SubscriptionRecord`'s `CommandContent` check), so that every device replays only what the native calendar accepts.

### Memoir rules

`Rules/` ports the reference rules engine (`src/modules/rules`, without the calendar functions): `Ruleset` and the frozen `Ruleset.v1`, the level curve, reward, timing bands, streaks and shields, HP, Crown, Comeback, Returner, momentum, capacity, achievements and titles. Arithmetic is exact and integer only, with no `Double` or `Float`: modifiers and ratios are `Thousandths`, momentum weights `Tenths`, Crown weights and medians `Halves`, derived values an exact `Fraction` compared by cross-multiplication, and wherever the reference calls `Math.round` the port rounds halves toward positive infinity as it does. Products and sums go through `Int128` and saturate at the edge of `Int` instead of trapping. The level table (`LevelCurve+V1.swift`) is generated from the reference's curve and never edited. A published ruleset never changes: `Fixtures/rules/ruleset-v1.json` pins `Ruleset.v1` by the SHA-256 of its canonical JSON, and a change means a new version. Every vector in `Fixtures/rules/` passes exactly except the 2,593 cases in `divergences.json`, where the reference's float result differs from an exact rational model of the same rule; for those the tests assert that the native result equals the exact model and differs from the reference. Only two of them change an outcome (momentum at exactly the cold ratio, which the reference's float reads as `cold` and the port as `steady`); the rest are fractional fields such as the reward modifier, the momentum ratio and the capacity baseline.

### Memoir schema

A vault is three stores in sibling directories, each opened only through `MemoirStore.open(_:in:wallClock:)` (or `openInMemory`) with its own registry from `MemoirSchema`: the main store `Vaults/<name>/vault.sqlite` holds the general-class kinds and admits only `.general`; the activity store `Vaults/<name>-activity/activity.sqlite` holds activity-class metrics so the iCloud setting for Activity can switch on and off without moving records; the restricted store `Vaults/<name>-health/health.sqlite` holds health-class kinds (weights, health metrics and their days). The activity and restricted stores are always excluded from device backups. Kinds are prefixed `mm_`. Everything that moves hero state is an appended `mm_command` (UUIDv7 id, type, payload, instant, UTC offset, issued-on date, optional occurrence, ruleset version) whose payload never carries the owner's words, a measured value, or a threshold of an activity- or health-class metric: those live in records of the metric's class (or content records such as `mm_quest`, `mm_journal_entry`, `mm_command_note`) that the command names by id or date. `CommandPayload` enforces what it can: strings are tokens and never digit-only, integers appear only at the paths `CommandPayload.integerPaths(for:)` pins for the command's type (schedule minutes, counts, calendar positions), and keys naming a measurement (`kg`, `value`, `healthThreshold`, ...) are refused. Quest deletion and subscription cycle confirmation are commands; a subscription record keeps only the owner's anchor date. `mm_fx_rate` (first writer wins), `mm_expense_category`, `mm_account_settings`, `mm_weight` and `mm_metric_day_{general,activity,health}` are natural-key records. Data is written through the typed records in `MemoirCore/Records` (`create`, `edit`, `remove`, `restore`, `append`; `restore` only clears the removal), never by setting raw fields; an edit writes only what changed and cannot alter a first-writer field once set. Each registry is frozen in `Packages/MemoirKit/Fixtures/schema/` (`registry-v1.json`, `activity-registry-v1.json`, `restricted-registry-v1.json`); adding kinds or fields raises that store's version in `MemoirSchema` and saves the new description beside v1.

### Memoir commands

`Commands/` is the command vocabulary: `MemoirCommandKind` names the 40 types (the reference's 36 handlers, the time-zone, intensity and returner-threshold settings, and `receipt.scan`) and `MemoirCommandBody` has one typed case per type, decoded from a payload with the reference's checks and field names (`quest-command.types.ts` and each handler's `require*` helpers) and encoded back. A command is built only from a body (`MemoirCommand(id:body:...)`), and a stored command of a known type whose payload does not decode as its body reads as unreadable; one of an unknown, newer type is held to the payload's own rules. A payload keeps the reference's key names for what stays in it and carries only ids, dates, closed-set tokens, flags and the integers its type pins (`quest.create`'s schedule and recurrence positions, `quest.update`'s under `patch.`, `quest.reschedule`'s `toMin`, the returner threshold); the owner's words and values are the records the command names (a weight by its date in the restricted store, a metric's day by metric and date, a quest, entry, expense or subscription by id), and a reason note or reflection is the command's `CommandNoteRecord`, which the payload marks with `note: true` or `reflectionText: true`. The occurrence is the command's own field, never the payload's. Beyond the reference, decoding refuses any key the type does not have (so adding a field to a type's payload needs a new ruleset version, or older devices read the command as unreadable), a non-boolean flag the reference reads as false, a quick-log or billing date that is not a real date, a monthly day below 1, a health threshold on a quest (it needs a record kind first), a log edit that sets both texts, a category other than the reference's nine built-ins (`FIN_005`), and a time zone that is not `UTC`, `GMT` or an `Area/Location` name. Rules that need state (whether the occurrence exists or has begun, the edit window, the reschedule cap, coins, earned titles and owned cosmetics, `QST_003` against the quest's current start time) are replay's. `CommandIssuer` stamps a body with a UUIDv7 id, the instant, the offset in force and `issuedOn` from `IssueClock.stamp`, and `Ruleset.current`'s version, and appends it with its note in the caller's transaction; `issue(_:text:content:in:)` first runs the reference's checks on the record the command names (`CommandContent`: names, mood, calories, weight, and the subscription's `BillingTerms`), which the caller still writes through its typed record, and `confirmCycle(_:in:)` writes the cycle's expense through `SubscriptionCycles.confirm`, logged at the command's instant, and appends the command in the same write. A reason note is 1 to 120 UTF-16 units (`CommandIssuer.validate(text:for:)`). `issuedOn` is the zone's date, never the account's open day: after a backward zone change the open day runs ahead of it (`rules/time.ts:157-161`), and since the open day is derived state, replay takes the later of the two. Settings carry `SettingTiming`: time zone and intensity take effect from the day after the account's day (`nextDayBoundary`), the returner threshold and the first time zone, which the reference's onboarding sets outright, at once. After a forward zone change replay skips the dates never lived instead of closing them as missed (`rollover.service.ts:437-447`); with a stale open day the reference keeps the old setting until its next rollover walk, while replay applies it from the day after the account's day on every device. A time zone is checked against this device's zone data, under exactly its name, when issued, and only for its shape when decoded, so a device with older data replays it alike. The vectors in `Fixtures/commands/` pass, and each case where the native code differs from the reference carries its reason.

### Memoir finance

`Finance/` holds money in Int64 minor units with checked arithmetic and an ISO 4217 exponent table (`ISO4217`). `HomeConversion` converts with the exponents applied, `roundHalfUp(amountMinor × rate × 10^(eHome − eSource))`, exactly from the rate's decimal text (`ExchangeRate`, at most 18 digits and 18 places), halves toward positive infinity as the reference's `Math.round`; the reference multiplies minor units by the rate without the exponents. Every case where it differs from the exact model (mixed exponents, binary-float rounding, amounts past 2^53 or past Int64), the custom intervals of zero or less the native code refuses, and the latest confirmed cycle winning in any order are listed in `Fixtures/finance/divergences.json` and asserted. An expense captures the `mm_fx_rate` of its own date when written (`createCapturingRate`); `RateFiller` fills the rest through a `RatesClient` that receives only currency pairs and a date (no network client yet: the service needs approval), rounds rates to eight places as the reference stores them, and records each pair and day once, first writer wins. `HomeConverter` converts every expense through that record, so devices agree even when an expense locked a rate that lost the merge. A subscription's next due and last confirmed dates are derived (`SubscriptionSchedule`) from its anchor date and its `subscription.confirmCycle` commands; an anchor moved to or before the latest confirmed billing date is ignored. Each confirmed cycle writes one expense under `derivedID("com.shadow.library.memoircore.subscription-cycle-expense", "<subscription>|<date>")`: a device that holds it never writes it again, but a device that has not received it writes it again, which with a later clock restores an expense the owner deleted elsewhere and reverts edits made elsewhere. `BudgetStanding` measures this month's spending in the home currency and counts expenses still waiting for a rate apart; changing the default currency clears the budget, and a budget in another currency is ignored.

## Novel Forge core

`Packages/NovelForgeKit` holds `NovelForgeCore`: the product's records, rules and derived state on top of `ShadowStore`. It imports no UI framework and depends on `ShadowCore`, `ShadowStore`, `ShadowText`, `ShadowAI`, `ShadowJobs` and GRDB; `ShadowTestSupport` is linked by its tests only. `NovelForgeEval` is an executable target that depends on `NovelForgeCore` and hosts the evaluation commands (command-line only; not linked into any app).

| Folder                   | Contents                                                                                               |
| ------------------------ | ------------------------------------------------------------------------------------------------------ |
| `Schema`                 | `NovelForgeSchema` (`version`), `NovelForgeKind`, `NovelForgeField`, `NovelForgeKey`                    |
| `Store`                  | `NovelForgeStore`: opens the vault (file or in-memory) with the schema registry and reconciler          |
| `Records`                | One typed record per kind (`NovelRecord`, `DraftRecord`, `FinalChapterRecord`, ...) with create, edit, revision and append writes and reads |
| `Rules`                  | Pure rules: content hash, progress, next chapter, batch selection, bible manifest, promises, volume stats |
| `Policies/*`             | Ported pure policies: `Checks`, `Chat`, `ChapterPlan` (plan cards, vetting, reveals), `Disclosure`, `FinalizeReview` (items, edits, the gate), `HardLine`, `Ideas`, `Metrics`, `Prose`, `ReplyScanner`, `Reveal`, `Review` (findings, the gate), `WritePolicy` |
| `ChangeSet`              | The change-set vocabulary (`OpType`, `OpSpecs`), parsing, reference resolution and validation          |
| `Projection`             | `Derivation`, `NovelForgeReconciler` and the record index: derived tables kept equal to a rebuild        |
| `Reconcile/*`            | Derivations per area: `Canon` (bindings, promise state), `Chapters` (lifecycle, approvals, headings, final chapters, disclosure), `Chat`, `Jobs` (entries, attempts, calls, costs, activity), `Notebook`, `PlanWorld`, `Story` |
| `Domain/*`               | Operations on the records: `Bible`, `Chapters` (drafts and versions, plans, reviews, approvals, finalize and its commit gate), `Chat` (sessions, cleanup), `Library`, `Story`, `Notebook`, `Proposals` (staging, apply, revert, turn staging) |
| `Domain/Jobs`            | Job requests: `NovelJobOrigin`, and the plan, generation and refresh requests (`PlanRequests`, `GenerationRequests`, `RefreshRequests`) that the app's backlog runs |
| `Chat/*`                 | `Engine` (`ChatTurnEngine`), `Turn` (relay and local turn store), `Compaction`, `Lookups`                |
| `Context`                | The chat context: `ChatPack` renderers, `ChatContextAssembler`, `TokenBudget`                            |
| `Context/Writer`         | The writer pack a chapter run reads: `WriterPackAssembler` and its loader, brief, knowledge and previous-ending renderers |
| `Context/Outline`        | The outline pack the plan run reads: `OutlinePack`, its loader, ledger, timeline, guard lines and retrieved references |
| `Prompts`                | Chat refine, compact and title prompts, scope playbooks, writing instructions                            |
| `Prompts/Chapters`       | Chapter generation, expand, fix, revision, title and judge prompts, output schemas, ending contract       |
| `Prompts/Pipelines`      | Plan, editorial review, continuity, summarize and canon refresh prompts with their schemas and outputs    |
| `Evaluation`             | The public facade `nf-eval` reads through: chapter rows, the deterministic prose metrics report, the plan-card apply |
| `Pipelines/Engine`       | `JobEngine` (starts, resumes and stops attempts; consent gate), `JobStepContext` (`call`, `callText`), pins, progress, `PipelineCatalog` |
| `Pipelines/Generation`   | Generate, expand, fix and judge steps, their saves and state, and the generation policies in its `Policies/` |
| `Pipelines/Plan`         | The plan run: one structured call that stages a plan card                                                 |
| `Pipelines/Review`       | Editorial and continuity review steps and requests, chapter summarize                                     |
| `Pipelines/FinalizeReview` | The finalize review run: inputs and steps behind the finalize gate                                      |
| `Pipelines/Refresh`      | The Story Bible refresh run after a chapter is final: material, call, steps, report                       |
| `Pipelines/Routing`      | `ChapterRoute` and `ChapterCallRouter`: a chapter call's content mode from its plan head and isolation (unrestricted refused with `AI_024` while the build cannot write it), hard-line screens of inputs and results, and the draft's generator and isolated flags |
| `Retrieval`              | `NovelRetrieval`: the local index of final prose and lore (chunker port, catch-up indexer, BM25 search, sentence embeddings) and `RetrievalUpkeep`, which keeps it current |
| `Export`                 | `NovelExport`: the manuscript (Markdown) and the `.novel` package (a stored zip, `NovelPackage`, `StoredZip`); sends nothing to a model |
| `ReadModels`             | Observed reads, among them `ChapterJobs` (a chapter's job lines), `FinalizeReadiness`, `FinalizeReviewScreen`, `ChapterRunCharges`, job activity and costs, the chat session list, transcript, Waiting on you, change history, reply costs and `UnrestrictedLock` (the chats, drafts, canon and reviews of isolated prose that keep a novel unrestricted; unavailable counts as locked) |

`nf-eval` (`NovelForgeEval`, run with `swift run --package-path Packages/NovelForgeKit nf-eval --help`) measures chapters and runs them through plan, generate, review, finalize review, finalize and refresh. A pipeline run calls a model, so it refuses without `--live`, without `NF_EVAL_PROVIDER=anthropic` and `NF_EVAL_API_KEY` in the environment (OpenRouter is refused), and, on a real vault, without an AI consent the author already recorded there. `--live --vault` also needs `--write-vault`: the run writes into the real vault, applying a plan card, writing a draft, a review and an approval as the author, finalizing the chapter and refreshing the Story Bible; those writes sync to the author's other devices and cannot be undone. `--fixture` runs in a throwaway in-memory vault. `--metrics-only` calls no model but still opens a real vault read-write, so pending migrations and projection catch-up are applied.

The report is JSON only. Metrics read a final chapter's canon and any other chapter's draft head (the reference reads one source per run), drop empty bodies as the reference does, and list a body this version cannot read under `skipped`; there is no `--from`, `--to`, `--all` or text report. The fail-open invariant skips the chapters the tool approved itself (`failOpenExcluded`), since its own approval would satisfy it.

### Chat

Schema v2 (`NovelForgeSchema.version`; `Fixtures/schema/registry-v2.json` beside v1) adds the synced kinds `nf_chat_session`, `nf_chat_message`, `nf_chat_summary`, `nf_proposal` and `nf_proposal_change`, and registers the ledger kinds `ai_model_call` and `ai_consent` in the vault. `Reconcile/Chat` derives the transcript, window, session state (including the unrestricted lock) and proposal state from them.

`ChatTurnEngine` (`Chat/Engine`) runs a turn: `send`, `answer`, `retry`, `resume`, `cancel` and `interrupt`. It screens the input, compacts the conversation, routes the call through `ShadowAI`, streams the reply, runs up to three lookup rounds and one negation-fix round, stages the change set (`stageTurn`) and appends the reply in one transaction. `resumeInterruptedTurns` runs once when the vault opens: it runs card actions left pending first, clears what this device kept of chats deleted elsewhere, ends turns the author had stopped, resumes the other interrupted turns it can, fails the rest (`CHT_013`), and runs owed chat namings last.

Tables of this device's own, never synced; each is created idempotently by the write that first needs it, read only after a `tableExists` check, and cleared with its owner: chat rows by `ChatLocalCleanup` and `ChatTurnRecords.forgetOrphans`, pending actions by the sweep once the card has none left or is gone:

| Table                       | Holds                                                                                              |
| --------------------------- | -------------------------------------------------------------------------------------------------- |
| `nf_local_turn`             | One row per turn on this device: its state, session, novel and replica; what resume reads          |
| `nf_local_turn_frame`       | The turn's stream frames, for re-attaching to a running or ended turn                              |
| `nf_local_turn_stop`        | The author's stop mark, so a stopped turn is ended cancelled at launch instead of resumed          |
| `nf_local_turn_basis`       | What a turn was asked and what it settled or staged, which a resume continues from                 |
| `nf_local_turn_call`        | The ledger ids of the model calls a turn began, a call a crash cut off included                    |
| `nf_local_turn_step`        | Which staging transactions of a reply committed, with the notes the reply then carries             |
| `nf_local_chat_naming`      | A session naming owed from its opening message until the naming ends                               |
| `nf_local_pending_action`   | Applied cards whose actions have not settled; the launch sweep runs them                           |
| `nf_local_chat_segment`     | What each reply's turn sent, replayed so the cached prefix holds; other devices send plain history |
| `nf_local_call_inspector`   | The last request of each turn, for the Inspector (newest 20 per session)                           |

Proposals live in `Domain/Proposals`: `ProposalStager` stages a card (anchors, baselines, warnings, supersession), `applyProposal` applies it whole or by selected indexes in one transaction (a baseline mismatch makes it conflicted; the actions `approve_draft`, `finalize` and `advance_volume` each run in their own transaction afterwards), and `undoProposalChange`, `redoProposalChange`, `revertProposal` and `rollbackProposals` reverse it. Every apply and revert goes through typed records and handlers per op family (`Apply/*Handlers.swift`). A passage rewrite that brings in a locked secret its own passage did not give away records the head it was written over as the revision's `leak_hold` (schema v4, `Fixtures/schema/registry-v4.json`); the lifecycle holds that revision as a contradiction until a judge review of it, an approval of it or a later revision. A device still on schema v3 shows that revision as needing review until it updates. The public `ProposalApplyContext(novel:now:)` and `ProposalRevertContext(novel:now:)` take whether unrestricted writing is available from the build (`UnrestrictedWriting.isAvailable`, `false` for now) and expose no way to override it. Unrestricted turns are refused with `AI_024` by `ChatTurnPreparation` and by compaction, and an op that raises a plan to unrestricted is refused by the apply.

### Retrieval

`NovelRetrieval` (`Retrieval/`) is the reference's retrieval service over an index this device keeps and never syncs. It indexes the same kinds of text with the reference's kind strings and keys: each final chapter's prose (its amendment when there is one), chunked as `chunker.ts` does, and one lore row per entity (`character`, keyed by the entity key, text `name`, `notes` and `body`) and per Story Bible page (`bible_doc`, keyed `section/slug`, planner-only pages left out). Unlike the reference, which indexes an entity only when a finalize touches it, pages only when the Bible builder runs, isolated prose never, and removes no lore, the native index covers every live entity and page, holds isolated prose and always follows the current records. `catchUp(novel:)` compares every corpus record's digest in the record index, stamped with `RetrievalCorpus.version`, against the one its source last read; it reads the changed records again, rewrites a source only when the hash of its text (taken before chunking) changed, and drops sources whose record left the corpus, one batch of sources per transaction. It picks up merged records, amends and deletions without any writer calling it, does nothing when nothing changed, and raising the version reads every record again. `searchProse`, `searchLore` (kinds bound as parameters) and `searchProseAndLore` rank with FTS5 BM25 (`unicode61`, diacritics folded) over a MATCH expression that quotes every term of the free-text query, and leave out the chapters isolated now. The tables are `nf_local_retrieval_source`, `nf_local_retrieval_prose`, `nf_local_retrieval_lore` and their external-content FTS5 tables (`*_fts`, kept equal by triggers); `VaultStore.forgetLocalState(novel:)` clears them with the rest of the novel's local state.

Embeddings are optional and never synced. `NovelRetrieval(store:embedders:)` takes an `EmbedderProvider`; `NLSentenceEmbedders` reads the novel's language with `NLLanguageRecognizer` from the opening of its prose (its lore when it has no prose) and uses `NLEmbedding.sentenceEmbedding(for:)` when the system has one for that language (which languages have one depends on the OS and the assets on the device: on the macOS 26 SDK, English, French, German, Spanish, Italian, Portuguese and Simplified Chinese list a revision, Japanese, Korean and Traditional Chinese none; otherwise search is FTS only). `embedPending(novel:limit:)`, run after `catchUp`, embeds the rows that have no vector of the current model in batches of its own writes, at most one vector per row in `nf_local_retrieval_vector` (unit-length little-endian Float32, removed with its row by triggers). Each vector records its model identity (framework model, language, revision, dimension and input recipe); a pass drops the novel's vectors of any other model, so a model change rebuilds and never mixes, and a text the model cannot embed is marked and not tried again until the text or the model changes. Once no row of the novel waits for its model (a failure mark counts as done), a search embeds the query with the model its vectors record (`EmbedderProvider.embedder(forModel:)`, so the text is not sampled again), ranks the novel's vectors by cosine (Accelerate, brute force), applies the same isolation and kinds filters and fuses that list with the BM25 list by reciprocal rank fusion (k = 60). Until then, or with no model, a system model that changed since, or a query it cannot embed, the BM25 ranking stands alone, exactly as without embeddings.

The chat lookups `search_lore` and `search_prose` (`Chat/Lookups`) answer from it in the reference's formats: each lookup round first runs `catchUp`, so an amended sentence is gone from the answer; it never embeds indexed text (no `embedPending`) and embeds only the query, and only once every row of the novel is embedded; a failed index read answers "No lore found." / "No prose found." as the reference does, and only cancellation propagates. `kinds` takes at most 16 entries, which the reference does not cap.

No record write updates the index. `RetrievalUpkeep` (one per open vault, held by the app's `Shared/RetrievalRuntimes`) catches every novel up when it starts and then follows the record index: it reads the rows of the corpus kinds again only after a commit that wrote to `nf_derived_record` (`VaultStore.observeReads(writingTo:_:)`), which the index's own writes never do, so they never wake it: a novel whose final chapters, entities or pages changed, by a local write or a merge, is caught up `RetrievalUpkeep.defaultDebounce` (3 s) after its last change. Each catch-up is followed by embedding in batches of 64 rows; one unit of work runs at a time at background priority, a waiting catch-up goes before the next embedding batch, and no novel is worked on twice at once. A failed unit is logged and tried again 30 s later, the wait doubling with each failure in a row up to 30 minutes, or sooner when the novel changes meanwhile; a retry of a failed embedding batch does not catch up again. On iOS the upkeep stops (between two batches) when the app goes to the background and catches every novel up again on return; on the Mac it keeps running. Embedding a long novel takes minutes; until it is done, search ranks by BM25 alone.

The plan's outline pack adds the reference's `prose_retrieved` and `lore_retrieved` after the catalog (`context-assembler.service.ts` `forOutline`): it searches for the first line of the current volume's objective, reads a failed search as no hits, and both sections are canonical and not required, so the budget drops them before anything else. The pack catches the novel up before it searches, so it never depends on the upkeep. The plan step builds its pack, these hits included, each time it runs and checkpoints only the vetted plan, so a resumed step searches again over the records as they are then, as every other section of the pack reads them again. Retrieved prose never includes a chapter isolated now, even for a planner that reads isolated chapters raw, and that planner's pack screens retrieved text for the hard line with the rest. An empty plan searches nothing.

### Reference fixtures

Expected outputs come from the TypeScript reference product and are committed under `Packages/NovelForgeKit/Fixtures/<area>/` (see the folder for the full list: `change-set`, `chat-turns`, `prompts`, `schema`, `write-policy`, ...). Regenerate an area with a read-only checkout of the reference:

```sh
PLATFORM_REPO=<path to the reference checkout> bun Packages/NovelForgeKit/Fixtures/<area>/generate.ts
```

`text/` uses `collect-regexes.ts` instead of `generate.ts`, and `regex/generate.ts` needs the checkout's installed dependencies. See `Packages/NovelForgeKit/Fixtures/README.md`.

## ShadowDesignSystem

Shadow UI for Apple: the brand (indigo accent, tinted neutrals, flat opaque content) on native SwiftUI controls, with Liquid Glass for the navigation layer only. Minimum OS 26 on every platform. It contains no user-facing strings.

### Adopting it in an app

1. Depend on it in the app's `Project.swift`: `dependencies: [.shared(.designSystem)]`, then `mise run bootstrap`.
2. Apply the theme and a toast presenter once at the root:

```swift
import ShadowDesignSystem

WindowGroup {
  RootView()
    .shadowTheme()
    .shadowToastPresenter()
}
```

3. Use semantic tokens only (`ShadowColor.textPrimary`, `Spacing.space4`, `Radius.section`), never primitive palette values or literal colours.
4. Keep glass on bars, toolbars, sidebars, menus, popovers and sheets. Content (cards, rows, fields) stays flat on `ShadowColor.surfaceCard`.

The DocC catalog has a getting-started article, the token and contrast reference, the glass rules, and the platform decisions that deviate from the Shadow UI design spec.

### Regenerating tokens

`Design/tokens.json` is the source for colours, spacing, radii, metrics, opacity and elevation. After editing it:

```sh
mise run tokens
```

This rewrites `Packages/ShadowKit/Sources/ShadowDesignSystem/Tokens/Generated/`. Never edit those files by hand. CI regenerates them and fails on a diff. Every text pair in `ContrastTests` must still pass `mise run test:packages`.

### Building the docs

The catalog is `Packages/ShadowKit/Sources/ShadowDesignSystem/ShadowDesignSystem.docc`. Build it with Xcode, which needs no extra package:

```sh
cd Packages/ShadowKit
xcodebuild docbuild -scheme ShadowDesignSystem -destination 'generic/platform=macOS' -derivedDataPath .build/docbuild
```

The archive is written to `.build/docbuild/Build/Products/Debug/ShadowDesignSystem.doccarchive`; open it in Xcode. `swift package generate-documentation` would need `swift-docc-plugin`, which is not a dependency of this repository.

## Novel Forge app

`Apps/NovelForge` runs on iPhone, iPad and Mac from one target (`.phoneAndMac`; no visionOS). It depends on `NovelForgeCore`, `ShadowStore`, `ShadowAI`, `ShadowJobs`, `ShadowKeychain`, `ShadowNetworking`, `ShadowDesignSystem`, `ShadowSync`, `ShadowSyncRuntime`, `ShadowSyncCloudKit` and `ShadowSyncS3`. At launch it opens the vault, one SQLite database at `<Application Support>/<bundle id>/Vaults/Default/vault.sqlite`, off the main actor; a failure shows an error screen with Try Again instead of crashing. The root is a three-column `NavigationSplitView`: the library, the sections of the selected novel, and the section's screen. Unit tests run against a temporary directory, and the app itself uses an in-memory store when hosted by XCTest. Opening goes through `NovelForgeStore` in `NovelForgeCore`.

Each area owns a folder under `Apps/NovelForge/Sources/<Area>/` (`Library`, `Reader`, `Story`, `StoryBible`, `Notebook`, `Chat`) and plugs into the shell through one entry view, `struct <Area>View: View { let context: NovelContext }`, where `NovelContext` holds the `VaultStore` and the novel's id. `Navigation/NovelDetailView.swift` maps a `NovelSection` to that view, so an area replaces only its own folder. The shell keeps one `NovelNavigator` per novel in the environment (`@Environment(NovelNavigator.self)`): `section` is the selected section, `show(_:)` switches to one, `open(_:_:)` replaces that section's own `NavigationStack` path with one `Hashable` route and selects the section (a deep link), and `push(_:)` appends a route within the current section. An area registers `navigationDestination(for:)` for its own route types, and each section's path survives switching sections. A route can outlive its entity (deleted, or removed on another device), so every destination must render a "not found" state rather than assume the entity exists.

A screen that holds text the user has typed registers its flush with `Shared/UnsavedWork` (`UnsavedWork.shared.register { … }` returns a token to `unregister` with). The app flushes every registration when the scene leaves the active phase (inside a background-task assertion on iOS), when a window closes, and before quitting on macOS (`applicationShouldTerminate` answers `.terminateLater` until the flushes finish or a timeout passes). A flush should write the text to durable local storage and not depend on the network. Models that carry such state are kept per novel above the section switch (`Navigation/NovelReaders` for the Reader) so a section or novel switch does not discard them.

The Chat area (`Apps/NovelForge/Sources/Chat`) is split into `Composer/` (composer state, mode menu, passage chips and the passage comment sheet), `Cards/` (proposal cards, receipts, question cards and `ChatRevertFlow`, the undo and revert flow shared with `Changes/`) and `Changes/` (Waiting on you tray and the change history with Undo and Roll Back to Here); the transcript, streamed turn, Inspector and history sheet sit beside them. Chat turns run on one `ChatTurnEngine` per open vault, held by `Chat/ChatRuntimes` in the app's environment and shared by every window: the engine alone knows which turns run on this device, so a second engine on the same vault would take a running turn for an interrupted one. When the vault opens, `ChatRuntime.launch()` calls `resumeInterruptedTurns` once and then has every open chat read its turn again. Each novel's `ChatNovelModel` and each chat's `ChatSessionModel` live in that runtime, above the section switch, so a running turn keeps being followed while the Chat section is out of view. The app builds proposal contexts only through the core's public inits. Whether a turn may be written unrestricted is the core's `UnrestrictedWriting.isAvailable`, which the engine enforces and the composer reads to hide the option.

Chapter jobs run on one `JobEngine` per open vault, held by `Jobs/JobRuntimes` in the app's environment and shared by every window. The engine takes the vault's jobs lock (`<db>-jobs.lock`, an `flock` beside the database that the system drops when the process ends), so a second copy of the app on the same vault runs no job: it shows this device's runs as running in another copy and tries to take the lock over every 30 seconds. When the vault opens, `JobRuntime.launch()` resumes the attempts this device was running, then starts, one at a time, every job this device asked for that no attempt has started (`JobBacklog`): card actions, approvals' finalize reviews and finals' canon refreshes request their jobs in their own writes and are picked up this way. A start refused for a reason other than consent is tried again only when that list changes; while the novel's text may not be sent to the AI provider the engine refuses every start before an attempt exists, and the runtime waits until consent is given (from the chapter strip's Review Permission or any other consent sheet). While a job runs here the Mac holds a power activity that keeps it from idle sleep and App Nap. A screen that starts a run itself hands the handle to `JobRuntime.follow(_:)`. `Chapters/ChapterWorkspaceStrip` shows a chapter's status chip and one line per job in flight or failed, with Stop or Cancel, Run on This Mac (only while no device holds a live lease) and Try Again.

Waiting on you (`Chat/Changes/ChatWaitingTray`) also lists conflicted cards, which the reference marks conflicted and stops listing, so the author can still apply what fits or discard them.

Observe reads with `ReadObserver` (`Shared/ReadObserver.swift`; `run(_:onValue:)` hands every emitted value to a hook, and an equal value is not republished) and surface failures through `PresentedError` (a localized headline with the error code as detail, never developer text). Markdown prose is rendered by `Shared/ProseView`, which the Reader and the Story Bible share. Strings are per area (`Library`, `Navigation`, `Notebook`, `Story`, `StoryBible`, `Reader`, `Settings`, `Jobs` for the job runtime and chapter strip, `Generation` for runs and versions, `PlanCard` for Plan next chapter and its cards, `Checks`, `Finalize` for approve, the finalize review and finalize, `Amend` for amend and summarize, `Export`, `Costs` for run charges and the writer's view, `Sync` for the sync status indicator, and for chat `Chat`, `ChatComposer`, `ChatCards` and `ChatChanges`, each its own `<Area>.xcstrings`) and are used with `Text(_:tableName:)` and `LocalizedStringResource(_:table:)`; an area adds its own `<Area>.xcstrings` and never edits another's. `Localizable.xcstrings` holds only the vault-opening strings.

Each job's screen lives under `Chapters/`, one folder per area, and starts or reads the job through the core:

- Generation and versions (`Chapters/Generation`): options (guidance for the run, and whether and how many times to repair what the checks find), progress while the run streams, the saved versions of a chapter's draft, and an inline compare with a word diff. A run is a job of the core's generation pipeline, its steps checkpointed.
- Plan cards and Plan next chapter (`Chapters/PlanStart`, with the cards in Waiting on you): Plan next chapter asks `JobEngine.requestPlan` for a plan job with the author's line, shows its progress, and lists the plan cards it stages. A plan card staged with no chat shows only here and in Waiting on you; applying it goes through the chat card flow.
- Checks (`Chapters/Checks`): a chapter's findings from the deterministic checks and the editorial and continuity reviews, with the run's progress, Stop and Try Again; the blocking ones must be confirmed to approve over them.
- Approve and finalize (`Chapters/Finalize`): approving a draft requests a finalize review job; the dialog lists its items to accept, edit or skip, and finalizing writes the final chapter and requests a Story Bible refresh job. An approval whose text is out of date is made on the text the author read. Open blocking findings must be confirmed, or the core refuses and asks again.
- Amend, summarize and export (`Chapters/Amend`, `Export/`): amend rewrites a final chapter's text in place (the chapter stays locked), summarize writes a chapter summary with a model call for the author to review and save to the draft, and Export writes the manuscript (Markdown) or a `.novel` package through `NovelExport` (nothing is sent to a model). `.novel` is an exported type, `com.shadow.apps.novelforge.novel` (a zip, declared in `Project.swift`).
- Costs and the writer's view (`Chapters/RunCharges`, `Chapters/WriterInspector`): a chapter's runs with their per-call charges and total, and, on the device that made a call, what the writer was sent (other devices keep no request).

The retrieval index is kept current in the background by `Shared/RetrievalRuntimes` (see Retrieval); one set of the system's sentence embeddings (`AIServices.embedders`) serves it, the job engine's searches and the chat engine's lookups.

Pending OpenRouter costs settle at launch, when a job attempt ends and when a chat turn ends (`Shared/CostSettler`; one batch at a time, then a 60 s cooldown after a batch that priced nothing).

The cost lookup sends only the generation id with the user's own key; novel-text consent covers content sent to a model, not metered-cost lookups.

### Novel Forge sync wiring

`Sync/Runtime/SyncRuntimes` holds one `SyncRuntime` per open vault in the app's environment, owned with the `VaultModel` by the app delegate so a silent push can open the vault and sync it with no window. The vault opens with `SyncEngine.wallClock(preferring:)` of the model's one `TrustedClock`, which the runtime is handed too. Launch starts the runtime; the scene phase calls `foreground()` and, on iOS inside a background task (`Sync/Runtime/SyncBackgroundWork`), `background()`; on the Mac the app or a window becoming main counts as a foreground at most once a minute, and quitting sends what is unsent for up to 3 s. Every commit that logs a change (`VaultStore.loggedChanges()`; uploads and remote applies do not) calls `localWrite()`, a push calls `changeNotice()` for up to 25 s, and a vault opened in place of another, or closed, shuts its runtime down. While XCTest hosts the app nothing syncs.

`Sync/Runtime/SyncWiring` builds the `SyncStartupEnvironment`: the files under `<Application Support>/<bundle id>/Sync/` (`location.json`, the first-unlock probe, CloudKit's index and engine state), `SyncSecureStores.keychain(app: "com.shadow.apps.novelforge", sharedAccessGroup:)`, providers (a local folder through its security-scoped bookmark, kept open for the life of the process; S3 with its keychain credentials; OneDrive and Google Drive refused until they can sign in) and account checks (iCloud binds the user record name). Restricted capabilities are known from the `ShadowCapabilities` Info.plist dictionary, which `Project.app` writes only for the entitlements it emitted (`CloudKitContainer`, `PushNotifications`, `SharedKeychainGroup` with `$(AppIdentifierPrefix)` expanded by Xcode): iCloud is offered, attached on first use and its one `CKZoneClient` made only when both the container and pushes are there, remote notifications are registered only with pushes, and a shared group whose prefix was not expanded leaves the keys in the app's own group. A build without a team therefore never touches CloudKit, and only a folder or S3 can be chosen; on the Mac such a build cannot sync even there, since the data-protection keychain refuses every item, synced or this-device, without an application identifier (`errSecMissingEntitlement`, seen from the hosted tests), so creating or joining a vault fails and an attached one reports a sync failure. The iOS simulator was not tried.

A vault that cannot be opened before the device's first unlock (`FirstUnlockProbe`) waits as `locked` and opens on `protectedDataDidBecomeAvailableNotification` or Try Again. `Sync/Status/SyncStatusIndicator` sits in the library sidebar's toolbar: hidden while sync is off, otherwise up to date, syncing or attention needed, with a popover saying what is wrong and what it stops (`SyncIndicator`, strings in `Sync.xcstrings`); it never blocks anything.

## Catalog app

`Apps/Catalog` is a gallery of every component and token page in light and dark, with the presentation and device-screen demos. It is also the pipeline's smoke test and the subject of the screenshot harness. Run the `Catalog` scheme from the workspace, or `Catalog -list-components` to print the page ids.

Launch arguments: `-component <id>`, `-appearance light|dark`, `-scroll <0..1>`, `-screen <name>`, `-present`, `-animated` (keeps animations on for a deep link, which otherwise disables them).

### Screenshot harness

```sh
mise run screenshots -- --platform iphone,macos --component Button,Card --appearance both
mise run screenshots -- --help
```

Output goes to `scratch-pad/shots/latest/<platform>/<id>-<appearance>[-s<percent>][-<screen>][-presented][-landscape].png`.

| Option                             | Effect                                                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `--platform iphone,ipad,macos`     | Platforms to capture (default all)                                                                           |
| `--component <id>,…`               | Page ids from `Catalog -list-components` (default all)                                                       |
| `--appearance light,dark,both`     | Appearances (default both)                                                                                   |
| `--scroll <f>,…`                   | Scroll positions from 0 to 1 on scrolling pages, for example `0,0.5,1`                                       |
| `--screen <name>,…`                | Sub-screens of pages that have several, such as `library`, `today` and `stepup` on iPhoneScreens             |
| `--present`                        | Open the page's sample sheet, alert, popover, toast or palette before the shot; files get `-presented`       |
| `--orientation portrait,landscape` | iPad orientation. Landscape runs a UI test (`CatalogUITests/CatalogShotTests`)                               |
| `--content-size <name>`            | Simulator Dynamic Type size, such as `accessibility-extra-extra-extra-large`; the next default run resets it |
| `--out <dir>`                      | Output directory                                                                                             |
| `--skip-build`, `--keep-booted`    | Reuse the last build in `scratch-pad/derived-data`; leave simulators booted                                  |

How it captures:

- iPhone and iPad use `simctl io screenshot` on iOS 26.5 simulators. Each shot is retaken until two consecutive frames match.
- iPad landscape runs the iOS UI test, which rotates the device and screenshots with `XCUIScreen`. The harness writes the shot list to a file and passes its path in `CATALOG_SHOT_PLAN`; the test skips when the variable is absent.
- Mac needs no permission: the app composites its own windows into a PNG (`-snapshot <png>`), without Screen Recording access.

Simulators and the window server require running outside any command sandbox. Inside one the run hangs.

## Testing

```sh
mise run test:packages                      # shared packages with SwiftPM; no generation needed
mise run test:apps                          # tuist test --skip-ui-tests
tuist test Catalog --platform macOS --no-selective-testing
tuist test NovelForge --platform macOS --no-selective-testing
```

- `mise run test:packages` covers `ShadowKit`, `NovelForgeKit` and `MemoirKit`. Property tests print their seed on failure; rerun it with `replay(seed:)` from `ShadowTestSupport`.
- NovelForgeKit property tests spread their iterations over the cores, at most one per processor (`forAllConcurrently`). Unset, `ProjectionProperty` runs and the record helpers (`ProjectionProperty.iterations(full:)`) run half their iterations; plain `forAll` is never reduced. These keep every iteration at the default because a coverage gate or a kill needs them: the three-replica domain property, the plan-world reach test, the Notebook projection property and the Volume state property. `NOVELFORGE_PROPERTY_SCALE=n` runs `n` times the full iteration count of every property: 1 is full strength and is what CI runs (`.github/workflows/ci.yml` sets it), `NOVELFORGE_PROPERTY_SCALE=4 swift test --package-path Packages/NovelForgeKit` is the deep run for mutation checks, and unset is the local default (half). `NOVELFORGE_DOMAIN_REPLAY=<seed>` replays one domain case.
- Every suite takes a `TestTimeLimit` tier (defined once per test target) instead of a literal limit: `quick` 5 minutes for unit suites, `standard` 10 for store, replica and derivation suites, `property` 20 for property, interleaving and concurrency suites. They are hang detectors with headroom for a loaded machine, not performance budgets; polling helpers wait up to two minutes and return as soon as the condition holds.
- Three suites under `Tests/NovelForgeCoreTests` carry the chapter work's done-when: `ChapterInterruptions` (plan to canon killed at every crash seam of every pipeline, and resumed, with the same footprint as an uninterrupted run), `ChapterReplicas` (two replicas alternating steps, both asking at once, running apart, and running here after a lease lapsed) and `FinalizeIdempotence` (finalizing again, by relaunch, job, card or a second device, writes the same values).
- Pass `--no-selective-testing` when verifying a change: Tuist otherwise skips targets it considers unchanged.
- CI runs `swift test` for the packages, then `tuist test` per platform: iOS with UI tests, macOS with `--skip-ui-tests`, and visionOS with `--skip-ui-tests` on `Catalog` only (the new apps have no visionOS destination).
- Swift Testing tests that resolve `Color` or `Font` must be `@MainActor`.

## Adding an app

```sh
mise run new-app Memoir --platform multiplatform   # ios | macos | multiplatform | phoneAndMac | watchos | tvos | visionos
```

This creates `Apps/Memoir` with app, test target and scheme, bundle ID `com.shadow.apps.memoir`, and regenerates the workspace.

## Tasks

| Command                   | What it does                                          |
| ------------------------- | ----------------------------------------------------- |
| `mise run bootstrap`      | `tuist install` + `tuist generate --no-open`          |
| `mise run test`           | Package tests (`swift test`) and app tests (`tuist test`) |
| `mise run test:packages`  | Shared package tests only — no project generation     |
| `mise run test:apps`      | App tests without UI tests (`tuist test --skip-ui-tests`) |
| `mise run tokens`         | Regenerates design-token sources from `Design/tokens.json` |
| `mise run screenshots`    | Captures Catalog pages (see Screenshot harness)       |
| `mise run lint`           | `swift format lint --strict`                          |
| `mise run lint:graph`     | Fails on implicit or redundant module dependencies    |
| `mise run format`         | Formats sources in place                              |
| `mise run clean`          | Removes generated projects and build artifacts        |

## Conventions

- Swift 6 language mode with complete concurrency checking; `ExistentialAny` and `MemberImportVisibility` are on everywhere.
- App targets default to `MainActor` isolation; library modules do not, except `ShadowDesignSystem`.
- Swift Testing (`import Testing`) for all tests; test names start with `should`.
- Errors crossing a module boundary conform to `ShadowError` and are thrown with typed `throws(...)` where the set is closed.
- Minimum OS 26 on every platform, set once in `Organization.minimumOSVersion` and the package manifest.

## Third-party notices

The BIP-39 English word list embedded in `RecoveryWordList.swift` is used under the MIT licence; see `THIRD_PARTY_NOTICES.md`.
