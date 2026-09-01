/// Tournament model + format/status/rating-type enums.
library;

import 'dart:math' as math;

import '../services/rating_service.dart';
import 'bracket_generator.dart';
import 'chess_match.dart';
import 'player.dart';
import 'standings.dart';
import 'team.dart';

/// Tournament format. Values are the EXACT §2 check-constraint strings.
enum TournamentFormat {
  roundRobin('roundRobin'),
  knockout('knockout'),
  swiss('swiss');

  const TournamentFormat(this.value);

  /// Exact text stored in the `format` column (§2).
  final String value;

  /// Lenient decode per §7.5: unknown/renamed values silently coerce to
  /// [swiss] instead of throwing. Intentional — see §7.5.
  static TournamentFormat fromValue(String? value) =>
      TournamentFormat.values.where((f) => f.value == value).firstOrNull ??
      TournamentFormat.swiss;
}

/// Lifecycle status: draft -> inProgress -> completed, with an explicit
/// reopen path back to inProgress (§5.4). Values are the EXACT §2 strings.
enum TournamentStatus {
  draft('draft'),
  inProgress('inProgress'),
  completed('completed');

  const TournamentStatus(this.value);

  /// Exact text stored in the `status` column (§2).
  final String value;

  /// Lenient decode per §7.5: unknown/renamed values silently coerce to
  /// [draft] instead of throwing. Intentional — see §7.5.
  static TournamentStatus fromValue(String? value) =>
      TournamentStatus.values.where((s) => s.value == value).firstOrNull ??
      TournamentStatus.draft;
}

/// Which independent Elo pool this tournament affects (§4.6). Values are the
/// EXACT §2 check-constraint strings.
enum RatingType {
  blitz('blitz'),
  rapid('rapid');

  const RatingType(this.value);

  /// Exact text stored in the `rating_type` column (§2).
  final String value;

  /// Lenient decode per §7.5: unknown values coerce to [rapid] (the §2 column
  /// default). Intentional.
  static RatingType fromValue(String? value) =>
      RatingType.values.where((r) => r.value == value).firstOrNull ??
      RatingType.rapid;
}

/// A chess tournament: metadata + jsonb snapshots + runtime state.
///
/// The `school_id` column is a tenant-scoping concern injected by the service
/// layer, not carried on the model (§2 / §6). Serialization round-trips the
/// players + rounds too, because the offline queue stores
/// `tournament.toJson()` plus the players list (§5.6) and must be able to
/// reconstruct everything from the queued JSON.
class Tournament {
  Tournament({
    required this.id,
    required this.name,
    this.format = TournamentFormat.swiss,
    this.status = TournamentStatus.draft,
    this.ratingType = RatingType.rapid,
    this.isRated = true,
    this.currentRound = 0,
    this.maxBoards,
    Map<String, int>? ratingSnapshot,
    Map<String, Map<String, int>>? wdlSnapshot,
    Map<String, String>? tiebreakResults,
    List<RosterTeam>? teams,
    List<List<TeamRoundPairing>>? teamPairings,
    List<Player>? players,
    List<List<ChessMatch>>? rounds,
  }) : ratingSnapshot = ratingSnapshot ?? {},
       wdlSnapshot = wdlSnapshot ?? {},
       tiebreakResults = tiebreakResults ?? {},
       teams = teams ?? [],
       teamPairings = teamPairings ?? [],
       players = players ?? [],
       rounds = rounds ?? [];

  /// App-generated id: ms-epoch string (§7.1) — collision risk accepted at
  /// club scale.
  final String id;

  String name;

  /// roundRobin / knockout / swiss (§2).
  TournamentFormat format;

  /// draft / inProgress / completed (§2, §5.4).
  TournamentStatus status;

  /// blitz / rapid — selects the independent Elo pool (§4.6).
  RatingType ratingType;

  /// Whether Elo deltas apply at finalization (§4.8).
  bool isRated;

  /// 1-based index of the round currently being played (0 = none yet).
  int currentRound;

  /// Fixed board count for team tournaments; non-null IFF a team tournament
  /// (§2, §5.2 team Swiss).
  int? maxBoards;

