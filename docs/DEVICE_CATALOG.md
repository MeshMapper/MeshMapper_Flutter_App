# Server Managed Device Catalog Design

Status: approved in conversation, revised after architecture review, pending final review of this written specification.

## Purpose

Move MeshMapper device recognition from a bundled app asset to a server-managed catalog. The app downloads the catalog once per launch, caches the last valid response, and uses aliases to recognize firmware identity variations such as `T1000e`, `T1000-E`, and `T1000E_OTA`.

Device recognition remains advisory. An unknown device can always connect and use the existing manual reporting-power flow. Catalog download, matching, and unknown-device reporting must never change radio settings or reject a connection.

## Current Behavior and Problem

The Flutter app currently reads `assets/device-models.json`. Connection code contains a private matcher separate from `DeviceModelService.matchDevice`, so recognition rules are duplicated. The bundled catalog contains a `Seeed Tracker T1000` row, but firmware can report other forms of the identity and those forms are not modeled explicitly.

The server has no catalog source of truth and `master_admin.php` has no workflow for reviewing unknown identities. Updating the bundled asset also requires an app release.

## Goals

- Make a SQLite database on the MeshMapper server the authoritative device catalog.
- Seed that database with all 39 records from the existing Flutter JSON catalog.
- Let MASTER admins add, edit, enable, and disable supported devices and their aliases.
- Let MASTER and GLOBAL admins see supported devices and unknown reports.
- Require a MASTER admin to approve every addition to the supported catalog.
- Put pending unknown devices at the top of the Devices page.
- Refresh the app catalog once per app process launch and cache the last valid response locally.
- Report genuinely unknown firmware identities without delaying or preventing connection.
- Centralize app matching so every transport uses the same rules.

## Non-Goals

- The app will not change a radio's configured TX power.
- Unknown reports will not automatically create devices or aliases.
- The app will not retain a bundled runtime catalog after migration.
- The server will not permanently delete supported devices or unknown reports through the admin interface.
- The first version will not add per-device analytics, location collection, or device ownership tracking.

## Source of Truth and Bootstrap

The server stores live data in `device_models.db`. A committed PHP seed resource is generated from the existing `assets/device-models.json` before that asset is removed. The seed records source commit `a66debd91f8f52b214be44ec71d4068d0c7c2815` and SHA-256 digest `765a4581443dd9752959ceaf9c37e2506392994eacafcd2b04b8adeec66870b2`. It preserves all six original fields of all 39 decoded device rows, then adds the approved T1000 aliases. Bootstrap does not fetch GitHub or depend on a sibling checkout.

Bootstrap is permitted only when the database file is absent or when a failed initial transaction left a valid SQLite file containing no committed catalog tables or rows. Initialization is serialized, and schema, seed data, aliases, and metadata commit together so concurrent first requests cannot seed twice. An existing database containing catalog tables or rows but missing valid metadata is an initialization error and must not be automatically seeded, repaired, or overwritten. A corrupt database is also an error. Both cases return the normal non-fatal catalog failure and require operator recovery.

After bootstrap, SQLite is authoritative. The seed is never reread into an existing initialized database, so subsequent admin edits are not overwritten. The Flutter asset and its `pubspec.yaml` registration are removed. If an installation has no local cache and the server is unavailable, the app has no catalog for that launch and treats the connected device as unknown without reporting it.

Direct HTTP access to the seed or catalog helper returns 404 without emitting catalog data or opening or creating the database. Deployment verifies the active `/etc/apache2/conf-available/meshmapper-security.conf` rule returns 403 for `device_models.db`, `device_models.db-wal`, and `device_models.db-shm`. The implementation must not rely on `.htaccess` because production uses `AllowOverride None`.

All SQLite connections enable a 5,000 ms busy timeout and `PRAGMA foreign_keys=ON`. Catalog and report writes acquire `BEGIN IMMEDIATE` before validation reads. Public catalog reads load metadata, enabled devices, and identities from one consistent read transaction.

## Server Data Model

### `device_catalog_meta`

