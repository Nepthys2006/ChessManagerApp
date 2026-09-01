# Chess Manager — Edge Cases, Error Handling & Custom Logic (Migration Phase 6)

A deep code-level verification of error handlers, try/catch blocks, bug-fix
comments, and custom utility functions across `lib/`. This is the final
verification document for the migration.

---

## 0. Global Findings Summary

| Check | Result |
|-------|--------|
| `TODO` / `FIXME` / `HACK` / `WORKAROUND` / `XXX` comments | **None found anywhere in `lib/`** |
| `@deprecated` markers | **None** |
| `print()` / `debugPrint()` / `kDebugMode` diagnostics | **None** (no stray debug output) |
| `assert(...)` debug guards | **None** |
| Retry loops with exponential backoff | **None** — see §2 for the manual retry model used instead |
| Hard-coded absolute filesystem paths (`/usr`, `/bin`, `C:\...`) | **None** |
| OS process / shell invocation (`Process.run`, `Runtime.exec`, `.bat`/`.exe`) | **None** |
| Crypto/hash utilities | **None** (no `md5`/`sha` — no password/code hashing in-app) |
| Surfaced exception types | Consistently **`Exception`** (SupabaseDb) and action-level **`bool` returns** (lossless guarded `try/catch`) |

---

## 1. Non-Standard Data Manipulations, Manual Parsers, Monkey-Patches

### 1.1 Surrogate ID generation from timestamps (not UUIDs)
Throughout the app, new entity IDs are hand-rolled from the clock rather than
generated with UUIDs:
```dart
id: DateTime.now().millisecondsSinceEpoch.toString()          // players, tournaments (main.dart, online_tournament_view.dart)
id: DateTime.now().microsecondsSinceEpoch.toString()          // teams (tournaments_page.dart:1355, online_tournament_view.dart:101)
name: 'team_${DateTime.now().microsecondsSinceEpoch}'         // team creation (tournaments_page.dart:2054)
name: 'roster_team_${DateTime.now().microsecondsSinceEpoch}'  // roster team (teams_page.dart:433)
```
- **Implication:** two records created within the same millisecond could
  collide. In practice this is safe per single user, but it is *not*
  collision-proof and not portable to multi-writer/multi-device scenarios.
- Note: `copyWith(id: originalId)` is used on edits so IDs are preserved; the
  surrogate is only minted once at creation.

### 1.2 Manual date parsing + custom timestamp sanitisation
- `DateTime.parse(r['created_at'] as String)` (Supabase ISO-8601) and
  `DateTime.parse(j['createdAt'] as String)` (local JSON) — standard parsers,
  but **no timezone normalization** is applied. All timestamps are stored as
  whatever the device sent; cross-timezone display may be off.
- **Backup filename sanitisation** (`local_db_backup.dart:40–43`) manually
  rewrites ISO-8601 into a filename-safe form:
  ```dart
  DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-')
  ```
  A hand-rolled transformer — fragile if the format ever changes (nested
  characters beyond `:`/`.` would pass through unsanitised).

### 1.3 Manual substHing / string key parsing
- `_maskId(String id) => '${id.substring(0, 8)}…'` (`accounts_page.dart:138`)
  — hard-coded prefix length (8 chars). Safe because IDs are fixed-length
  ms-epoch strings, but breaks silently if the ID format changes.
- **Tiebreak key splitting** (`tournament.dart:434`): `entry.key.split('_')`
  parses round/player composite keys by splitting on `_`. Assumes a
  specific key grammar; a player/round whose id later contains `_` would
  mis-parse (currently impossible since IDs are pure digits, but it's an
  implicit coupling).
- `trim().toLowerCase()` normalisation in every search box
  (`player_picker_widget.dart:110`, `players_page.dart`, `teams_page.dart`,
  `tournaments_page.dart:1996`) — manual, consistent, fine.

### 1.4 Manual membership/JSON reconstruction (custom "deserialisers")
Models hand-roll their own `fromJson`, relying on `Enum.values.firstWhere(...)`
by `name`/`label` (e.g. `supabase_db.dart:74–77`, `tournament.dart:523–530`).
These are **default-or-first-match fallbacks**, i.e. a lenient decoder that
silently coerces unknown enum strings to the first value rather than erroring:
```dart
PlayerGender.values.firstWhere(..., orElse: ...)
```
- **Risk:** an unknown/renamed enum value in stored data is silently mapped to
  a wrong category instead of producing a data-integrity error. Migration
  should consider strict validation.

