/// Pairing engines per ORCHESTRATOR_BUILD_PROMPT.md §5.2.
library;

import 'chess_match.dart';
import 'player.dart';
import 'standings.dart';
import 'team.dart';
import 'tournament.dart';

/// Result of a maximum-cardinality matching pass (individual or team).
class MatchAllResult {
  MatchAllResult({required this.pairs, required this.unpaired});

  /// (white-candidate, black-candidate) pairs; final colors assigned later.
  final List<(String, String)> pairs;
  final List<String> unpaired;
}

/// Team-level staged matching result (§5.2 _matchAllTeams).
class MatchAllTeamsResult {
  MatchAllTeamsResult({required this.pairs, required this.unpaired});

  final List<(RosterTeam, RosterTeam)> pairs;
  final List<RosterTeam> unpaired;
}

/// All pairing engines: Round Robin (Berger), Knockout (seeded bracket),
/// individual Swiss, and the team-Swiss engine.
///
/// The team-Swiss engine is a DELIBERATELY SEPARATE implementation mirroring
/// the individual one at team granularity (§5.2) — never merge the two, so
/// the hardened individual code path is never touched by team-specific
/// changes. Every public method doc-comment points back at its §5.2
/// subsection.
class BracketGenerator {
  BracketGenerator._();

  /// Swiss/team-Swiss backtracking attempt cap (§0/§5.2).
  static const int swissMaxAttempts = 20000;

  /// Dummy bye-player id used by the round-robin engine (§5.2).
  static const String dummyByePlayerId = 'bye';

  static int _rating(Player p, RatingType ratingType) =>
      ratingType == RatingType.blitz ? p.blitzRating : p.rapidRating;

  // =========================================================================
  // Round Robin — Berger circle rotation (§5.2)
  // =========================================================================

  /// Generates ALL round-robin rounds up front via the Berger circle rotation,
  /// alternating colors via [assignColors] against the history generated so
  /// far. Odd fields get a dummy bye player (id `bye`, 0 ratings); either side
  /// being the dummy yields `ChessMatch(white=real, black=null, result=bye)`.
  /// Ids `rr_{r}_{i}` with round r+1 and board i+1 (§5.2).
  static List<List<ChessMatch>> generateRoundRobinRounds(List<Player> roster) {
    final ps = List<Player>.of(roster);
    if (ps.length < 2) return const [];
    if (ps.length.isOdd) {
      ps.add(
        Player(
          id: dummyByePlayerId,
          firstName: 'bye',
          lastName: '',
          blitzRating: 0,
          rapidRating: 0,
        ),
      );
    }
    final rounds = <List<ChessMatch>>[];
    for (var r = 0; r < ps.length - 1; r++) {
      final matches = <ChessMatch>[];
      for (var i = 0; i < ps.length ~/ 2; i++) {
        final a = ps[i];
        final b = ps[ps.length - 1 - i];
        if (a.id == dummyByePlayerId || b.id == dummyByePlayerId) {
          final real = a.id == dummyByePlayerId ? b : a;
          matches.add(
            ChessMatch(
              id: 'rr_${r}_$i',
              round: r + 1,
              board: i + 1,
              whitePlayerId: real.id,
              blackPlayerId: null,
              result: MatchResult.bye,
            ),
          );
        } else {
          final (w, bl) = assignColors(a.id, b.id, rounds);
          matches.add(
            ChessMatch(
              id: 'rr_${r}_$i',
              round: r + 1,
              board: i + 1,
              whitePlayerId: w,
              blackPlayerId: bl,
            ),
          );
        }
      }
      rounds.add(matches);
      // Berger rotation: move the last player to index 1; others shift.
      final last = ps.removeLast();
      ps.insert(1, last);
    }
    return rounds;
  }

  // =========================================================================
  // Knockout — single elimination, seeded bracket (§5.2)
  // =========================================================================

  /// Recursive classic bracket seeding: size 8 -> [1,8,4,5,2,7,3,6] (§5.2).
  static List<int> bracketSeedOrder(int size) {
    if (size == 1) return [1];
    final prev = bracketSeedOrder(size ~/ 2);
    final out = <int>[];
    for (final s in prev) {
      out
        ..add(s)
        ..add(size + 1 - s);
    }
    return out;
  }

  /// Smallest power of 2 >= [n].
  static int knockoutBracketSize(int n) {
    var size = 1;
    while (size < n) {
      size *= 2;
    }
    return size;
  }

  /// Knockout round 1 ONLY (§5.2): players sorted by rating desc, mapped via
  /// the seed order; seed numbers beyond the player count become null (bye)
  /// slots interleaved by bracket position (never trailing). Consecutive
  /// pairs; when both are real, the more white-heavy player ([colorBalance])
  /// becomes black (a balance tie keeps the listed order); a null slot yields
  /// a bye match for the real player. Later rounds come one at a time via
  /// [generateKnockoutNextRound].
  static List<ChessMatch> generateKnockoutRound1(
    List<Player> roster,
    RatingType ratingType,
  ) {
    final n = roster.length;
    if (n == 0) return const [];
    final byRating = List<Player>.of(
      roster,
    )..sort((a, b) => _rating(b, ratingType).compareTo(_rating(a, ratingType)));
    final size = knockoutBracketSize(n);
    final seeded = <String?>[
      for (final s in bracketSeedOrder(size))
        s <= n ? byRating[s - 1].id : null,
    ];
    final matches = <ChessMatch>[];
    var board = 0;
    for (var i = 0; i + 1 < seeded.length; i += 2) {
      final a = seeded[i];
      final b = seeded[i + 1];
      if (a == null && b == null) continue;
      if (a == null || b == null) {
        final real = a ?? b;
        matches.add(
          ChessMatch(
            id: 'ko_1_$board',
            round: 1,
            board: board,
            whitePlayerId: real,
            blackPlayerId: null,
            result: MatchResult.bye,
          ),
        );
      } else {
        // The more white-heavy player becomes black (§5.2).
        final white = colorBalance(a, const []) > colorBalance(b, const [])
            ? b
            : a;
        matches.add(
          ChessMatch(
            id: 'ko_1_$board',
            round: 1,
            board: board,
            whitePlayerId: white,
            blackPlayerId: white == a ? b : a,
          ),
        );
      }
      board++;
    }
    return matches;
  }