  /// playerId -> pre-finalization rating, for undo (§4.8, §5.4).
  Map<String, int> ratingSnapshot;

  /// playerId -> {wins, draws, losses} snapshot, for undo (§4.8, §5.4).
  /// Undo is available IFF this is non-empty; empty on legacy tournaments
  /// triggers the reopen-legacy path (§5.4 reopenLegacy).
  Map<String, Map<String, int>> wdlSnapshot;

  /// Manual head-to-head tiebreak injections: `"winnerId_loserId" -> winnerId`
  /// (§4.4). Keys are parsed via split('_') later — safe only because ids are
  /// pure digits (§7.6). Malformed keys are skipped by consumers, not fatal.
  Map<String, String> tiebreakResults;

  /// Team snapshot; present IFF a team tournament (§2 teams jsonb).
  List<RosterTeam> teams;

  /// Per-round team pairings, parallel to [rounds] (§2 team_pairings, §4.5).
  List<List<TeamRoundPairing>> teamPairings;

  /// Tournament roster (players at enrollment — §2 tournament_players).
  List<Player> players;

  /// Generated rounds, each a list of [ChessMatch] ordered by board (§5.2).
  List<List<ChessMatch>> rounds;

  /// New tournaments get an ms-epoch id (§7.1).
  factory Tournament.create(String name) => Tournament(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: name,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'format': format.value,
    'status': status.value,
    'rating_type': ratingType.value,
    'is_rated': isRated,
    'current_round': currentRound,
    'max_boards': maxBoards,
    'rating_snapshot': ratingSnapshot,
    'wdl_snapshot': wdlSnapshot,
    'tiebreak_results': tiebreakResults,
    'teams': teams.map((t) => t.toJson()).toList(),
    'team_pairings': teamPairings
        .map((roundPairings) => roundPairings.map((p) => p.toJson()).toList())
        .toList(),
    'players': players.map((p) => p.toJson()).toList(),
    'rounds': rounds
        .map((roundMatches) => roundMatches.map((m) => m.toJson()).toList())
        .toList(),
  };

  factory Tournament.fromJson(Map<String, dynamic> json) {
    Map<String, int> intMap(dynamic raw) =>
        (raw as Map<String, dynamic>? ?? const {}).map(
          (k, v) => MapEntry(k, (v as num).toInt()),
        );
    Map<String, Map<String, int>> intIntMap(dynamic raw) =>
        (raw as Map<String, dynamic>? ?? const {}).map(
          (k, v) => MapEntry(k, intMap(v)),
        );
    Map<String, String> stringMap(dynamic raw) =>
        (raw as Map<String, dynamic>? ?? const {}).map(
          (k, v) => MapEntry(k, v as String),
        );
    return Tournament(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      // Lenient enum decode per §7.5 (intentional): format -> swiss,
      // status -> draft, rating type -> rapid.
      format: TournamentFormat.fromValue(json['format'] as String?),
      status: TournamentStatus.fromValue(json['status'] as String?),
      ratingType: RatingType.fromValue(json['rating_type'] as String?),
      isRated: json['is_rated'] as bool? ?? true,
      currentRound: (json['current_round'] as num?)?.toInt() ?? 0,
      maxBoards: (json['max_boards'] as num?)?.toInt(),
      ratingSnapshot: intMap(json['rating_snapshot']),
      wdlSnapshot: intIntMap(json['wdl_snapshot']),
      tiebreakResults: stringMap(json['tiebreak_results']),
      teams: (json['teams'] as List<dynamic>? ?? const [])
          .map((t) => RosterTeam.fromJson(t as Map<String, dynamic>))
          .toList(),
      teamPairings: (json['team_pairings'] as List<dynamic>? ?? const [])
          .map(
            (roundPairings) => (roundPairings as List<dynamic>)
                .map(
                  (p) => TeamRoundPairing.fromJson(p as Map<String, dynamic>),
                )
                .toList(),
          )
          .toList(),
      players: (json['players'] as List<dynamic>? ?? const [])
          .map((p) => Player.fromJson(p as Map<String, dynamic>))
          .toList(),
      rounds: (json['rounds'] as List<dynamic>? ?? const [])
          .map(
            (roundMatches) => (roundMatches as List<dynamic>)
                .map((m) => ChessMatch.fromJson(m as Map<String, dynamic>))
                .toList(),
          )
          .toList(),
    );
  }

