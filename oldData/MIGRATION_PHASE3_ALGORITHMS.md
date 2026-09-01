# Chess Manager — Algorithm Extraction (Migration Phase 3)

A scan of every service, business-logic module, processing engine, and
utility across the project, with each algorithm documented as: purpose &
context, inputs/parameters, complete language-agnostic pseudocode, and edge
cases / fallbacks.

**Scope / location of algorithms:**
- `lib/services/rating_service.dart` — Elo calculations
- `lib/models/tournament.dart` — standings, tiebreaks, and the full pairing
  engines (round robin, knockout, Swiss, team Swiss), color assignment
- `lib/pages/tournaments_page.dart` — tournament finalization, rating
  application, undo/reopen
- `lib/main.dart` — W/D/L recount, match-delta backfill
- `lib/models/player.dart` — model-derived metrics
- `lib/services/*` — offline sync queue, migration, backup

**Billing / financial logic: NONE.** This is a student/chess-club tournament
app; there is no pricing, billing, payment, or monetary computation anywhere
in the repository.

---

## 1. FIDE Expected Score — `RatingService.expectedScore`

**Purpose & context:** Computes a player's statistically expected score
against a specific opponent using the standard FIDE Elo formula. Foundation of
every rating change in the app (finalization and online import). File:
`rating_service.dart:7`.

**Inputs / parameters:**
- `ra` (int): rating of the player (blitz or rapid, chosen by caller)
- `rb` (int): rating of the opponent

**Pseudocode:**
```
FUNCTION expectedScore(ra, rb):
    RETURN 1 / (1 + 10 ^ ((rb - ra) / 400))
```

**Edge cases:**
- `ra == rb` → returns `0.5` (equal ratings, equal expectation).
- Large rating gaps (>~800) → result approaches `0.0` or `1.0` (float asymptote, never exactly 0/1).
- Standard FIDE formula; no clamping of extreme values.

---

## 2. Actual Score From Result — `RatingService.actualScore`

**Purpose & context:** Converts a match result into a 1.0/0.5/0.0 score for a
given color (the "S" term in the Elo formula). File: `rating_service.dart:12`.

**Inputs / parameters:**
- `result` (`MatchResult`): `whiteWins` | `blackWins` | `draw` | `pending` | `bye`
- `isWhite` (bool): whether scoring the white or black player

**Pseudocode:**
```
FUNCTION actualScore(result, isWhite):
    SWITCH result:
        whiteWins: RETURN isWhite ? 1.0 : 0.0
        blackWins: RETURN isWhite ? 0.0 : 1.0
        draw:      RETURN 0.5
        DEFAULT (pending): RETURN 0.0
        (bye is filtered out by callers before this is reached)
```

**Edge cases:**
- `pending` → returns `0.0` (but callers skip pending matches first).
- `bye` → not handled here; **callers must skip byes** before calling (both
  `calculateTournamentChanges` and `calculateAndApplyMatchDeltas` check
  `m.isBye` / `pending` and `continue`).

---

## 3. Elo K-Factor — `RatingService.kFactor`

**Purpose & context:** Determines the K-factor per FIDE rules — how much a
single game moves a rating. Tiered by experience then strength. File:
`rating_service.dart:26`.

**Inputs / parameters:**
- `p` (`Player`): the player
- `ratingType` (`RatingType`): `blitz` | `rapid` (picks which rating to read)

**Pseudocode:**
```
FUNCTION kFactor(p, ratingType):
    rating = (ratingType == blitz) ? p.blitzRating : p.rapidRating
    IF p.gamesPlayed < 30:    RETURN 40      // new / provisional players
    IF rating < 2400:         RETURN 20      // normal players
    RETURN 10                                  // elite players
```

**Edge cases / fallbacks:**
- `gamesPlayed == 0` → 40 (new player).
- `rating >= 2400` with `gamesPlayed >= 30` → 10.
- `gamesPlayed` derives from `wins + draws + losses` (see §9).

---

## 4. Tournament Elo Changes — `RatingService.calculateTournamentChanges`