  /// Next knockout round generated ONE at a time from the winners of the last
  /// existing round (§5.2). Bye winners advance; odd leftover gets a bye;
  /// colors assigned via [assignColors] against the full history. Undecided
  /// (pending/draw) matches contribute no winner.
  static List<ChessMatch> generateKnockoutNextRound(
    List<List<ChessMatch>> existingRounds,
  ) {
    if (existingRounds.isEmpty) return const [];
    final lastRound = existingRounds.last;
    final winners = <String?>[];
    for (final m in lastRound) {
      if (m.isBye) {
        winners.add(m.whitePlayerId ?? m.blackPlayerId);
        continue;
      }
      switch (m.result) {
        case MatchResult.whiteWins:
          winners.add(m.whitePlayerId);
        case MatchResult.blackWins:
          winners.add(m.blackPlayerId);
        case MatchResult.draw:
        case MatchResult.pending:
          winners.add(null);
        case MatchResult.bye:
          winners.add(null);
      }
    }
    final roundNum = existingRounds.length + 1;
    final matches = <ChessMatch>[];
    var board = 0;
    for (var i = 0; i + 1 < winners.length; i += 2) {
      final a = winners[i];
      final b = winners[i + 1];
      if (a == null && b == null) continue;
      if (a == null || b == null) {
        final real = a ?? b;
        if (real != null) {
          matches.add(
            ChessMatch(
              id: 'ko_${roundNum}_$board',
              round: roundNum,
              board: board,
              whitePlayerId: real,
              blackPlayerId: null,
              result: MatchResult.bye,
            ),
          );
        }
      } else {
        final (w, bl) = assignColors(a, b, existingRounds);
        matches.add(
          ChessMatch(
            id: 'ko_${roundNum}_$board',
            round: roundNum,
            board: board,
            whitePlayerId: w,
            blackPlayerId: bl,
          ),
        );
      }
      board++;
    }
    if (winners.length.isOdd) {
      final leftover = winners.last;
      if (leftover != null) {
        matches.add(
          ChessMatch(
            id: 'ko_${roundNum}_$board',
            round: roundNum,
            board: board,
            whitePlayerId: leftover,
            blackPlayerId: null,
            result: MatchResult.bye,
          ),
        );
      }
    }
    return matches;
  }

  // =========================================================================
  // Individual Swiss (§5.2)
  // =========================================================================

  /// Swiss round 1 (§5.2): sort by rating desc; pair sorted[i] (white) vs
  /// sorted[i+half] (black) for i in 0..half-1; odd count -> sorted.last gets
  /// a bye, appended LAST.
  static List<ChessMatch> generateSwissRound1(
    List<Player> roster,
    RatingType ratingType,
  ) {
    final sorted = List<Player>.of(
      roster,
    )..sort((a, b) => _rating(b, ratingType).compareTo(_rating(a, ratingType)));
    final half = sorted.length ~/ 2;
    final matches = <ChessMatch>[];
    for (var i = 0; i < half; i++) {
      matches.add(
        ChessMatch(
          id: 'sw_1_$i',
          round: 1,
          board: i,
          whitePlayerId: sorted[i].id,
          blackPlayerId: sorted[i + half].id,
        ),
      );
    }
    if (sorted.length.isOdd) {
      matches.add(
        ChessMatch(
          id: 'sw_1_$half',
          round: 1,
          board: half,
          whitePlayerId: sorted.last.id,
          blackPlayerId: null,
          result: MatchResult.bye,
        ),
      );
    }
    return matches;
  }

