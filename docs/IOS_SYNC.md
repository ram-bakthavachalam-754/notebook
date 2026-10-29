# iPhone app and private iCloud sync

Notebook has native SwiftUI iPhone/iPad and Mac apps and a shared Swift SQLite
store with CloudKit sync. iOS 17+ and macOS 14+ are required. No VPN, network ports, or third-party app
is needed. Both devices use the same Apple Account for iCloud.

## Current build status

Local builds work without signing in to iCloud. The iPhone simulator build and
Mac app have been exercised locally. Offline storage, causal conflict handling,
JSON migration, encryption, and the pairing cryptography have automated tests.
The simulator UI test writes a note, terminates/relaunches the app, verifies its
body, creates a separate journal entry, and opens pairing settings. Thirteen native
core tests, twelve Node tests, and the iPhone UI test pass. The packaged Mac app
and DMG also pass startup/storage and signature/checksum verification.

A signed CloudKit-enabled Release build was installed and launched on the paired
iPhone on 2026-10-12. Updating the same bundle ID retains its local notebook.

An earlier integration attempt encountered CloudKit's **“Invalid bundle ID for
container”** error. The existing paired notebook successfully uploaded through
the provisioned Mac helper on 2026-10-12; that earlier association failure was not
reproduced. If the association error recurs, confirm the container is assigned to both
the iOS and Mac App IDs under iCloud → Edit in Apple's Developer Portal, refresh
provisioning, then rebuild the signed apps. Apple describes this error
and possible server-side association delays in
[TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer).
Explicit offline builds report “iCloud setup required”; provisioned builds display
the server error if pairing cannot proceed. Automated tests use isolated temporary
libraries. The 2026-10-12 repair also synced the user's existing paired notebook.

## Run and build

From the repository root:

```sh
npm test
npm run test:native
npm run build:ios
npm run test:ios
npm run start:macos
```

`ios/Notebook.xcodeproj` contains the iPhone app, its UI tests, the Mac app
(NotebookMac) and the share extension. Open it in Xcode,
select Notebook and an iPhone simulator, then Run. The app uses no external Swift
packages; the `NotebookCore` local package lives in `native/`.

The iOS simulator app is `build/ios/Build/Products/Debug-iphonesimulator/Notebook.app`.
A simulator `.app` cannot be installed on a physical phone. Build with your team
and device selected in Xcode, or distribute a signed archive through TestFlight.

## Enable CloudKit with your Apple Developer team

1. Create a private CloudKit container, for example `iCloud.com.yourteam.notebook`.
   Register an iOS App ID and a macOS App ID under the **same team**, each
   entitled to that container. Enable iCloud/CloudKit and push notifications.
2. Copy `ios/Signing.local.xcconfig.example` to `ios/Signing.local.xcconfig`.
   Set `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER`, and
   `NOTEBOOK_CLOUD_CONTAINER`. Set `NOTEBOOK_CLOUD_ENABLED = YES` and the supplied
   `CODE_SIGN_ENTITLEMENTS` path only after the provisioning is in place.
   The local file is ignored by git. Select your physical phone in Xcode and Run.
3. For the Mac app, set `NOTEBOOK_MAC_BUNDLE_ID` and `NOTEBOOK_MAC_ENTITLEMENTS`
   and run `npm run build:macos:signed` or `npm run install:macos`. See
   [Native Mac app](NATIVE_MAC.md).

4. Use the **same CloudKit environment on both builds**. Development iOS and
   development Mac profiles use Development. TestFlight/App Store and Developer
   ID release builds use Production. Develop/test the schema in Development,
   then deploy it to Production in CloudKit Console before release.

CloudKit schema uses two record types:

| Type | Custom zone | Fields |
| --- | --- | --- |
| `NotebookChange` | `Notebook-<notebook UUID>` | `payload`: Asset (application-encrypted revision) |
| `NotebookPairing` | `NotebookPairing` | `request`: Bytes; `approval`: Bytes (both encrypted) |

