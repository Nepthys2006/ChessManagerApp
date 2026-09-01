# Chess Manager — Complete Migration Specification (MIGRATION_SPEC.md)

**Lead Systems Architect / Reverse-Engineering analysis of the entire
repository.** This document is the authoritative reference for a full tech
stack migration. Every capability, algorithm, schema, service, route, and
integration is captured so no business logic or implicit behavior is lost.

- **Stack:** Flutter (Dart `>=3.0.0 <4.0.0`), Material 3 dark-theme client app.
- **Primary backend:** Supabase (PostgREST database + GoTrue auth), SDK
  `supabase_flutter ^2.15.0` (transitive `supabase` v2.13.0, `http`,
  `http_parser`).
- **Local persistence:** `shared_preferences ^2.2.2` (JSON cache + offline
  queue); `path_provider ^2.1.5` (backup files in the application documents
  directory).
- **Entry point:** `lib/main.dart` (1729 lines) — single in-memory state owner
  `_MainScreenState`.
- **Business logic core:** `lib/models/tournament.dart` (1790 lines) — all
  pairing engines, standings, tiebreaks.
- **Deploy:** Netlify web hosting (`netlify.toml`, SPA → `/index.html`).
- **Tests:** `test/pairing_test.dart`, `test/team_pairing_test.dart`,
  `test/pending_sync_test.dart`.

---