  /// Swiss subsequent rounds (§5.2 steps 1-7):
  /// 1. score groups by points desc, within-group NARROW tiebreak order
  ///    (Cut1 -> Buchholz -> Progressive -> SB -> Wins -> Rating — NO direct
  ///    encounter; deliberately narrower than TournamentStanding.compareTo);
  /// 2. odd count -> bye to the LOWEST-ranked player without a prior bye,
  ///    repeated bye as last resort;
  /// 3. [_matchAll]; 4. [_repairColorClashes]; 5. [assignColors] per pair,
  ///    sequential boards; 6. rescue force-pairing for leftovers (a player is
  ///    NEVER dropped from the round); 7. the bye match appended LAST (an odd
  ///    rescue leftover falls through to the bye).
  static List<ChessMatch> generateSwissNextRound(Tournament t) {
    final roundNum = t.rounds.length + 1;
    final order = _scoreGroupOrder(t);
    String? byePlayerId;
    if (order.length.isOdd) {
      final priorByeIds = _byePlayerIds(t.rounds);
      final byePlayer = order.lastWhere(
        (p) => !priorByeIds.contains(p.id),
        orElse: () => order.last,
      );
      order.remove(byePlayer);
      byePlayerId = byePlayer.id;
    }

    final matchAll = _matchAll(order, t.rounds);
    final pairs = _repairColorClashes(matchAll.pairs, t.rounds);

    final matches = <ChessMatch>[];
    var board = 0;
    for (final (aId, bId) in pairs) {
      final (w, bl) = assignColors(aId, bId, t.rounds);
      matches.add(
        ChessMatch(
          id: 'sw_${roundNum}_$board',
          round: roundNum,
          board: board,
          whitePlayerId: w,
          blackPlayerId: bl,
        ),
      );
      board++;
    }
    // Rescue pass (§5.2 step 6): force-pair leftovers — never silently drop.
    final leftovers = List<String>.of(matchAll.unpaired);
    for (var i = 0; i + 1 < leftovers.length; i += 2) {
      matches.add(
        ChessMatch(
          id: 'sw_${roundNum}_$board',
          round: roundNum,
          board: board,
          whitePlayerId: leftovers[i],
          blackPlayerId: leftovers[i + 1],
        ),
      );
      board++;
    }
    if (leftovers.length.isOdd) {
      byePlayerId = leftovers.last;
    }
    if (byePlayerId != null) {
      matches.add(
        ChessMatch(
          id: 'sw_${roundNum}_$board',
          round: roundNum,
          board: board,
          whitePlayerId: byePlayerId,
          blackPlayerId: null,
          result: MatchResult.bye,
        ),
      );
    }
    return matches;
  }

  /// Orders all roster players for pairing: points groups desc; within a
  /// group the NARROW §5.2 score-group order (Cut1 -> Buchholz -> Progressive
  /// -> SB -> Wins -> Rating). Deliberately NOT TournamentStanding.compareTo
  /// (which adds the pairwise direct-encounter level — see standings.dart).
  static List<Player> _scoreGroupOrder(Tournament t) {
    final standings = List<TournamentStanding>.of(t.standings());
    standings.sort((a, b) {
      if (a.points != b.points) return b.points.compareTo(a.points);
      if (a.buchholzCut1 != b.buchholzCut1) {
        return b.buchholzCut1.compareTo(a.buchholzCut1);
      }
      if (a.buchholz != b.buchholz) return b.buchholz.compareTo(a.buchholz);
      if (a.progressiveScore != b.progressiveScore) {
        return b.progressiveScore.compareTo(a.progressiveScore);
      }
      if (a.sonnebornBerger != b.sonnebornBerger) {
        return b.sonnebornBerger.compareTo(a.sonnebornBerger);
      }
      if (a.wins != b.wins) return b.wins.compareTo(a.wins);
      return b.rating.compareTo(a.rating);
    });
    return standings.map((s) => s.player).toList();
  }

  static Set<String> _byePlayerIds(List<List<ChessMatch>> rounds) {
    final ids = <String>{};
    for (final round in rounds) {
      for (final m in round) {
        if (m.isBye) {
          final present = m.whitePlayerId ?? m.blackPlayerId;
          if (present != null) ids.add(present);
        }
      }
    }
    return ids;
  }

  /// True iff the two player ids already played each other in [rounds].
  static bool havePlayed(String a, String b, List<List<ChessMatch>> rounds) {
    for (final round in rounds) {
      for (final m in round) {
        if (m.isBye) continue;
        final ab = m.whitePlayerId == a && m.blackPlayerId == b;
        final ba = m.whitePlayerId == b && m.blackPlayerId == a;
        if (ab || ba) return true;
      }
    }
    return false;
  }

  /// Staged constraint relaxation (§5.2 _matchAll): (no rematch, no clash) ->
  /// (rematch ok, no clash) -> (no rematch, clash ok) -> (rematch, clash ok).
  /// Rematches relax BEFORE color clashes. The first perfect match wins;
  /// otherwise the attempt with the FEWEST unpaired players is kept.
  static MatchAllResult _matchAll(
    List<Player> order,
    List<List<ChessMatch>> previousRounds,
  ) {
    MatchAllResult? best;
    for (final excludeRematch in const [true, false]) {
      for (final excludeClash in const [true, false]) {
        final result = _maxMatch(
          order,
          previousRounds,
          excludeRematch,
          excludeClash,
        );
        if (result.unpaired.isEmpty) return result;
        if (best == null || result.unpaired.length < best.unpaired.length) {
          best = result;
        }
      }
    }
    return best!;
  }

