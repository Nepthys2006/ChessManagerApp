import 'models/chess_match.dart';
import 'models/player.dart';
import 'models/team.dart';
import 'models/tournament.dart';

/// Compile-time demo-seed flag (§3 table row SEED_DEMO). Set via
/// `--dart-define-from-file=.env` or `--dart-define=SEED_DEMO=true`.
/// Phase 3 wires seeding: when true, LocalDb is seeded with [DemoData] —
/// touching only the local snapshot, never live Supabase data.
const bool seedDemo = bool.fromEnvironment('SEED_DEMO');

/// Static sample dataset. NO service/LocalDb wiring lives here — Phase 3
/// (services agent) wires the seeding; this file only supplies the data.
class DemoData {
  DemoData._();

  /// Consistent player ids (>= 100000 per §4.2).
  static final List<Player> players = [
    Player(
      id: '100001',
      firstName: 'Alicia',
      lastName: 'Fernandez',
      blitzRating: 1810,
      rapidRating: 1785,
      email: 'alicia@example.edu',
      title: PlayerTitle.none,
      gender: PlayerGender.female,
      memberStatus: MemberStatus.member,
      college: 'UM College',
      program: 'BS Mathematics',
      wins: 4,
      losses: 1,
      draws: 2,
    ),
    Player(
      id: '100002',
      firstName: 'Ben',
      lastName: 'Okafor',
      blitzRating: 1720,
      rapidRating: 1690,
      email: 'ben@example.edu',
      title: PlayerTitle.none,
      memberStatus: MemberStatus.member,
      college: 'UM College',
      program: 'BA Physics',
      wins: 3,
      losses: 2,
      draws: 1,
    ),
    Player(
      id: '100003',
      firstName: 'Carla',
      lastName: 'Nguyen',
      blitzRating: 1645,
      rapidRating: 1610,
      email: null,
      phone: '555-0103',
      title: PlayerTitle.none,
      gender: PlayerGender.female,
      memberStatus: MemberStatus.member,
      college: 'UM College',
      program: 'BS Computer Science',
      wins: 2,
      losses: 3,
      draws: 2,
    ),
    Player(
      id: '100004',
      firstName: 'Diego',
      lastName: 'Santos',
      blitzRating: 1580,
      rapidRating: 1555,
      title: PlayerTitle.none,
      memberStatus: MemberStatus.member,
      college: 'UM College',
      program: 'BA Economics',
      wins: 2,
      losses: 2,
      draws: 3,
    ),
    Player(
      id: '100005',
      firstName: 'Emma',
      lastName: 'Kowalski',
      blitzRating: 1515,
      rapidRating: 1495,
      title: PlayerTitle.none,
      gender: PlayerGender.female,
      memberStatus: MemberStatus.member,
      college: 'UM College',
      program: 'BS Biology',
      wins: 1,
      losses: 3,
      draws: 2,
    ),
    Player(
      id: '100006',
      firstName: 'Farid',
      lastName: 'Haddad',
      blitzRating: 1465,
      rapidRating: 1450,
      title: PlayerTitle.none,
      memberStatus: MemberStatus.guest,
      college: 'Northgate High',
      program: 'Grade 12',
      wins: 1,
      losses: 2,
      draws: 1,
    ),
    Player(
      id: '100007',
      firstName: 'Grace',
      lastName: 'Lim',
      blitzRating: 1410,
      rapidRating: 1405,
      title: PlayerTitle.none,
      gender: PlayerGender.female,
      memberStatus: MemberStatus.guest,
      college: 'Westbrook Academy',
      program: 'Grade 11',
      wins: 0,
      losses: 2,
      draws: 1,
    ),
    Player(
      id: '100008',
      firstName: 'Hugo',
      lastName: 'Weber',
      blitzRating: 1350,
      rapidRating: 1330,
      title: PlayerTitle.candidateMaster,
      memberStatus: MemberStatus.member,
      college: 'UM College',
      program: 'BA History',
      wins: 0,
      losses: 1,
      draws: 0,
    ),
  ];

  /// One saved reusable roster; board order matters (§4.3).
  static final List<RosterTeam> teams = [
    RosterTeam(
      id: '1756712000000',
      name: 'UMCCC A Team',
      playerIds: ['100001', '100002', '100003', '100004'],
    ),
  ];

  /// Two tournaments: a fully-played (2 rounds) individual swiss with a bye,
  /// and a draft team tournament.
  static final List<Tournament> tournaments = [
    _individualSwiss(),
    _teamDraft(),
  ];