- `schema_version INTEGER NOT NULL`
- `catalog_revision INTEGER NOT NULL`
- `seeded_at TEXT NOT NULL`

There is exactly one metadata row. `catalog_revision` increments only when a supported device or alias is added, edited, enabled, disabled, or removed from a relationship. Unknown report activity does not change it.

### `device_models`

- `id INTEGER PRIMARY KEY`
- `short_name TEXT NOT NULL`
- `power REAL NOT NULL`
- `platform TEXT NOT NULL`
- `tx_power INTEGER NOT NULL`
- `notes TEXT NOT NULL DEFAULT ''`
- `enabled INTEGER NOT NULL DEFAULT 1`
- `created_at TEXT NOT NULL`
- `updated_at TEXT NOT NULL`

`power` is reporting metadata and must be finite and greater than zero. `tx_power` is descriptive firmware metadata and is not written to the radio.

### `device_model_identities`

- `id INTEGER PRIMARY KEY`
- `device_model_id INTEGER NOT NULL`
- `kind TEXT NOT NULL`, limited to `manufacturer` or `alias`
- `value TEXT NOT NULL`
- `normalized_value TEXT NOT NULL UNIQUE`
- `created_at TEXT NOT NULL`

Identities use a foreign key to `device_models`. A partial unique index permits at most one `manufacturer` identity per device, while any number of aliases may belong to it. Transactional bootstrap and admin validation require exactly one manufacturer identity before a device can commit. The single `normalized_value` uniqueness constraint prevents manufacturer-versus-alias and alias-versus-alias collisions across all devices. Removing an alias is allowed, but deleting a supported device is not exposed by the admin interface.

### `unknown_device_reports`

- `id INTEGER PRIMARY KEY`
- `reported_name TEXT NOT NULL`
- `normalized_name TEXT NOT NULL UNIQUE`
- `report_count INTEGER NOT NULL DEFAULT 1`
- `first_seen_at TEXT NOT NULL`
- `last_seen_at TEXT NOT NULL`
- `latest_app_version TEXT NOT NULL DEFAULT ''`
- `latest_firmware_version TEXT NOT NULL DEFAULT ''`
- `status TEXT NOT NULL`, limited to `pending`, `resolved`, or `dismissed`
- `resolved_device_model_id INTEGER NULL`
- `resolution_kind TEXT NULL`, limited to `new_device` or `alias`
- `resolved_at TEXT NULL`

Repeated accepted API submissions update the existing normalized row, its count, last-seen time, and latest version fields. `report_count` counts accepted submissions, not unique devices or people. A dismissed row stays dismissed when reported again, but its count and last-seen time continue to update. MASTER can reopen it. Approval marks it resolved and records the target device and resolution type. If a previously resolved identity later stops matching the enabled catalog because its alias was removed or its device was disabled, a new report returns that report to pending, clears its resolution fields, and requires human review again. This is the only automatic reopening rule.

## Normalization and Matching

Both repositories use identical committed fixtures for normalization and validation. Matching first sanitizes the reported text, then removes only a trailing firmware build suffix matching `nightly-<hex>`, `stable-<hex>`, or `dev-<hex>`, case-insensitively, with optional separating whitespace. No other suffix or prefix is removed.

Normalization then applies these exact operations:

1. Remove control characters U+0000 through U+001F and U+007F.
2. Trim surrounding Unicode whitespace.
3. Lowercase ASCII `A` through `Z` only.
4. Remove every character except ASCII `a` through `z` and `0` through `9`.

Values whose normalized result is empty are invalid. Input JSON must be valid UTF-8. Length limits count Unicode scalar values after sanitization, never bytes or UTF-16 code units.

The client compares the normalized firmware identity for exact equality with each enabled model's normalized manufacturer, short name, and aliases. There is no arbitrary substring, prefix, token-count, or fuzzy matching. All exact matches are collected by unique device ID. Exactly one matching device ID is recognized; zero or multiple matching device IDs are unknown. Duplicate short names remain allowed because the existing catalog has hardware variants with a shared display name.

The seeded T1000 record gains these aliases:

- `Seeed Tracker T1000-E`
- `T1000e`
- `T1000E_OTA`

`T1000-E` normalizes to the same identity as `T1000e`, so it is covered without storing a duplicate normalized alias. Additional firmware identity forms require a human-approved alias.

Matching is implemented once in a pure Flutter matcher used by `MeshCoreConnection` and any service-level lookup. The server independently applies the same exact-match rule to a submitted unknown name inside the same write transaction that creates or updates a pending report.

## App API Contract

Both operations use `POST /wardrive-api.php/devices` and the existing API key whose key type is `App`. The route is recognized before normal wardrive parameter inference and handled immediately after the App-key check, before session, zone, or location work.

### List request

```json
{
  "key": "<build-injected app key>",
  "action": "list"
}
```

Successful response:

```json
{
  "success": true,
  "revision": 4,
  "devices": [
    {
      "id": 12,
      "manufacturer": "Seeed Tracker T1000",
      "shortName": "Seeed Tracker T1000",
      "aliases": ["Seeed Tracker T1000-E", "T1000e", "T1000E_OTA"],
      "power": 0.3,
      "platform": "nrf52",
      "txPower": 22,
      "notes": "Seeed Tracker T1000"
    }
  ]
}
```

Only enabled devices appear. Aliases are ordered case-insensitively for stable responses. Invalid keys receive the existing indistinguishable 401 response used by the wardrive API. Invalid actions or fields receive a JSON 400 response. Server failures receive a JSON 500 response without internal paths or SQL details.

The list client accepts a response only when HTTP status is 200, `success` is boolean `true`, `revision` is a non-negative integer, and `devices` is an array. Each `id` and `txPower` is an integer, `power` is a finite JSON number, every text field is a string, and `aliases` is an array containing only strings. It does not coerce strings, numbers, booleans, arrays, or null between types.

### Unknown report request

```json
{
  "key": "<build-injected app key>",
  "action": "report_unknown",
  "manufacturer": "T1000e",
  "app_version": "1.4.0",
  "firmware_version": "1.10.0"
}
```

The server accepts a non-empty manufacturer of at most 160 Unicode scalar values and version strings of at most 80 scalar values after sanitization. The manufacturer must normalize to a non-empty value. It returns one of these successful statuses:

- `known`: the current server catalog already recognizes the name.
- `pending`: a pending report was created or updated.
- `dismissed`: a dismissed report was updated without reopening it.

A successful report returns HTTP 200 with exactly this envelope, where `status` is one of the three values above:

```json
{
  "success": true,
  "status": "pending"
}
```

The client acknowledges an outbox entry only when HTTP status is 200, `success` is boolean `true`, and `status` is exactly `known`, `pending`, or `dismissed`. Every other response retains the entry.

Requests must be JSON objects. `action` and every text field must be strings, with no coercion from arrays, numbers, booleans, or null. Validation failures return HTTP 400 with exactly:

```json
{
  "success": false,
  "reason": "invalid_request",
  "message": "Invalid device request"
}
```

The request contains no location, public key, API session, or persistent app-install identifier.

## App Startup, Cache, and Reporting Flow

`DeviceModelService` owns the cache, one shared launch refresh future, matcher, and local unknown-report outbox. `ApiService` owns only the HTTP requests and strict response decoding. Catalog methods do not invoke maintenance, authentication, session-expiry, or session-failure callbacks.

On every app process launch:

1. Await only the local `SharedPreferences` read and make the last valid catalog available immediately.
2. Start exactly one shared server refresh future for that launch without awaiting its network work during general app initialization.
3. Validate the entire response before changing memory or disk.
4. Atomically replace the in-memory catalog and cached JSON after a valid response.
5. Keep the previous cache unchanged after the 10-second request timeout, a transport error, authentication error, malformed response, empty list, a response over 1 MiB, more than 500 devices, more than 50 aliases on one device, an invalid record, or a normalized identity collision.
6. After a successful refresh, discard queued unknown reports now recognized by the fresh catalog and retry the remaining reports.