  // =========================================================================
  // Structure helpers (§5.1 / §5.2)
  // =========================================================================

  /// True iff this is a team tournament (non-null maxBoards, §2/§5.2).
  bool get isTeamTournament => maxBoards != null;

  /// Rating of [p] in this tournament's pool (§4.6 — blitz/rapid pools).
  int ratingFor(Player p) =>
      ratingType == RatingType.blitz ? p.blitzRating : p.rapidRating;

  /// Total rounds per format (§5.1 totalRounds): roundRobin n odd ? n : n-1;
  /// knockout rounds = bitLength(smallest pow2 >= n) - 1; swiss n<=4 -> 3,
  /// n<=8 -> 4, n<=16 -> 5, else 7, or an explicit [swissRoundsOverride].
  int totalRounds({int? swissRoundsOverride}) {
    switch (format) {
      case TournamentFormat.roundRobin:
        final n = players.length;
        return n.isOdd ? n : n - 1;
      case TournamentFormat.knockout:
        final size = BracketGenerator.knockoutBracketSize(players.length);
        return size.bitLength - 1;
      case TournamentFormat.swiss:
        final n = players.length;
        return swissRoundsOverride ??
            (n <= 4
                ? 3
                : n <= 8
                ? 4
                : n <= 16
                ? 5
                : 7);
    }
  }

  /// Generates the next round per the active format's engine (§4.4/§5.2).
  /// Round Robin generates its FULL Berger schedule on the first call
  /// (subsequent calls return empty); Knockout generates one round at a time
  /// from the previous round's winners; Swiss one round at a time. Appends
  /// the round to [rounds] and advances [currentRound]. Returns the new
  /// round's matches (empty when nothing more to generate).
  List<ChessMatch> generateNextRound() {
    // Team tournaments always go through the separate team-Swiss engine
    // (§5.2 — deliberate separation).
    if (isTeamTournament) return generateNextTeamRound();
    switch (format) {
      case TournamentFormat.roundRobin:
        if (rounds.isNotEmpty) return const [];
        final all = BracketGenerator.generateRoundRobinRounds(players);
        if (all.isEmpty) return const [];
        rounds.addAll(all);
        currentRound = 1;
        return all.first;
      case TournamentFormat.knockout:
        final next = rounds.isEmpty
            ? BracketGenerator.generateKnockoutRound1(players, ratingType)
            : BracketGenerator.generateKnockoutNextRound(rounds);
        if (next.isEmpty) return const [];
        rounds.add(next);
        currentRound = rounds.length;
        return next;
      case TournamentFormat.swiss:
        final next = rounds.isEmpty
            ? BracketGenerator.generateSwissRound1(players, ratingType)
            : BracketGenerator.generateSwissNextRound(this);
        rounds.add(next);
        currentRound = rounds.length;
        return next;
    }
  }

  /// Generates the next TEAM Swiss round (§5.2 team engine): matches plus the
  /// persisted [TeamRoundPairing] record (parallel to [rounds]). Appends to
  /// [rounds]/[teamPairings] and advances [currentRound].
  List<ChessMatch> generateNextTeamRound() {
    final (matches, pairings) = teamPairings.isEmpty
        ? BracketGenerator.generateTeamRound1(this)
        : BracketGenerator.generateTeamNextRound(this);
    teamPairings.add(pairings);
    rounds.add(matches);
    currentRound = rounds.length;
    return matches;
  }

  /// True iff every unordered roster pair has met (§5.2 allPairsPlayed).
  bool get allPairsPlayed => BracketGenerator.allPairsPlayed(players, rounds);

  /// True iff every unordered team pair has met (§5.2 allTeamPairsPlayed).
  bool get allTeamPairsPlayed =>
      BracketGenerator.allTeamPairsPlayed(teams, teamPairings);