**Purpose & context:** Accumulates each player's total rating delta over all
rounds of a tournament, using **fixed initial ratings** (key correctness
fix — subsequent rounds don't compound on partial changes). File:
`rating_service.dart:35`. (A secondary/legacy path; §5 is the primary one used
at finalization because it also writes per-match deltas.)

**Inputs / parameters:**
- `players` (`List<Player>`)
- `rounds` (`List<List<ChessMatch>>`)
- `ratingType` (`RatingType`, default `rapid`)

**Pseudocode:**
```
FUNCTION calculateTournamentChanges(players, rounds, ratingType):
    initialRatings = MAP from player.id -> current rating (blitz/rapid)
    changes = MAP from player.id -> 0.0 (float accumulator)

    FOR each round in rounds:
        FOR each match m in round:
            IF m.result == pending OR m.isBye: CONTINUE

            white = m.white; black = m.black
            rw = initialRatings[white.id]         // ALWAYS initial
            rb = initialRatings[black.id]
            Ew = expectedScore(rw, rb)
            Eb = expectedScore(rb, rw)
            Sw = actualScore(m.result, isWhite=true)
            Sb = actualScore(m.result, isWhite=false)
            Kw = kFactor(white, ratingType)
            Kb = kFactor(black, ratingType)

            changes[white.id] += Kw * (Sw - Ew)
            changes[black.id] += Kb * (Sb - Eb)

    RETURN MAP id -> round(changes[id])            // float accumulated, rounded ONCE at end
```

**Edge cases / fallbacks:**
- Pending matches and byes are skipped (not scored).
- Delta for a player appearing in no completed match stays `0`.
- Floating-point accumulation then a single `round()` per player — the sum of
  per-game rounded deltas may differ by ±1 from this method (documented
  caveat in §5).

---

## 5. Per-Match Rating Deltas — `RatingService.calculateAndApplyMatchDeltas`

**Purpose & context:** The **primary** rating computation. Computes AND writes
`whiteRatingDelta` / `blackRatingDelta` onto each `ChessMatch` (mutating in
place), and returns accumulated totals. This is what finalization uses so the
visible per-game numbers sum exactly to the player's rating change. File:
`rating_service.dart:98`.

**Inputs / parameters:**
- `players` (`List<Player>`)
- `rounds` (`List<List<ChessMatch>>`) — **mutated** (deltas written to matches)
- `ratingType` (`RatingType`, default `rapid`)

**Pseudocode:**
```
FUNCTION calculateAndApplyMatchDeltas(players, rounds, ratingType):
    initialRatings = MAP id -> rating (blitz/rapid)   // fixed for whole tournament
    playerById     = MAP id -> Player
    totals         = MAP id -> 0 (int accumulator)

    FOR each round in rounds:
        FOR each match m:
            IF pending OR by: CONTINUE

            white = m.white; black = m.black
            rw = initialRatings[white.id] ?? currentPlayerRating(white, ratingType)
            rb = initialRatings[black.id] ?? currentPlayerRating(black, ratingType)
            Ew = expectedScore(rw, rb); Eb = expectedScore(rb, rw)
            Sw = actualScore(m.result, true);  Sb = actualScore(m.result, false)
            Kw = kFactor(playerById[white.id] ?? white, ratingType)
            Kb = kFactor(playerById[black.id] ?? black, ratingType)

            whiteDelta = round(Kw * (Sw - Ew))    // rounded PER GAME
            blackDelta = round(Kb * (Sb - Eb))

            m.whiteRatingDelta = whiteDelta        // write onto match
            m.blackRatingDelta = blackDelta

            totals[white.id] += whiteDelta
            totals[black.id] += blackDelta

    RETURN totals                                  // per-player sum of rounded game deltas
```

**Edge cases / fallbacks:**
- If `initialRatings` lacks a player (shouldn't normally happen), falls back
  to `getPlayerRating` of the current object.
- Per-game `round()` means `totals[id]` is the exact sum of the stored
  per-match deltas (source of truth for applying changes — §7 relies on this).
- Pending/byes skipped; a player with no completed games → `totals` entry `0`.

---

## 6. Apply Rating Changes — `RatingService.applyChanges`

**Purpose & context:** Produces updated `Player` copies with the new rating
applied to the correct pool (blitz vs rapid), keeping all other fields. File:
`rating_service.dart:153`.

**Inputs / parameters:**
- `players` (`List<Player>`)
- `changes` (`Map<String,int>`: player.id → delta)
- `ratingType` (`RatingType`)

**Pseudocode:**
```
FUNCTION applyChanges(players, changes, ratingType):
    RETURN players.map(p):
        delta = changes[p.id] ?? 0
        IF ratingType == blitz:
            RETURN p with blitzRating = p.blitzRating + delta
        ELSE:
            RETURN p with rapidRating = p.rapidRating + delta
```

**Edge cases:**
- Missing key → `delta = 0` (player unchanged).
- Only the matching rating pool is modified; the other pool is untouched.

---

## 7. Tournament Finalization (rating + W/D/L application) — `tournaments_page.dart:_endTournament`

**Purpose & context:** The end-to-end "End Tournament" operation: snapshot the
master roster, compute deltas, apply ratings + win/draw/loss, mark complete,
and persist. File: `tournaments_page.dart:249`.

**Inputs / parameters:**
- `t` (`Tournament`)
- `widget.players` — current **master roster** (not just tournament roster)
- `t.standings` — computed standings (source of W/D/L)

**Pseudocode:**
```
FUNCTION endTournament(t):
    standings = MAP id -> standing          // from t.standings

    // ---- UNRATED path ----
    IF NOT t.isRated:
        t.wdlSnapshot = { for p in masterPlayers where p in t.players:
                          p.id -> (p.wins, p.draws, p.losses) }   // snapshot for undo
        t.status = completed
        updated = for each tp in t.players:
                    current = master[tp.id] ?? tp
                    s = standings[tp.id]
                    s is null ? current :
                        current with wins+=s.wins, draws+=s.draws, losses+=s.losses
        t.players = updated
        return applyFinalization(t, updated)        // persist

    // ---- RATED path ----
    t.ratingSnapshot = { for p in master where p in t.players:
                         p.id -> (blitz? p.blitzRating : p.rapidRating) }
    t.wdlSnapshot    = { ... same as unrated ... }

    changes = calculateAndApplyMatchDeltas(t.players, t.rounds, t.ratingType)  // writes per-match deltas

    updated = for each tp in t.players:
                current = master[tp.id] ?? tp
                delta = changes[tp.id] ?? 0
                s = standings[tp.id]
                current.copyWith(
                    blitzRating: (ratingType==blitz)  ? current.blitzRating + delta : current.blitzRating,
                    rapidRating: (ratingType==rapid)  ? current.rapidRating + delta : current.rapidRating,
                    wins:  current.wins  + (s?.wins  ?? 0),
                    draws: current.draws + (s?.draws ?? 0),
                    losses:current.losses + (s?.losses ?? 0))

    t.players = updated
    t.status = completed
    return applyFinalization(t, updated)            // persist (server or offline queue)
```

**Edge cases / fallbacks:**
- Roster player not in master roster → falls back to `tp` itself as base.
- Standing missing for a player → W/D/L unchanged (`0` deltas).
- Offline: `applyFinalization` → `onFinalizeTournament` returns `false` →
  queued via `PendingSyncService` (see §13); user shown SnackBar.
- Unrated tournaments are still snapshotted (`wdlSnapshot`) so W/D/L can be
  undone even without ratings.

---

## 8. Undo Last Submission — `tournaments_page.dart:_undoLastSubmission`

**Purpose & context:** Reverts ratings and W/D/L applied by the most recent
completed tournament using its stored snapshots, and reopens it for editing.
File: `tournaments_page.dart:439`.

**Inputs / parameters:**
- `t` (`Tournament`, the last completed one with a non-empty `wdlSnapshot`)
- `widget.players` (master roster)

**Pseudocode:**
```
FUNCTION undoLastSubmission(t):
    restored = for each tp in t.players:
        current = master[tp.id] ?? tp
        restored = current
        // ratings (only rated tournaments store ratingSnapshot)
        IF t.isRated:
            ratingSnap = t.ratingSnapshot[tp.id]
            IF ratingSnap != null:
                restored = (blitz) ? current with blitzRating=r : current with rapidRating=r
        // W/D/L (both rated & unrated)
        wdl = t.wdlSnapshot[tp.id]
        IF wdl != null:
            restored = restored with wins=wdl.wins, draws=wdl.draws, losses=wdl.losses
        restored

    t.players = restored
    t.status = inProgress
    t.ratingSnapshot = {}
    t.wdlSnapshot = {}
    FOR each match in t.rounds: m.whiteRatingDelta = null; m.blackRatingDelta = null

    persist t; persist each restored player
```

**Edge cases / fallbacks:**
- **Legacy fallback** (tournaments completed before snapshots existed, empty
  `wdlSnapshot`): `_undoLastSubmission` is not available; the app instead
  offers `_confirmReopenLegacy` which merely sets status → `inProgress` WITHOUT
  rolling back any ratings — this is explicitly surfaced to the user because
  the original contribution stays "baked in" (see `tournaments_page.dart:397`).
  Selection logic: `_lastSubmittedTournament` (non-empty `wdlSnapshot`);
  otherwise `_lastLegacyCompletedTournament` (empty snapshot).

---

## 9. Player Derived Metrics — `models/player.dart`

**Purpose & context:** Convenience metrics computed from stored W/D/L. File:
`player.dart:47`.

**Inputs / parameters:**
- `Player` with `wins`, `draws`, `losses`, `memberStatus`

**Pseudocode:**
```
name        = trim(firstName + " " + lastName)
gamesPlayed = wins + draws + losses
score       = wins + draws * 0.5
winRate     = gamesPlayed == 0 ? 0 : wins / gamesPlayed
isGuest     = memberStatus == guest

FUNCTION nextId(players):         // auto-assign 6-digit ids
    max = 99999
    FOR p in players: n = int(p.id); IF n > max: max = n
    RETURN (max + 1) as string
```

**Edge cases:**
- `gamesPlayed == 0` → `winRate` returns `0` (division-by-zero guard).
- `nextId` bases on the max numeric id so a new id never collides; ids are
  strings.

---

## 10. Individual Standings & Tiebreaks — `Tournament.standings`

**Purpose & context:** Computes every player's score, game tally, and all
tiebreaks, then sorts by the full tiebreak chain. File:
`tournament.dart:237`.

**Inputs / parameters:**
- `rounds` (`List<List<ChessMatch>>`), `players`, `tiebreakResults`
  (`Map<String,String>`: `"<idA>_<idB>"` → winnerId)

**Pseudocode:**
```
FUNCTION standings():
    map = { each player.id -> Standing(player) }

    // Late-joiner detection
    firstRoundSeen = {}
    FOR each round: FOR each match: note earliest round each player appears
    FOR each standing: IF firstRoundSeen[id] > 1: standing.points = 0.5

    // Pass 1: basic scores
    FOR each round: FOR each match:
        IF pending: CONTINUE
        IF bye:     present player: played++, points+=1, wins++; CONTINUE
        white side: played++; whiteWins->points+1,wins++; draw->+0.5,draws++; blackWins->losses++
        black side: (mirror)

    // Pass 2: progressive (running cumulative score across rounds)
    running seeded 0.5 for late joiners else 0
    FOR each round: FOR each match: add round score to running
        prog += running   // sum of cumulative after each round

    // Pass 3: Buchholz, Buchholz-Cut1, Sonneborn-Berger, direct encounter
    FOR each player:
        opponentScores = []
        FOR each match involving player:
            oppScore = opponents' points
            opponentScores.add(oppScore)
            SB += (myResult==1) ? oppScore : (myResult==0.5 ? oppScore*0.5 : 0)
        buchholz    = sum(opponentScores); if empty -> 0
        buchholzCut1 = buchholz - min(opponentScores)     // lowest opponent dropped
    // direct encounter: table of head-to-head points a vs b; inject tiebreakResults as +1.0 wins

    // Sort by chain
    points ↓, buchholzCut1 ↓, buchholz ↓, progressive ↓,
    directEncounter (head-to-head) ↓, sonnebornBerger ↓, wins ↓, rating ↓

    RETURN sorted list
```

**Edge cases / fallbacks:**
- **Late joiner**: first appearance round 2+ → seeded `0.5` point (progressive
  also seeded 0.5); players with **no matches at all** (`firstRound == null`)
  are left at 0 (not treated as late joiners).
- Bye counts as a win (+1 point, `wins++`, no opponent, no draw/loss).
- No opponents → Buchholz stays `0` (`opponentScores` empty guard).
- `buchholzCut1` on a single opponent = `0` (subtracts the only score).
- Direct encounter only meaningful for players who actually faced each other;
  otherwise `0`.
- Sort ties cascade through 8 levels; final fallback is rating.

---

## 11. Team Standings — `Tournament.teamStandings`

**Purpose & context:** Computes team match points, board points, and Buchholz
for team tournaments from `teamRoundPairings` + `rounds`. File:
`tournament.dart:569`.

**Inputs / parameters:**
- `teams` (`List<Team>` with `boardSlots`), `teamRoundPairings`
  (`List<List<TeamRoundPairing>>`), `rounds`

**Pseudocode:**
```
FUNCTION teamStandings():
    map = { team.id -> TeamStanding }
    rosterIds = { team.id -> set of non-null boardSlots }

    // Board points: attribute each round's individual results to the owning team
    boardPointsFor(teamId, roundMatches):
        pts = 0
        FOR each match: FOR white/black in team's roster:
            white: whiteWins or bye -> +1; draw -> +0.5
            black: blackWins -> +1;   draw -> +0.5
        return pts

    FOR each round index r (parallel to rounds):
        roundMatches = rounds[r] if exists else []
        FOR each pairing in teamRoundPairings[r]:
            A = map[pairing.teamAId]; if null: CONTINUE
            IF pairing.teamBId == null (bye):
                A.matchPoints+=1; A.matchWins++; A.matchesPlayed++; CONTINUE
            B = map[pairing.teamBId]; if null: CONTINUE
            aPts = boardPointsFor(A); bPts = boardPointsFor(B)
            A.boardPoints+=aPts; B.boardPoints+=bPts; A.matchesPlayed++; B.matchesPlayed++
            IF aPts>bPts: A.matchPoints+=1;A.matchWins++;B.matchLosses++
            ELIF bPts>aPts: B.matchPoints+=1;B.matchWins++;A.matchLosses++
            ELSE: A.matchPoints+=0.5;B.matchPoints+=0.5;A.matchDraws++;B.matchDraws++

    // Team Buchholz: sum of opponents' final matchPoints
    FOR each team: FOR each round: FOR each pairing: add opponent's matchPoints

    Sort: matchPoints ↓, boardPoints ↓, buchholz ↓, name ↑
    RETURN sorted
```

**Edge cases:**
- Bye = full match point (boardPoints untouched).
- Missing `rounds[r]` for a pairing round → no board points that round.
- Short roster → missing boards contribute no board point (forfeited; the
  opponent's present player gets the bye at the individual level).
- Missing map entry for a pairing → skipped.

---

## 12. Round Robin (Berger) — `BracketGenerator.generateRoundRobin`

**Purpose & context:** Builds a complete round-robin schedule using Berger
circle rotation with alternating colors. File: `tournament.dart:676`.

**Inputs / parameters:**
- `players` (`List<Player>`)

**Pseudocode:**
```
FUNCTION generateRoundRobin(players):
    ps = copy(players); if ps.length is odd: ps.add(_bye())   // dummy BYE player
    n = ps.length
    allRounds = []
    FOR r in 0 .. n-2:
        roundMatches = []
        FOR i in 0 .. (n ~/ 2 - 1):
            p1 = ps[i]; p2 = ps[n-1-i]
            IF p1 or p2 is the BYE:
                roundMatches.add(bye match   // white=real player, black=null, result=bye
                                  id 'rr_{r}_{i}', board i+1)
            ELSE:
                (white,black) = _assignColors(p1, p2, allRounds)
                roundMatches.add(match(white, black, pending, round r+1, board i+1))
        allRounds.add(roundMatches)
        // Berger rotation: move last element to position 1
        last = ps.removeLast(); ps.insert(1, last)
    RETURN allRounds
```

**Edge cases:**
- Odd player count → a fictive `_bye()` player is added; the real player
  facing it gets a bye each round (only those rounds).
- Exactly 1 player → `n-1 = 0` rounds, empty schedule.
- Color assignment via `_assignColors` (see §15).

---

## 13. Knockout (Single Elimination) — `BracketGenerator`

**Purpose & context:** Produces a seeded single-elimination bracket (first
round only) and subsequent rounds from winners. File: `tournament.dart:723`.

**generateKnockout (round 1):**
```
FUNCTION generateKnockout(players, ratingType):
    seeded = _seedPlayers(players, ratingType)      // power-of-2 bracket order, nulls = byes
    for i in 0 step 2:
        p1 = seeded[i]; p2 = seeded[i+1]
        white=p1; black=p2
        IF both non-null:
            // prefer the player with the worse (more negative) color balance as white
            IF _colorBalance(p1,[]) > _colorBalance(p2,[]):
                white=p2; black=p1
        add match(white, black, result=(p1 or p2 null ? bye : pending), board++)
    RETURN [round1]
```

**generateKnockoutNextRound (rounds 2+):**
```
FUNCTION generateKnockoutNextRound(winners, roundNum, previousRounds):
    for i in 0 step 2:
        p1 = winners[i]; p2 = winners[i+1] or null
        IF p2 == null: add bye match(p1)
        ELSE: (white,black) = _assignColors(p1,p2,previousRounds); add pending match
    return matches
```

**Seed ordering — `_seedPlayers` / `_bracketSeedOrder`:**
```
FUNCTION _seedPlayers(players, ratingType):
    sorted = players sorted by rating descending
    size = smallest power of 2 >= players.length
    order = _bracketSeedOrder(size)
    RETURN [ for seedNum in order: seedNum <= players.length ? sorted[seedNum-1] : null ]

FUNCTION _bracketSeedOrder(size):           // recursive, classic bracket ordering
    IF size == 1: return [1]
    prev = _bracketSeedOrder(size/2)
    return flatten([s, size+1-s] for s in prev)
    // size=8 → [1,8,4,5,2,7,3,6] → pairs (1v8,4v5,2v7,3v6)
```

**Edge cases:**
- Non-power-of-2 fields padded with `null` (bye) **interleaved** by bracket
  position (not trailing) so at most one bye lands in any first-round pair.
- Empty/1-player fields → no or single bye.
- Determining end: `_isOnFinalRound` checks the last round has exactly one
  non-bye match ($\text{real}=1$).

---

## 14. Swiss Pairing Engine — `BracketGenerator` (core)

**Purpose & context:** The most complex algorithm. Generates Swiss rounds
with global backtracking pairing, hard rematch/color avoidance, fair byes,
and auto-stop when all pairings are exhausted. Files:
`generateSwissRound1` (`:800`), `generateSwissNextRound` (`:838`),
`_matchAll` (`:923`), `_maxMatch` (`:953`).

### Round 1:
```
FUNCTION generateSwissRound1(players, ratingType):
    sorted = players by rating descending
    half = length ~/ 2
    for i in 0..half-1: add match(sorted[i], sorted[i+half], pending)
    IF odd: add bye match(sorted.last)          // bottom seed gets the round-1 bye
```

### Subsequent rounds:
```
FUNCTION generateSwissNextRound(players, standings, roundNum, previousRounds, ratingType):
    // Order by score groups, preserving standings' tiebreak order within groups
    groups = map score -> list of players
    orderedPlayers = concat(groups scores descending)

    pairable = orderedPlayers
    IF pairable.length is odd:
        byePlayer = lowest-ranked player who has NOT had a bye
                    (orElse: lowest-ranked player — repeat bye as last resort)
        remove byePlayer from pairable

    result     = _matchAll(pairable, previousRounds)
    pairs      = _repairColorClashes(result.pairs, previousRounds)

    for each (a,b) in pairs:
        (white,black) = _assignColors(a,b,previousRounds)
        add match(white, black, pending)

    // Rescue path when attempt cap hit: pair any leftover unpaired players
    for i in 0 step 2 over result.unpaired:
        (white,black) = _assignColors(...); add match

    IF byePlayer != null: add bye match(byePlayer)
```

### `_matchAll` (staged constraint relaxation):
```
FUNCTION _matchAll(order, previousRounds):
    IF empty: return (pairs=[], unpaired=[])
    best = null
    FOR excludeRematch in [true,false]:
      FOR excludeClash in [true,false]:
        result = _maxMatch(order, previousRounds, excludeRematch, excludeClash)
        IF result.unpaired empty: return result        // perfect, stop immediately
        keep best (fewest unpaired)
    RETURN best
    // Relax order: rematches only after BOTH color-respecting stages fail
```

### `_maxMatch` (backtracking with attempt cap):
```
FUNCTION _maxMatch(order, previousRounds, {excludeRematch, excludeClash}):
    bestUnpairedCount = INF; attempts=0; stop=false; maxAttempts=20000

    SEARCH(idx, current pairs, used set, unpaired):
        IF stop: return
        attempts++; IF attempts > maxAttempts: stop=true; return
        i = next un-used index >= idx
        IF i >= order.length:                 // full assignment candidate
            IF unpaired.length < bestUnpairedCount:
                record best (pairs, unpaired)
                IF unpaired.length == 0: stop=true
            return
        IF unpaired.length >= bestUnpairedCount: return    // can't beat best

        p1 = order[i]
        candidates = un-used players after i
        IF excludeRematch: filter out players p1 has already played
        IF excludeClash:   filter out players that force a color clash
        sort candidates: prefer no-rematch over rematch, no-clash over clash,
                         then by original rank proximity

        FOR candidate in candidates:
            used+= {p1, candidate}; current+= (p1,candidate)
            SEARCH(i+1, ...)
            backtrack; IF stop: return

        // alternative: leave p1 unpaired this round
        unpaired+= p1; SEARCH(i+1, ...); unpaired.pop

    SEARCH(0, [], {}, [])
    RETURN best (or fallback: no pairs, all players unpaired)
```

### `_repairColorClashes` (local swap repair):
```
FOR each pair (x1,x2) that forces a color clash:
    FOR each other pair (y1,y2):
        try swap to (x1,y2),(y1,x2) if that resolves both clashes and introduces no rematch
        else try (x1,y1),(y2,x2) under same conditions
        break once fixed (leave as-is if no swap works)
```

### Helpers:
- `havePlayed(a,b,rounds)`: any match where (a,b) or (b,a) faced off. Skips
  byes (null players).
- `allPairsPlayed(players,rounds)`: every unordered pair has played → Swiss is
  exhausted; no new rounds (except explicit tiebreaker).
- `_hadBye(p,rounds)`: player already had a bye round.
- `_bye()`: a sentinel `Player` with id `'bye'` and 0 ratings.

**Edge cases / fallbacks:**
- **Odd field**: exactly one bye; assigned to the lowest-ranked player without
  a bye; a repeat bye only if everyone has had one.
- **Forced rematch**: allowed only when `_matchAll`'s rematch-avoiding stages
  all fail (after color-respecting stages). Rematches relaxed before colors.
- **Color clash**: two players both locked to the same required color; avoided
  where an alternative exists; knockdown has no escape hatch (fixed bracket) —
  `_assignColors` breaks such ties fairly.
- **Attempt cap (20,000)**: aborts to prevent UI hang; returns best matching
  found so far; leftover unpaired players are force-paired in the rescue loop
  (never silently dropped from the round).
- **Exhaustion stop**: `_isOnFinalRound` / `allPairsPlayed` prevents new Swiss
  rounds that would only be rematches.

---

## 15. Color Assignment — `BracketGenerator._assignColors`

**Purpose & context:** Chooses which player in a pair is white, enforcing the
"no three same-color games in a row" rule, then alternation, then balance,
with fair tiebreaks. File: `tournament.dart:1234`.

**Inputs / parameters:**
- `a`, `b` (`Player`)
- `rounds` (history)

**Pseudocode:**
```
FUNCTION _assignColors(a, b, rounds):
    streakA = _colorStreak(a, rounds)     // +N = N consecutive whites, -N = N blacks
    streakB = _colorStreak(b, rounds)

    aMustBlack = streakA >=  2            // 2+ whites in a row → must be black now
    aMustWhite = streakA <= -2
    bMustBlack = streakB >=  2
    bMustWhite = streakB <= -2

    // Both locked, compatible needs → honor both
    IF aMustWhite AND bMustBlack: return (a, b)
    IF aMustBlack AND bMustWhite: return (b, a)

    // Both locked to the SAME need (unavoidable clash) → fair tiebreak
    IF aMustWhite AND bMustWhite: return (rounds.length + a.id.hash).isEven ? (a,b) : (b,a)
    IF aMustBlack AND bMustBlack: return (rounds.length + a.id.hash).isEven ? (a,b) : (b,a)

    // Single side locked → honor it
    IF aMustWhite: return (a, b);  IF aMustBlack: return (b, a)
    IF bMustWhite: return (b, a);  IF bMustBlack: return (a, b)

    // Soft rule: more black-heavy streak → more due for white (symmetric compare)
    IF streakA < streakB: return (a, b)
    IF streakB < streakA: return (b, a)

    // Balance tiebreak (whites - blacks), lower = more due for white
    IF balanceA < balanceB: return (a, b)
    IF balanceB < balanceA: return (b, a)

    // Fully tied → round-varying fair flip
    return (rounds.length + a.id.hash).isEven ? (a, b) : (b, a)
```

**Helper — `_colorStreak`:** scan rounds newest→oldest, skip byes; build
streak sign by last color, stop at first color change. **Helper —
`_colorBalance`:** `(whites − blacks)` counting all non-bye games.

**Edge cases:**
- Tie-break uses `(rounds.length + id.hashCode)` parity so it flips round to
  round (doesn't systematically favor one side of a pair).
- Byes are skipped in streak/balance computations.

---

## 16. Team Swiss Pairing Engine — `BracketGenerator`

**Purpose & context:** A separate team-level implementation mirroring the
individual Swiss engine (§14/§15) but operating on `Team` objects and
`teamRoundPairings` history. Key entry points: `generateTeamSwissRound1`
(`:1313`), `generateTeamSwissNextRound` (`:1351`), `_matchAllTeams`
(`:1519`), `_maxMatchTeams` (`:1541`), `_repairTeamColorClashes` (`:1623`),
`_assignWhiteTeam` (`:1739`), `_buildTeamPairingMatches` (`:1452`).

### Round 1:
```
FUNCTION generateTeamSwissRound1(teams, players, ratingType):
    sorted = teams by average board rating descending     // _teamAverageRating
    half = length ~/ 2
    for i in 0..half-1:
        whiteTeam = sorted[i]; blackTeam = sorted[i+half]
        matches += _buildTeamPairingMatches(whiteTeam, blackTeam, round 1)
        pairings += TeamRoundPairing(whiteTeam, blackTeam, whiteTeam)
    IF odd: byeTeam = sorted.last; matches += _buildTeamByeMatches(byeTeam);
            pairings += TeamRoundPairing(byeTeam, null)
```

### Subsequent rounds:
Mirrors §14 but groups by `matchPoints`, reads `_teamWhiteStreak` /
`_teamColorBalance` / `_teamsHavePlayed` / `_teamHadBye` from
`previousPairings`, assigns white via `_assignWhiteTeam` (same logic shape
as §15 at team granularity), and `allTeamPairsPlayed` for exhaustion.

### Board construction — `_buildTeamPairingMatches`:
```
FUNCTION _buildTeamPairingMatches(whiteTeam, blackTeam, roundNum, playerMap):
    maxBoards = whiteTeam.boardSlots.length
    for i in 0..maxBoards-1:
        board = i+1
        wPlayer = playerMap[whiteTeam.boardSlots[i]] if present else null
        bPlayer = playerMap[blackTeam.boardSlots[i]] if present else null
        IF both null: CONTINUE (no match)
        IF either null: add bye match(present player)      // forfeited board
        ELSE:
            // Olympiad-style: odd boards → whiteTeam's player white,
            //                  even boards → flipped (blackTeam's player white)
            white = board.isOdd ? wPlayer : bPlayer
            black = board.isOdd ? bPlayer : wPlayer
            add pending match
```

**Edge cases:**
- Short roster on a board → the opponent's present player gets a bye.
- Board with neither team filling it → no match generated.
- Odd teams → one team has a round bye (full match point; every present player
  of that team gets an individual bye).
- Same staged relaxation + attempt cap (20,000) + rescue pairing as §14.

---

## 17. W/D/L Recalculation From History — `main.dart:_recalculateWdl`

**Purpose & context:** One-time/idempotent maintenance fix — resets every
player's wins/draws/losses to zero and recounts them by replaying completed
tournaments. Safe to run repeatedly. File: `main.dart:694`.

**Inputs / parameters:**
- `_players` (master roster), `_tournaments`

**Pseudocode:**
```
FUNCTION recalculateWdl():
    tally = { each player.id -> (wins:0, draws:0, losses:0) }
    FOR each tournament t:
        IF t.status != completed: CONTINUE
        FOR each round: FOR each match m:
            IF m.result == pending or bye: CONTINUE     // byes not W/D/L counted here
            white/black sides: tally[wins/draws/losses] += based on result
    FOR each player: player.copyWith(tally[id])
    save players
```

**Edge cases:**
- Always resets to zero first (no double counting).
- Byes/pending excluded from this recount (unlike standings, where a bye is a
  win — this matches the stored per-player record semantics).
- Players with no completed matches → `(0,0,0)`.

---

## 18. Match Rating-Delta Backfill — `main.dart:_recalculateMatchRatingDeltas`

**Purpose & context:** Maintenance fix that fills in per-match
`whiteRatingDelta`/`blackRatingDelta` for tournaments finalized *before*
per-match tracking existed. Does NOT touch players' current ratings — display
only. File: `main.dart:793`.

**Inputs / parameters:**
- `_tournaments`, `_players`

**Pseudocode:**
```
FUNCTION recalculateMatchRatingDeltas():
    counts = (filled:0, skippedNoSnapshot:0, alreadyDone:0, notRated:0)

    FOR each t in tournaments:
        IF t.status != completed: CONTINUE
        IF NOT t.isRated: notRated++; CONTINUE
        IF every non-pending/non-bye match already has whiteRatingDelta:
            alreadyDone++; CONTINUE                             // idempotent
        IF t.ratingSnapshot is empty:
            skippedNoSnapshot++; CONTINUE                       // cannot reconstruct
        // Rebuild players at their PRE-tournament rating from the snapshot,
        // keeping their CURRENT gamesPlayed (best approximation):
        reconstructed = t.players -> preRating via ratingSnapshot (blitz/rapid pool)
        calculateAndApplyMatchDeltas(reconstructed, t.rounds, t.ratingType)   // writes deltas
        filled++
    IF filled > 0: save tournaments
    RETURN counts
```

**Edge cases / known caveats (documented in code):**
- K-factor depends on `gamesPlayed`, which has grown; backfill uses current
  `gamesPlayed`, so a backfilled delta may be off by one K-tier (40 vs 20).
- Trailing white for a total. Only fills in display-only per-match numbers;
  player totals untouched.
- Returns a record of counts so the UI can show accurate feedback rather than
  a generic "done".

---

## 19. Offline Sync Queue — `PendingSyncService`

**Purpose & context:** Lossless offline fallback for writes: queues
players/tournaments to `shared_preferences` when Supabase is unreachable, and
drains on launch / "Sync Now". File: `pending_sync_service.dart` (also
covered in Phase 4; algorithm summarized here).

**Pseudocode — queue:**
```
FUNCTION queue(players, tournament?):
    entries = load raw JSON from prefs key 'pending_tournament_finalizations_v1'
    IF tournament != null:
        entries.removeWhere(entry has same tournament.id)   // replace, no duplicates
    add { tournament: tournament.toJson? , players: players.map(toJson) }
    write back
```
**Pseudocode — trySyncAll:**
```
FUNCTION trySyncAll(saveTournament, savePlayers):
    entries = load
    IF empty: return 0
    remaining = []; synced = 0
    FOR each entry:
        TRY:
            players = decode players; savePlayers(players)
            IF tournament present: decode (with playerMap); saveTournament(tournament)
            synced++
        CATCH: remaining += entry                          // stays queued
    write remaining
    RETURN synced
```

**Edge cases:**
- When a tournament is queued, its `players` is the **full roster** so the
  tournament can be reconstructed from a single entry.
- A retry for the same tournament replaces the earlier entry (dedup by id).
- Failing entries persist for the next attempt; successes are removed.

---

## 20. Legacy → Supabase Migration — `MigrationService.migrate`

**Purpose & context:** One-time/idempotent push of all locally-stored data to
Supabase. File: `migration_service.dart:44`.

**Pseudocode:**
```
FUNCTION migrate(onProgress?):
    stopwatch start; errors = []
    // 1. Load
    players     = LocalDb.loadPlayers()        // on failure → return with error
    tournaments = LocalDb.loadTournaments(players)   // on failure → record error, continue

    // 2. Players: upsert in batches of 50 (Supabase request-limit safety)
    for i in 0 step 50 over players:
        TRY savePlayers(batch); count++
        CATCH errors += batch label

    // 3. Tournaments: full metadata+roster+matches each
    for each t:
        TRY saveTournament(t); tournamentsMigrated++; matchesMigrated += m count
        CATCH errors += tournament label

    RETURN MigrationResult(players, tournaments, matches, errors, elapsed)
```

**Edge cases:**
- Idempotent (upsert never duplicates).
- Batches of ≤ 50 players to respect request limits.
- Per-item error captures so one failure doesn't stop the whole run.
- Ordering matters: players pushed before tournaments (tournaments reference
  player ids).

---

## 21. Backup / Restore — `LocalDbBackup`

**Purpose & context:** Export/import of players + tournaments to a versioned
JSON file (see Phase 2/4 for detail). Algorithm summary:

**Pseudocode — backup:**
```
backup(players, tournaments):
    return jsonEncode({
        version: 1, created_at: now,
        players: players.map(toJson),
        tournaments: tournaments.map(toJson)
    }) written to <documentsDir>/chess_backup_<stamp>.json   // stamp = ISO with ':' → '-'
```
**Pseudocode — restore (upsert, never deletes):**
```
restore(file, savePlayers, saveTournaments):
    payload = jsonDecode; IF version != 1: THROW
    players = decode; playerMap = by id
    tournaments = decode using playerMap
    savePlayers(players); saveTournaments(tournaments)
    return (players, tournaments)
```

**Edge cases:**
- Unknown backup `version` → throws (cannot restore).
- Restore is upsert-only: adds/updates by id, never deletes anything outside
  the backup.

---

## 22. Dashboard Statistics — `main.dart:_DashboardPage`

**Purpose & context:** Aggregate stat cards and top-player/`recent-tournament`
lists. File: `main.dart` (dashboard widget).

**Pseudocode:**
```
activeMembers = players where (not guest) and (isActive)
rating(p) = blitz or rapid pool (toggle)
topPlayers  = activeMembers sorted by rating descending
members     = count(activeMembers)      // non-guest & active
guests      = count(isGuest)
avgRating   = activeMembers empty ? 0 : sum(rating)/count (integer floor division)
active      = count(tournaments with status inProgress)
top-5       = topPlayers.take(5)
recent      = tournaments.reversed.take(3)
```

**Edge cases:**
- `activeMembers` empty → `avgRating = 0` (division-by-zero guard).
- Display uses integer division (`~`/`) for the average.

---

## Cross-Cutting: Boundary Conditions & Fallback Summary

| Concern | Boundaries / fallbacks |
|---------|------------------------|
| Elo | Equal rating → 0.5 expectation; K tiers 40/20/10 by games & rating |
| Ratings finalize | Fixed initial ratings per tournament (no compounding); per-game rounding; per-player accumulated totals as source of truth |
| Late joiners | First round 2+ → 0.5 point; no-matches ever → not late joiner |
| Byes | Count as a win in standings; excluded from W/D/L recount and from Elo |
| Swiss exhaustion | `allPairsPlayed` / `allTeamPairsPlayed` stop new rounds (forced rematch guard) |
| Odd fields | Single fair bye (lowest without one; repeat only as last resort) |
| Color rule | No 3 consecutive same color; clash resolved by fair round-varying tiebreak |
| Backtracking | 20,000-attempt cap → best-effort result + rescue pairing of leftovers |
| Knockout seeding | Padded to power of 2 with byes interleaved (≤1 bye per first-round pair) |
| Undo | Snapshot-based for modern tournaments; legacy reopen without rollback (explicitly warned) |
| Offline persistence | Queue for create/finalize/update-tournament & new players; drops silent best-effort routine edits |
| Numbers | Division-by-zero guards on win rate & average rating; integer floor for averages |

**Billing / financial / payment algorithms: none exist in this project.**
