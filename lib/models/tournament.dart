/// Tournament model + format/status/rating-type enums.
library;

import 'chess_match.dart';
import 'player.dart';
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
}