  // =========================================================================
  // Standings & tiebreaks (§5.3)
  // =========================================================================

  /// Individual standings (§5.3). Recomputed on every access — no
  /// memoization (§7.11, accepted at club scale).
  ///
  /// Pass 1: bye -> present player +1 point +1 win (no opponent recorded);
  /// decisive/draw -> both sides; pending skipped. Late joiners (earliest
  /// appearance — playing OR bye — in round >= 2) seed 0.5 raw points.
  /// Players who never appear are NOT late joiners and stay at 0.
  /// Pass 2: progressive cumulative score, late joiners starting the running
  /// total at 0.5. Pass 3: Buchholz / Cut-1 / Sonneborn-Berger / direct
  /// encounter (plus injected tiebreakResults as full 1.0 wins; malformed
  /// keys skipped, §4.4/§7.6). Sorted via TournamentStanding.compareTo.
  List<TournamentStanding> standings() {
    final points = <String, double>{};
    final wins = <String, int>{};
    final draws = <String, int>{};
    final losses = <String, int>{};
    final opponents = <String, List<String>>{};
    final direct = <String, Map<String, double>>{};
    final firstAppearance = <String, int>{};
    // Registration covers the roster plus any appearing id (defensive).
    final known = <String>{for (final p in players) p.id};
    void ensure(String id) {
      if (known.add(id)) {
        points[id] = 0;
        wins[id] = 0;
        draws[id] = 0;
        losses[id] = 0;
        opponents[id] = [];
        direct[id] = {};
      }
    }

    for (final id in known) {
      points[id] = 0;
      wins[id] = 0;
      draws[id] = 0;
      losses[id] = 0;
      opponents[id] = [];
      direct[id] = {};
    }

    // Pass 1: basic tally.
    for (final round in rounds) {
      for (final m in round) {
        if (m.result == MatchResult.pending) continue;
        if (m.whitePlayerId != null) {
          firstAppearance.putIfAbsent(m.whitePlayerId!, () => m.round);
        }
        if (m.blackPlayerId != null) {
          firstAppearance.putIfAbsent(m.blackPlayerId!, () => m.round);
        }
        if (m.isBye) {
          final present = m.whitePlayerId ?? m.blackPlayerId;
          if (present != null) {
            ensure(present);
            points[present] = points[present]! + 1;
            wins[present] = wins[present]! + 1;
          }
          continue;
        }
        final w = m.whitePlayerId!;
        final b = m.blackPlayerId!;
        ensure(w);
        ensure(b);
        opponents[w]!.add(b);
        opponents[b]!.add(w);
        switch (m.result) {
          case MatchResult.whiteWins:
            points[w] = points[w]! + 1;
            wins[w] = wins[w]! + 1;
            losses[b] = losses[b]! + 1;
            direct[w]![b] = (direct[w]![b] ?? 0) + 1;
          case MatchResult.blackWins:
            points[b] = points[b]! + 1;
            wins[b] = wins[b]! + 1;
            losses[w] = losses[w]! + 1;
            direct[b]![w] = (direct[b]![w] ?? 0) + 1;
          case MatchResult.draw:
            points[w] = points[w]! + 0.5;
            points[b] = points[b]! + 0.5;
            draws[w] = draws[w]! + 1;
            draws[b] = draws[b]! + 1;
            direct[w]![b] = (direct[w]![b] ?? 0) + 0.5;
            direct[b]![w] = (direct[b]![w] ?? 0) + 0.5;
          case MatchResult.pending:
          case MatchResult.bye:
            break;
        }
      }
    }

    // Late joiners: first appearance (play OR bye) in round >= 2 (§5.3).
    final lateJoinerIds = <String>{
      for (final e in firstAppearance.entries)
        if (e.value >= 2) e.key,
    };
    // Late joiners seed at 0.5 points (raw AND progressive — §4.7).
    for (final id in lateJoinerIds) {
      ensure(id);
      points[id] = points[id]! + 0.5;
    }

    // Pass 2: progressive — running total starts at 0.5 for late joiners.
    final progressive = <String, double>{
      for (final id in points.keys) id: lateJoinerIds.contains(id) ? 0.5 : 0.0,
    };
    for (final round in rounds) {
      for (final m in round) {
        if (m.result == MatchResult.pending) continue;
        if (m.isBye) {
          final present = m.whitePlayerId ?? m.blackPlayerId;
          if (present != null) {
            progressive[present] = progressive[present]! + 1;
          }
          continue;
        }
        switch (m.result) {
          case MatchResult.whiteWins:
            progressive[m.whitePlayerId!] = progressive[m.whitePlayerId!]! + 1;
          case MatchResult.blackWins:
            progressive[m.blackPlayerId!] = progressive[m.blackPlayerId!]! + 1;
          case MatchResult.draw:
            progressive[m.whitePlayerId!] =
                progressive[m.whitePlayerId!]! + 0.5;
            progressive[m.blackPlayerId!] =
                progressive[m.blackPlayerId!]! + 0.5;
          case MatchResult.pending:
          case MatchResult.bye:
            break;
        }
      }
    }

    // Pass 3: opponent-based tiebreaks.
    final buchholz = <String, double>{};
    final buchholzCut1 = <String, double>{};
    final sonnebornBerger = <String, double>{};
    for (final id in points.keys) {
      final oppScores = [for (final opp in opponents[id]!) points[opp] ?? 0.0];
      final total = oppScores.fold<double>(0, (s, v) => s + v);
      buchholz[id] = total; // empty -> 0
      buchholzCut1[id] = oppScores.isEmpty
          ? 0
          : total - oppScores.reduce(math.min);
      sonnebornBerger[id] = 0;
    }
    // Sonneborn-Berger: win -> opponent's final points; draw -> half; loss/bye -> 0.
    for (final round in rounds) {
      for (final m in round) {
        if (m.result == MatchResult.pending || m.isBye) continue;
        final w = m.whitePlayerId!;
        final b = m.blackPlayerId!;
        switch (m.result) {
          case MatchResult.whiteWins:
            sonnebornBerger[w] = sonnebornBerger[w]! + (points[b] ?? 0.0);
          case MatchResult.blackWins:
            sonnebornBerger[b] = sonnebornBerger[b]! + (points[w] ?? 0.0);
          case MatchResult.draw:
            sonnebornBerger[w] = sonnebornBerger[w]! + (points[b] ?? 0.0) / 2;
            sonnebornBerger[b] = sonnebornBerger[b]! + (points[w] ?? 0.0) / 2;
          case MatchResult.pending:
          case MatchResult.bye:
            break;
        }
      }
    }

    // Inject manual tiebreak results (§4.4): "winnerId_loserId" -> winnerId as
    // a full 1.0-point win. Malformed keys are SKIPPED, not fatal (§4.4/§7.6).
    tiebreakResults.forEach((key, winnerId) {
      final parts = key.split('_');
      if (parts.length != 2) return; // malformed — skipped
      ensure(winnerId);
      direct[winnerId]![parts[1]] = (direct[winnerId]![parts[1]] ?? 0) + 1.0;
    });

    final rosterById = {for (final p in players) p.id: p};
    final rows = <TournamentStanding>[
      for (final id in points.keys)
        TournamentStanding(
          player: rosterById[id] ?? Player(id: id, firstName: id, lastName: ''),
          points: points[id]!,
          wins: wins[id]!,
          draws: draws[id]!,
          losses: losses[id]!,
          progressiveScore: progressive[id] ?? 0,
          buchholz: buchholz[id] ?? 0,
          buchholzCut1: buchholzCut1[id] ?? 0,
          sonnebornBerger: sonnebornBerger[id] ?? 0,
          directEncounter: Map<String, double>.of(direct[id] ?? {}),
          lateJoiner: lateJoinerIds.contains(id),
          rating: rosterById[id] != null ? ratingFor(rosterById[id]!) : 0,
        ),
    ];
    rows.sort((a, b) => a.compareTo(b));
    return rows;
  }