  /// Backtracking search for maximum-cardinality matching, capped at
  /// [swissMaxAttempts] attempts (§5.2 _maxMatch). Prunes when the current
  /// unpaired count can't beat the best. Each level: next unused index,
  /// candidates sorted (prefer no-rematch, then no-clash, then closeness to
  /// the original rank); also a fallback branch leaving p1 unpaired.
  static MatchAllResult _maxMatch(
    List<Player> order,
    List<List<ChessMatch>> previousRounds,
    bool excludeRematch,
    bool excludeClash,
  ) {
    var bestUnpairedCount = order.length + 1; // stand-in for infinity
    List<(String, String)>? bestPairs;
    List<String>? bestUnpaired;
    var attempts = 0;
    var stop = false;
    final used = List<bool>.filled(order.length, false);
    final currentPairs = <(String, String)>[];
    final unpairedSoFar = <String>[];

    void search(int idx) {
      if (stop) return;
      attempts++;
      if (attempts > swissMaxAttempts) {
        stop = true;
        return;
      }
      var i = idx;
      while (i < order.length && used[i]) {
        i++;
      }
      if (i >= order.length) {
        // A complete candidate assignment.
        if (unpairedSoFar.length < bestUnpairedCount) {
          bestUnpairedCount = unpairedSoFar.length;
          bestPairs = List.of(currentPairs);
          bestUnpaired = List.of(unpairedSoFar);
          if (unpairedSoFar.isEmpty) stop = true;
        }
        return;
      }
      if (unpairedSoFar.length >= bestUnpairedCount) return; // prune
      final p1 = order[i].id;
      final candidates = <int>[];
      for (var j = i + 1; j < order.length; j++) {
        if (used[j]) continue;
        if (excludeRematch && havePlayed(p1, order[j].id, previousRounds)) {
          continue;
        }
        if (excludeClash && wouldForceColorClash(p1, order[j].id)) continue;
        candidates.add(j);
      }
      candidates.sort((j1, j2) {
        if (excludeRematch) {
          final r1 = havePlayed(p1, order[j1].id, previousRounds) ? 1 : 0;
          final r2 = havePlayed(p1, order[j2].id, previousRounds) ? 1 : 0;
          if (r1 != r2) return r1 - r2;
        }
        if (excludeClash) {
          final c1 = wouldForceColorClash(p1, order[j1].id) ? 1 : 0;
          final c2 = wouldForceColorClash(p1, order[j2].id) ? 1 : 0;
          if (c1 != c2) return c1 - c2;
        }
        return (j1 - i) - (j2 - i); // closeness to p1's original rank
      });
      for (final c in candidates) {
        used[i] = true;
        used[c] = true;
        currentPairs.add((p1, order[c].id));
        search(i + 1);
        currentPairs.removeLast();
        used[i] = false;
        used[c] = false;
        if (stop) return;
      }
      // Fallback branch: also try leaving p1 unpaired this round.
      used[i] = true;
      unpairedSoFar.add(p1);
      search(i + 1);
      unpairedSoFar.removeLast();
      used[i] = false;
    }

    search(0);
    if (bestPairs == null || bestUnpaired == null) {
      // Last-resort fallback: nothing paired, everyone unpaired (§5.2).
      return MatchAllResult(
        pairs: const [],
        unpaired: order.map((p) => p.id).toList(),
      );
    }
    return MatchAllResult(pairs: bestPairs!, unpaired: bestUnpaired!);
  }

  // =========================================================================
  // Color assignment (§5.2 _assignColors and helpers)
  // =========================================================================

  /// Consecutive same-color streak reading the player's games backwards from
  /// the most recent round, SKIPPING byes, stopping at the first color change
  /// (§5.2). Positive = N consecutive whites, negative = N blacks.
  static int whiteStreak(String playerId, List<List<ChessMatch>> rounds) {
    var streak = 0;
    for (var r = rounds.length - 1; r >= 0; r--) {
      final round = rounds[r];
      for (var m = round.length - 1; m >= 0; m--) {
        final match = round[m];
        if (match.isBye) continue;
        final isWhite = match.whitePlayerId == playerId;
        final isBlack = match.blackPlayerId == playerId;
        if (!isWhite && !isBlack) continue;
        if (streak == 0) {
          streak = isWhite ? 1 : -1;
        } else if (streak > 0 && isWhite) {
          streak++;
        } else if (streak < 0 && !isWhite) {
          streak--;
        } else {
          return streak; // first color change stops the read
        }
      }
    }
    return streak;
  }

  /// Overall color balance: whites played minus blacks played (§5.2
  /// _colorBalance). Byes contribute nothing.
  static int colorBalance(String playerId, List<List<ChessMatch>> rounds) {
    var balance = 0;
    for (final round in rounds) {
      for (final m in round) {
        if (m.isBye) continue;
        if (m.whitePlayerId == playerId) {
          balance++;
        } else if (m.blackPlayerId == playerId) {
          balance--;
        }
      }
    }
    return balance;
  }

  /// True iff pairing [a] and [b] would force BOTH onto the same mandatory
  /// color (each has a 2+ streak of one color, §5.2).
  static bool wouldForceColorClash(
    String a,
    String b, [
    List<List<ChessMatch>> rounds = const [],
  ]) {
    final forcedA = _forcedColor(a, rounds);
    final forcedB = _forcedColor(b, rounds);
    return forcedA != null && forcedA == forcedB;
  }

  static String? _forcedColor(String p, List<List<ChessMatch>> rounds) {
    final streak = whiteStreak(p, rounds);
    if (streak >= 2) return 'black'; // the OTHER color is mandatory now
    if (streak <= -2) return 'white';
    return null;
  }

  /// Parity tiebreak that intentionally FLIPS round to round (§5.2):
  /// rounds-count parity combined with a's id hash decides, so the same side
  /// of a pairing isn't systematically favored.
  static bool _parityGivesWhiteToA(int roundsCount, String aId) =>
      (roundsCount + aId.hashCode) % 2 == 0;

