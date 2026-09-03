## 0.4.0 - 2026-09-03

- Add `dart-vm object find` for stored-field filtering, value inspection, schema discovery, and bounded List, Set, and Map extraction.
- Add repeatable `--where` filters, `--match-limit`, and `--row-limit` for object inspection.
- Add adaptive collection paging that rebinds an expired temporary VM object ID and retries the same page with a smaller size.
- Keep object references compact by default and add `--verbose` for diagnostic metadata.

## 0.3.0 - 2026-09-02

- Add loaded-class search and live-instance listing through `dart-vm object`.
- Add shallow object inspection with stored-field, List, Map, and Record paths.
- Add actionable diagnostics for missing classes, ambiguous classes, multiple instances, invalid paths, and expired object IDs.

## 0.2.2 - 2026-08-18

- Fix the Windows installer release smoke test fixture.

## 0.2.1 - 2026-08-18

- Fix Dart 3.13 static analysis compatibility in the release updater.

## 0.2.0 - 2026-08-18

- Add `dart-vm service list` to discover reachable local VM Services with their Flutter device and package names.
- Add versioned GitHub Release builds and checksum-verified installers for macOS, Linux, and Windows.
- Add `dart-vm upgrade --check` and checksum-verified in-place upgrades.

## 0.1.0

- Initial version.