  /// Team standings (§5.3). Deliberately OMITS progressive score and
  /// Sonneborn-Berger — a documented club-scale simplification.
  ///
  /// Replays the recorded [TeamRoundPairing]s: a team bye -> +1 match point,
  /// +1 match win, +1 match played, board points untouched; otherwise
  /// boardPointsFor both teams, higher board points -> win/loss, equal -> 0.5
  /// each + draw. Team Buchholz = sum of each faced opponent's FINAL match
  /// points. Sorted via TeamStanding.compareTo.
  List<TeamStanding> teamStandings() {
    final matchPoints = <String, double>{};
    final matchWins = <String, int>{};
    final matchDraws = <String, int>{};
    final matchLosses = <String, int>{};
    final boardPoints = <String, double>{};
    final opponentsFaced = <String, Set<String>>{};
    for (final team in teams) {
      matchPoints[team.id] = 0;
      matchWins[team.id] = 0;
      matchDraws[team.id] = 0;
      matchLosses[team.id] = 0;
      boardPoints[team.id] = 0;
      opponentsFaced[team.id] = {};
    }
    RosterTeam? teamById(String? id) {
      if (id == null) return null;
      for (final t in teams) {
        if (t.id == id) return t;
      }
      return null;
    }

    for (var r = 0; r < teamPairings.length; r++) {
      final roundMatches = r < rounds.length ? rounds[r] : const <ChessMatch>[];
      for (final pairing in teamPairings[r]) {
        final white = pairing.whiteTeamId;
        final black = pairing.blackTeamId;
        if (black == null) {
          // Team bye: +1 match point, +1 win, +1 played; board points
          // untouched (§5.3).
          matchPoints[white] = (matchPoints[white] ?? 0) + 1;
          matchWins[white] = (matchWins[white] ?? 0) + 1;
          continue;
        }
        final bpW = boardPointsFor(teamById(white), roundMatches);
        final bpB = boardPointsFor(teamById(black), roundMatches);
        boardPoints[white] = (boardPoints[white] ?? 0) + bpW;
        boardPoints[black] = (boardPoints[black] ?? 0) + bpB;
        opponentsFaced[white]!.add(black);
        opponentsFaced[black]!.add(white);
        if (bpW > bpB) {
          matchPoints[white] = (matchPoints[white] ?? 0) + 1;
          matchWins[white] = (matchWins[white]! + 1);
          matchLosses[black] = matchLosses[black]! + 1;
        } else if (bpB > bpW) {
          matchPoints[black] = (matchPoints[black] ?? 0) + 1;
          matchWins[black] = matchWins[black]! + 1;
          matchLosses[white] = matchLosses[white]! + 1;
        } else {
          matchPoints[white] = (matchPoints[white] ?? 0) + 0.5;
          matchPoints[black] = (matchPoints[black] ?? 0) + 0.5;
          matchDraws[white] = matchDraws[white]! + 1;
          matchDraws[black] = matchDraws[black]! + 1;
        }
      }
    }
    // Team Buchholz: sum of each faced opponent's FINAL match points.
    final rows = <TeamStanding>[
      for (final team in teams)
        TeamStanding(
          team: team,
          matchPoints: matchPoints[team.id] ?? 0,
          matchWins: matchWins[team.id] ?? 0,
          matchDraws: matchDraws[team.id] ?? 0,
          matchLosses: matchLosses[team.id] ?? 0,
          boardPoints: boardPoints[team.id] ?? 0,
          teamBuchholz: opponentsFaced[team.id]!.fold<double>(
            0,
            (s, opp) => s + (matchPoints[opp] ?? 0),
          ),
        ),
    ];
    rows.sort((a, b) => a.compareTo(b));
    return rows;
  }