Zones and records are created by the app when permitted in Development. No
public database or server API key is used. Both sides use record IDs/change
tracking; no query indexes are needed. Register iOS remote notifications and
allow its `remote-notification` background mode. CloudKit's engine manages its
record-change subscription.

## Pair and validate on real devices

Open **iCloud** (or **Connect iPhone**) on an unlocked Mac, then choose
**Generate new QR code**. The QR code expires after ten minutes.
On iPhone, open Settings → Scan pairing code. Check the six-digit code matches
on both screens, then approve on the Mac. The Mac uploads its existing records;
the phone downloads them into its own database. Notes created on the phone
before pairing are included too, using unique record IDs.

To retry pairing, generate another code on the Mac. On iPhone, Settings →
**Pair again** keeps the scanner available even if the notebook is already linked.
Re-pairing only accepts the same notebook and preserves local edits, history,
cloud checkpoints, and the existing encryption key. It does not clear a cooldown.
There is no device-disconnect/revocation feature in this version.

After pairing, devices exchange changes independently through iCloud. The Mac
checks while Notebook is open/unlocked (30-second timer plus focus/reconnection).
iOS checks on foreground activation, while open (20-second timer), after leaving
an editor, on pull-to-refresh, and on background notifications. iOS decides when
background delivery runs; “continuous” does not mean guaranteed instant delivery
while suspended or force-quit. An off/sleeping device catches up when it runs again.

Before considering cloud sync release-ready, validate these cases on a signed
Mac and physical iPhone using a **test notebook**:

- Pair, including attachments, and confirm full download after app restart.
- Edit while the other device is asleep; reconnect and compare both copies.
- Edit the same note on both devices offline: both versions must remain.
- Delete on one while editing on the other: preserve the edited conflict copy.
- Kill the app during upload/download and verify idempotent retry.
- Cancel/expire pairing; mismatched confirmation must not grant the key.
- Sign out/switch iCloud accounts: pause without deleting or uploading the
  original notebook into another account.
- Exercise quota/network failures, large photos/videos, and real Face ID/Touch ID.
- Delete the test CloudKit zone: stop sync, retain local data, report the error.

## Temporary iCloud throttling

CloudKit can return HTTP 503/service-unavailable or rate-limit errors with a
retry-after interval. Version 0.2.1 saves that deadline in SQLite and gates
manual sync, account checks, and pairing requests until it expires, including
after restart. The app shows the remaining wait in minutes. Automatic
CKSyncEngine requests use Apple's own retry handling. Local edits remain
available and queued. A pairing invitation may expire during a long cooldown;
after the wait, generate and scan a fresh code. A cooldown expiring does not
resolve a separate app/container association error.

## Storage, migration, and conflicts

The canonical Mac database is now
`~/Library/Application Support/Notebook/notebook.sqlite`, with SQLite WAL files.
Before the first migration, the old JSON `data/` directory is copied into a
`data-backup-<timestamp>/` directory. Its original JSON files remain untouched.
Migration validates JSON before import, preserves IDs/HTML/attachments, and is
restart-safe. After migration those JSON files are a historical backup, not the
active data.

Markdown files in `~/Notebook` remain a Mac projection. Local Markdown edits and
explicit deletions enter the same revision stream as edits made in the app.

Each note, journal entry, tag, or media object has immutable revisions with
parent revision IDs. Saving a record and queuing its upload is one transaction.
Deletes are revisions with no payload. Omission from a stale collection is not
a deletion. Clocks are used for display, never to choose a winning concurrent
edit. Repeated/out-of-order delivery is safe. Concurrent heads appear as separate
copies; the iPhone editor offers “Keep this version” with confirmation. Resolution
only replaces versions the user actually saw. Other branches remain intact.

