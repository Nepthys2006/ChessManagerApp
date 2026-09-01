import 'package:flutter_test/flutter_test.dart';

import 'package:chess_manager/demo_data.dart';
import 'package:chess_manager/models/chess_match.dart';
import 'package:chess_manager/models/player.dart';
import 'package:chess_manager/models/standings.dart';
import 'package:chess_manager/models/team.dart';
import 'package:chess_manager/models/tournament.dart';

void main() {
  group('Player JSON round-trip', () {
    test('full player survives toMap/fromMap', () {
      final p = Player(
        id: '100123',
        firstName: 'Alicia',
        lastName: 'Fernandez',
        blitzRating: 1810,
        rapidRating: 1785,
        email: 'a@x.edu',
        phone: '555-0100',
        title: PlayerTitle.candidateMaster,
        gender: PlayerGender.female,
        memberStatus: MemberStatus.guest,
        college: 'UM College',
        program: 'BS Math',
        wins: 3,
        losses: 1,
        draws: 2,
        isActive: false,
      );
      final back = Player.fromJson(p.toJson());
      expect(back.id, p.id);
      expect(back.firstName, 'Alicia');
      expect(back.lastName, 'Fernandez');
      expect(back.blitzRating, 1810);
      expect(back.rapidRating, 1785);
      expect(back.email, 'a@x.edu');
      expect(back.phone, '555-0100');
      expect(back.title, PlayerTitle.candidateMaster);
      expect(back.gender, PlayerGender.female);
      expect(back.memberStatus, MemberStatus.guest);
      expect(back.college, 'UM College');
      expect(back.program, 'BS Math');
      expect(back.wins, 3);
      expect(back.losses, 1);
      expect(back.draws, 2);
      expect(back.isActive, false);
    });

    test('snake_case keys match §2 columns exactly', () {
      final json = Player(id: '1', firstName: 'A', lastName: 'B').toJson();
      expect(json.keys.toSet(), {
        'id',
        'first_name',
        'last_name',
        'blitz_rating',
        'rapid_rating',
        'email',
        'phone',
        'title',
        'gender',
        'member_status',
        'college',
        'program',
        'wins',
        'losses',
        'draws',
        'is_active',
      });
      expect(json['title'], '');
      expect(json['gender'], 'male');
      expect(json['member_status'], 'member');
    });
  });

  group('Player.nextId (§4.2)', () {
    test('empty list -> 100000', () {
      expect(Player.nextId([]), '100000');
    });

    test('existing max -> +1', () {
      final existing = [
        Player(id: '100005', firstName: 'A', lastName: 'B'),
        Player(id: '100002', firstName: 'C', lastName: 'D'),
      ];
      expect(Player.nextId(existing), '100006');
    });

    test('non-numeric ids are ignored for the max', () {
      final existing = [
        Player(id: '999999', firstName: 'A', lastName: 'B'),
        Player(id: 'not-a-number', firstName: 'C', lastName: 'D'),
      ];
      expect(Player.nextId(existing), '1000000');
    });
  });

  group('Player derived metrics (§4.2, zero-guarded)', () {
    test('gamesPlayed / score / winRate', () {
      final p = Player(
        id: '1',
        firstName: 'A',
        lastName: 'B',
        wins: 3,
        draws: 2,
        losses: 1,
      );
      expect(p.gamesPlayed, 6);
      expect(p.score, 4.0);
      expect(p.winRate, closeTo(0.5, 1e-9));
    });

    test('zero games -> winRate 0 (no divide-by-zero)', () {
      final p = Player(id: '1', firstName: 'A', lastName: 'B');
      expect(p.gamesPlayed, 0);
      expect(p.score, 0.0);
      expect(p.winRate, 0);
    });
  });

  group('Player.copyWith preserves id by default (§7.1)', () {
    test('copyWith(id: originalId) pattern and implicit preservation', () {
      final p = Player(id: '100042', firstName: 'Old', lastName: 'Name');
      final edited = p.copyWith(firstName: 'New');
      expect(edited.id, '100042');
      final explicit = p.copyWith(id: p.id, lastName: 'Surname');
      expect(explicit.id, '100042');
    });
  });

  group('Lenient enum decode (§7.5)', () {
    test('unknown gender -> male, unknown memberStatus -> member', () {
      final p = Player.fromJson({
        'id': '1',
        'first_name': 'A',
        'last_name': 'B',
        'gender': 'nonbinary-legacy',
        'member_status': 'expired',
      });
      expect(p.gender, PlayerGender.male);
      expect(p.memberStatus, MemberStatus.member);
    });

    test('unknown match result -> pending', () {
      final m = ChessMatch.fromJson({
        'id': 'sw_1_0',
        'round': 1,
        'board': 0,
        'result': 'resigned',
      });
      expect(m.result, MatchResult.pending);
    });

    test('unknown tournament format/status/ratingType -> defaults', () {
      final t = Tournament.fromJson({
        'id': '1',
        'name': 'T',
        'format': 'ladder',
        'status': 'archived',
        'rating_type': 'classical',
      });
      expect(t.format, TournamentFormat.swiss);
      expect(t.status, TournamentStatus.draft);
      expect(t.ratingType, RatingType.rapid);
    });

    test('unknown title coerces to none', () {
      final p = Player.fromJson({'id': '1', 'title': 'WGM'});
      expect(p.title, PlayerTitle.none);
    });
  });

  group('ChessMatch round-trip + isBye', () {
    test('played match round-trips incl. deltas', () {
      final m = ChessMatch(
        id: 'sw_2_1',
        round: 2,
        board: 1,
        whitePlayerId: '100001',
        blackPlayerId: '100002',
        result: MatchResult.blackWins,
        whiteRatingDelta: -8,
        blackRatingDelta: 8,
      );
      final back = ChessMatch.fromJson(m.toJson());
      expect(back.id, 'sw_2_1');
      expect(back.round, 2);
      expect(back.board, 1);
      expect(back.whitePlayerId, '100001');
      expect(back.blackPlayerId, '100002');
      expect(back.result, MatchResult.blackWins);
      expect(back.whiteRatingDelta, -8);
      expect(back.blackRatingDelta, 8);
      expect(back.isBye, false);
    });

    test('bye detection on null side and bye result', () {
      expect(
        ChessMatch(id: 'a', round: 1, board: 0, whitePlayerId: '1').isBye,
        true,
      );
      expect(
        ChessMatch(id: 'b', round: 1, board: 0, result: MatchResult.bye).isBye,
        true,
      );
    });
  });

  group('RosterTeam round-trip (§4.3)', () {
    test('ordered player_ids preserved', () {
      final t = RosterTeam(
        id: '1756712000000',
        name: 'A Team',
        playerIds: ['100003', '100001', '100002'],
      );
      final back = RosterTeam.fromJson(t.toJson());
      expect(back.id, t.id);
      expect(back.name, 'A Team');
      expect(back.playerIds, ['100003', '100001', '100002']);
    });

    test('player_ids key is jsonb-shaped (§2 teams table)', () {
      expect(RosterTeam(id: 'x', name: 'n').toJson(), {
        'id': 'x',
        'name': 'n',
        'player_ids': <String>[],
      });
    });
  });

  group('TeamRoundPairing round-trip', () {
    test('null team (bye) and null board slots survive', () {
      final p = TeamRoundPairing(
        round: 2,
        whiteTeamId: 'teamA',
        blackTeamId: null,
        whiteBoardSlots: ['100001', null, '100003', '100004'],
        blackBoardSlots: const [],
        // Board-aligned per §5.2: board 0 single-present -> bye match id;
        // board 1 double-null -> no match (null id); boards 2-3 single-present
        // -> bye match ids.
        matchIds: ['tsw_2_0', null, 'tsw_2_1', 'tsw_2_2'],
      );
      final back = TeamRoundPairing.fromJson(p.toJson());
      expect(back.round, 2);
      expect(back.whiteTeamId, 'teamA');
      expect(back.blackTeamId, isNull);
      expect(back.whiteBoardSlots, ['100001', null, '100003', '100004']);
      expect(back.blackBoardSlots, isEmpty);
      expect(back.matchIds, ['tsw_2_0', null, 'tsw_2_1', 'tsw_2_2']);
    });
  });

  group('Tournament round-trip (incl. rounds + roster, §5.6 shape)', () {
    test('DemoData swiss tournament survives full round-trip', () {
      final source = DemoData.tournaments.first;
      final json = source.toJson();
      final back = Tournament.fromJson(json);

      expect(back.id, source.id);
      expect(back.name, source.name);
      expect(back.format, TournamentFormat.swiss);
      expect(back.status, TournamentStatus.inProgress);
      expect(back.ratingType, RatingType.rapid);
      expect(back.isRated, true);
      expect(back.currentRound, 2);
      expect(back.maxBoards, isNull);
      expect(back.players.length, 7);
      expect(back.rounds.length, 2);
      expect(back.rounds[0].length, 4);
      expect(back.rounds[1][3].result, MatchResult.bye);
      expect(back.rounds[1][3].blackPlayerId, isNull);
      // Nested match + player fields survive too.
      expect(back.rounds[0][0].whiteRatingDelta, 8);
      expect(back.players.first.rapidRating, 1785);
      // A second round-trip is stable (idempotent JSON shape).
      expect(Tournament.fromJson(back.toJson()).toJson(), json);
    });

    test('DemoData team draft round-trips teams + pairings structure', () {
      final source = DemoData.tournaments.last;
      final back = Tournament.fromJson(source.toJson());
      expect(back.maxBoards, 4);
      expect(back.teams.length, 1);
      expect(back.teams.first.playerIds, [
        '100001',
        '100002',
        '100003',
        '100004',
      ]);
      expect(back.teamPairings, isEmpty);
      expect(back.rounds, isEmpty);
    });

    test('snapshots and tiebreak keys round-trip verbatim (§7.6 shape)', () {
      final t = Tournament(
        id: '1756712300003',
        name: 'Tiebreak Cup',
        ratingSnapshot: {'100001': 1785},
        wdlSnapshot: {
          '100001': {'wins': 1, 'draws': 0, 'losses': 0},
        },
        tiebreakResults: {'100001_100002': '100001'},
      );
      final back = Tournament.fromJson(t.toJson());
      expect(back.ratingSnapshot['100001'], 1785);
      expect(back.wdlSnapshot['100001'], {'wins': 1, 'draws': 0, 'losses': 0});
      // Key stays a raw string; split('_') parsing is a later-phase concern.
      expect(back.tiebreakResults['100001_100002'], '100001');
    });
  });

  group('Standing comparators (§5.3 sort orders)', () {
    Player p(String id) => Player(id: id, firstName: 'P$id', lastName: id);

    TournamentStanding st(
      String id, {
      double points = 0,
      double buchholzCut1 = 0,
      double buchholz = 0,
      double progressive = 0,
      double direct = 0,
      double sb = 0,
      int wins = 0,
      int rating = 1500,
    }) {
      return TournamentStanding(
        player: p(id),
        points: points,
        wins: wins,
        draws: 0,
        losses: 0,
        progressiveScore: progressive,
        buchholz: buchholz,
        buchholzCut1: buchholzCut1,
        sonnebornBerger: sb,
        directEncounter: direct > 0 ? {'opp': direct} : {},
        lateJoiner: false,
        rating: rating,
      );
    }

    test('higher points sort first', () {
      final a = st('a', points: 2.5);
      final b = st('b', points: 2.0);
      expect(a.compareTo(b), lessThan(0));
    });

    test('buchholzCut1 breaks points ties before buchholz', () {
      final a = st('a', points: 2, buchholzCut1: 3.5, buchholz: 5);
      final b = st('b', points: 2, buchholzCut1: 3.0, buchholz: 9);
      expect(a.compareTo(b), lessThan(0));
    });

    TournamentStanding h2h(
      String id,
      Map<String, double> de, {
      double points = 3,
      double sb = 0,
      int rating = 1500,
    }) => TournamentStanding(
      player: p(id),
      points: points,
      wins: 0,
      draws: 0,
      losses: 0,
      progressiveScore: 0,
      buchholz: 0,
      buchholzCut1: 0,
      sonnebornBerger: sb,
      directEncounter: de,
      lateJoiner: false,
      rating: rating,
    );

    test('direct encounter is head-to-head, not a map-sum (§5.3 level 5)', () {
      // A beat B head-to-head; otherwise fully tied -> A must rank first even
      // though both DE maps hold one entry (sum-equal under the old bug).
      final a = h2h('a', {'b': 1.0});
      final b = h2h('b', {'a': 0.0});
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(a), greaterThan(0));
    });

    test(
      'direct encounter ignores unrelated DE entries and byes (no leak)',
      () {
        // Same points, never met: a's point is a bye (no DE entries), b beat
        // someone else. Level 5 must NOT split them; the tie falls through to
        // the final rating level.
        final a = h2h('a', {}, points: 1, rating: 1700);
        final b = h2h('b', {'c': 1.0}, points: 1, rating: 1600);
        expect(a.compareTo(b), lessThan(0));
        expect(b.compareTo(a), greaterThan(0));
      },
    );

    test('injected tiebreakResult resolves winner above loser (§4.4)', () {
      // tiebreakResults['winner_loser'] = winner injects a full 1.0-point
      // win for the winner against the loser (§5.3 pass 3).
      final winner = h2h('w', {'l': 1.0});
      final loser = h2h('l', {'w': 0.0});
      expect(winner.compareTo(loser), lessThan(0));
      expect(loser.compareTo(winner), greaterThan(0));
    });

    test('head-to-head is intentionally non-transitive among 3+ (legacy)', () {
      final a = h2h('a', {'b': 1.0, 'c': 0.0});
      final b = h2h('b', {'c': 1.0, 'a': 0.0});
      final c = h2h('c', {'a': 1.0, 'b': 0.0});
      // A beat B, B beat C, C beat A — pairwise only, no total order. This is
      // the spec-described legacy behavior; do not "fix" it into a map-sum.
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(c), lessThan(0));
      expect(c.compareTo(a), lessThan(0));
    });

    test('rating is the final fallback', () {
      final a = st('a', rating: 1700);
      final b = st('b', rating: 1600);
      expect(a.compareTo(b), lessThan(0));
    });

    test('team standings: matchPoints -> boardPoints -> buchholz -> name', () {
      RosterTeam team(String name) =>
          RosterTeam(id: 't_$name', name: name, playerIds: const []);
      TeamStanding ts(
        String name, {
        double mp = 0,
        double bp = 0,
        double tb = 0,
      }) => TeamStanding(
        team: team(name),
        matchPoints: mp,
        matchWins: 0,
        matchDraws: 0,
        matchLosses: 0,
        boardPoints: bp,
        teamBuchholz: tb,
      );

      expect(ts('A', mp: 3).compareTo(ts('B', mp: 2)), lessThan(0));
      expect(
        ts('A', mp: 2, bp: 5).compareTo(ts('B', mp: 2, bp: 4)),
        lessThan(0),
      );
      expect(
        ts('A', mp: 2, bp: 4, tb: 3).compareTo(ts('B', mp: 2, bp: 4)),
        lessThan(0),
      );
      // Name is ascending at the final level.
      expect(ts('B').compareTo(ts('A')), greaterThan(0));
    });
  });
}