## TABLE OF CONTENTS
1. [Application Capabilities & Functional Inventory](#1-application-capabilities--functional-inventory)
2. [Core Algorithms & Business Logic](#2-core-algorithms--business-logic)
3. [Database & Storage Architecture](#3-database--storage-architecture)
4. [Function & Service Module Directory](#4-function--service-module-directory)
5. [API Routes, Controllers & Interaction Map](#5-api-routes-controllers--interaction-map)
6. [Integrations, Dependencies & Environment](#6-integrations-dependencies--environment)

---

# 1. APPLICATION CAPABILITIES & FUNCTIONAL INVENTORY

## 1.1 Feature inventory (user-facing)

### Authentication & roles
- **Login** (`login_screen.dart`): email + password via
  `signInWithPassword`, then `SupabaseDb.init()` resolves `school_id`.
- **Magic-link invite** (`accounts_page.dart:_invite`): admin sends
  `signInWithOtp` magic link; profile row is **not** auto-created by the app —
  the user must be given a role after first sign-in (or a trigger must exist
  in the DB; none is defined in-repo).
- **Change password** (`_ChangePasswordDialog`): `updateUser(pass)`, 8-char
  min, confirm-match validation.
- **Session gate** (`main.dart:_handleAuthChange`): `_loggedIn =
  session != null`. Deliberately **offline-safe**: the presence of a persisted
  local session alone determines login state, independent of the network-based
  `SupabaseDb.init()`. This prevents silently logging a previously-authenticated
  user out to the public view when offline.
- **Roles** (from `profiles.role`): `player`, `school_admin`, `super_admin`.
  `_canManage => role == 'school_admin' || 'super_admin'`.

### Access modes
- **PublicScreen** (unauthenticated): read-only view of players, tournaments,
  and teams for a school resolved by a **hard-coded default school code
  `'UMCCC'`** via `initPublic({schoolCode = 'UMCCC'})`. Falls back to the
  local snapshot offline.
- **MainScreen** (authenticated): full read/write admin UI.

### Player management (`players_page.dart`, `player_profile_page.dart`)
- Create/edit/delete players (fields: name split first/last, blitz & rapid
  ratings, email, phone, title GM/IM/FM/CM/NM, gender, member/guest status,
  college, program/grade, active flag).
- Search by name (case-insensitive `trim().toLowerCase()` contains-match).
- **Soft delete:** `isActive` flag — inactive players hidden but retained.
- Player profile: career stats (wins/draws/losses, win rate, cumulative rating
  graph `Path()+moveTo` custom painter), tournament history, guest badges.
- **Next ID generation** `Player.nextId(players)`: max 6-digit numeric id in
  roster + 1 (>= 100000).

### Tournament management (`tournaments_page.dart` 2195 lines)
- Create individual tournaments: name, format (round-robin / knockout /
  Swiss), rated/unrated, rating type (blitz/rapid), auto max-rounds (or manual
  for Swiss).
- Roster selection, add/remove players; **late-comer** flow is fully supported.
- Run rounds: generate next round per format engine; manually assign board
  colors via a board-level editor with per-pairing white/black toggle.
- Record results: white wins / black wins / draw / (auto) bye.
- **End / finalize tournament** (rated & unrated) — see §2.3.
- **Undo last submission** and **reopen legacy tournament** — see §2.4.
- Tiebreak result entry (`tiebreakResults`) for manual head-to-head resolution.
- Toolbar actions: **Recalc W/D/L from history**,
  **Backfill per-match rating deltas** — see §2.6.

### Team tournaments (`teams_page.dart`, `tournaments_page.dart`)
- Reusable **RosterTeam** rosters (saved independently of tournaments, capped
  at 10 players).
- Team tournament setup: fixed board count (`maxBoards`), each team has
  `boardSlots` (length == maxBoards, nullable slots for short rosters).
- Team Swiss pairing (round 1 + subsequent) — see §2.2.
- **TeamRoundPairing** records persist per-round team-vs-team pairings
  (needed because a forfeited board has a null player, so the absent team is
  unresolvable from match data alone).

### Match/round viewing
- `f2f_tournament_view.dart` (1980 lines): interactive board-by-board
  tournament playing surface with per-match result entry.
- `online_tournament_view.dart` (939 lines): scoreboard-style view.

### Dashboard & maintenance (`main.dart`)
- Dashboard stats page (players count, tournaments, ratings distribution).
- **Recalculate W/D/L** from all completed tournaments (idempotent, resets to
  0 first) — §2.6.
- **Backfill per-match rating deltas** for legacy rated tournaments — §2.6.

### Data & offline utilities
- **Offline write queue** (`pending_sync_service.dart`) — fired on launch and
  via **Sync Now** button — §2.8.
- **Local snapshot fallback** on read (`local_db.dart`) — §2.8.
- **Backup / restore / delete backup** (JSON files, versioned) —
  `local_db_backup.dart` — §2.9.
- **One-time migration** from local storage to Supabase `migration_service.dart`
  (§2.9).

### Administrative capabilities (`accounts_page.dart`)
- List accounts for the school.
- Manage roles: `school_admin`/`super_admin` can edit another user's role
  (can't touch super admins or self).
- Send invites via magic link.

## 1.2 Background jobs / scheduled tasks
**There are NO true background jobs, cron jobs, scheduled tasks, or worker
processes.** The only asynchronous/background-style activity is client-side
and event-triggered:

| "Job" | Trigger | Executes in |
|-------|---------|-------------|
| Offline queue drain | App launch (`MainScreen._loadAll`) | UI isolate, await |
| Offline queue drain | **Sync Now** button | UI isolate, await |
| Local snapshot write (`unawaited`) | After each successful Supabase load | fire-and-forget async |
| `Recalc W/D/L`, `Backfill deltas` | Explicit user toolbar action | UI isolate |
| Migration (local→Supabase) | User-initiated | UI isolate |

No `Timer.periodic`, no background isolate, no platform background execution.

## 1.3 End-to-end data flow

```
User input (pages / dialogs)
   │  validate() form rules (email contains @, pwd ≥8, name non-empty …)
   ▼
Pages call state-owner callbacks (onCreate, onUpdate, onUpdatePlayer …)
   ▼
_MainScreenState (single owner of _players / _tournaments / _teams)
   │  mutate in-memory lists (indexWhere + replace)
   │  compute standings/ratings via model getters & RatingService
   ▼
Persistence layer (SupabaseDb / LocalDb / PendingSyncService)
   │  - try SupabaseDb.save*() → success
   │  - on failure → PendingSyncService.queue() (offline, lossless)
   ▼
Supabase (PostgREST + GoTrue) & local shared_preferences / backup files
   ▼
Rebuild: reads flow back through loadPlayers/loadTournaments/loadTeams
   → snapshot to LocalDb → render in pages
```

**Middleware/pipeline:** There is no server middleware. The client pipeline
is: view/controller (pages) → single state owner (main.dart) → service layer
(SupabaseDb) → Supabase REST. Exception-based failures are caught at the
boundary and converted to either `bool` returns, offline-queue enqueue, or the
local-snapshot fallback (never a crash).

---

# 2. CORE ALGORITHMS & BUSINESS LOGIC

All pairing engines and standings live in `lib/models/tournament.dart`
(`BracketGenerator`, `Tournament.standings`, `Tournament.teamStandings`);
ratings in `lib/services/rating_service.dart`.

## 2.1 Ratings (Elo / FIDE) — `RatingService`

### Total rounds per format — `Tournament.totalRounds`
```
roundRobin: if (n is odd) n else n - 1
knockout:   size = smallest power of 2 >= n;  rounds = bitLength(size) - 1
            (i.e. 2^r rounds for n players in [2^(r-1)+1 .. 2^r])
swiss:      n <= 4 → 3; n <= 8 → 4; n <= 16 → 5; else → 7
            (or user-set maxRounds if provided)
```

### Expected score — `expectedScore(ra, rb)`
```
E = 1 / (1 + 10 ^ ((rb - ra) / 400))        // FIDE formula
```

### Actual score — `actualScore(result, isWhite)`
```
whiteWins: white=1, black=0
blackWins: white=0, black=1
draw:      0.5 then 0.5
pending/else: 0
```

### K-Factor — `kFactor(player, ratingType)`
```
rating = blitz or rapid per type
if gamesPlayed < 30          → 40   // new players
else if rating < 2400        → 20   // normal players
else                         → 10   // elite players
```

### Whole-tournament change map — `calculateTournamentChanges(players, rounds)`
```
initialRatings[pid] = player's rating at call time (blitz or rapid)
changes[pid] = 0 for all
for each round, each match (skip pending & byes):
    use INITIAL ratings rw, rb (NOT in-progress values)  ← key correctness fix
    Ew = expectedScore(rw, rb);  Eb = expectedScore(rb, rw)
    Sw = actualScore(result, isWhite=true);  Sb = actualScore(result, isWhite=false)
    Kw = kFactor(white); Kb = kFactor(black)
    changes[white] += Kw * (Sw - Ew)
    changes[black] += Kb * (Sb - Eb)
return each changes[id].round()     // rounded ONCE per player
```

### Per-match deltas — `calculateAndApplyMatchDeltas(players, rounds)` ★source of truth
Mutates `whiteRatingDelta`/`blackRatingDelta` directly on each `ChessMatch`;
computes each game's delta with fixed initial ratings, **rounded per game**:
```
whiteDelta = round(Kw * (Sw - Ew))
blackDelta = round(Kb * (Sb - Eb))
m.whiteRatingDelta = whiteDelta; m.blackRatingDelta = blackDelta
totals[white] += whiteDelta; totals[black] += blackDelta
```
> **IMPORTANT semantic caveat (must survive migration):** because per-game
> deltas are rounded individually, the *sum* of a player's match deltas can
> differ by 1–2 from `calculateTournamentChanges` (which rounds once over a
> float total). The app treats the returned `totals` map — NOT
> `calculateTournamentChanges` — as authoritative for applying the player's
> overall rating change, so the displayed per-match numbers always match the
> applied total.

### Apply changes — `applyChanges(players, changes, ratingType)`
Replaces each player's blitz or rapid rating (per `ratingType`) with
`current + changes[id]`.

## 2.2 Pairing engines — `BracketGenerator`

### Round Robin (Berger circle rotation) — `generateRoundRobin(players)`
```
if n is odd: append a dummy player with id == 'bye'
n = effective size; rounds = n - 1
keep players list; for r in 0..n-2:
    build n/2 pairs: (ps[i], ps[n-1-i]) for i in 0..n/2-1
    if either is bye-player → ChessMatch(white=real, black=null, result=bye)
    else → assign colors via _assignColors
    round id: 'rr_{r}_{i}', round=r+1, board=i+1
    Berger rotation: move ps[n-1] to index 1
```

### Knockout (single elimination) — `generateKnockout(players, ratingType)` + `generateKnockoutNextRound`
```
seed order = _bracketSeedOrder(size)  // size = next power of 2
recursive: size==1 → [1]; else _bracketSeedOrder(size/2) spread with
           for each s in prev: [s, size+1-s]     // e.g. size=8 → [1,8,4,5,2,7,3,6]
map seeds to players; seeds > count → null (bye)
round 1: pair consecutive [seeded[0],seeded[1]],...; color:
    b1=_colorBalance(p1, []), b2=_colorBalance(p2, [])
    if b1 > b2 → black=p1 (i.e. whoever is more white-heavy becomes black)
    a null slot → MatchResult.bye; id 'ko_1_{board}'
next round: winners list → pair [w0,w1],[w2,w3],...; odd → bye
    colors via _assignColors with prior rounds; id 'ko_{r}_{board}'
```
Only round 1 is auto-generated up front; subsequent rounds are generated one
at a time from the winners.

### Swiss Round 1 — `generateSwissRound1(players, ratingType)`
```
sort players by rating desc
half = n ~/ 2
for i in 0..half-1: pair (sorted[i] WHITE vs sorted[i+half] BLACK)
if n odd: sorted.last gets a bye (white, black=null), board = half+1
ids: 'sw_1_{i}', bye id 'sw_1_bye'
```

### Swiss subsequent rounds — `generateSwissNextRound` ★most complex
```
1. Group all players by points (score), order groups desc; within a group
   preserve standings tiebreak order (Buchholz→progressive→SB→wins→rating).
2. If odd count: bye → lowest-ranked player who hasn't had a bye yet
   (orElse: lowest-ranked overall if everyone has had one); remove from field.
3. pairs = _matchAll(pairable, previousRounds)   // global backtracking match
4. pairs = _repairColorClashes(pairs, previousRounds)
5. for each pair assign colors _assignColors; board numbers sequential.
6. If any unpaired remain (attempt-cap case): pair them off regardless.
7. Append bye as last board (white=bye player, black=null).
```

#### `_matchAll` — staged constraint relaxation
```
if empty → no pairs
best = null
for excludeRematch in [true, false]:
  for excludeClash in [true, false]:
    result = _maxMatch(order, prev, excludeRematch, excludeClash)
    if result.unpaired.empty → return result          // fully paired
    best = min by unpaired count
return best
```
Order: (rematch+clash) → (rematch only) → (clash only) → (permissive).
Rematches relax before color-clash constraints.

#### `_maxMatch` — backtracking maximum-cardinality matching
```
bestUnpairedCount = INF; attempts = 0; stop = false; maxAttempts = 20000
search(idx, currentPairs, usedSet, unpaired):
    if stop: return
    if ++attempts > maxAttempts: stop = true; return
    i = first unused index >= idx
    if i >= length: record best (unpairedMin, copy pairs/unpaired); stop if 0; return
    if unpaired.length >= bestUnpairedCount: return     // cannot improve this path
    p1 = order[i]
    candidates = unused players after i
    if excludeRematch: filter to !havePlayed(p1, c)
    if excludeClash:   filter to !_forcesColorClash(p1, c)
    sort candidates: prefer no-rematch over rematch, then no-clash over
        clash, then by original order index (rank proximity)
    for each candidate:
        add (p1,candidate); recurse search(i+1,...); backtrack
        if stop return
    unpaired.add(p1); recurse search(i+1,...); unpaired.removeLast()
```

#### Color rules — `_assignColors(a, b, rounds)`
```
streakA = _colorStreak(a)  // +N whites / -N blacks, skip byes, reading backwards
aMustBlack = streakA >= 2;   aMustWhite = streakA <= -2
bMustBlack = streakB >= 2;   bMustWhite = streakB <= -2

HARD/base cases:
  aMustWhite && bMustBlack → (a,b)
  aMustBlack && bMustWhite → (b,a)
  aMustWhite && bMustWhite → (rounds.length + a.id.hashCode).isEven ? (a,b) : (b,a)
  aMustBlack && bMustBlack → same parity tiebreak
  single locked side → honor it

SOFT:
  if streakA < streakB → (a,b)      // A more "due" for white
  if streakB < streakA → (b,a)
  balance = _colorBalance (whites - blacks, skip byes)
  if balA < balB → (a,b); if balB < balA → (b,a)
  final tie → (rounds.length + a.id.hashCode).isEven ? (a,b) : (b,a)
```
The parity tiebreak (`rounds.length + id.hashCode` even?) intentionally flips
round-to-round so the same side of a pair isn't always favored (avoids
systematically penalizing the lower-ranked player who tends to land in the
"b" position).

#### `_repairColorClashes(pairs, previousRounds)` (local repair)
For each pair that forces a clash, try swapping opponents with another pair
such that neither new pairing creates a rematch or a clash (`x1-y2`, `y1-x2`,
or the `x1-y1`, `y2-x2` arrangement). If no swap resolves it, leave as-is
(`_assignColors` still picks a color — an unavoidable rare clash).

#### Helpers — `_colorStreak` / `_colorBalance` / `_forcesColorClash` / `havePlayed`
- `_colorStreak`: iterate rounds backwards; skip byes; accumulate +1 white /
  -1 black; stop when color switches.
- `_colorBalance`: white +1, black -1 across all real games.
- `_forcesColorClash(a,b)`: both locked (|streak| >= 2) and both need the same
  color.
- `havePlayed(a,b)`: any prior real match with both.

#### Complete-round-robin detection — `allPairsPlayed`
True if every i<j pair has `havePlayed` → used to stop offering new Swiss
rounds (a further round would necessarily be a rematch) except a deliberate
tiebreaker, which uses a separate flow.

### Team Swiss — `generateTeamSwissRound1` / `generateTeamSwissNextRound`
A **deliberately separate** implementation mirroring the individual engine's
shape but reading the much smaller `teamRoundPairings` list instead of
`rounds`/`ChessMatch` (avoids re-touching the hardened individual engine).

- **Round 1:** sort teams by average board-player rating desc; top half vs
  bottom half; top-half team is white team. Odd → last team gets a bye.
  `_teamAverageRating = mean(rating of all non-null boardSlots players)`;
  0 if no rated players.
- **Next rounds:** group by `matchPoints`, order desc; staged backtracking
  `_matchAllTeams` with `_maxMatchTeams` (same 20k cap); `_repairTeamColorClashes`;
  `_assignWhiteTeam` mirrors `_assignColors` at team granularity using
  `_teamWhiteStreak` / `_teamColorBalance`.
- **Board construction** `_buildTeamPairingMatches`: Olympiad color alternation —
  odd boards use designated whiteTeam's player as white, **even boards flip**
  (blackTeam's player is white) so each physical team mixes colors within the
  round. A board with only one filled slot → individual bye for that player; a
  board with neither slot filled → no match produced.
- `_buildTeamByeMatches`: every present player on a bye team gets an individual
  bye (feeds individual standings/W-D-L exactly like an individual Swiss bye).
- `allTeamPairsPlayed` detection provided.

### Individual standings — `Tournament.standings`
```
Late-joiner detection: a player is "late" if their EARLIEST appearance (play
  OR bye) in any round is round 2+ (uses m.round not list index). Late joiners
  start with 0.5 points regardless of the round they join. Players with no
  matches at all are left alone.
Pass 1 (basic): per real match, +/- points & wins/draws/losses per player;
  skip pending; bye = full point + win for present player.
Pass 2 (progressive): running cumulative score across rounds; late joiners
  seed the running total at 0.5.
Pass 3 (Buchholz / Cut1 / Sonneborn-Berger): opponentScores = opponents'
  final points; buchholz = sum; buchholzCut1 = buchholz - min(opponentScore);
  SB = Σ (win → full opp score, draw → ½ opp score, loss → 0).
Direct encounter (de): a→b = total points a scored vs b across all rounds,
  then inject manual tiebreak results (key 'winner_loser' split on '_').
SORT (each tiebreak only if previous equal):
  1 points desc → 2 Buchholz-Cut1 desc → 3 Buchholz desc →
  4 Progressive desc → 5 Direct Encounter (more points head-to-head) →
  6 Sonneborn-Berger desc → 7 Wins desc → 8 Rating desc
```

### Team standings — `Tournament.teamStandings`
```
boardPointsFor(team, round) = Σ per match: win/bye=1, draw=0.5 for each of the
  team's roster players in that round (player → exactly one team).
For each recorded TeamRoundPairing per round:
  bye (teamBId null) → +1 match point, +1 matchWin, +1 matchPlayed (board pts
    untouched)
  else compute aPts,bPts; award board points; compare:
    aPts>bPts → A+1MP win / B loss; bPts>aPts → reverse
    equal → both +0.5MP, draw
Team Buchholz = Σ opponent teams' final match points.
SORT: matchPoints desc → boardPoints desc → buchholz desc → team name asc.
```
Note: team standings deliberately omit progressive score & Sonneborn-Berger —
documented as a simplification for club scale.

## 2.3 Tournament finalization state machine — `_endTournament`

States: `draft → inProgress → completed` (re-open: `completed → inProgress`).

```
[completed is desired for t]
if !t.isRated:
    t.wdlSnapshot = { current master W/D/L for each t.players }   // for undo
    t.status = completed
    for each tp in t.players:
        apply only W/D/L deltas from t.standings onto current master player
else (isRated):
    t.ratingSnapshot = { current master rating (blitz/rapid) per player }
    t.wdlSnapshot    = { current master W/D/L per player }
    changes = RatingService.calculateAndApplyMatchDeltas(t.players, t.rounds)
                // writes per-match deltas onto each ChessMatch
    for each tp: copyWith(blitz/rapid += delta, wins += s.wins,
                draws += s.draws, losses += s.losses)  // from CURRENT master
    t.status = completed
persist finalization via _persistTournament/finalize path (offline queue on fail)
```
Validation rules on ending: must have ≥1 round; pending results handled by
counting only decided matches; `maxRounds` respected.

## 2.4 Undo / reopen state machine

### Undo last submission — `_undoLastSubmission(t)`
Selects `_lastSubmittedTournament` = most recent `completed` tournament with
**non-empty `wdlSnapshot`** (works for rated AND unrated tournaments). For
each player in roster:
```
restored = current master player
if t.isRated and ratingSnapshot[id] != null:
    restored.blitz/rapid = ratingSnapshot[id] (per t.ratingType)
if wdlSnapshot[id] != null: restored.w/d/l = wdlSnapshot
t.players = restored players
t.status = inProgress
clear t.ratingSnapshot and t.wdlSnapshot
clear all per-match whiteRatingDelta/blackRatingDelta
persist; UI returns to editing
```

### Reopen legacy — `_confirmReopenLegacy`
Triggered when the newest completed tournament has **empty `wdlSnapshot`**
(finalized before snapshot tracking existed → pre-tournament ratings lost
forever). This path only sets `status = inProgress` WITHOUT rolling back any
player's ratings/W-D-L. When re-ended, a **fresh** delta is applied on top of
current ratings, so the old contribution stays "baked in" — clearly warned in
a dialog before proceeding.

## 2.5 Tiebreaker manual entry
`tiebreakResults` maps `'winnerId_loserId'` → winner id. Injected into the
direct-encounter table during standings computation (winner gets +1.0 against
loser). Key split on `'_'`; malformed keys skipped.

## 2.6 Maintenance algorithms (`main.dart`)

### Recalculate W/D/L — `_recalculateWdl()`
```
tally[pid] = (0,0,0) for all players
for each completed tournament, each round, each match:
    if pending or bye: continue
    update wins/draws/losses for white and black per result
    (blackWins → white loss, black win; whiteWins → white win, black loss)
    NOTE: byes are EXCLUDED from W/D/L here (deliberate — finalization's
    standings credit a bye as a win, but the global W/D/L recalc from match
    history does NOT count byes)
write tallies back to _players; persist
```
Idempotent: resets to zero first so repeated runs don't double-count.

### Backfill per-match rating deltas — `_recalculateMatchRatingDeltas()`
Backfills `whiteRatingDelta`/`blackRatingDelta` for completed, rated
tournaments lacking them (pre-tracking era). Reconstructs pre-tournament
rating from `t.ratingSnapshot` and replays Elo. Does NOT touch current
ratings — display-only.
> **CAVEAT (documented in code):** the K-factor depends on `gamesPlayed`, a
> running total that has since grown, so backfilled deltas use the player's
> *current* gamesPlayed — a backfilled delta may be off by one K-factor tier
> (40 vs 20) from what was originally applied. Player-record totals are not
> affected; only display-only per-match numbers. Returns a breakdown:
> `(filled, skippedNoSnapshot, alreadyDone, notRated)`.

## 2.7 Automated triggers / cron / background
None. All computation is synchronous on UI interactions or explicit toolbar
actions. No database triggers, stored procedures, or scheduled jobs are
defined in-repo (the only trigger referenced is hypothetical in a comment for
auto-creating profile rows — **not implemented**).

## 2.8 Offline queue & fallback (`pending_sync_service.dart`, `main.dart`)
- **Queue key:** `pending_tournament_finalizations_v1` (shared_preferences
  JSON array).
- **Enqueued on write failure:** tournament finalization
  (players + tournament), tournament creation/update, and new-player creation.
  When a tournament is queued, `players` is its **full roster** so the entry
  can be reconstructed standalone.
- **Upsert semantics:** re-queueing the same tournament id replaces the prior
  entry (no duplicates).
- **Drain** `trySyncAll(saveTournament, savePlayers)`: iterate entries,
  `savePlayers` then (if tournament present) `saveTournament`; success →
  remove, failure → keep. Returns count synced.
- **Read fallback** `_loadAll` catch: if Supabase load throws (offline), load
  the last `LocalDb` snapshot, set `_offline = true`. Successful loads are
  snapshotted via `unawaited(LocalDb.save*())`.

## 2.9 Backup / restore / migration
- **Backup** `LocalDbBackup.backup()`: serialize all players & tournaments to
  JSON with `version: 1`, write to
  `{documentsDir}/chess_backup_<ISO-with-:-and-.-replaced-by--->.json`;
  `flush:true`.
- **List** `listBackups()`: scans `documentsDir` for files whose path
  contains `'chess_backup_'`, newest first (`path.compareTo` desc). ≠ an error
  if dir absent.
- **Restore** `restore(file, savePlayers, saveTournaments)`: read JSON, **hard
  reject** `version != 1` (`throw Exception('Unrecognised backup version …')`),
  rebuild Player/Tournament objects, `savePlayers` then `saveTournaments`
  (upsert, nothing else touched/deleted), return restored records for in-memory
  merge.
- **Delete** `delete(file)` → `file.delete()`.
- **One-time migration** `MigrationService.migrate(onProgress)`: reads
  everything from LocalDb, batches player upserts in groups of 50 (Supabase
  request limit), then each tournament via `saveTournament`. Returns
  `MigrationResult(players/tournaments/matches migrated, errors[], elapsed)`;
  `success => errors.isEmpty`. Safe to re-run (upsert idempotent). A failed
  batch is recorded, not auto-retried.

## 2.10 Other business rules
- **Colour alternation** on team boards: odd boards normal, even boards flip
  (Olympiad style).
- **Bye scoring:** present player gets 1 point + a win; counts in
  `standings` but excluded from the global W/D/L recalc.
- **Late joiner:** 0.5 starting points (no matter the round joined).
- **Player id scheme:** sequential 6-digit (`nextId`) for locally-created
  players; tournament/team creation uses
  `DateTime.now().(milli|micro)secondsSinceEpoch` string ids (see §4 — edge
  cases).

---

# 3. DATABASE & STORAGE ARCHITECTURE

Backend is Supabase Postgres accessed only via PostgREST (no SQL migrations /
schema files in-repo; the schema is expressed entirely through the Dart
service layer + remote project). Table/column names below are the exact keys
used in `supabase_db.dart`. **All tables are tenanted** by `school_id`.

## 3.1 Tables / contracts

### `players`
| Column (API key) | Dart type | Nullable | Notes |
|---|---|---|---|
| `id` | String | PK | sequential 6-digit string (>=100000) |
| `school_id` | String (FK `schools`) | no | tenant scope; written by app |
| `first_name` | String | no | |
| `last_name` | String | no | |
| `blitz_rating` | int | no | |
| `rapid_rating` | int | no | |
| `email` | String? | yes | |
| `phone` | String? | yes | |
| `title` | String | default '' | GM\|IM\|FM\|CM\|NM\|'' |
| `gender` | String | enum | male\|female\|other |
| `member_status` | String | enum | member\|guest |
| `college` | String | default '' | college (member) / school (guest) |
| `program` | String | default '' | degree/grade |
| `wins` | int | default 0 | career, updated at finalize/undo |
| `losses` | int | default 0 | |
| `draws` | int | default 0 | |
| `is_active` | bool | default true | **soft delete** |
| `created_at` | timestamp | no | |

### `tournaments`
| Column (API key) | Dart type | Nullable | Notes |
|---|---|---|---|
| `id` | String | PK | ms-epoch string |
| `school_id` | String (FK `schools`) | no | tenant |
| `name` | String | no | |
| `format` | String | enum | roundRobin\|knockout\|swiss |
| `status` | String | enum | draft\|inProgress\|completed |
| `rating_type` | String | enum | blitz\|rapid |
| `is_rated` | bool | default true | |
| `current_round` | int | default 0 | |
| `rating_snapshot` | jsonb | | playerId → pre-tournament rating (undo) |
| `wdl_snapshot` | jsonb | | playerId → {wins,draws,losses} (undo) |
| `tiebreak_results` | jsonb | | key → winner id |
| `created_at` | timestamp | no | |
| `teams` | jsonb | | per-tournament `Team[]` snapshots (team tournaments) |
| `max_boards` | int? | yes | board count for team tourneys |
| `team_pairings` | jsonb | | `TeamRoundPairing[][]` history |

### `tournament_players` (join / roster snapshot)
| Column | Type | Notes |
|---|---|---|
| `tournament_id` | FK `tournaments` (cascade delete) | |
| `player_id` | FK `players` | composite PK |
| `blitz_rating` | int | **rating at enrollment time** (copy) |
| `rapid_rating` | int | rating at enrollment time |

Roster reconstruction uses the enrollment-time ratings (via `copyWith`),
so historical tournaments keep players' ratings as they were when they
played.

### `matches`
| Column | Type | Notes |
|---|---|---|
| `id` | String | PK (e.g. `rr_0_0`, `sw_1_0`, `ko_1_1`, `tsw_…`) |
| `tournament_id` | FK `tournaments` (cascade delete) | |
| `round` | int | |
| `board` | int | |
| `white_player_id` | FK `players`? | null → bye |
| `black_player_id` | FK `players`? | null → bye |
| `result` | String | pending\|whiteWins\|blackWins\|draw\|bye |
| `white_rating_delta` | int? | null until finalize/backfill |
| `black_rating_delta` | int? | |

### `profiles`
| Column | Type | Notes |
|---|---|---|
| `id` | FK `auth.users` | PK |
| `role` | String | player\|school_admin\|super_admin |
| `school_id` | FK `schools` | linked at login (`SupabaseDb.init`) |
| `created_at` | timestamp | |

### `schools`
| Column | Type | Notes |
|---|---|---|
| `id` | String | PK |
| `code` | String | resolved in `initPublic('UMCCC')` |

### `teams` (saved rosters — different from tournament teams jsonb)
| Column | Type | Notes |
|---|---|---|
| `id` | String | PK (`team_<us-epoch>` / `roster_team_…`) |
| `school_id` | FK `schools` | tenant |
| `name` | String | |
| `player_ids` | jsonb List<String> | ordered board order, cap ~10 |

### `auth.users` (managed by Supabase)
Referenced via `currentUser`; emails not directly queryable by the app
(account list masks other users' ids, self email only).

## 3.2 Database-level logic / ORM pipelines / transactions
- **No stored procedures or triggers** defined in-repo.
- **Transactional boundaries:** `SupabaseDb.saveTournament` performs 3
  sequential upserts (metadata → roster → matches) with **no DB transaction**.
  Each is individually upserted. Resilience against partial writes is provided
  by the **offline queue** (the whole tournament object is queued and
  re-written on retry) rather than DB transactions.
- **Cascade deletes:** rely on FK `ON DELETE CASCADE` for
  `tournament_players` and `matches` when a tournament is deleted
  (`deleteTournament` deletes only the `tournaments` row; code comment
  confirms cascade).
- **`supabase_db.dart` also performs the client-side "join"**: loads
  `tournaments` + bulk `tournament_players` + bulk `matches`, then reconstructs
  `Tournament` objects (roster snapshot, rounds grouped & sorted by round then
  board, jsonb snapshots decoded).

## 3.3 Data lifecycle
- **Create:** players mint sequential ids; tournaments/teams mint epoch string
  ids. Insert via `upsert` (works as insert).
- **Update:** `upsert` overwrites by PK. Roster snapshot ratings refreshed on
  save; matches fully rewritten per save.
- **Soft deletion:** players/tournaments are **not hard-deleted by the normal
  UI** — players use `is_active`; tournaments can be deleted via
  `deleteTournament` (hard, cascade). `deletePlayer`/`deleteTeam` do hard
  deletes.
- **Purging / archiving:** no archiving. Backups are explicit user actions.
  Local snapshot / queue persist indefinitely in shared_preferences until
  overwritten/cleared (`clearAll()` dev helper).
- **`main.dart:514`** — on reload, lists are **cleared then `addAll`** (never
  `addAll` on top of existing), preventing duplicate rows on re-login.

---

# 4. FUNCTION & SERVICE MODULE DIRECTORY

## 4.1 Models (`lib/models/`)
| File | Contents |
|---|---|
| `player.dart` | `Player` (+getters `name`, `gamesPlayed`, `score`, `winRate`, `isGuest`; `nextId`; `copyWith`; to/fromJson **with legacy single-`name` and single-`rating` fallbacks**) |
| `team.dart` | `Team` (boardSlots), `TeamRoundPairing`, `RosterTeam` (saved rosters) |
| `tournament.dart` | `ChessMatch`, `TournamentStanding`, `TeamStanding`, `Tournament`, enums (`RatingType`, `TournamentFormat`, `TournamentStatus`, `MatchResult`), `BracketGenerator`, pairing result types |

## 4.2 Services (`lib/services/`)
| Service | Responsibility | Key signatures |
|---|---|---|
| `supabase_db.dart` | PostgREST persistence layer (drop-in for `local_db`) | `init()`/`initPublic()`/`reset()`; `loadPlayers()→Future<List<Player>>`; `savePlayers(List<Player>)`; `savePlayer(Player)`; `deletePlayer(String)`; `loadTeams()/saveTeams()/deleteTeam`; `loadTournaments(List<Player>)→Future<List<Tournament>>`; `saveTournament(Tournament)`; `saveTournaments(List)`; `deleteTournament(String)` |
| `local_db.dart` | snapshot/cache via shared_preferences | `load*/save*` mirroring SupabaseDb surface + `clearAll()` |
| `rating_service.dart` | Elo/FIDE | `expectedScore(int,int)→double`; `actualScore(MatchResult,bool)→double`; `kFactor(Player,RatingType)→int`; `calculateTournamentChanges(...,{ratingType})→Map<String,int>`; `calculateAndApplyMatchDeltas(...,{ratingType})→Map<String,int>`; `applyChanges(List<Player>,Map<String,int>,RatingType)→List<Player>` |
| `pending_sync_service.dart` | offline queue | `queue({required players, Tournament? tournament})`; `pendingCount()→Future<int>`; `trySyncAll({saveTournament, savePlayers})→Future<int>` |
| `local_db_backup.dart` | JSON file backup/restore | `backup()→Future<String>` (file path); `listBackups()→Future<List<File>>`; `restore(File,{savePlayers,saveTournaments})→Future<({List<Player>,List<Tournament>})>`; `delete(File)→Future<void>` |
| `migration_service.dart` | LocalDb→Supabase one-time | `migrate({void Function(String)? onProgress})→Future<MigrationResult>` (batch=50) |

## 4.3 Pages / views (`lib/pages/`)
`login_screen.dart` (202), `accounts_page.dart` (899), `tournaments_page.dart`
(2195), `teams_page.dart` (586), `f2f_tournament_view.dart` (1980),
`online_tournament_view.dart` (939), `players_page.dart` (1596),
`player_profile_page.dart` (1395). `lib/widgets/player_picker_widget.dart`
(451), `lib/demo_data.dart` (364, `SEED_DEMO` preview seeding).

## 4.4 Legacy workarounds / non-obvious code paths (MUST NOT be lost)
1. **`Player.fromJson` legacy migration:** if `firstName` is absent but a
   legacy single `name` key exists, split to first/last (on spaces, full rest
   = last). If `blitzRating`/`rapidRating` absent, both fall back to legacy
   single `rating` (default 1500).
2. **Lenient enum decode (`orElse:` first value):** unknown/renamed enum names
   silently coerce (e.g. `MatchResult→pending`, `gender→male`,
   `memberStatus→member`, `format→swiss`, `status→draft`). This is permissive
   on purpose but masks data-corruption errors — see §4.5.
3. **`_maskId` (accounts):** hard-coded first-8-chars substring; depends on
   UUID-length ids.
4. **Tiebreak key parsing** (`split('_')`): depends on a `winner_loser` key
   grammar; currently safe (numeric ids) but an implicit coupling.
5. **Timestamp-sanitised backup filenames** (`replaceAll(':', '-')
   .replaceAll('.', '-')`).
6. **`backup listing via path.contains('chess_backup_')`** — any file whose
   name contains the prefix is treated as a backup.
7. **Per-match delta rounding divergence** (§2.1) — two rounding policies
   coexist; the per-match/`totals` path is authoritative.
8. **K-factor backfill off-by-one** (§2.6) — current `gamesPlayed` used for
   historical deltas.
9. **`main.dart:129`** — login gate deliberately does NOT call
   `SupabaseDb.init()` (would throw offline); data loading and login state
   fail independently.
10. **Late joiner progressive seed** — 0.5 seeded into both `points` and the
    `progressive` running total.
11. **Standings recomputed by hand per access** (no memoization) — correct but
    O(rounds×matches) each read; fine at club scale.
12. **Swiss 20,000-attempt cap** — best-effort matching; leftover players are
    still paired (never silently dropped).
13. **`_MainScreenState` single-owner** pattern — all mutation flows through
    main.dart callbacks; new code must follow this or risk divergent state.

## 4.5 Known risk register for migration
| Risk | Impact |
|---|---|
| No timezone normalization on `DateTime.parse` / `toIso8601String` | Cross-timezone display drift |
| Timestamp-surrogate ids (`millisecondsSinceEpoch`) | Collision under multi-device/multi-writer |
| Non-transactional triple-upsert in `saveTournament` | Partial-write window (mitigated only by offline queue) |
| Soft-delete vs hard-delete inconsistency (`isActive` players vs `deleteTournament`) | Data-loss confusion |
| Lenient enum coercion | Silent data corruption on unknown values |
| Profile row not auto-created on invite (no trigger in-repo) | Invited user can't reach MainScreen until role assigned |

---

# 5. API ROUTES, CONTROLLERS & INTERACTION MAP

There is **no server-side router**. The app is the client; every route is a
Supabase PostgREST / GoTrue call made by `SupabaseDb` / the auth client.

## 5.1 Auth (GoTrue) endpoints called
| Operation | Method/Endpoint | Auth | Input validation | Behavior / response |
|---|---|---|---|---|
| Login | `POST /auth/v1/token?grant_type=password` (`signInWithPassword`) | — | email contains `@`; pwd non-empty (form) | Returns session; catches `AuthException` → message |
| Magic-link invite | `POST /auth/v1/otp` (`signInWithOtp`) | **any logged-in** (admin UI) | `email.contains('@')`, role select | Sends magic link; no profile auto-created; success message |
| Change password | `PATCH /auth/v1/user` (`updateUser`) | logged-in | pwd ≥ 8 chars; confirm matches | Updates password |
| Session restore | `GET` persisted session (`supabase_flutter`) | — | — | Local, offline-safe; sets `_loggedIn` |
| Sign out | GoTrue (`signOut`) | logged-in | — | Fires `onAuthStateChange` → public view |

## 5.2 PostgREST table endpoints (all scoped by RLS + `school_id`)
| Table | Operations | Query filters/body |
|---|---|---|
| `schools` | SELECT (public) | `.eq('code', schoolCode)` (default `UMCCC`) |
| `profiles` | SELECT (own role, school), UPDATE (role) | `.eq('id', uid)`; `.update({'role': …}).eq('id', …)` |
| `players` | SELECT, UPSERT (insert+update), DELETE | `.eq('school_id', _sid).order('last_name')`; bulk upsert rows |
| `teams` | SELECT, UPSERT, DELETE | `.eq('school_id', _sid).order('name')` |
| `tournaments` | SELECT, UPSERT, DELETE | `.eq('school_id', _sid).order('created_at')`; upsert metadata (jsonb snapshots) |
| `tournament_players` | SELECT (bulk), UPSERT | `.inFilter('tournament_id', tIds)` |
| `matches` | SELECT (bulk), UPSERT | `.inFilter('tournament_id', tIds).order('round').order('board')` |

### Route → application-failure model
- PostgREST carries RLS enforcement; the app maps auth/DB errors to either
  `AuthException` (auth topics) or generic `Exception` (business ops).
- **Response structure:** PostgREST returns JSON arrays/objects; the app
  decodes into in-memory `Player`/`Tournament`/`RosterTeam` models.

### RLS / authorization model (documented in code comments; enforced remotely)
- Rows scoped by `school_id`; public access grants read to players/tournaments
  for a school via `initPublic` (anon key).
- Role-based: `player` (view), `school_admin` (CRUD + account management),
  `super_admin` (global; role-edits exempt from modification).
- **No Edge Functions / RPC / WebSockets / Realtime subscriptions** are used.

## 5.3 End-to-end request examples
- **Create tournament:** UI builds `Tournament` → `_persistTournament` →
  `SupabaseDb.saveTournament` → upsert metadata, roster, matches.
- **Finalize:** `_endTournament` → compute deltas/standings → update
  in-memory players → `saveTournament` + `savePlayers` (offline⇒queue).
- **Load:** `_loadAll` → `init()` → `trySyncAll` → 3 bulk loads → snapshot.

---

# 6. INTEGRATIONS, DEPENDENCIES & ENVIRONMENT

## 6.1 Third-party services
| Service | Used for | SDK | Notes |
|---|---|---|---|
| **Supabase** | Database (Postgres/PostgREST) + Auth (GoTrue) | `supabase_flutter ^2.15.0` | *Only* service. No storage, no edge functions, no realtime |
| **Netlify** | Web hosting (static SPA) | — | `netlify.toml` redirect `/*`→`/index.html` |
| **path_provider** | Documents-dir path for backup files | `^2.1.5` | Local only |
| **shared_preferences** | JSON cache + offline queue | `^2.2.2` | Local only |

**Explicitly NOT integrated:** payment/billing, email providers (auth emails
are sent by Supabase itself), AI APIs, analytics/crash reporting, cloud
object storage, WebSockets, message queues, edge functions, webhooks.

## 6.2 Environment variables & config flags
Configuration is **compile-time only** (baked in at build via
`--dart-define-from-file=.env`; not read at runtime).

| Variable | Read at | Type | Description | Fallback |
|---|---|---|---|---|
| `SUPABASE_URL` | `main.dart:26` (`String.fromEnvironment`) | String | Supabase REST/Auth base URL | **None** — `main()` throws `StateError` if unset |
| `SUPABASE_ANON_KEY` | `main.dart:27` (`String.fromEnvironment`) | String | publishable/anon key | **None** — throws if unset |
| `SEED_DEMO` | `demo_data.dart:16` (`bool.fromEnvironment`) | bool | `true` → seed local snapshot with demo data (no backend) | `false` |

- `.env` (git-ignored) holds the two real values. `.env.example` documents
  them. **No service-role key** exists in-repo; the invite flow deliberately
  uses the anon key + magic link (`accounts_page.dart:484` note).
- **Config flags / behavior switches** baked into code:
  - `initPublic({schoolCode = 'UMCCC'})` — default public school code.
  - `maxAttempts = 20000` — Swiss backtracking cap.
  - `MigrationService` batch size `= 50`.
  - `LocalDb`/queue storage keys: `chess_players_v1`, `chess_tournaments_v1`,
    `chess_teams_v1`, `pending_tournament_finalizations_v1`.
  - Backup file prefix `chess_backup_`, version `1`.
  - Backups cleared/cleared by `LocalDb.clearAll()` (dev).

## 6.3 Secret / security notes for the target stack
1. Keep `SUPABASE_ANON_KEY` client-safe; never add the service-role key
   client-side.
2. RLS is the sole authorization boundary — it **must** be re-created in the
   target DB exactly (school-scoped reads, admin-only writes, public school
   read).
3. The invite flow depends on **magic-link OTP** and an admin manually
   assigning the role post-signup (or a DB trigger that does not exist
   in-repo); preserve this behavior or formalize a trigger in the target.
4. All timestamps are device-local ISO-8601 strings with no TZ normalization;
   decide on UTC handling during migration.

---

*End of MIGRATION_SPEC.md. This document is generated from a full
reverse-engineering pass of the repository and is intended to be the single
source of truth for the tech-stack migration. Companion per-phase documents
(`MIGRATION_PHASE1_OVERVIEW.md` … `MIGRATION_PHASE6_EDGE_CASES.md`) contain
deeper detail per topic.*
