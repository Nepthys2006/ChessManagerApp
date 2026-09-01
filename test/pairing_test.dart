import 'package:flutter_test/flutter_test.dart';

import 'package:chess_manager/models/bracket_generator.dart';
import 'package:chess_manager/models/chess_match.dart';
import 'package:chess_manager/models/player.dart';
import 'package:chess_manager/models/tournament.dart';

Player rated(String id, int rating) =>
    Player(id: id, firstName: 'F$id', lastName: 'L$id', rapidRating: rating);

Tournament _swiss(List<Player> players) => Tournament(
  id: '1',
  name: 'T',
  format: TournamentFormat.swiss,
  ratingType: RatingType.rapid,
  players: players,
);

ChessMatch match(
  String id,
  int round,
  String? white,
  String? black,
  MatchResult result,
) => ChessMatch(
  id: id,
  round: round,
  board: 0,
  whitePlayerId: white,
  blackPlayerId: black,
  result: result,
);

void main() {
  group('Round Robin — Berger rotation (§5.2)', () {
    test('4 players: 3 rounds, every pair meets exactly once', () {
      final roster = [
        rated('100001', 1800),
        rated('100002', 1700),
        rated('100003', 1600),
        rated('100004', 1500),
      ];
      final rounds = BracketGenerator.generateRoundRobinRounds(roster);
      expect(rounds.length, 3);
      final played = <String>{};
      for (var r = 0; r < rounds.length; r++) {
        expect(rounds[r].length, 2);
        for (var i = 0; i < rounds[r].length; i++) {
          final m = rounds[r][i];
          expect(m.id, 'rr_${r}_$i');
          expect(m.round, r + 1);
          expect(m.board, i + 1); // board i+1, 1-based per §5.2
          final pair = [m.whitePlayerId, m.blackPlayerId]..sort();
          played.add(pair.join('-'));
        }
      }
      // C(4,2) = 6 distinct pairs.
      expect(played.length, 6);
    });

    test('5 players (odd): dummy bye player, one bye match per round', () {
      final roster = [for (var i = 1; i <= 5; i++) rated('10000$i', 1500 + i)];
      final rounds = BracketGenerator.generateRoundRobinRounds(roster);
      // 5 real + dummy = 6 -> 5 rounds.
      expect(rounds.length, 5);
      final byeCounts = <String, int>{};
      for (final round in rounds) {
        final byeMatches = round
            .where((m) => m.result == MatchResult.bye)
            .toList();
        expect(byeMatches.length, 1);
        expect(byeMatches.single.blackPlayerId, isNull);
        expect(byeMatches.single.whitePlayerId, isNot('bye'));
        byeCounts[byeMatches.single.whitePlayerId!] =
            (byeCounts[byeMatches.single.whitePlayerId!] ?? 0) + 1;
      }
      // Every real player gets exactly one bye.
      for (final player in roster) {
        expect(byeCounts[player.id], 1);
      }
    });
  });

  group('Knockout — seeded bracket (§5.2)', () {
    test('bracketSeedOrder size 8 -> [1,8,4,5,2,7,3,6]', () {
      expect(BracketGenerator.bracketSeedOrder(8), [1, 8, 4, 5, 2, 7, 3, 6]);
    });

    test('non-power-of-2 field: byes interleaved by bracket position', () {
      final roster = [
        rated('100001', 1800),
        rated('100002', 1700),
        rated('100003', 1600),
        rated('100004', 1500),
        rated('100005', 1400),
      ];
      final round1 = BracketGenerator.generateKnockoutRound1(
        roster,
        RatingType.rapid,
      );
      // 5 players -> size 8; seeds 6-8 are byes. With seed order
      // [1,8,4,5,2,7,3,6]: (s1 bye), (s4 vs s5), (s2 bye), (s3 bye).
      final byes = round1.where((m) => m.isBye).toList();
      expect(byes.length, 3);
      expect(byes.map((m) => m.whitePlayerId).toSet(), {
        '100001',
        '100002',
        '100003',
      });
      final real = round1.where((m) => !m.isBye).toList();
      expect(real.single.whitePlayerId, '100004');
      expect(real.single.blackPlayerId, '100005');
    });

    test('round 2 generated one at a time from winners', () {
      final roster = [
        rated('100001', 1800),
        rated('100002', 1700),
        rated('100003', 1600),
        rated('100004', 1500),
      ];
      final rounds = <List<ChessMatch>>[];
      final round1 = BracketGenerator.generateKnockoutRound1(
        roster,
        RatingType.rapid,
      );
      expect(round1.length, 2);
      // Winners: 100001 (white win in m0) and 100003 (black win in m1).
      round1[0].result = MatchResult.whiteWins;
      round1[1].result = MatchResult.blackWins;
      rounds.add(round1);
      final round2 = BracketGenerator.generateKnockoutNextRound(rounds);
      expect(round2.length, 1);
      expect(round2.single.round, 2);
      expect(
        round2.single.whitePlayerId != null &&
            round2.single.blackPlayerId != null,
        isTrue,
      );
      expect(
        {round2.single.whitePlayerId, round2.single.blackPlayerId},
        {'100001', '100003'},
      );
    });
  });

  group('Swiss round 1 (§5.2)', () {
    test('rating desc seeding: 1v4, 2v5, 3v6', () {
      final roster = [
        rated('100001', 2000),
        rated('100002', 1800),
        rated('100003', 1600),
        rated('100004', 1400),
        rated('100005', 1300),
        rated('100006', 1200),
      ];
      final round1 = BracketGenerator.generateSwissRound1(
        roster,
        RatingType.rapid,
      );
      expect(round1.length, 3);
      expect(round1[0].whitePlayerId, '100001');
      expect(round1[0].blackPlayerId, '100004');
      expect(round1[1].whitePlayerId, '100002');
      expect(round1[1].blackPlayerId, '100005');
      expect(round1[2].whitePlayerId, '100003');
      expect(round1[2].blackPlayerId, '100006');
    });

    test('odd count: last (lowest-rated) gets the bye, appended last', () {
      final roster = [
        rated('100001', 2000),
        rated('100002', 1800),
        rated('100003', 1600),
        rated('100004', 1400),
        rated('100005', 1300),
      ];
      final round1 = BracketGenerator.generateSwissRound1(
        roster,
        RatingType.rapid,
      );
      expect(round1.length, 3);
      expect(round1.last.result, MatchResult.bye);
      expect(round1.last.whitePlayerId, '100005');
    });
  });

  group('Swiss later rounds (§5.2)', () {
    test('rematch avoidance across generated rounds', () {
      final t = _swiss([
        for (var i = 1; i <= 6; i++) rated('10000$i', 2000 - i * 100),
      ]);
      final seen = <String>{};
      for (var round = 0; round < 3; round++) {
        final matches = t.generateNextRound();
        for (final m in matches) {
          if (m.isBye) continue;
          final key = ([m.whitePlayerId, m.blackPlayerId]..sort()).join('-');
          final added = seen.add(key);
          expect(added, isTrue, reason: 'rematch generated: $key');
        }
        for (final m in matches) {
          if (!m.isBye) m.result = MatchResult.whiteWins;
        }
      }
    });

    test('bye rotation fairness: lowest-ranked without a prior bye', () {
      final t = _swiss([
        for (var i = 1; i <= 5; i++) rated('10000$i', 2000 - i * 100),
      ]);
      final byeIds = <String>[];
      for (var round = 0; round < 3; round++) {
        final matches = t.generateNextRound();
        final bye = matches.where((m) => m.isBye).toList();
        expect(bye.length, 1);
        byeIds.add(bye.single.whitePlayerId!);
        for (final m in matches) {
          if (!m.isBye) m.result = MatchResult.draw;
        }
      }
      expect(
        byeIds.toSet().length,
        byeIds.length,
        reason: 'no player should get a second bye early',
      );
      expect(byeIds.first, '100005');
      expect(byeIds, contains('100004'));
    });

    test('rescue: nobody is dropped from a round even when all pairs met', () {
      final t = _swiss([
        rated('100001', 2000),
        rated('100002', 1800),
        rated('100003', 1600),
        rated('100004', 1400),
      ]);
      void recordResults() {
        for (final round in t.rounds) {
          for (final m in round) {
            if (!m.isBye) m.result = MatchResult.whiteWins;
          }
        }
      }

      t.generateNextRound();
      recordResults();
      while (!t.allPairsPlayed) {
        t.generateNextRound();
        recordResults();
      }
      final matches = t.generateNextRound();
      final appearing = <String>{};
      for (final m in matches) {
        if (m.whitePlayerId != null) appearing.add(m.whitePlayerId!);
        if (m.blackPlayerId != null) appearing.add(m.blackPlayerId!);
      }
      expect(appearing.length, t.players.length);
      expect(appearing, containsAll(t.players.map((p) => p.id)));
    });

    test('allPairsPlayed exhaustion', () {
      final players = [
        rated('100001', 1500),
        rated('100002', 1600),
        rated('100003', 1700),
      ];
      final rounds = [
        [
          match('sw_1_0', 1, '100001', '100002', MatchResult.whiteWins),
          match('sw_1_1', 1, '100003', null, MatchResult.bye),
        ],
        [
          match('sw_2_0', 2, '100001', '100003', MatchResult.whiteWins),
          match('sw_2_1', 2, '100002', null, MatchResult.bye),
        ],
        [
          match('sw_3_0', 3, '100002', '100003', MatchResult.whiteWins),
          match('sw_3_1', 3, '100001', null, MatchResult.bye),
        ],
      ];
      expect(BracketGenerator.allPairsPlayed(players, rounds), isTrue);
    });
  });

  group('Color assignment (§5.2 _assignColors)', () {
    test('streak reads backwards, skips byes, stops at color change', () {
      final history = [
        [
          ChessMatch(
            id: 'a',
            round: 1,
            board: 0,
            whitePlayerId: '100001',
            blackPlayerId: '100002',
          ),
        ],
        [
          ChessMatch(
            id: 'b',
            round: 2,
            board: 0,
            whitePlayerId: '100001',
            result: MatchResult.bye,
          ),
        ],
        [
          ChessMatch(
            id: 'c',
            round: 2,
            board: 0,
            whitePlayerId: '100001',
            blackPlayerId: '100002',
          ),
        ],
      ];
      // Backwards read for 100001: white (latest), bye skipped, white -> +2.
      expect(BracketGenerator.whiteStreak('100001', history), 2);
      // For 100002: black (latest), black (round 1) -> -2.
      expect(BracketGenerator.whiteStreak('100002', history), -2);
    });

    test('2+ white streak forces black', () {
      final history = [
        for (var r = 0; r < 2; r++)
          [
            ChessMatch(
              id: 'h$r',
              round: r + 1,
              board: 0,
              whitePlayerId: '100001',
              blackPlayerId: '10000${r + 2}',
            ),
          ],
      ];
      final (w, b) = BracketGenerator.assignColors('100001', '100099', history);
      expect(w, '100099'); // the streaky player must be black
      expect(b, '100001');
    });

    test('both locked compatible -> both honored', () {
      final history = [
        [
          ChessMatch(
            id: 'a',
            round: 1,
            board: 0,
            whitePlayerId: '100001',
            blackPlayerId: '100003',
          ),
          ChessMatch(
            id: 'b',
            round: 1,
            board: 1,
            whitePlayerId: '100005',
            blackPlayerId: '100002',
          ),
        ],
        [
          ChessMatch(
            id: 'c',
            round: 2,
            board: 0,
            whitePlayerId: '100001',
            blackPlayerId: '100004',
          ),
          ChessMatch(
            id: 'd',
            round: 2,
            board: 1,
            whitePlayerId: '100006',
            blackPlayerId: '100002',
          ),
        ],
      ];
      // 100001: two whites -> must black; 100002: two blacks -> must white.
      final (w, b) = BracketGenerator.assignColors('100001', '100002', history);
      expect(w, '100002');
      expect(b, '100001');
    });

    test('repair: a forced-clash pair is swapped with a compatible pair', () {
      // 100002 & 100004 both have 2-black streaks (both forced WHITE -> clash
      // if paired together). 100001 has a 2-white streak (forced black);
      // 100003 has mixed colors (no streak).
      final history = [
        [
          ChessMatch(
            id: 'a',
            round: 1,
            board: 0,
            whitePlayerId: '100001',
            blackPlayerId: '100002',
          ),
          ChessMatch(
            id: 'b',
            round: 1,
            board: 1,
            whitePlayerId: '100003',
            blackPlayerId: '100004',
          ),
        ],
        [
          ChessMatch(
            id: 'c',
            round: 2,
            board: 0,
            whitePlayerId: '100001',
            blackPlayerId: '100004',
          ),
          ChessMatch(
            id: 'd',
            round: 2,
            board: 1,
            whitePlayerId: '100003',
            blackPlayerId: '100002',
          ),
        ],
      ];
      // Streaks: 100002 & 100004 -> 2 blacks (both forced WHITE -> clash when
      // paired); 100001 -> 2 whites (forced black); 100003 -> 2 whites (also
      // forced black).
      expect(
        BracketGenerator.wouldForceColorClash('100002', '100004', history),
        isTrue,
      );
      expect(
        BracketGenerator.wouldForceColorClash('100002', '100003', history),
        isFalse,
      );
      expect(
        BracketGenerator.wouldForceColorClash('100001', '100004', history),
        isFalse,
      );
      expect(
        BracketGenerator.wouldForceColorClash('100001', '100003', history),
        isTrue,
      );
    });
  });
}