  /// Assigns white/black for a pair against the full round history (§5.2
  /// _assignColors). Mandatory streaks: both locked compatible -> honor both;
  /// both locked to the SAME color (unavoidable clash) -> parity tiebreak;
  /// one locked -> honor it; neither locked (soft rule) -> the more
  /// black-heavy streak is more due white, ties by overall color balance
  /// (whites - blacks, lower = more due white), final tie by the parity
  /// tiebreak. Returns (whitePlayerId, blackPlayerId).
  static (String, String) assignColors(
    String a,
    String b,
    List<List<ChessMatch>> rounds,
  ) {
    final streakA = whiteStreak(a, rounds);
    final streakB = whiteStreak(b, rounds);
    final aMustWhite = streakA <= -2;
    final aMustBlack = streakA >= 2;
    final bMustWhite = streakB <= -2;
    final bMustBlack = streakB >= 2;

    if (aMustWhite && bMustBlack) return (a, b);
    if (aMustBlack && bMustWhite) return (b, a);
    if (aMustWhite && bMustWhite) {
      // Unavoidable clash: both locked to white.
      return _parityGivesWhiteToA(rounds.length, a) ? (a, b) : (b, a);
    }
    if (aMustBlack && bMustBlack) {
      return _parityGivesWhiteToA(rounds.length, a) ? (b, a) : (a, b);
    }
    if (aMustWhite) return (a, b);
    if (bMustWhite) return (b, a);
    if (aMustBlack) return (b, a);
    if (bMustBlack) return (a, b);

    // Neither locked (soft rule).
    if (streakA != streakB) {
      return streakA < streakB ? (a, b) : (b, a);
    }
    final balanceA = colorBalance(a, rounds);
    final balanceB = colorBalance(b, rounds);
    if (balanceA != balanceB) {
      return balanceA < balanceB ? (a, b) : (b, a);
    }
    return _parityGivesWhiteToA(rounds.length, a) ? (a, b) : (b, a);
  }

  /// Repairs color clashes (§5.2 _repairColorClashes): for each forced-clash
  /// pair, try swapping opponents with another pair — two possible
  /// cross-swaps — such that NEITHER resulting pairing creates a rematch or a
  /// new clash; take the first swap that works; otherwise leave the pair
  /// as-is (an unavoidable rare clash — [assignColors] still picks a fair
  /// color).
  static List<(String, String)> _repairColorClashes(
    List<(String, String)> pairs,
    List<List<ChessMatch>> rounds,
  ) {
    final out = List<(String, String)>.of(pairs);
    for (var k = 0; k < out.length; k++) {
      final (ak, bk) = out[k];
      if (!wouldForceColorClash(ak, bk, rounds)) continue;
      var repaired = false;
      for (var j = 0; j < out.length && !repaired; j++) {
        if (j == k) continue;
        final (aj, bj) = out[j];
        // Cross-swap 1: (ak, bj) and (aj, bk).
        if (_swapOk(ak, bj, rounds) && _swapOk(aj, bk, rounds)) {
          out[k] = (ak, bj);
          out[j] = (aj, bk);
          repaired = true;
        } else if (_swapOk(ak, aj, rounds) && _swapOk(bk, bj, rounds)) {
          // Cross-swap 2: (ak, aj) and (bk, bj).
          out[k] = (ak, aj);
          out[j] = (bk, bj);
          repaired = true;
        }
      }
    }
    return out;
  }

  static bool _swapOk(String x, String y, List<List<ChessMatch>> rounds) =>
      !havePlayed(x, y, rounds) && !wouldForceColorClash(x, y, rounds);

  /// True iff EVERY unordered pair of players has already faced each other
  /// (§5.2 allPairsPlayed) — stop offering new Swiss rounds.
  static bool allPairsPlayed(
    List<Player> players,
    List<List<ChessMatch>> rounds,
  ) {
    for (var i = 0; i < players.length; i++) {
      for (var j = i + 1; j < players.length; j++) {
        if (!havePlayed(players[i].id, players[j].id, rounds)) return false;
      }
    }
    return true;
  }

  // =========================================================================
  // Team Swiss — a deliberately SEPARATE implementation mirroring the
  // individual engine at team granularity (§5.2). Do not merge.
  // =========================================================================

  /// Fixed board slots for a team: playerIds padded/truncated to [maxBoards]
  /// with nulls (§5.2 boardSlots).
  static List<String?> teamBoardSlots(RosterTeam team, int maxBoards) => [
    for (var i = 0; i < maxBoards; i++)
      i < team.playerIds.length ? team.playerIds[i] : null,
  ];

  /// Average pool rating of a team's non-null board-slot players (§5.2 team
  /// round 1); 0 if none rated.
  static double teamAverageRating(
    RosterTeam team,
    int maxBoards,
    List<Player> roster,
    RatingType ratingType,
  ) {
    final slots = teamBoardSlots(team, maxBoards);
    final rated = slots
        .whereType<String>()
        .map((id) => roster.where((p) => p.id == id).firstOrNull)
        .whereType<Player>()
        .toList();
    if (rated.isEmpty) return 0;
    return rated.fold<double>(0, (s, p) => s + _rating(p, ratingType)) /
        rated.length;
  }

  /// Team-level white streak: +N consecutive rounds as the white team, -N as
  /// black, reading backwards, SKIPPING team byes, stopping at the first
  /// change (§5.2 _teamWhiteStreak).
  static int teamWhiteStreak(
    RosterTeam team,
    List<List<TeamRoundPairing>> teamPairings,
  ) {
    var streak = 0;
    for (var r = teamPairings.length - 1; r >= 0; r--) {
      final pairings = teamPairings[r];
      for (var p = pairings.length - 1; p >= 0; p--) {
        final pairing = pairings[p];
        if (pairing.blackTeamId == null) continue; // team bye — skip
        if (pairing.whiteTeamId == team.id) {
          if (streak >= 0) {
            streak++;
          } else {
            return streak;
          }
        } else if (pairing.blackTeamId == team.id) {
          if (streak <= 0) {
            streak--;
          } else {
            return streak;
          }
        }
      }
    }
    return streak;
  }