The refresh has one 10-second total deadline measured from its initial start. That deadline includes a stale-connection replay and reading the response body, so a replay cannot start a second 10-second budget.

The connection UI does not wait on the refresh when a cached catalog is available. At connection workflow step 4, identification obtains the service's current catalog rather than using a list copied before the protocol handshake. If no cache exists, identification awaits only the remaining lifetime of the already-running refresh. It proceeds as unknown when that shared deadline expires.

Once identification finishes, its selected model and reporting power remain fixed for that connection. A refresh that completes later applies only to a subsequent connection and never replaces a user's manual reporting-power override.

When a successfully queried device identity does not match an available catalog, the app adds it to a small `SharedPreferences` outbox and attempts the report asynchronously. One serialized mutation path owns every outbox read, write, and dispatch. Refresh draining, reconnects, and new observations share one in-memory attempted set. A normalized identity is claimed in that set before the first await, so it is attempted at most once per launch. A failed report is not retried again during the same launch.

Each outbox entry carries a local generation that changes when a newer observation replaces its metadata. A successful `known`, `pending`, or `dismissed` response removes the entry only if the stored generation is still the one submitted. A failed request remains for a future launch. The outbox is bounded to 50 normalized identities by last-observed order, retaining the newest observation for each name.

A failed catalog refresh does not drain reports left from an earlier launch. A new unknown observation made against a valid cached catalog may still attempt its report. Reporting has its own 10-second total deadline and never blocks connection work.

If no catalog is available, the app cannot distinguish an unsupported model from a catalog outage. It therefore connects as unknown but neither queues nor submits an unknown report. Recognition failure never rejects, disconnects, or limits the transport.

## Master Admin Interface

Add a Devices tab under Configuration. It is visible to MASTER and GLOBAL roles and follows the existing `master_admin.php` visual system, typography, colors, spacing, table behavior, and modal conventions.

The page's primary emphasis is the review queue. A compact pending-count badge and restrained attention styling distinguish it without redesigning the admin shell.

### Pending Unknown Devices

This section is always first. Pending rows sort by `last_seen_at` descending and show:

- Reported name
- Report count
- First seen
- Last seen
- Latest app version
- Latest firmware version

GLOBAL sees the table without action controls. The report view uses server-side pagination with 100 rows per page while preserving the status filter and sort order. MASTER receives:

- **Approve as new**: opens a modal prefilled from the report. Manufacturer, short name, reporting power, platform, TX power, notes, and aliases can be completed before saving. Approval always creates an enabled device. The reported name is preserved as the manufacturer or an alias so the approved identity matches immediately.
- **Attach as alias**: opens a searchable enabled-device selector and a confirmation summary. Disabled devices cannot be targets. Saving adds the reported identity as an alias and resolves the report in one transaction.
- **Dismiss**: keeps the record with dismissed status.

A status filter exposes dismissed and resolved reports. MASTER can reopen a dismissed report, returning it to pending. A resolved report automatically returns to pending only when a later report no longer matches the current enabled catalog. Nothing automatically approves a report, and dismissed reports never reopen automatically.

### Supported Devices

This section appears below Pending Unknown Devices. It supports text search and enabled/disabled filters and shows manufacturer, short name, aliases, reporting power, platform, TX power, status, and updated time.

GLOBAL has read-only access. MASTER can add a device, edit all device fields and aliases, enable a device, or disable a device. There is no permanent delete action. Validation and uniqueness failures stay in the modal with the submitted values intact.

All interactive controls have visible keyboard focus, modal labels, descriptive button text, and responsive table overflow consistent with the existing admin interface.

Add `devices` to the page's `SKIP_TABS` collection so the tab uses a full page load rather than generic PJAX form interception. A failed mutation renders the submitted values back into the correct open modal with a field-specific error. Every database, catalog, and report value is HTML-escaped in table cells, attributes, modal content, and audit display.

## Authorization and Audit

Every Devices tab mutation is POST-only, CSRF-protected, and gated directly with:

```php
($_SESSION['master_role'] ?? '') === 'MASTER'
```

