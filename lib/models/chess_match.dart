/// One chess match/bye record.
library;

/// Ids follow the §2 convention (`'rr_0_0'`, `'sw_1_0'`, `'ko_1_1'`,
/// `'tsw_...'`).

/// Match result. Values are the EXACT §2 check-constraint strings; they
/// round-trip through Supabase as text (§10.3).
enum MatchResult {
  pending('pending'),
  whiteWins('whiteWins'),
  blackWins('blackWins'),
  draw('draw'),
  bye('bye');

  const MatchResult(this.value);

  /// Exact text stored in the `result` column (§2).
  final String value;

  /// Lenient decode per §7.5: unknown/renamed values silently coerce to
  /// [pending] instead of throwing. Intentional — see §7.5.
  static MatchResult fromValue(String? value) =>
      MatchResult.values.where((r) => r.value == value).firstOrNull ??
      MatchResult.pending;
}

/// A single board game (or bye) inside a tournament round.
class ChessMatch {
  ChessMatch({
    required this.id,
    required this.round,
    required this.board,
    this.whitePlayerId,
    this.blackPlayerId,
    this.result = MatchResult.pending,
    this.whiteRatingDelta,
    this.blackRatingDelta,
  });

  /// Deterministic id per format, e.g. `'sw_1_0'` (round 1, board 0) — §2.
  final String id;

  /// 1-based round number.
  final int round;

  /// Board number within the round. Base per §5.2 format rules — Round Robin
  /// boards are 1-based (round r+1, board i+1); Swiss uses sequential board
  /// numbers; knockout is unspecified by the spec. The field itself is
  /// base-agnostic; check the generating engine before assuming.
  final int board;

  /// White-side player id; null means a bye (§2).
  final String? whitePlayerId;

  /// Black-side player id; null means a bye (§2).
  final String? blackPlayerId;

  MatchResult result;

  /// Per-game Elo delta for white, written at finalization and rounded PER
  /// GAME (§5.1(B) — the authoritative path). Null until finalize/backfill.
  int? whiteRatingDelta;

  /// Per-game Elo delta for black (§5.1(B)). Null until finalize/backfill.
  int? blackRatingDelta;

  /// True when this record is a bye (either side null / result bye) — §5.2.
  bool get isBye =>
      result == MatchResult.bye ||
      whitePlayerId == null ||
      blackPlayerId == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'round': round,
    'board': board,
    'white_player_id': whitePlayerId,
    'black_player_id': blackPlayerId,
    'result': result.value,
    'white_rating_delta': whiteRatingDelta,
    'black_rating_delta': blackRatingDelta,
  };

  factory ChessMatch.fromJson(Map<String, dynamic> json) {
    return ChessMatch(
      id: json['id'] as String? ?? '',
      round: (json['round'] as num?)?.toInt() ?? 0,
      board: (json['board'] as num?)?.toInt() ?? 0,
      whitePlayerId: json['white_player_id'] as String?,
      blackPlayerId: json['black_player_id'] as String?,
      // Lenient decode per §7.5: unknown result -> pending (intentional).
      result: MatchResult.fromValue(json['result'] as String?),
      whiteRatingDelta: (json['white_rating_delta'] as num?)?.toInt(),
      blackRatingDelta: (json['black_rating_delta'] as num?)?.toInt(),
    );
  }
}