  /// Team color balance: rounds as white minus rounds as black (§5.2
  /// _teamColorBalance). Team byes skipped.
  static int teamColorBalance(
    RosterTeam team,
    List<List<TeamRoundPairing>> teamPairings,
  ) {
    var balance = 0;
    for (final pairings in teamPairings) {
      for (final p in pairings) {
        if (p.blackTeamId == null) continue;
        if (p.whiteTeamId == team.id) {
          balance++;
        } else if (p.blackTeamId == team.id) {
          balance--;
        }
      }
    }
    return balance;
  }

  /// True iff pairing the two teams would force BOTH onto the same mandatory
  /// white side (§5.2, mirroring the individual clash rule).
  static bool wouldForceTeamClash(
    RosterTeam a,
    RosterTeam b, [
    List<List<TeamRoundPairing>> history = const [],
  ]) {
    final forcedA = _forcedTeamColor(a, history);
    final forcedB = _forcedTeamColor(b, history);
    return forcedA != null && forcedA == forcedB;
  }

  static String? _forcedTeamColor(
    RosterTeam t,
    List<List<TeamRoundPairing>> history,
  ) {
    final streak = teamWhiteStreak(t, history);
    if (streak >= 2) return 'black';
    if (streak <= -2) return 'white';
    return null;
  }

  static bool _haveTeamsPlayed(
    RosterTeam a,
    RosterTeam b,
    List<List<TeamRoundPairing>> history,
  ) {
    for (final pairings in history) {
      for (final p in pairings) {
        if (p.blackTeamId == null) continue;
        final ab = p.whiteTeamId == a.id && p.blackTeamId == b.id;
        final ba = p.whiteTeamId == b.id && p.blackTeamId == a.id;
        if (ab || ba) return true;
      }
    }
    return false;
  }

  /// Team Swiss round 1 (§5.2): sort teams by average rating of their
  /// non-null board-slot players desc (0 if none rated); top half vs bottom
  /// half, top-half team white; odd team count -> the LAST team gets a
  /// full-match-point bye AND every present player on it gets an individual
  /// bye (feeding individual standings/W-D-L like a normal Swiss bye).
  /// Returns (round matches, round pairing records).
  static (List<ChessMatch>, List<TeamRoundPairing>) generateTeamRound1(
    Tournament t,
  ) {
    final maxBoards = t.maxBoards ?? 0;
    final sorted = List<RosterTeam>.of(t.teams)
      ..sort(
        (a, b) => teamAverageRating(
          b,
          maxBoards,
          t.players,
          t.ratingType,
        ).compareTo(teamAverageRating(a, maxBoards, t.players, t.ratingType)),
      );
    final half = sorted.length ~/ 2;
    final matches = <ChessMatch>[];
    final pairings = <TeamRoundPairing>[];
    for (var i = 0; i < half; i++) {
      final (ms, pairing) = buildTeamPairing(
        whiteTeam: sorted[i],
        blackTeam: sorted[i + half],
        round: 1,
        maxBoards: maxBoards,
      );
      matches.addAll(ms);
      pairings.add(pairing);
    }
    if (sorted.length.isOdd) {
      final (ms, pairing) = buildTeamPairing(
        whiteTeam: sorted.last,
        blackTeam: null,
        round: 1,
        maxBoards: maxBoards,
      );
      matches.addAll(ms);
      pairings.add(pairing);
    }
    return (matches, pairings);
  }

  /// Team Swiss subsequent rounds (§5.2): group teams by matchPoints desc
  /// (within group: average rating desc); staged backtracking
  /// [_matchAllTeams]/[_maxMatchTeams] with the same 20,000 cap;
  /// [_repairTeamColorClashes]; [_assignWhiteTeam]; odd team count -> bye to
  /// the lowest-ranked team without a prior team bye (repeated bye as last
  /// resort); rescue force-pairing for leftovers — never drop a team.
  static (List<ChessMatch>, List<TeamRoundPairing>) generateTeamNextRound(
    Tournament t,
  ) {
    final roundNum = t.rounds.length + 1;
    final maxBoards = t.maxBoards ?? 0;
    final history = t.teamPairings;
    final matchPoints = {
      for (final s in t.teamStandings()) s.team.id: s.matchPoints,
    };
    final order = List<RosterTeam>.of(t.teams)
      ..sort((a, b) {
        final mpDiff = (matchPoints[b.id] ?? 0) - (matchPoints[a.id] ?? 0);
        if (mpDiff != 0) return mpDiff.sign.toInt();
        return teamAverageRating(
          b,
          maxBoards,
          t.players,
          t.ratingType,
        ).compareTo(teamAverageRating(a, maxBoards, t.players, t.ratingType));
      });

    RosterTeam? byeTeam;
    if (order.length.isOdd) {
      final priorByeIds = _teamByeIds(history);
      byeTeam = order.lastWhere(
        (team) => !priorByeIds.contains(team.id),
        orElse: () => order.last,
      );
      order.remove(byeTeam);
    }

    final matchAll = _matchAllTeams(order, history);
    final pairs = _repairTeamColorClashes(matchAll.pairs, history);

    final matches = <ChessMatch>[];
    final pairings = <TeamRoundPairing>[];
    for (final (teamA, teamB) in pairs) {
      final white = _assignWhiteTeam(teamA, teamB, history);
      final black = identical(white, teamA) ? teamB : teamA;
      final (ms, pairing) = buildTeamPairing(
        whiteTeam: white,
        blackTeam: black,
        round: roundNum,
        maxBoards: maxBoards,
      );
      matches.addAll(ms);
      pairings.add(pairing);
    }
    // Rescue pass: force-pair leftovers — never silently drop a team.
    final leftovers = List<RosterTeam>.of(matchAll.unpaired);
    for (var i = 0; i + 1 < leftovers.length; i += 2) {
      final (ms, pairing) = buildTeamPairing(
        whiteTeam: leftovers[i],
        blackTeam: leftovers[i + 1],
        round: roundNum,
        maxBoards: maxBoards,
      );
      matches.addAll(ms);
      pairings.add(pairing);
    }
    if (leftovers.length.isOdd) {
      byeTeam = leftovers.last;
    }
    if (byeTeam != null) {
      final (ms, pairing) = buildTeamPairing(
        whiteTeam: byeTeam,
        blackTeam: null,
        round: roundNum,
        maxBoards: maxBoards,
      );
      matches.addAll(ms);
      pairings.add(pairing);
    }
    return (matches, pairings);
  }