The initial implementation retains full revision history, including media, to
avoid deleting something an offline device still needs. Storage and iCloud usage
will grow over time; compaction and storage management are follow-up work before
large-scale distribution. Rich HTML remains compatible with the Mac. iOS supports
text formatting, tags, moods, images, and displaying existing embedded media;
it does not reproduce every specialized desktop editor/template command.

## Privacy and key ownership

Sync revision payloads (including attachment bytes) are sealed with AES-GCM
before CloudKit receives them. Notebook UUID plus revision ID is authenticated
associated data. CloudKit sees opaque IDs, ciphertext sizes/timing, and the
account's private zones, not the note/journal payload.

The QR carries a random invitation secret and ephemeral public key. A phone
submits an encrypted request containing its own ephemeral public key. After Mac
approval, ECDH/HKDF derives a key specific to that phone; the approval contains the
notebook key encrypted for it. Expiration, explicit approval, and the matching
confirmation code protect the pairing flow. Notebook keys are stored in each
device's non-synchronizing Keychain, not in renderer storage or CloudKit.

Keep at least one authorized device available. This version does not yet provide
an offline recovery-key export or device revocation/key rotation. Losing all
Keychain copies means the encrypted cloud history cannot be decrypted, though
surviving local databases/exports can still be recovered independently.

Mac password/Touch ID and iPhone Face ID/device passcode are local app locks;
password hashes are never synced. The Mac SQLite database and Markdown exports
remain readable on disk, as the previous JSON files were. iOS uses its sandbox
and file protection. Cloud encryption does not make the Mac app lock into
at-rest encryption.

## References

- [Apple: CKSyncEngine sample and setup](https://github.com/apple/sample-cloudkit-sync-engine)
- [Apple: CloudKit architecture choices](https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app)
- [Apple: Developer ID and CloudKit provisioning](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple: background execution](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)

## Finance (2026-10-11)

Finance is available on Mac and in the native iPhone/iPad app. The iOS target
bundles the same `portfolio-app.js`, `portfolio-strategy.js`, `spending-app.js`
and `finance-transfer.js` resources used by the Mac. JavaScriptCore runs the
arithmetic and transfer validation; native SwiftUI owns screens, forms, Files
import/export, URLSession quotes and SQLite writes. No hosted coach or banking
credentials are involved.

`RecordStore` projects Finance's three blob interfaces from individual immutable
`finance` revisions: a separate entity for each array record and snapshot day.
All keys in an import, including their pending sync revisions, commit together.
Independent offline additions union. Unlike prose conflicts, concurrent versions
of one Finance record resolve deterministically by revision time then revision ID,
so totals never include two copies; all versions remain in immutable history.
Unchanged stale rows cannot overwrite incoming edits or resurrect deleted records.
Snapshots carry explicit tombstones. Quotes stay on each device and never stamp
account or transaction records. Legacy Mac-only Finance keys are migrated once;
original KV values are retained. Older builds do not recognize Finance revisions:
update every paired device together.

On 2026-10-12 the running desktop package had an ad-hoc helper without iCloud
entitlements, leaving 230 Finance revisions pending. Rebuilding with the provisioned
helper uploaded all pending revisions and reported zero pending uploads. Both
devices were already paired to the same notebook; no re-pairing or re-import was
needed. Build scripts now retain configured CloudKit support for ordinary builds.
After the repair, a diagnostic copy of the physical iPhone database contained all
330 Finance revision IDs with payloads identical to the Mac and no pending Finance
uploads on either device. The repaired `/Applications/Notebook.app` helper reports
iCloud available and up to date. All 26 Node regression tests pass, including the
new build-mode checks. This verifies delivery on the existing pairing, not every
failure scenario in the release checklist above.
JSON import/export through Files also works independently of pairing.

iOS fetches quotes directly with URLSession. Pull down in Finance or use Finance
actions → Refresh prices; the Mac does not need to run. Quotes are cached locally
and do not sync as account edits.
