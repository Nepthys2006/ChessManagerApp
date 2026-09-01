import 'package:flutter_test/flutter_test.dart';

import 'package:chess_manager/models/chess_match.dart';
import 'package:chess_manager/models/player.dart';
import 'package:chess_manager/models/tournament.dart';
import 'package:chess_manager/services/rating_service.dart';

Player _player(String id, int rating, {int gamesPlayed = 0}) =>
    Player(id: id, firstName: 'F$id', lastName: 'L$id', rapidRating: rating)
      ..wins = gamesPlayed;

ChessMatch _game(int round, String white, String black, MatchResult result) =>
    ChessMatch(
      id: 'sw_${round}_0',
      round: round,
      board: 0,
      whitePlayerId: white,
      blackPlayerId: black,
      result: result,
    );

void main() {
  group('RatingService formulas (§5.1)', () {
    test('expectedScore symmetric and known value', () {
      expect(RatingService.expectedScore(1500, 1500), 0.5);
      expect(RatingService.expectedScore(1500, 1600), closeTo(0.36, 0.001));
      expect(
        RatingService.expectedScore(1500, 1600) +
            RatingService.expectedScore(1600, 1500),
        closeTo(1.0, 1e-9),
      );
    });

    test('actualScore map incl. pending -> 0', () {
      expect(RatingService.actualScore(MatchResult.whiteWins, true), 1.0);
      expect(RatingService.actualScore(MatchResult.whiteWins, false), 0.0);
      expect(RatingService.actualScore(MatchResult.blackWins, false), 1.0);
      expect(RatingService.actualScore(MatchResult.draw, true), 0.5);
      expect(RatingService.actualScore(MatchResult.pending, true), 0.0);
    });

    test('tiered K-factor (§4.6)', () {
      expect(RatingService.kFactor(_player('1', 1500), 1500), 40);
      expect(
        RatingService.kFactor(_player('1', 2399, gamesPlayed: 30), 2399),
        20,
      );
      expect(
        RatingService.kFactor(_player('1', 2400, gamesPlayed: 30), 2400),
        10,
      );
    });
  });

  group('Two coexisting rounding strategies (§5.1)', () {
    test('(A) rounds once at the end; (B) rounds per game — they diverge', () {
      final playersA = [_player('100001', 1500), _player('100002', 1600)];
      final rounds = [
        [_game(1, '100001', '100002', MatchResult.whiteWins)],
        [_game(2, '100001', '100002', MatchResult.blackWins)],
      ];
      // (A) legacy: one rounding per player at the very end.
      // white: 40*((1-0.360) + (0-0.360)) = 40*0.280 = 11.2 -> 11
      final a = RatingService.calculateTournamentChanges(
        playersA,
        rounds,
        RatingType.rapid,
      );
      expect(a['100001'], 11);
      expect(a['100002'], -11);

      // (B) authoritative: rounded PER GAME.
      // g1 white: round(40*0.640)=26, black: -26; g2 white: round(-14.4)=-14,
      // black: 14 -> totals white 12, black -12.
      final playersB = [_player('100001', 1500), _player('100002', 1600)];
      final b = RatingService.calculateAndApplyMatchDeltas(
        playersB,
        rounds,
        RatingType.rapid,
      );
      expect(b['100001'], 12);
      expect(b['100002'], -12);
      // Divergence by ±1–2 is the documented, intentional quirk.
      expect(a['100001'], isNot(b['100001']));
      // (B) writes the per-game deltas onto the match records.
      expect(rounds[0].single.whiteRatingDelta, 26);
      expect(rounds[0].single.blackRatingDelta, -26);
      expect(rounds[1].single.whiteRatingDelta, -14);
      expect(rounds[1].single.blackRatingDelta, 14);
    });

    test('applyChanges touches only the matching pool (§4.6)', () {
      final p = _player('1', 1500);
      RatingService.applyChanges([p], {'1': 12}, RatingType.rapid);
      expect(p.rapidRating, 1512);
      expect(p.blitzRating, 1500);
    });

    test('pending matches are skipped; byes filtered before scoring', () {
      final players = [_player('1', 1500), _player('2', 1600)];
      final rounds = [
        [_game(1, '1', '2', MatchResult.pending)],
      ];
      final a = RatingService.calculateTournamentChanges(
        players,
        rounds,
        RatingType.rapid,
      );
      expect(a['1'], 0);
      expect(a['2'], 0);
    });
  });

  group('totalRounds (§5.1)', () {
    Tournament t(TournamentFormat format, int n) => Tournament(
      id: '1',
      name: 'T',
      format: format,
      players: [for (var i = 0; i < n; i++) _player('10000$i', 1500)],
    );

    test('round robin: n odd -> n, else n-1', () {
      expect(t(TournamentFormat.roundRobin, 5).totalRounds(), 5);
      expect(t(TournamentFormat.roundRobin, 4).totalRounds(), 3);
    });

    test('knockout: bitLength(smallest pow2 >= n) - 1', () {
      expect(t(TournamentFormat.knockout, 5).totalRounds(), 3);
      expect(t(TournamentFormat.knockout, 8).totalRounds(), 3);
      expect(t(TournamentFormat.knockout, 9).totalRounds(), 4);
    });

    test('swiss thresholds with override', () {
      expect(t(TournamentFormat.swiss, 3).totalRounds(), 3);
      expect(t(TournamentFormat.swiss, 5).totalRounds(), 4);
      expect(t(TournamentFormat.swiss, 10).totalRounds(), 5);
      expect(t(TournamentFormat.swiss, 20).totalRounds(), 7);
      expect(
        t(TournamentFormat.swiss, 20).totalRounds(swissRoundsOverride: 9),
        9,
      );
    });
  });

  group('Standings (§5.3)', () {
    test('late joiner seeds 0.5 into raw points AND progressive', () {
      final t = Tournament(
        id: '1',
        name: 'T',
        format: TournamentFormat.swiss,
        players: [
          _player('100001', 1600),
          _player('100002', 1500),
          _player('100003', 1400),
        ],
      );
      // Round 1: 100001 beats 100002; 100003 not yet enrolled.
      t.rounds.add([_game(1, '100001', '100002', MatchResult.whiteWins)]);
      // Round 2: 100003 appears first time (a bye) — late joiner.
      t.rounds.add([
        _game(2, '100001', '100002', MatchResult.draw),
        ChessMatch(
          id: 'sw_2_1',
          round: 2,
          board: 1,
          whitePlayerId: '100003',
          result: MatchResult.bye,
        ),
      ]);
      final standings = t.standings();
      final late = standings.firstWhere((s) => s.player.id == '100003');
      expect(late.lateJoiner, isTrue);
      // 0.5 seed + 1.0 bye = 1.5 raw; progressive also starts at 0.5.
      expect(late.points, 1.5);
      expect(late.progressiveScore, 1.5);
      // A bye counts as +1 point and a win (§4.7).
      expect(late.wins, 1);
      final early = standings.firstWhere((s) => s.player.id == '100001');
      expect(early.lateJoiner, isFalse);
      expect(early.points, 1.5); // 1 (R1 win) + 0.5 (R2 draw)
    });

    test('never-appearing player: 0 points, NOT a late joiner', () {
      final t = Tournament(
        id: '1',
        name: 'T',
        players: [_player('100001', 1600), _player('100002', 1500)],
      );
      t.rounds.add([_game(1, '100001', '100002', MatchResult.whiteWins)]);
      final ghost = Tournament(
        id: '2',
        name: 'T2',
        players: [
          _player('100001', 1600),
          _player('100002', 1500),
          _player('100003', 1400),
        ],
      )..rounds.add([_game(1, '100001', '100002', MatchResult.whiteWins)]);
      final standings = ghost.standings();
      final absent = standings.firstWhere((s) => s.player.id == '100003');
      expect(absent.lateJoiner, isFalse);
      expect(absent.points, 0);
      expect(absent.progressiveScore, 0);
    });

    test('direct encounter includes injected tiebreak results (§7.6)', () {
      final t = Tournament(
        id: '1',
        name: 'T',
        players: [_player('100001', 1600), _player('100002', 1500)],
        tiebreakResults: {'100001_100002': '100001'},
      );
      final standings = t.standings();
      final a = standings.firstWhere((s) => s.player.id == '100001');
      expect(a.directEncounter['100002'], 1.0);
    });

    test('malformed tiebreak keys are skipped, not fatal (§4.4)', () {
      final t = Tournament(
        id: '1',
        name: 'T',
        players: [_player('100001', 1600), _player('100002', 1500)],
        tiebreakResults: {'broken': '100001', 'a_b_c': '100001'},
      );
      expect(t.standings().length, 2);
    });

    test('buchholz / cut-1 / sonneborn-berger computed', () {
      final t = Tournament(
        id: '1',
        name: 'T',
        players: [
          _player('100001', 1600),
          _player('100002', 1500),
          _player('100003', 1400),
        ],
      );
      // R1: 1 beats 2; 3 bye. R2: 1 beats 3; 2 bye.
      t.rounds.add([
        _game(1, '100001', '100002', MatchResult.whiteWins),
        ChessMatch(
          id: 'sw_1_1',
          round: 1,
          board: 1,
          whitePlayerId: '100003',
          result: MatchResult.bye,
        ),
      ]);
      t.rounds.add([
        _game(2, '100001', '100003', MatchResult.whiteWins),
        ChessMatch(
          id: 'sw_2_1',
          round: 2,
          board: 1,
          whitePlayerId: '100002',
          result: MatchResult.bye,
        ),
      ]);
      final s = t.standings();
      final p1 = s.firstWhere((e) => e.player.id == '100001');
      // Opponents' final points: 100002 (R1 loss + R2 bye = 1.0) and 100003
      // (R1 bye + R2 loss = 1.0). Buchholz = 2.0.
      expect(p1.points, 2.0);
      expect(p1.buchholz, closeTo(2.0, 1e-9));
      expect(p1.buchholzCut1, closeTo(1.0, 1e-9)); // drop the lowest (1.0)
      // SB: two wins -> opponent final points: 1.0 + 1.0 = 2.0.
      expect(p1.sonnebornBerger, closeTo(2.0, 1e-9));
    });
  });

  group('Maintenance (§5.5)', () {
    test('bye-vs-recalc asymmetry: byes excluded from W/D/L recalc', () {
      final master = [_player('100001', 1600), _player('100002', 1500)];
      final t = Tournament(
        id: '1',
        name: 'T',
        players: [_player('100001', 1600), _player('100002', 1500)],
        status: TournamentStatus.completed,
      );
      t.rounds.add([
        _game(1, '100001', '100002', MatchResult.whiteWins),
        ChessMatch(
          id: 'sw_1_1',
          round: 1,
          board: 1,
          whitePlayerId: '100001',
          result: MatchResult.bye,
        ),
      ]);
      Tournament.recalculateWdl(master, [t]);
      // Standings would give the bye +1 win; recalc EXCLUDES byes.
      expect(master[0].wins, 1);
      expect(master[1].losses, 1);
    });

    test('recalculateWdl is idempotent', () {
      final master = [_player('1', 1500), _player('2', 1600)];
      final t = Tournament(
        id: '1',
        name: 'T',
        players: [_player('1', 1500), _player('2', 1600)],
        status: TournamentStatus.completed,
      );
      t.rounds.add([_game(1, '1', '2', MatchResult.draw)]);
      Tournament.recalculateWdl(master, [t]);
      Tournament.recalculateWdl(master, [t]);
      expect(master[0].draws, 1);
      expect(master[0].wins, 0);
      expect(master[1].draws, 1);
    });

    test('recalculateMatchRatingDeltas backfills from snapshot', () {
      final t = Tournament(
        id: '1',
        name: 'T',
        ratingType: RatingType.rapid,
        isRated: true,
        status: TournamentStatus.completed,
        players: [_player('1', 1526), _player('2', 1574)],
        ratingSnapshot: {'1': 1500, '2': 1600},
      );
      t.rounds.add([_game(1, '1', '2', MatchResult.whiteWins)]);
      final counts = Tournament.recalculateMatchRatingDeltas([t]);
      expect(counts.filled, 1);
      expect(t.rounds.single.single.whiteRatingDelta, isNotNull);
      expect(t.rounds.single.single.whiteRatingDelta, 26);
      // Second run: already done.
      final counts2 = Tournament.recalculateMatchRatingDeltas([t]);
      expect(counts2.alreadyDone, 1);
    });

    test('skips unrated and snapshot-less tournaments', () {
      final unrated = Tournament(
        id: '1',
        name: 'U',
        isRated: false,
        status: TournamentStatus.completed,
        players: [_player('1', 1500)],
      )..rounds.add([_game(1, '1', '2', MatchResult.whiteWins)]);
      final noSnapshot = Tournament(
        id: '2',
        name: 'N',
        isRated: true,
        status: TournamentStatus.completed,
        players: [_player('1', 1500), _player('2', 1600)],
      )..rounds.add([_game(1, '1', '2', MatchResult.whiteWins)]);
      final counts = Tournament.recalculateMatchRatingDeltas([
        unrated,
        noSnapshot,
      ]);
      expect(counts.notRated, 1);
      expect(counts.skippedNoSnapshot, 1);
      expect(counts.filled, 0);
    });
  });

  group('Finalization state machine (§5.4)', () {
    test('endTournament rated path applies deltas + W/D/L, undo restores', () {
      final master = [_player('1', 1500), _player('2', 1600)];
      final t = Tournament(
        id: '1',
        name: 'T',
        ratingType: RatingType.rapid,
        isRated: true,
        status: TournamentStatus.inProgress,
        players: [_player('1', 1500), _player('2', 1600)],
      );
      t.rounds.add([_game(1, '1', '2', MatchResult.whiteWins)]);
      t.endTournament(master);
      expect(t.status, TournamentStatus.completed);
      expect(master[0].rapidRating, 1526); // 1500 + 26
      expect(master[1].rapidRating, 1574); // 1600 - 26
      expect(master[0].wins, 1);
      expect(master[1].losses, 1);
      expect(t.wdlSnapshot, isNotEmpty);
      expect(t.ratingSnapshot['1'], 1500);

      t.undoLastSubmission(master);
      expect(t.status, TournamentStatus.inProgress);
      expect(master[0].rapidRating, 1500);
      expect(master[1].rapidRating, 1600);
      expect(master[0].wins, 0);
      expect(master[1].losses, 0);
      expect(t.wdlSnapshot, isEmpty);
      expect(t.rounds.single.single.whiteRatingDelta, isNull);
    });

    test('endTournament unrated path applies only W/D/L', () {
      final master = [_player('1', 1500), _player('2', 1600)];
      final t = Tournament(
        id: '1',
        name: 'T',
        ratingType: RatingType.rapid,
        isRated: false,
        status: TournamentStatus.inProgress,
        players: [_player('1', 1500), _player('2', 1600)],
      );
      t.rounds.add([_game(1, '1', '2', MatchResult.whiteWins)]);
      t.endTournament(master);
      expect(master[0].rapidRating, 1500); // no rating change
      expect(master[0].wins, 1);
      expect(t.ratingSnapshot, isEmpty);
    });

    test('reopenLegacy only flips status, no rollback', () {
      final master = [_player('1', 1526)];
      final t = Tournament(
        id: '1',
        name: 'T',
        isRated: true,
        status: TournamentStatus.completed,
        players: [_player('1', 1500)],
      );
      t.rounds.add([_game(1, '1', '2', MatchResult.whiteWins)]);
      t.reopenLegacy();
      expect(t.status, TournamentStatus.inProgress);
      expect(master[0].rapidRating, 1526); // untouched
      expect(t.wdlSnapshot, isEmpty);
    });
  });
}