### 1.5 Manual `indexWhere`/`firstWhere` in-memory state updates
No ORM — `_MainScreenState` mutates `List<Player>/List<Tournament>` by
locating elements with `indexWhere((x) => x.id == ...)` and replacing them
in place (`main.dart:568–571, 632, 670, 678`). This is a manual
find-and-substitute pattern; **no monkey-patching of framework behavior** was
found anywhere.

### 1.6 Other custom utilities
- `Stopwatch`-based migration timing (`migration_service.dart:47`) and
  progress via `void Function(String)? onProgress` callbacks — a custom
  reporting mechanism.
- Deterministic color/roster helpers returning enum→(color,icon,label) maps
  (`players_page.dart:625+`, `player_profile_page.dart:1359+`) — bespoke but
  pure and low-risk.

**No genuine "monkey-patches"** (no overriding of SDK internals, no
`dynamic`/`noSuchMethod` hacks, no reflection) were found.

---

## 2. Custom Error-Handling Logic, Retries, Backoff, Fallback States

### 2.1 Core error-handling model: **guarded operations returning `bool` + lossless offline queue**
The dominant pattern is NOT exceptions propagating to the UI. Persistence
operations wrap risky calls in `try/catch` and return a `bool`:

| Caller | Location | On failure |
|--------|----------|-----------|
| `_finalizeTournament` | `main.dart:565–587` | `PendingSyncService.queue(...)`; returns `false`; **in-memory state already applied** so UI matches immediately |
| `_persistTournament` | `main.dart:600–613` | queues tournament + full roster; returns `false` |
| `_persistNewPlayer` | `main.dart:617+` | queues player; no throw |
| `_loadAll` (private/`PublicScreen._load`) | `main.dart:495–558` / `:196–234` | catch-all → **offline fallback** to local snapshot |

### 2.2 Fallback states (network resilience)
- **Offline read fallback:** every successful load is snapshotted to
  `LocalDb` (`LocalDb.savePlayers/Tournaments/Teams` as `unawaited(...)` at
  `main.dart:531–533`). A failed Supabase load is caught, and the app swaps in
  the last cached snapshot and sets `_offline = true` (`main.dart:534–557`;
  identical at `main.dart:217–234` for the public screen). The UI never shows
  an empty view just because the network is down.
- **Role-gating fallback — `SupabaseDb.init()`:** for public access, school
  resolution via `initPublic()` throws (`Exception('School "$schoolCode" not
  found')` — `supabase_db.dart:44`). Gauged intentionally per `main.dart:129`
  comment "throw when offline and, if used to gate here, would silently log a
  user out" (the private-gate deliberately avoids an offline throw).

### 2.3 Retries — **manual, user-triggered (NO exponential backoff)**
There is **no automatic retry with exponential backoff or jitter** anywhere.
The retry model is:
- **Explicit "Sync Now" button** (`_syncPendingNow`, `main.dart:641–658`)
  re-invokes the queue drain. On failure it shows: `'Still no connection —
  will keep retrying.'` (`main.dart:658`).
- **Startup drain:** `PendingSyncService.trySyncAll(...)` before every load
  (`main.dart:503`) and on launch.
- **Queue semantics:** a retry *replaces* the prior queued attempt for the
  same tournament (`pending_sync_service.dart:24` — idempotent upsert, no
  duplicate growth). This is the closest thing to a bounded "at-least-once"
  delivery — items persist in `shared_preferences` until they succeed.
- **Batch retry at 50**: migration groups player uploads in batches of 50 to
  respect Supabase request limits (`migration_service.dart:84–95`); a failed
  batch is recorded in `errors`, not auto-retried.

### 2.4 Exception-routing by domain
- **Auth**: specifically caught as `on AuthException catch (e)` and surfaced
  distinctly from generic errors — `login_screen.dart:46`, `accounts_page.dart:503, 727`.
