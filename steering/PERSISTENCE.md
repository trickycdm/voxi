# Persistence

> _Cross-cutting standard — how Voxi stores data. GRDB (SQLite) for records, UserDefaults for settings. The schema is small on purpose; these rules keep upgrades safe for a database that lives in `~/Library/Application Support/Voxi/` across every future version._

## The rules

- **One `DatabaseQueue`, owned by `AppDatabase`, passed to stores.** No second connection, no ad-hoc SQL outside the store types (`HistoryStore`, `DictionaryStore`, `CardStore`).
- **Migrations are append-only.** New schema = a new `migrator.registerMigration("vN")` block appended after the last one in `AppDatabase.migrator` — never edit a registered migration, ever (shipped databases have already run it). New columns are nullable or defaulted (`ALTER TABLE … ADD COLUMN`), so old rows stay valid.
- **Records are `Sendable` value types with hand-written GRDB conformances** (`Records.swift` + `RecordConformances.swift`). Any field change touches three places in the same commit: the struct, `init(row:)`, and `encode(to:)`. Conventions inside conformances: UUIDs stored as lowercased strings; structured data as JSON in TEXT columns; a corrupt row throws `PersistenceError.corruptRow` rather than silently defaulting.
- **Status fields change only through validated store helpers.** `ActionCard.status` transitions go through `CardStore` methods that enforce `CardStatus.canTransition(to:)` — never write a status column directly. Interrupted-at-crash cards are reconciled on launch (`CardStore.reconcileInterrupted`); preserve that invariant when adding states.
- **FTS5 is external-content, trigger-synced.** `history_ft` is populated by `synchronize(withTable:)` triggers — write to `history` only; never insert into the FTS table directly.
- **Settings live in UserDefaults, not the DB.** Config structs (`RefinerConfig`, `InsertionSettings`, `ChordBinding`) are Codable JSON blobs with `load`/`save` helpers; simple values use dotted keys (`audio.inputDeviceUID`). The DB holds user *data* (history, dictionary, cards); UserDefaults holds *preferences*.
- **Tests use `AppDatabase(inMemory: true)`** — a private, fully-migrated database per test. Migration changes additionally need an upgrade test: build a database at the previous schema version with representative rows, run the migrator, assert the rows survive.

## Verification

1. Any migration change: run the upgrade test (previous-version DB + rows → migrate → assert), not just fresh-DB tests.
2. Any record-field change: grep for the record type in `RecordConformances.swift` and confirm all three sites changed together.
3. Full test suite green (`PersistenceTests` exercise round-trips and FTS sync).
