/// FIDE Elo rating service (§5.1).
library;

import 'dart:math' as math;

import '../models/chess_match.dart';
import '../models/player.dart';
import '../models/tournament.dart';

/// Elo rating math for the two independent rating pools (blitz / rapid).
///
/// ⚠️ This class intentionally contains TWO coexisting, differently-rounded
/// change calculations (§5.1):
///
///  * (A) [calculateTournamentChanges] — rounds ONCE, at the very end, per
///        player. Secondary/legacy path.
///  * (B) [calculateAndApplyMatchDeltas] — rounds PER GAME, writes the delta
///        onto each [ChessMatch], and its totals are the AUTHORITATIVE numbers
///        applied at finalization (§4.6, §5.4).
///
/// Because (B) rounds every game individually, its per-player total can differ
/// by ±1–2 from (A)'s single end-of-tournament rounding. This divergence is a
/// documented, load-bearing quirk — do NOT unify the two paths.
class RatingService {
  RatingService._();

  /// Expected score of `ra` against `rb` (§5.1).
  static double expectedScore(int ra, int rb) =>
      1 / (1 + math.pow(10, (rb - ra) / 400));

  /// Actual score for a side given the match result (§5.1). Byes must be
  /// filtered out by callers BEFORE this is reached; pending -> 0.
  static double actualScore(MatchResult result, bool isWhite) {
    switch (result) {
      case MatchResult.whiteWins:
        return isWhite ? 1.0 : 0.0;
      case MatchResult.blackWins:
        return isWhite ? 0.0 : 1.0;
      case MatchResult.draw:
        return 0.5;
      case MatchResult.pending:
      case MatchResult.bye:
        return 0.0;
    }
  }

  /// Tiered K-factor (§5.1): gamesPlayed < 30 -> 40; else rating < 2400 -> 20;
  /// else 10. [rating] must be from the tournament's rating pool.
  static int kFactor(Player player, int rating) {
    if (player.gamesPlayed < 30) return 40;
    if (rating < 2400) return 20;
    return 10;
  }

  static int _poolRating(Player p, RatingType ratingType) =>
      ratingType == RatingType.blitz ? p.blitzRating : p.rapidRating;

  static int _kFor(Player p, RatingType ratingType) =>
      kFactor(p, _poolRating(p, ratingType));

  /// (A) Whole-tournament change map — secondary/legacy path (§5.1).
  ///
  /// Uses each player's INITIAL (call-time) rating for every expected-score
  /// calculation — never in-progress values (no compounding). Accumulates
  /// double deltas and rounds ONCE at the very end per player. This sum can
  /// differ by ±1–2 from (B) — keep both paths, do not unify (§5.1).
  static Map<String, int> calculateTournamentChanges(
    List<Player> players,
    List<List<ChessMatch>> rounds,
    RatingType ratingType,
  ) {
    final initialRatings = <String, int>{
      for (final p in players) p.id: _poolRating(p, ratingType),
    };
    final changes = <String, double>{for (final p in players) p.id: 0.0};
    for (final round in rounds) {
      for (final m in round) {
        if (m.result == MatchResult.pending || m.isBye) continue;
        final w = players.firstWhere(
          (p) => p.id == m.whitePlayerId,
          orElse: () => Player(id: '', firstName: '', lastName: ''),
        );
        final b = players.firstWhere(
          (p) => p.id == m.blackPlayerId,
          orElse: () => Player(id: '', firstName: '', lastName: ''),
        );
        if (w.id.isEmpty || b.id.isEmpty) continue;
        final rw = initialRatings[w.id]!;
        final rb = initialRatings[b.id]!;
        final ew = expectedScore(rw, rb);
        final sw = actualScore(m.result, true);
        changes[w.id] = changes[w.id]! + _kFor(w, ratingType) * (sw - ew);
        final sb = actualScore(m.result, false);
        changes[b.id] = changes[b.id]! + _kFor(b, ratingType) * (sb - (1 - ew));
      }
    }
    return changes.map((id, c) => MapEntry(id, c.round()));
  }

  /// (B) Per-match deltas — PRIMARY / authoritative path (§5.1).
  ///
  /// Mutates the matches in [rounds], writing the PER-GAME-rounded
  /// [ChessMatch.whiteRatingDelta] / [ChessMatch.blackRatingDelta]. Uses fixed
  /// initial ratings (call-time snapshot) for the whole tournament — no
  /// compounding round to round. Returns the per-player int totals; these ARE
  /// the numbers applied to the master roster at finalization (§5.4).
  static Map<String, int> calculateAndApplyMatchDeltas(
    List<Player> players,
    List<List<ChessMatch>> rounds,
    RatingType ratingType,
  ) {
    final initialRatings = <String, int>{
      for (final p in players) p.id: _poolRating(p, ratingType),
    };
    final totals = <String, int>{for (final p in players) p.id: 0};
    for (final round in rounds) {
      for (final m in round) {
        if (m.result == MatchResult.pending || m.isBye) continue;
        final w = players.firstWhere(
          (p) => p.id == m.whitePlayerId,
          orElse: () => Player(id: '', firstName: '', lastName: ''),
        );
        final b = players.firstWhere(
          (p) => p.id == m.blackPlayerId,
          orElse: () => Player(id: '', firstName: '', lastName: ''),
        );
        if (w.id.isEmpty || b.id.isEmpty) continue;
        final rw = initialRatings[w.id]!;
        final rb = initialRatings[b.id]!;
        final ew = expectedScore(rw, rb);
        final eb = expectedScore(rb, rw);
        final sw = actualScore(m.result, true);
        final sb = actualScore(m.result, false);
        final whiteDelta = (_kFor(w, ratingType) * (sw - ew)).round();
        final blackDelta = (_kFor(b, ratingType) * (sb - eb)).round();
        // Rounded PER GAME and written onto the record (§4.6, §5.1(B)).
        m.whiteRatingDelta = whiteDelta;
        m.blackRatingDelta = blackDelta;
        totals[w.id] = totals[w.id]! + whiteDelta;
        totals[b.id] = totals[b.id]! + blackDelta;
      }
    }
    return totals;
  }

  /// Applies pre-computed per-player changes onto the matching rating pool
  /// only; the other pool is untouched (§5.1 applyChanges).
  static void applyChanges(
    List<Player> players,
    Map<String, int> changes,
    RatingType ratingType,
  ) {
    for (final p in players) {
      final change = changes[p.id] ?? 0;
      if (change == 0) continue;
      if (ratingType == RatingType.blitz) {
        p.blitzRating += change;
      } else {
        p.rapidRating += change;
      }
    }
  }
}