  /// Individual swiss, 7 of the 8 players enrolled (so every round has one
  /// bye), 2 fully-played rounds (§8-style sample data).
  static Tournament _individualSwiss() {
    final t = Tournament(
      id: '1756712100001',
      name: 'UMCCC Rapid Swiss September',
      format: TournamentFormat.swiss,
      status: TournamentStatus.inProgress,
      ratingType: RatingType.rapid,
      isRated: true,
      currentRound: 2,
      players: [
        _roster('100001', 1785),
        _roster('100002', 1690),
        _roster('100003', 1610),
        _roster('100004', 1555),
        _roster('100005', 1495),
        _roster('100006', 1450),
        _roster('100007', 1405),
      ],
    );

    // Round 1: rating-seeded pairs (1v4, 2v5, 3v6); lowest (100007) gets the
    // round-1 bye (§5.2 Swiss round 1: sorted.last gets a bye).
    t.rounds.add([
      ChessMatch(
        id: 'sw_1_0',
        round: 1,
        board: 0,
        whitePlayerId: '100001',
        blackPlayerId: '100004',
        result: MatchResult.whiteWins,
        whiteRatingDelta: 8,
        blackRatingDelta: -8,
      ),
      ChessMatch(
        id: 'sw_1_1',
        round: 1,
        board: 1,
        whitePlayerId: '100002',
        blackPlayerId: '100005',
        result: MatchResult.draw,
        whiteRatingDelta: 0,
        blackRatingDelta: 0,
      ),
      ChessMatch(
        id: 'sw_1_2',
        round: 1,
        board: 2,
        whitePlayerId: '100003',
        blackPlayerId: '100006',
        result: MatchResult.blackWins,
        whiteRatingDelta: -9,
        blackRatingDelta: 9,
      ),
      ChessMatch(
        id: 'sw_1_3',
        round: 1,
        board: 3,
        whitePlayerId: '100007',
        result: MatchResult.bye,
      ),
    ]);

    // Round 2: leaders clash; lowest player without a bye (100004) gets it.
    t.rounds.add([
      ChessMatch(
        id: 'sw_2_0',
        round: 2,
        board: 0,
        whitePlayerId: '100001',
        blackPlayerId: '100006',
        result: MatchResult.whiteWins,
        whiteRatingDelta: 6,
        blackRatingDelta: -6,
      ),
      ChessMatch(
        id: 'sw_2_1',
        round: 2,
        board: 1,
        whitePlayerId: '100003',
        blackPlayerId: '100007',
        result: MatchResult.blackWins,
        whiteRatingDelta: -9,
        blackRatingDelta: 9,
      ),
      ChessMatch(
        id: 'sw_2_2',
        round: 2,
        board: 2,
        whitePlayerId: '100002',
        blackPlayerId: '100005',
        result: MatchResult.draw,
        whiteRatingDelta: 0,
        blackRatingDelta: 0,
      ),
      ChessMatch(
        id: 'sw_2_3',
        round: 2,
        board: 3,
        whitePlayerId: '100004',
        result: MatchResult.bye,
      ),
    ]);

    return t;
  }

  /// Roster snapshot player at enrollment-time rating (§2 tournament_players).
  static Player _roster(String id, int rapidRating) {
    final master = players.firstWhere((p) => p.id == id);
    return Player(
      id: master.id,
      firstName: master.firstName,
      lastName: master.lastName,
      blitzRating: master.blitzRating,
      rapidRating: rapidRating,
      email: master.email,
      phone: master.phone,
      title: master.title,
      gender: master.gender,
      memberStatus: master.memberStatus,
      college: master.college,
      program: master.program,
    );
  }

  /// Team tournament draft: fixed board count, teams + pairing structure
  /// declared but no rounds generated yet (§5.2 team Swiss).
  static Tournament _teamDraft() {
    return Tournament(
      id: '1756712200002',
      name: 'UMCCC Team Blitz Cup',
      format: TournamentFormat.swiss,
      status: TournamentStatus.draft,
      ratingType: RatingType.blitz,
      isRated: true,
      currentRound: 0,
      maxBoards: 4,
      teams: List.of(teams),
      teamPairings: [],
      players: [
        _roster('100001', 1810),
        _roster('100002', 1720),
        _roster('100003', 1645),
        _roster('100004', 1580),
        _roster('100005', 1515),
        _roster('100006', 1465),
        _roster('100007', 1410),
        _roster('100008', 1350),
      ],
      rounds: [],
    );
  }
}