  static Set<String> _teamByeIds(List<List<TeamRoundPairing>> history) {
    final ids = <String>{};
    for (final pairings in history) {
      for (final p in pairings) {
        if (p.blackTeamId == null) ids.add(p.whiteTeamId);
      }
    }
    return ids;
  }

  /// Staged relaxation for teams (§5.2) — same order as the individual
  /// engine: rematches relaxed BEFORE clashes.
  static MatchAllTeamsResult _matchAllTeams(
    List<RosterTeam> order,
    List<List<TeamRoundPairing>> history,
  ) {
    MatchAllTeamsResult? best;
    for (final excludeRematch in const [true, false]) {
      for (final excludeClash in const [true, false]) {
        final result = _maxMatchTeams(
          order,
          history,
          excludeRematch,
          excludeClash,
        );
        if (result.unpaired.isEmpty) return result;
        if (best == null || result.unpaired.length < best.unpaired.length) {
          best = result;
        }
      }
    }
    return best!;
  }

  /// Backtracking team matching, same 20,000-attempt cap, prune and fallback
  /// branch as the individual engine (§5.2 _maxMatchTeams).
  static MatchAllTeamsResult _maxMatchTeams(
    List<RosterTeam> order,
    List<List<TeamRoundPairing>> history,
    bool excludeRematch,
    bool excludeClash,
  ) {
    var bestUnpairedCount = order.length + 1;
    List<(RosterTeam, RosterTeam)>? bestPairs;
    List<RosterTeam>? bestUnpaired;
    var attempts = 0;
    var stop = false;
    final used = List<bool>.filled(order.length, false);
    final currentPairs = <(RosterTeam, RosterTeam)>[];
    final unpairedSoFar = <RosterTeam>[];

    void search(int idx) {
      if (stop) return;
      attempts++;
      if (attempts > swissMaxAttempts) {
        stop = true;
        return;
      }
      var i = idx;
      while (i < order.length && used[i]) {
        i++;
      }
      if (i >= order.length) {
        if (unpairedSoFar.length < bestUnpairedCount) {
          bestUnpairedCount = unpairedSoFar.length;
          bestPairs = List.of(currentPairs);
          bestUnpaired = List.of(unpairedSoFar);
          if (unpairedSoFar.isEmpty) stop = true;
        }
        return;
      }
      if (unpairedSoFar.length >= bestUnpairedCount) return;
      final t1 = order[i];
      final candidates = <int>[];
      for (var j = i + 1; j < order.length; j++) {
        if (used[j]) continue;
        if (excludeRematch && _haveTeamsPlayed(t1, order[j], history)) continue;
        if (excludeClash && wouldForceTeamClash(t1, order[j], history)) {
          continue;
        }
        candidates.add(j);
      }
      candidates.sort((j1, j2) {
        if (excludeRematch) {
          final r1 = _haveTeamsPlayed(t1, order[j1], history) ? 1 : 0;
          final r2 = _haveTeamsPlayed(t1, order[j2], history) ? 1 : 0;
          if (r1 != r2) return r1 - r2;
        }
        if (excludeClash) {
          final c1 = wouldForceTeamClash(t1, order[j1], history) ? 1 : 0;
          final c2 = wouldForceTeamClash(t1, order[j2], history) ? 1 : 0;
          if (c1 != c2) return c1 - c2;
        }
        return (j1 - i) - (j2 - i);
      });
      for (final c in candidates) {
        used[i] = true;
        used[c] = true;
        currentPairs.add((t1, order[c]));
        search(i + 1);
        currentPairs.removeLast();
        used[i] = false;
        used[c] = false;
        if (stop) return;
      }
      used[i] = true;
      unpairedSoFar.add(t1);
      search(i + 1);
      unpairedSoFar.removeLast();
      used[i] = false;
    }

    search(0);
    if (bestPairs == null || bestUnpaired == null) {
      return MatchAllTeamsResult(pairs: const [], unpaired: List.of(order));
    }
    return MatchAllTeamsResult(pairs: bestPairs!, unpaired: bestUnpaired!);
  }