The implementation must not use the fail-open `$userRole` default for mutation authorization. GLOBAL can reach only read paths, even when crafting requests directly. CSRF validation also fails closed when the expected helper is unavailable.

Each mutation is registered in `admin_audit.php::aa_actions()` with role `MASTER`. Every handled path explicitly settles the existing audit result as `ok` after commit, `fail` after validation or database refusal, `csrf_fail` after CSRF refusal, or `forbidden` after role refusal. Required audited actions are:

- Add supported device
- Edit supported device
- Enable supported device
- Disable supported device
- Approve report as new device
- Attach report as alias
- Dismiss report
- Reopen report

Captured audit metadata may include database IDs and non-secret display names. It must not include the app API key.

## Validation and Failure Handling

- Server strings follow the shared sanitization rules, and exact maximum lengths are enforced: 160 Unicode scalar values for manufacturer and alias, 160 for short name, 80 for platform, and 2,000 for notes.
- A manufacturer identity, short name, power, platform, and TX power are required for a supported record. Manufacturer and aliases must normalize to non-empty values.
- Reporting power must be finite, greater than zero, and no greater than 100. TX power must be an integer from -30 through 100.
- Manufacturer and alias normalized values are globally unique through `device_model_identities.normalized_value`.
- Every supported device is limited to 50 aliases, including while disabled. Before any catalog mutation commits, the server serializes the prospective enabled catalog with the production response encoder and next revision. It rejects the mutation unless the result contains 1 through 500 enabled devices and the complete UTF-8 response is no larger than 1,048,576 bytes. This validation occurs inside the same write transaction. Public reads never truncate devices or aliases to fit.
- Admin mutations that affect multiple rows use one `BEGIN IMMEDIATE` transaction and increment the catalog revision exactly once. Every validation read occurs after the transaction acquires its write lock.
- Approve-as-new must produce an enabled device. Attach-as-alias requires an enabled target. Before resolving the report, the server runs the production matcher against the prospective enabled catalog and requires the reported name to match the selected device uniquely. Catalog mutation, prospective-response validation, match validation, report resolution, and revision increment commit together.
- Report matching and the resulting insert or update use one `BEGIN IMMEDIATE` transaction, preventing an approval from racing between the recognition check and pending-row write.
- Admin mutations re-read report status and target enabled state after acquiring the transaction and reject stale actions without changing rows or revision.
- An invalid or empty catalog response never replaces the app's last valid cache. Catalog validation rejects cross-device manufacturer or alias collisions but permits duplicate short names.
- Disabled devices disappear from the public response. An offline app may continue recognizing one from its last valid cache until its next successful refresh.
- An absent database or an empty valid SQLite file left by a rolled-back first initialization may bootstrap. A database with catalog tables or rows but missing or malformed metadata, and any corrupt database, is refused without modification and requires operator recovery.
- Unknown-report failures are non-fatal and do not surface as connection errors.

## Implementation Boundaries

### Server repository

- Add a guarded device-catalog module responsible for schema setup, bootstrap, validation, queries, normalization, and transactional mutations.
- Add the guarded seed resource generated from the existing Flutter JSON.
- Add the `/devices` route and two actions to `wardrive-api.php` behind the existing App-key gate.
- Add the Devices tab, POST handlers, tables, filters, and modals to `master_admin.php`.
- Register every new mutation in `admin_audit.php`.
- Document the App API contract in `docs/APP_API.md`.

### Flutter repository

- Extend the device model with aliases and introduce a catalog response type with a revision.
- Add list and unknown-report methods to `ApiService`.
- Replace asset loading in `DeviceModelService` with validated `SharedPreferences` cache and one refresh per launch.
- Add a pure shared matcher and remove the duplicate connection matcher.
- Preserve unknown-device connection and manual reporting-power behavior.
- Remove `assets/device-models.json` and its asset registration.
- Update `AGENTS.md` and `DEVELOPMENT.md` together for the architecture and service changes.

## Test Strategy

Implementation follows red, green, refactor. Each behavioral test must be observed failing for the intended missing behavior before production code is added.

### Server tests