  /// Individual board points a [team]'s roster players scored in
  /// [roundMatches] (§5.3 boardPointsFor): white win or white-side bye -> +1;
  /// white draw -> +0.5; black win -> +1; black draw -> +0.5 (a black-side
  /// bye gives the present black player +1 identically).
  double boardPointsFor(RosterTeam? team, List<ChessMatch> roundMatches) {
    if (team == null) return 0;
    var total = 0.0;
    for (final m in roundMatches) {
      final isWhiteSide =
          m.whitePlayerId != null && team.playerIds.contains(m.whitePlayerId);
      final isBlackSide =
          m.blackPlayerId != null && team.playerIds.contains(m.blackPlayerId);
      if (m.isBye) {
        if (isWhiteSide || isBlackSide) total += 1;
        continue;
      }
      if (isWhiteSide) {
        if (m.result == MatchResult.whiteWins) {
          total += 1;
        } else if (m.result == MatchResult.draw) {
          total += 0.5;
        }
      } else if (isBlackSide) {
        if (m.result == MatchResult.blackWins) {
          total += 1;
        } else if (m.result == MatchResult.draw) {
          total += 0.5;
        }
      }
    }
    return total;
  }

  // =========================================================================
  // Finalization / undo state machine (§5.4)
  // =========================================================================