  /// Repairs team color clashes (§5.2 _repairTeamColorClashes): same two
  /// cross-swaps, first that creates no rematch and no new clash wins;
  /// otherwise the pair is left as-is.
  static List<(RosterTeam, RosterTeam)> _repairTeamColorClashes(
    List<(RosterTeam, RosterTeam)> pairs,
    List<List<TeamRoundPairing>> history,
  ) {
    final out = List<(RosterTeam, RosterTeam)>.of(pairs);
    for (var k = 0; k < out.length; k++) {
      final (ak, bk) = out[k];
      if (!wouldForceTeamClash(ak, bk, history)) continue;
      for (var j = 0; j < out.length; j++) {
        if (j == k) continue;
        final (aj, bj) = out[j];
        if (_teamSwapOk(ak, bj, history) && _teamSwapOk(aj, bk, history)) {
          out[k] = (ak, bj);
          out[j] = (aj, bk);
          break;
        } else if (_teamSwapOk(ak, aj, history) &&
            _teamSwapOk(bk, bj, history)) {
          out[k] = (ak, aj);
          out[j] = (bk, bj);
          break;
        }
      }
    }
    return out;
  }

  static bool _teamSwapOk(
    RosterTeam x,
    RosterTeam y,
    List<List<TeamRoundPairing>> history,
  ) => !_haveTeamsPlayed(x, y, history) && !wouldForceTeamClash(x, y, history);

  /// Mirrors [assignColors] at team granularity (§5.2 _assignWhiteTeam):
  /// team-level streak/balance; mandatory sides honored (compatible
  /// both-locked honored directly; same-color unavoidable clash -> parity
  /// tiebreak); one locked -> honored; neither -> the more black-heavy team
  /// streak is due white, ties by team color balance, final tie by the
  /// round-flipping parity tiebreak. Returns the team that plays white.
  static RosterTeam _assignWhiteTeam(
    RosterTeam a,
    RosterTeam b,
    List<List<TeamRoundPairing>> history,
  ) {
    final streakA = teamWhiteStreak(a, history);
    final streakB = teamWhiteStreak(b, history);
    final aMustWhite = streakA <= -2;
    final aMustBlack = streakA >= 2;
    final bMustWhite = streakB <= -2;
    final bMustBlack = streakB >= 2;

    if (aMustWhite && bMustBlack) return a;
    if (aMustBlack && bMustWhite) return b;
    if (aMustWhite && bMustWhite) {
      return _parityGivesWhiteToA(history.length, a.id) ? a : b;
    }
    if (aMustBlack && bMustBlack) {
      return _parityGivesWhiteToA(history.length, a.id) ? b : a;
    }
    if (aMustWhite) return a;
    if (bMustWhite) return b;
    if (aMustBlack) return b;
    if (bMustBlack) return a;
    if (streakA != streakB) return streakA < streakB ? a : b;
    final balanceA = teamColorBalance(a, history);
    final balanceB = teamColorBalance(b, history);
    if (balanceA != balanceB) return balanceA < balanceB ? a : b;
    return _parityGivesWhiteToA(history.length, a.id) ? a : b;
  }

  /// Builds the round's board matches and the [TeamRoundPairing] record
  /// (§5.2 _buildTeamPairingMatches, Olympiad-style alternation). Board i
  /// (0-based): both slots null -> NO match (matchIds[i] stays null); exactly
  /// one present -> that player gets an individual BYE (forfeited board);
  /// both present -> ODD boards (1-based): the white team's player is White;
  /// EVEN boards: FLIPPED — the black team's player is White, so each
  /// physical team mixes colors within a single round. A null [blackTeam] is
  /// a team bye: every present white-team player gets an individual bye.
  static (List<ChessMatch>, TeamRoundPairing) buildTeamPairing({
    required RosterTeam whiteTeam,
    required RosterTeam? blackTeam,
    required int round,
    required int maxBoards,
  }) {
    final wSlots = teamBoardSlots(whiteTeam, maxBoards);
    final bSlots = blackTeam == null
        ? List<String?>.filled(maxBoards, null)
        : teamBoardSlots(blackTeam, maxBoards);
    final matches = <ChessMatch>[];
    final matchIds = List<String?>.filled(maxBoards, null);
    for (var i = 0; i < maxBoards; i++) {
      final wP = wSlots[i];
      final bP = bSlots[i];
      if (wP == null && bP == null) continue; // no match for this board
      if (wP == null || bP == null) {
        final present = wP ?? bP;
        final m = ChessMatch(
          id: 'tsw_${round}_$i',
          round: round,
          board: i,
          whitePlayerId: present,
          blackPlayerId: null,
          result: MatchResult.bye,
        );
        matches.add(m);
        matchIds[i] = m.id;
        continue;
      }
      // Olympiad alternation: board 1,3,5.. (0-based index even) -> white
      // team's player is White; even boards -> FLIPPED.
      final whiteId = i.isEven ? wP : bP;
      final blackId = i.isEven ? bP : wP;
      final m = ChessMatch(
        id: 'tsw_${round}_$i',
        round: round,
        board: i,
        whitePlayerId: whiteId,
        blackPlayerId: blackId,
      );
      matches.add(m);
      matchIds[i] = m.id;
    }
    final pairing = TeamRoundPairing(
      round: round,
      whiteTeamId: whiteTeam.id,
      blackTeamId: blackTeam?.id,
      whiteBoardSlots: wSlots,
      blackBoardSlots: bSlots,
      matchIds: matchIds,
    );
    return (matches, pairing);
  }

  /// True iff EVERY unordered pair of teams has already faced each other
  /// (§5.2 allTeamPairsPlayed).
  static bool allTeamPairsPlayed(
    List<RosterTeam> teams,
    List<List<TeamRoundPairing>> history,
  ) {
    for (var i = 0; i < teams.length; i++) {
      for (var j = i + 1; j < teams.length; j++) {
        if (!_haveTeamsPlayed(teams[i], teams[j], history)) return false;
      }
    }
    return true;
  }
}
