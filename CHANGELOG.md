## 4.2.16 (45)

- Preserve the last 64-bit traffic baseline during temporary 32-bit fallback reads in both app and widget, recovering the full interval on the next wide reading.
- Start traffic sampling before permission requests and connection lookups.
- Add regression coverage for a 7.10 GB recovery across fallback reads, interface disappearance and an app restart.
- Regenerate the checked-in Xcode project to include the shared counter reader.

## 4.2.13 (42)

- Removed the App Group requirement for enterprise/resigned installations.
- Kept exactly one NetFlow widget implementation.
- Widget traffic counters are fully independent inside the widget extension.
- Replaced repeated +/- plan controls with direct numeric widget configuration.
- Long-press the widget and choose Edit Widget to type plan capacity and reset day directly.
- App and widget data are intentionally separate in this compatibility build.

## 4.2.12 (41)\n\n- Replaced multiple/legacy widget implementations with one NetFlow widget.\n- App and widget now use the same App Group data file as the single source of truth.\n- App requests WidgetKit reloads after persisted usage or plan changes.\n- Removed the widget-only traffic counters and widget-only plan settings.\n- Widget now shows today, month, lifetime, plan used/remaining, and percentage from app data.\n- Removed obsolete .widget_patch files.\n\n# Changelog

All notable changes to NetFlow are documented here.

## [4.2.0] - 2026-09-22

### Added
- Data-plan usage forecasting based on the current cycle's measured cellular usage.
- Projected end-of-cycle usage, average daily usage, and an over-limit indicator.
- Monthly and yearly CSV exports using stable machine-readable byte columns.
- JSON backup and restore for settings, data-plan configuration, usage history, and alerts.
- GitHub Actions checks for static validation and an unsigned iOS build.
- Issue templates for bug reports and feature requests.

### Changed
- Updated the app version to 4.2.0 (Build 29).
- Expanded the repository documentation around local-first behavior and development.

## [4.1.12] - 2026-08-12

### Changed
- Improved location selection and reverse-geocoded display names.
- Refined cellular plan status coloring.
- Improved public-IP and VPN state handling.
- Fixed data-plan cycle resets, midnight sample splitting, persistence migration, and localization coverage.
