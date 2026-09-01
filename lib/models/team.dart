/// Team models: reusable saved rosters ([RosterTeam]) and the per-round team
/// pairing record ([TeamRoundPairing]) used by team tournaments.
library;

/// JSON keys mirror the §2 `teams` table / `team_pairings` jsonb column exactly.

/// A reusable, tournament-independent named roster (§4.3).
///
/// [playerIds] is ORDERED — its index is the player's board number (§4.3).
/// The ~10-player cap is a UI-level rule, NOT a model invariant (§4.3).
///
/// Note: this file holds two public classes deliberately — the spec's Phase-1
/// file layout (§1) places both team models in `team.dart`.
class RosterTeam {
  RosterTeam({required this.id, required this.name, this.playerIds = const []});

  /// App-generated id (ms-epoch string per §7.1), not a UUID.
  final String id;

  String name;

  /// Ordered list of player ids; index == board number (§4.3).
  /// Not FK-enforced, matching the §2 `player_ids jsonb` column.
  List<String> playerIds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'player_ids': playerIds,
  };

  factory RosterTeam.fromJson(Map<String, dynamic> json) {
    return RosterTeam(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      playerIds: (json['player_ids'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
    );
  }
}

/// One team-vs-team pairing within a single round of a team tournament.
///
/// Persisted PER ROUND (§4.5) because a forfeited board has a null player and
/// the absent team cannot be inferred from individual match data alone.
///
/// Minimal shape designed against §5.2 `_buildTeamPairingMatches`: to rebuild
/// the round's board matches you need both teams' board slots (players may be
/// null on short rosters / forfeits) and the ids of the matches generated for
/// this round. A null [blackTeamId] means the white team got a full
/// match-point bye (§5.2 team Swiss).
class TeamRoundPairing {
  TeamRoundPairing({
    required this.round,
    required this.whiteTeamId,
    this.blackTeamId,
    this.whiteBoardSlots = const [],
    this.blackBoardSlots = const [],
    this.matchIds = const [],
  });

  /// 1-based round number this pairing belongs to.
  final int round;

  /// Team playing the nominal white side (null team on the black side = the
  /// white team receives a team bye, §5.2).
  final String whiteTeamId;

  /// Opposing team id, or null when this is a team bye.
  final String? blackTeamId;

  /// White team's board-slot player ids, index == board index, null slot =
  /// empty board / short roster (§5.2 `boardSlots`).
  final List<String?> whiteBoardSlots;

  /// Black team's board-slot player ids (null slots allowed, §5.2).
  final List<String?> blackBoardSlots;

  /// Ids of the individual [ChessMatch]s generated from this pairing for this
  /// round, index == board index: null ONLY where both board slots are null
  /// (no match generated, §5.2); a single-present (forfeited) board generates
  /// a bye match and DOES have an id.
  final List<String?> matchIds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'round': round,
    'white_team_id': whiteTeamId,
    'black_team_id': blackTeamId,
    'white_board_slots': whiteBoardSlots,
    'black_board_slots': blackBoardSlots,
    'match_ids': matchIds,
  };

  factory TeamRoundPairing.fromJson(Map<String, dynamic> json) {
    List<String?> nullableStringList(dynamic raw) =>
        (raw as List<dynamic>? ?? const []).map((e) => e as String?).toList();
    return TeamRoundPairing(
      round: (json['round'] as num?)?.toInt() ?? 0,
      whiteTeamId: json['white_team_id'] as String? ?? '',
      blackTeamId: json['black_team_id'] as String?,
      whiteBoardSlots: nullableStringList(json['white_board_slots']),
      blackBoardSlots: nullableStringList(json['black_board_slots']),
      matchIds: nullableStringList(json['match_ids']),
    );
  }
}
