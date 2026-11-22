# Privacy manifests

Every app that uses an API on Apple's required-reason list ships `Apps/<App>/Resources/PrivacyInfo.xcprivacy`. The app target's `Resources` buildable
folder copies it to the bundle root (`<App>.app/PrivacyInfo.xcprivacy` on iOS, `<App>.app/Contents/Resources/PrivacyInfo.xcprivacy` on the Mac).
Catalog uses no listed API and ships none.

Both manifests set `NSPrivacyTracking` to false with no tracking domains and leave `NSPrivacyCollectedDataTypes` empty: the developer collects
nothing. Writing and model requests go only to the provider the owner configured, under the owner's key, and the vault syncs only to a location the
owner chose. The App Privacy answers in App Store Connect are the owner's to give and must agree with these files.

## What links into each app

ShadowKit, NovelForgeKit and MemoirKit link statically into the app binary, so their API use is the app's and is declared in the app's manifest.
GRDB also links statically; its own `PrivacyInfo.xcprivacy` (declaring no API and no data) arrives in the app as `GRDB_GRDB.bundle`, and its sources
call no listed API. SQLite is the system `libsqlite3`, outside the app binary.

## Declared reasons

| Category | Reason | Apps | Why |
| --- | --- | --- | --- |
| UserDefaults | CA92.1 | Memoir, Novel Forge | Device-local settings under `com.shadow.apps.<app>.*` and the shell's `.ai.*`/`.sync.*` keys, read and written by the app alone; no App Group suite |
| FileTimestamp | 3B52.1 | Memoir, Novel Forge | `LocalFolderProvider` reads entry kind and size (`lstat`) and the age of its own stale temporary files (`.modificationDate`) inside the folder the owner picked through `LocalFolderAccess` |

Neither app uses a SystemBootTime, DiskSpace or ActiveKeyboards API; elapsed time comes from `ContinuousClock` (Novel Forge's chat trace through
`SystemMonotonicTimeSource`). No listed FileTimestamp API touches files in the app container, so C617.1 is not declared.

Looked at and not on Apple's list: `ContinuousClock` (Swift runtime), `attributesOfItem` read for `.size` and `.protectionKey` (`VaultBlobs`,
`VaultFiles`), `resourceValues` for `.fileSizeKey`, `.isExcludedFromBackupKey` and `.canonicalPathKey`, and `CKRecord.modificationDate` (a server
record's metadata, not a file's). The reason codes are the ones Xcode's own `.xcprivacy` schema allows (`DVTCorePlistStructDefs`) and Apple's
`NSPrivacyAccessedAPIType` reference describes.

## Evidence

`swift Scripts/check-privacy-manifests.swift --evidence` prints every call site with its line and the apps that link it. The files:

| Category | Files | Linked by |
| --- | --- | --- |
| FileTimestamp | `Packages/ShadowKit/Sources/ShadowSync/Storage/LocalFolderProvider.swift` | Memoir, Novel Forge |
| UserDefaults | `Packages/ShadowKit/Sources/ShadowAppShell/AI/AIServices.swift`, `Packages/ShadowKit/Sources/ShadowAppShell/Sync/Keys/RecoveryPhraseRecord.swift` | Memoir, Novel Forge |
| UserDefaults | `Apps/Memoir/Sources/`: `AI/MemoirConsent.swift`, `Ask/AskView.swift`, `Data/MemoirDeviceDefaults.swift`, `Data/MemoirVaultDeletion.swift`, `Health/HealthEnvironment.swift`, `Hero/WithdrawalAcknowledgements.swift`, `Log/WeightModel.swift`, `Reminders/ReminderDeviceSetting.swift`, `Reminders/RemindersSettingsView.swift`, `Shared/ComingBackDismissal.swift` | Memoir |
| UserDefaults | `Apps/NovelForge/Sources/`: `Chapters/Finalize/FinalizeButton.swift`, `Shared/AIServices+NovelForge.swift`, `Worker/WorkerModel.swift`, `Worker/WorkerRecordAccess.swift` | Novel Forge |

## The guard

`mise run privacy:check` (also the last step of `mise run lint`, so CI runs it) reads each app's `dependencies:` in `Project.swift`, follows
`.shared`/`.product` modules through the packages' targets (`swift package dump-package`), scans the app's `Sources` and every linked module for the
listed APIs, skipping line and block comments, and fails when:

- an app uses a category its manifest does not declare, or uses one and has no manifest;
- a dependency names a module that no package under `Packages/` defines (only a product of a package outside `Packages/` counts as third-party);
- a manifest declares a category nothing linked uses;
- a manifest is not a property-list dictionary, lacks one of the four top-level keys, declares a category twice or without a reason, or gives a
  reason Apple does not define for that category.

It checks categories, not which reason applies; choosing the reason stays a reading of Apple's text against the call site. It reads source, so a
call it has no pattern for escapes it, and `getattrlist` counts as FileTimestamp only: a call that reads volume capacity also needs DiskSpace.
Modules from third-party packages are out of scope and must ship their own manifest.