  /// "End Tournament" (§5.4). Applies onto [masterPlayers] — the CURRENT
  /// master records, NOT the roster snapshot.
  ///
  /// Unrated path: snapshot W/D/L for undo, apply ONLY W/D/L deltas from the
  /// standings, mark completed. Rated path: snapshot ratings (the
  /// tournament's pool) + W/D/L, compute per-match Elo deltas with FIXED
  /// initial ratings (no compounding — §5.1(B), authoritative) and apply the
  /// per-pool delta totals + W/D/L, mark completed.
  void endTournament(List<Player> masterPlayers) {
    final standings = this.standings();
    // Snapshot the master pre-tournament state for undo.
    wdlSnapshot = {
      for (final p in players)
        p.id: {'wins': p.wins, 'draws': p.draws, 'losses': p.losses},
    };
    Map<String, int>? ratingTotals;
    if (isRated) {
      ratingSnapshot = {for (final p in players) p.id: ratingFor(p)};
      ratingTotals = RatingService.calculateAndApplyMatchDeltas(
        players,
        rounds,
        ratingType,
      );
    }
    for (final s in standings) {
      final master = masterPlayers
          .where((p) => p.id == s.player.id)
          .firstOrNull;
      if (master == null) continue;
      // W/D/L deltas from the standings: totals minus the roster's
      // enrollment-time W/D/L (the roster snapshot is the delta baseline).
      final rosterPlayer = players
          .where((p) => p.id == s.player.id)
          .firstOrNull;
      if (rosterPlayer != null) {
        master
          ..wins += s.wins - rosterPlayer.wins
          ..draws += s.draws - rosterPlayer.draws
          ..losses += s.losses - rosterPlayer.losses;
      }
      if (ratingTotals != null) {
        RatingService.applyChanges(
          [master],
          {master.id: ratingTotals[master.id] ?? 0},
          ratingType,
        );
      }
    }
    status = TournamentStatus.completed;
  }

  /// Undo the last submission (§5.4). Only valid for a NON-EMPTY
  /// wdlSnapshot. Restores ratings (if rated and the snapshot entry exists)
  /// and W/D/L from the snapshots onto [masterPlayers], reopens to
  /// inProgress, clears the snapshots AND all per-match rating deltas.
  void undoLastSubmission(List<Player> masterPlayers) {
    for (final rosterPlayer in players) {
      final master = masterPlayers
          .where((p) => p.id == rosterPlayer.id)
          .firstOrNull;
      if (master == null) continue;
      if (isRated && ratingSnapshot.containsKey(rosterPlayer.id)) {
        if (ratingType == RatingType.blitz) {
          master.blitzRating = ratingSnapshot[rosterPlayer.id]!;
        } else {
          master.rapidRating = ratingSnapshot[rosterPlayer.id]!;
        }
      }
      final snap = wdlSnapshot[rosterPlayer.id];
      if (snap != null) {
        master
          ..wins = snap['wins'] ?? 0
          ..draws = snap['draws'] ?? 0
          ..losses = snap['losses'] ?? 0;
      }
    }
    status = TournamentStatus.inProgress;
    ratingSnapshot = {};
    wdlSnapshot = {};
    for (final round in rounds) {
      for (final m in round) {
        m.whiteRatingDelta = null;
        m.blackRatingDelta = null;
      }
    }
  }

