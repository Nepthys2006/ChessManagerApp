/// DATA-ONLY classes for standings computation results (§5.3). All engines
/// (points/tiebreak computation) live in Phase 2 — this file intentionally
/// contains no computation, only shapes and the exact comparison orders.
library;

import 'player.dart';
import 'team.dart';

/// Individual player standing row (§5.3 — DATA ONLY).
class TournamentStanding {
  TournamentStanding({
    required this.player,
    required this.points,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.progressiveScore,
    required this.buchholz,
    required this.buchholzCut1,
    required this.sonnebornBerger,
    required this.directEncounter,
    required this.lateJoiner,
    required this.rating,
  });

  /// Reference to the roster player this row describes.
  final Player player;

  /// Total points (byes count +1; late joiners seed 0.5 — §5.3).
  final double points;

  final int wins;
  final int draws;
  final int losses;

  /// Cumulative running score across rounds (§5.3 pass 2).
  final double progressiveScore;

  /// Sum of opponents' final points (§5.3 pass 3).
  final double buchholz;

  /// Buchholz minus the single lowest opponent score (§5.3).
  final double buchholzCut1;

  /// Sonneborn-Berger: win -> opp final points, draw -> half, loss -> 0 (§5.3).
  final double sonnebornBerger;

  /// opponentId -> points scored against that opponent, including injected
  /// tiebreak results (§5.3 pass 3; keys of tiebreakResults parsed via
  /// split('_') later, §7.6).
  final Map<String, double> directEncounter;

  /// True iff the player's first appearance (play or bye) is round >= 2
  /// (§5.3 late-joiner detection). Players never appearing are NOT late
  /// joiners — Phase 2 owns that distinction.
  final bool lateJoiner;

  /// Rating fallback for the final sort level (§5.3 sort step 8). Which pool
  /// (blitz/rapid) is the Phase-2 caller's choice per tournament.ratingType.
  final int rating;

  /// EXACT §5.3 standings sort order: points -> Buchholz-Cut1 -> Buchholz ->
  /// Progressive -> Direct Encounter -> Sonneborn-Berger -> Wins -> Rating,
  /// all descending, each level only breaking ties from the previous.
  ///
  /// NOTE (§5.2 vs §5.3): this is the STANDINGS order. The Swiss pairing
  /// engine's score-group ordering (§5.2 step 1) is a DIFFERENT, deliberately
  /// narrower order — Buchholz-Cut1 -> Buchholz -> Progressive -> SB -> Wins
  /// -> Rating, WITHOUT the direct-encounter level. Do not reuse this
  /// comparator verbatim for score-group ordering.
  ///
  /// The direct-encounter level below is a pairwise head-to-head comparison
  /// between the two rows being compared (§5.3 sort step 5: "more points
  /// head-to-head wins"). It can be non-transitive among 3+ tied players —
  /// that is the spec-described legacy behavior and is intentional.
  int compareTo(TournamentStanding other) {
    if (points != other.points) return other.points.compareTo(points);
    if (buchholzCut1 != other.buchholzCut1) {
      return other.buchholzCut1.compareTo(buchholzCut1);
    }
    if (buchholz != other.buchholz) return other.buchholz.compareTo(buchholz);
    if (progressiveScore != other.progressiveScore) {
      return other.progressiveScore.compareTo(progressiveScore);
    }
    final mineAgainstThem = directEncounter[other.player.id] ?? 0.0;
    final theirsAgainstMe = other.directEncounter[player.id] ?? 0.0;
    if (mineAgainstThem != theirsAgainstMe) {
      return theirsAgainstMe.compareTo(mineAgainstThem);
    }
    if (sonnebornBerger != other.sonnebornBerger) {
      return other.sonnebornBerger.compareTo(sonnebornBerger);
    }
    if (wins != other.wins) return other.wins.compareTo(wins);
    return other.rating.compareTo(rating);
  }
}

/// Team standing row (§5.3 — DATA ONLY).
///
/// Deliberately OMITS progressive score and Sonneborn-Berger — a documented
/// club-scale simplification (§5.3 team standings).
class TeamStanding {
  TeamStanding({
    required this.team,
    required this.matchPoints,
    required this.matchWins,
    required this.matchDraws,
    required this.matchLosses,
    required this.boardPoints,
    required this.teamBuchholz,
  });

  /// Reference to the team this row describes.
  final RosterTeam team;

  /// Match points: +1 win, +0.5 draw, +1 for a team bye (§5.3).
  final double matchPoints;

  final int matchWins;
  final int matchDraws;
  final int matchLosses;

  /// Sum of individual board points across all rounds (§5.3).
  final double boardPoints;

  /// Sum of each faced opponent's FINAL match points (§5.3).
  final double teamBuchholz;

  /// EXACT §5.3 team sort order: matchPoints desc -> boardPoints desc ->
  /// teamBuchholz desc -> team name asc.
  int compareTo(TeamStanding other) {
    if (matchPoints != other.matchPoints) {
      return other.matchPoints.compareTo(matchPoints);
    }
    if (boardPoints != other.boardPoints) {
      return other.boardPoints.compareTo(boardPoints);
    }
    if (teamBuchholz != other.teamBuchholz) {
      return other.teamBuchholz.compareTo(teamBuchholz);
    }
    return team.name.compareTo(other.team.name);
  }
}