- **Persistence guards**: `catch (_)` (dart) — silent parameter omitted since
  the outcome is conveyed by return value / queueing, never a crash.
  `pending_sync_service.dart:64–91`, `local_db.dart:20–68`.
- **Backup/restore**: distinct validation — throws
  `Exception('Unrecognised backup version $version — cannot restore.')`
  (`local_db_backup.dart:83`) to abort a restore on schema mismatch; migration
  version-guards restores. `local_db_backup.dart:147–217` catches per-record
  decode errors.
- **Migration**: non-fatal failures are *collected* as strings and counted
  (`MigrationResult.errors`, `migration_service.dart`). `success =>
  errors.isEmpty` (`:30`). Migration is idempotent via upsert, so a re-run
  completes any partial work.

### 2.5 Graceful-degradation checklist (all verified)
- Missing local cache → `LocalDb.load*` returns empty without crashing
  (`local_db.dart` catch-all returns empty lists).
- No backups yet → `listBackups()` returns `[]` (guard: `if (!await
  dir.exists()) return []` — `local_db_backup.dart:56`).
- Unknown enum in stored data → silently coerced to `orElse` default (§1.4).
- Deleted/absent record during in-memory index lookups → `indexWhere == -1`
  checks guard replacements (`main.dart:568–571`).
- Supabase unreachable at startup → snapshot fallback (§2.2).

---

## 3. Implicit Dependencies on Filesystem Paths, OS Utilities, System Binaries

### 3.1 Filesystem — **one** implicit dependency, device-local only
The **only** filesystem access is via the `path_provider` package's
`getApplicationDocumentsDirectory()` (`local_db_backup.dart:39, 55`):
- Backup export: writes `File('${dir.path}/chess_backup_<stamp>.json')`
  (`:44`).
- Backup listing: `dir.listSync()` filtered on `path.contains('chess_backup_')`
  (`:57–62`) — **this is an implicit filename-prefix contract**: any
  unrelated file whose name contains `chess_backup_` would be treated as a
  backup candidate.
- Restore reads the chosen file back.

The exact on-disk location is platform-dependent (managed by `path_provider`):
- **Windows:** `%USERPROFILE%\Documents`
- **Linux:** `$HOME/Documents`
- **macOS:** `~/Documents` (sandboxed container actually)
- **iOS/Android:** the app's private documents directory.

### 3.2 OS utilities / system binaries — **none**
- **No** `Process.run` / `Process.start` calls.
- **No** reliance on shell commands, `curl`, `git`, PowerShell, `.bat`, `.exe`
  scripts at runtime.
- **No** hard-coded absolute paths (`/usr/bin`, `C:\Program Files`, etc.)
  anywhere in `lib/`.

### 3.3 Other local persistence
- `shared_preferences` (`local_db.dart`) is the local cache + offline queue
  store — a platform-abstracted KV, not a fixed filesystem path.

### 3.4 Implicit external dependency (non-filesystem)
- `supabase_flutter` — the sole network dependency. It also supplies auth
  magic-link email delivery (managed by Supabase, not this repo). No other
  network or OS service is implicitly depended on.

---

## 4. Verification / Action Items for Migration

1. **Timestamps lack timezone handling** — decide whether `created_at` and
   match/backup timestamps are UTC; migrate consistently.
2. **ISO→filename sanitisation** (`replaceAll(':', '-').replaceAll('.','-')`)
   is brittle — consider a single sanitise helper or zero-padded UTC stamp.
3. **Enum `orElse` coercion** is silent — add strict validation or explicit
   parse errors during data migration to catch corrupted rows.
4. **Timestamp-surrogate IDs** risk collision under multi-device writes —
   strengthen to UUIDs during migration (tables support arbitrary string PKs).
5. **Backup filename prefix contract** (`contains('chess_backup_')`) — keep
   gated, but document that the naming prefix is a hard contract.
6. **No retry/backoff** for transient network errors — acceptable for a
   client app, but the offline queue is the only durability mechanism; confirm
   producers (`_persist*`) can never lose data on the error path (they queue
   on every failure — verified).
7. **Confirm the offline snapshot fallback stays only in device storage** —
   there is no cloud backup; users' data durability depends on Supabase + the
   local queue, never on a filesystem export by default.
