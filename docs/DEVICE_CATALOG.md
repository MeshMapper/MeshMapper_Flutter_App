# Server Managed Device Catalog Design

Status: approved in conversation, pending review of this written specification.

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

The server stores live data in `device_models.db`. A guarded PHP seed resource contains the exact records imported from the existing `assets/device-models.json`. On first database creation, the server imports those records in one transaction and records the schema version and catalog revision. The import must contain 39 supported records before the database is accepted.

After bootstrap, SQLite is authoritative. The seed is never reread into an existing initialized database, so subsequent admin edits are not overwritten. The Flutter asset and its `pubspec.yaml` registration are removed. If an installation has no local cache and the server is unavailable, the app has no catalog for that launch and treats the connected device as unknown without reporting it.

The database file uses the server's existing protection for `*.db` files. All SQLite connections enable a 5,000 ms busy timeout. Schema setup and multi-table mutations run in transactions.

## Server Data Model

### `device_catalog_meta`

- `schema_version INTEGER NOT NULL`
- `catalog_revision INTEGER NOT NULL`
- `seeded_at TEXT NOT NULL`

There is exactly one metadata row. `catalog_revision` increments only when a supported device or alias is added, edited, enabled, disabled, or removed from a relationship. Unknown report activity does not change it.

### `device_models`

- `id INTEGER PRIMARY KEY`
- `manufacturer TEXT NOT NULL`
- `normalized_manufacturer TEXT NOT NULL UNIQUE`
- `short_name TEXT NOT NULL`
- `power REAL NOT NULL`
- `platform TEXT NOT NULL`
- `tx_power INTEGER NOT NULL`
- `notes TEXT NOT NULL DEFAULT ''`
- `enabled INTEGER NOT NULL DEFAULT 1`
- `created_at TEXT NOT NULL`
- `updated_at TEXT NOT NULL`

`power` is reporting metadata and must be finite and greater than zero. `tx_power` is descriptive firmware metadata and is not written to the radio.

### `device_model_aliases`

- `id INTEGER PRIMARY KEY`
- `device_model_id INTEGER NOT NULL`
- `alias TEXT NOT NULL`
- `normalized_alias TEXT NOT NULL UNIQUE`
- `created_at TEXT NOT NULL`

Aliases use a foreign key to `device_models`. An alias cannot normalize to another device's manufacturer or alias. Removing an alias is allowed, but deleting a supported device is not exposed by the admin interface.

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

Repeated reports update the existing normalized row, its count, last-seen time, and latest version fields. A dismissed row stays dismissed when reported again, but its count and last-seen time continue to update. MASTER can reopen it. Approval marks it resolved and records the target device and resolution type. If a previously resolved identity later stops matching the enabled catalog because its alias was removed or its device was disabled, a new report returns that report to pending for human review.

## Normalization and Matching

Both server-side report checks and the Flutter matcher apply the same normalization:

1. Trim leading and trailing whitespace and NUL characters.
2. Convert to lowercase.
3. Remove every character except ASCII `a` through `z` and `0` through `9`.

The client compares the normalized firmware identity with each enabled model's normalized manufacturer, short name, and aliases. Exact equality wins. If no exact match exists, a normalized catalog identity of at least six characters may match when it is contained in the reported normalized identity. The candidate with the longest contained identity wins, which favors a specific alias over a shorter family name. A tie between different device records is treated as unknown instead of guessing. Duplicate short names are allowed because the existing catalog has hardware variants with a shared display name. Normalized manufacturers and aliases may not collide across device records.

The seeded T1000 record gains these aliases:

- `Seeed Tracker T1000-E`
- `T1000e`
- `T1000E_OTA`

`T1000-E` normalizes to the same identity as `T1000e`, so it is covered without storing a duplicate normalized alias.

Matching is implemented once in a pure Flutter matcher used by `MeshCoreConnection` and any service-level lookup. The server independently checks a submitted unknown name against the current enabled catalog before it creates or updates a pending report.

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

The server accepts a non-empty manufacturer of at most 160 characters and version strings of at most 80 characters. It strips control characters before storage. It returns one of these successful statuses:

- `known`: the current server catalog already recognizes the name.
- `pending`: a pending report was created or updated.
- `dismissed`: a dismissed report was updated without reopening it.

The request contains no location, public key, API session, or persistent app-install identifier.

## App Startup, Cache, and Reporting Flow

`DeviceModelService` owns the cache, refresh, matcher, and local unknown-report outbox. `ApiService` owns only the HTTP requests and response decoding.

On every app process launch:

1. Read the last valid catalog from `SharedPreferences` and make it available immediately.
2. Start exactly one server refresh for that launch.
3. Validate the entire response before changing memory or disk.
4. Atomically replace the in-memory catalog and cached JSON after a valid response.
5. Keep the previous cache unchanged after the 10-second request timeout, a transport error, authentication error, malformed response, empty list, a response over 1 MiB, more than 500 devices, more than 50 aliases on one device, an invalid record, or a normalized identity collision.
6. After a successful refresh, discard queued unknown reports now recognized by the fresh catalog and retry the remaining reports.