- Bootstrap has full row-for-row parity with all 39 decoded source rows and adds the T1000 aliases. Direct seed/helper requests return 404, concurrent first requests seed once, an empty valid file left by an injected pre-commit rollback can retry, and reopening preserves admin edits. A database with catalog rows but missing or malformed metadata is refused without modification.
- Schema constraints reject competing normalized manufacturer and alias additions and enforce foreign keys on real connections.
- Public list returns enabled devices only with stable aliases and revision.
- `/devices` rejects missing, wrong-type, and invalid API keys through the existing gate.
- Report responses cover all three exact success envelopes plus missing status, unknown status, false success, a non-200 success-looking body, and invalid JSON field types.
- Unknown reports become pending, deduplicate by normalized name, update counts, preserve dismissed status, and reopen resolved rows only when their identity is no longer recognized.
- A name already supported returns `known` without creating a pending row.
- Publication validation refuses disabling the final enabled model, a 501st enabled model, a 51st alias, and a response over 1,048,576 bytes without changing rows or revision.
- Competing catalog additions, simultaneous approvals, approval-versus-report, and reads during edits preserve uniqueness and consistent snapshots.
- GLOBAL can render both tables but crafted POSTs for all eight actions cannot mutate data.
- MASTER add, edit, enable, disable, approve, attach, dismiss, and reopen flows require valid CSRF, fail closed without the helper, and write the correct audit outcome.
- Approval refuses disabled new devices, disabled alias targets, stale actions, and any prospective match that is not uniquely the selected device.
- Devices tab navigation performs a full load, and a rejected modal submission retains values and the open modal.
- Normalization fixtures cover punctuation-only input, ASCII case, non-ASCII letters, emoji at scalar-value limits, embedded controls, invalid UTF-8, and case/punctuation duplicates.
- All server-rendered device/report strings are escaped in text and attribute contexts.
- All changed PHP files pass `php -l` and relevant local integration suites.

### Flutter tests

- Exact manufacturer, exact alias, duplicate-short-name ambiguity, documented build suffixes, ASCII case, whitespace, punctuation, non-ASCII input, and embedded-control matching.
- `T1000e`, `T1000-E`, and `T1000E_OTA` match the T1000 record.
- All 39 canonical manufacturers match their source records. `Heltec V30`, `Seeed Tracker T1000X`, and `LilyGo T-Beam Supreme` remain unknown rather than matching by substring.
- A valid server response atomically replaces memory and cache.
- A 10-second timeout, invalid JSON, empty lists, invalid fields, responses over 1 MiB, more than 500 devices, more than 50 aliases per device, and cross-device identity collisions retain the prior cache.
- A first launch without network connects as unknown and does not report.
- Unknown devices always remain connectable and retain manual power selection.
- Cache-present startup continues while HTTP is pending. Cacheless identification uses only the remaining shared deadline. Replays stay inside that deadline, and identification reads the catalog at workflow step 4 rather than before the handshake.
- A refresh that completes during a handshake is available at identification. A refresh after identification affects only later connections and does not overwrite a manual selection.
- Catalog HTTP failures invoke no maintenance, authentication, session-expiry, or session-failure callback.
- Unknown reports send once per normalized identity per launch, persist after failure, retry on a future launch, and are removed only after a valid successful report envelope for the same outbox generation.
- A fresh catalog suppresses stale queued reports that are now recognized.
- Outbox tests cover observation/refresh overlap, concurrent distinct identities, metadata replacement during a request, failed refresh precedence, last-observed eviction, and a hung report request.
- Shared cross-repository fixtures verify normalization and the actual list/report wire format.
- Run focused tests, the full Flutter suite, and `flutter analyze`.

## Delivery

The server and Flutter implementations use separate implementation plans and separate feature branches because their shared interface is fixed by this specification. The server should land first or be deployed before an app build depending on the new endpoint. The app remains safe before deployment because catalog failure is non-fatal, although a first launch without a reachable server has no automatic device recognition.

After both branches pass review and verification, merge each into its repository's `dev` branch and push `dev` to its `origin` remote. Preserve unrelated working-tree files and changes throughout the work.