  /// Reopen a LEGACY completed tournament whose wdlSnapshot is EMPTY
  /// (§5.4 reopenLegacy): sets status back to inProgress ONLY — no rollback
  /// of ratings or W/D/L (the original contribution stays "baked in"; the
  /// UI must warn before this action).
  void reopenLegacy() {
    status = TournamentStatus.inProgress;
  }

  // =========================================================================
  // Maintenance (§5.5)
  // =========================================================================

  /// Recalculate W/D/L from history (§5.5): idempotent — zeroes every
  /// player's W/D/L, then replays every COMPLETED tournament's matches onto
  /// [players]. BYES ARE EXCLUDED here (unlike standings, where a bye counts
  /// as +1 point +1 win) — an intentional asymmetry, not a bug.
  static void recalculateWdl(
    List<Player> players,
    List<Tournament> tournaments,
  ) {
    for (final p in players) {
      p
        ..wins = 0
        ..draws = 0
        ..losses = 0;
    }
    final byId = {for (final p in players) p.id: p};
    for (final t in tournaments) {
      if (t.status != TournamentStatus.completed) continue;
      for (final round in t.rounds) {
        for (final m in round) {
          if (m.result == MatchResult.pending || m.isBye) continue;
          final w = byId[m.whitePlayerId];
          final b = byId[m.blackPlayerId];
          switch (m.result) {
            case MatchResult.whiteWins:
              w?.wins++;
              b?.losses++;
            case MatchResult.blackWins:
              b?.wins++;
              w?.losses++;
            case MatchResult.draw:
              w?.draws++;
              b?.draws++;
            case MatchResult.pending:
            case MatchResult.bye:
              break;
          }
        }
      }
    }
  }

  /// Backfill per-match rating deltas (§5.5): display-only, idempotent.
  /// For each COMPLETED, RATED tournament with a rating snapshot, reconstruct
  /// each roster player at their PRE-tournament rating (keeping their CURRENT
  /// gamesPlayed — a backfilled delta may land in the wrong K-factor tier;
  /// documented, accepted caveat) and write the per-match deltas. Skips
  /// tournaments already fully filled. Returns counts:
  /// (filled, skippedNoSnapshot, alreadyDone, notRated).
  static ({int filled, int skippedNoSnapshot, int alreadyDone, int notRated})
  recalculateMatchRatingDeltas(List<Tournament> tournaments) {
    var filled = 0;
    var skippedNoSnapshot = 0;
    var alreadyDone = 0;
    var notRated = 0;
    for (final t in tournaments) {
      if (!t.isRated) {
        notRated++;
        continue;
      }
      if (t.status != TournamentStatus.completed) continue;
      final fullyFilled = t.rounds.every(
        (round) => round.every(
          (m) =>
              m.result == MatchResult.pending ||
              m.isBye ||
              (m.whiteRatingDelta != null && m.blackRatingDelta != null),
        ),
      );
      if (fullyFilled) {
        alreadyDone++;
        continue;
      }
      if (t.ratingSnapshot.isEmpty) {
        skippedNoSnapshot++;
        continue;
      }
      // Reconstruct at pre-tournament ratings; keep current gamesPlayed.
      final reconstructed = [
        for (final p in t.players)
          if (t.ratingSnapshot.containsKey(p.id))
            Player(
              id: p.id,
              firstName: p.firstName,
              lastName: p.lastName,
              blitzRating: p.blitzRating,
              rapidRating: p.rapidRating,
            )
          else
            p,
      ];
      if (t.ratingType == RatingType.blitz) {
        for (final r in reconstructed) {
          r.blitzRating = t.ratingSnapshot[r.id] ?? r.blitzRating;
        }
      } else {
        for (final r in reconstructed) {
          r.rapidRating = t.ratingSnapshot[r.id] ?? r.rapidRating;
        }
      }
      RatingService.calculateAndApplyMatchDeltas(
        reconstructed,
        t.rounds,
        t.ratingType,
      );
      filled++;
    }
    return (
      filled: filled,
      skippedNoSnapshot: skippedNoSnapshot,
      alreadyDone: alreadyDone,
      notRated: notRated,
    );
  }
}