The connection UI does not wait on the refresh when a cached catalog is available. If no cache exists, device identification may await the already-running refresh only until its 10-second request timeout. It proceeds as unknown after that timeout.

When a successfully queried device identity does not match an available catalog, the app adds it to a small `SharedPreferences` outbox and attempts the report asynchronously. A successful `known`, `pending`, or `dismissed` response removes it from the outbox. A failed request remains for a future launch. A normalized identity is reported at most once per app launch. The outbox is bounded to 50 identities, keeping the most recently observed entry for each normalized name.

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

GLOBAL sees the table without action controls. MASTER receives:

- **Approve as new**: opens a modal prefilled from the report. Manufacturer, short name, reporting power, platform, TX power, notes, aliases, and enabled state can be completed before saving. The reported name is preserved as the manufacturer or an alias so the approved identity matches immediately.
- **Attach as alias**: opens a searchable supported-device selector and a confirmation summary. Saving adds the reported identity as an alias and resolves the report in one transaction.
- **Dismiss**: keeps the record with dismissed status.

A status filter exposes dismissed and resolved reports. MASTER can reopen a dismissed report, returning it to pending. Nothing automatically reopens or approves a report.

### Supported Devices

This section appears below Pending Unknown Devices. It supports text search and enabled/disabled filters and shows manufacturer, short name, aliases, reporting power, platform, TX power, status, and updated time.

GLOBAL has read-only access. MASTER can add a device, edit all device fields and aliases, enable a device, or disable a device. There is no permanent delete action. Validation and uniqueness failures stay in the modal with the submitted values intact.

All interactive controls have visible keyboard focus, modal labels, descriptive button text, and responsive table overflow consistent with the existing admin interface.

## Authorization and Audit

Every Devices tab mutation is POST-only, CSRF-protected, and gated directly with:

```php
($_SESSION['master_role'] ?? '') === 'MASTER'
```

The implementation must not use the fail-open `$userRole` default for mutation authorization. GLOBAL can reach only read paths, even when crafting requests directly.

Each mutation is registered in `admin_audit.php::aa_actions()` and records an `ok`, `error`, or `forbidden` result through the existing audit mechanism. Required audited actions are:

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

- Server strings are trimmed, control characters are removed, and exact maximum lengths are enforced: 160 characters for manufacturer and alias, 160 for short name, 80 for platform, and 2,000 for notes.
- Manufacturer, short name, normalized manufacturer, power, platform, and TX power are required for a supported record.
- Reporting power must be finite, greater than zero, and no greater than 100. TX power must be an integer from -30 through 100.
- Manufacturer and alias normalized values are globally unique across both identity types.
- Admin mutations that affect multiple rows use one transaction and increment the catalog revision once.
- An invalid or empty catalog response never replaces the app's last valid cache. Catalog validation rejects cross-device manufacturer or alias collisions but permits duplicate short names.
- Disabled devices disappear from the public response. An offline app may continue recognizing one from its last valid cache until its next successful refresh.
- A missing or corrupt server database is never silently overlaid onto an initialized database. Bootstrap runs only when creating a new database.
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

- Bootstrap imports exactly 39 source rows and the T1000 aliases.
- Schema constraints reject normalized manufacturer and alias collisions.
- Public list returns enabled devices only with stable aliases and revision.
- `/devices` rejects missing, wrong-type, and invalid API keys through the existing gate.
- Unknown reports become pending, deduplicate by normalized name, update counts, and preserve dismissed status.
- A name already supported returns `known` without creating a pending row.
- GLOBAL can render both tables but cannot execute any mutation.
- MASTER add, edit, enable, disable, approve, attach, dismiss, and reopen flows require CSRF and write audit outcomes.
- All changed PHP files pass `php -l` and relevant local integration suites.

### Flutter tests

- Exact, alias, longest containment, ambiguous tie, suffix, case, whitespace, and punctuation matching.
- `T1000e`, `T1000-E`, and `T1000E_OTA` match the T1000 record.
- A valid server response atomically replaces memory and cache.
- A 10-second timeout, invalid JSON, empty lists, invalid fields, responses over 1 MiB, more than 500 devices, more than 50 aliases per device, and cross-device identity collisions retain the prior cache.
- A first launch without network connects as unknown and does not report.
- Unknown devices always remain connectable and retain manual power selection.
- Unknown reports send once per normalized identity per launch, persist after failure, retry later, and are removed after any successful report status.
- A fresh catalog suppresses stale queued reports that are now recognized.
- Run focused tests, the full Flutter suite, and `flutter analyze`.

## Delivery

The server and Flutter implementations use separate implementation plans and separate feature branches because their shared interface is fixed by this specification. The server should land first or be deployed before an app build depending on the new endpoint. The app remains safe before deployment because catalog failure is non-fatal, although a first launch without a reachable server has no automatic device recognition.

After both branches pass review and verification, merge each into its repository's `dev` branch and push `dev` to its `origin` remote. Preserve unrelated working-tree files and changes throughout the work.
