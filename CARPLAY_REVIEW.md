# CarPlay dashboard and status widget — draft review

This contribution adds a compact recent-repeater dashboard, a WidgetKit status widget using the existing Siri snapshot, and Flutter scene lifecycle integration. It preserves upstream's app identity and signing configuration.

## Release blocker

The custom UIKit dashboard sits beneath an empty CPMapTemplate and is not a map. Apple's approval message supplied to the contributor requires that layer to contain map content only. This prototype is not represented as App Store compliant. The owner must resolve the appropriate category/presentation with Apple, redesign the dashboard, or exclude it before release. A capability checkbox alone does not resolve this issue.

## Owner checklist

- Confirm acceptable CarPlay UI/category and obtain any required approval for the owner's account and App ID. The contributor's approval does not transfer.
- Verify the shared group `group.net.meshmapper.app.shared` is assigned to Runner, App Intents, and the Live Activity extension (which now also hosts the widget).
- Refresh provisioning profiles for the approved capabilities and extension App Group; update release/CI signing as needed. Keep the existing production IDs and private API-key workflow.
- Verify minimum Flutter/iOS support for the scene lifecycle APIs and the iOS-16-gated CarPlay delegate, including behavior on the iOS 15 deployment floor.
- Run full analysis/tests and a signed production archive. Validate app launch, background/foreground, lock/unlock, incoming calls, Bluetooth reconnect and CarPlay reconnect on devices. Disabling scene restoration fixed an observed crash but needs wider regression coverage.
- Verify battery/status updates, stale snapshots, Deferred/Skipped transitions, 60-second column migration, five-minute expiry, long names, signal colors and overflow counts on supported head units.
- Scrolling is a known limitation on the contributor's head unit and is out of scope; do not advertise scrollable history.
- Test WidgetKit separately: refresh timing and relevance are system-controlled, not guaranteed real-time or guaranteed Siri placement. Review reload frequency and extended-drive battery use.
- Add consented/sample-data screenshots and release notes for approved features. Keep this PR draft until release blockers are resolved; consider splitting the widget/lifecycle work from CarPlay.

## Integration notes

Based on upstream dev `b857836` fetched October 30, 2026. The provider overlap was limited to two optional power snapshot fields; upstream logic and formatting were preserved. Personal signing, app-name, authentication/background identifiers, release notes and local dependency-lock changes are excluded. The personal phone-build checkout is unchanged.

Prior personal-build testing does not establish that this upstream integration passes production signing or App Store review. The integrated branch still needs a signed iOS build and device testing.

Integrated validation: all 263 tests in `test/services/app_intents` and `test/services/status` passed; plist/project syntax and diff whitespace checks passed. Dependencies were resolved from the local cache; the local SDK resolved four test-library versions differently, but that lockfile churn was not retained in the contribution. Repeat tests with the upstream CI toolchain before merge.
