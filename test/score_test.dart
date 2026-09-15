import 'package:flutter_test/flutter_test.dart';
import 'package:tennis_remote_mvp/score.dart';

void main() {
  test('15:0, 15:15, 30:15, 40:15, game and server switch', () {
    final s = TennisScore();
    for (final a in [ScoreAction.server, ScoreAction.receiver, ScoreAction.server, ScoreAction.server]) {
      expect(s.point(a), isNull);
    }
    expect([s.label(0), s.label(1)], ['40', '15']);
    expect(s.point(ScoreAction.server), 0);
    expect(s.games, [1, 0]); expect(s.points, [0, 0]); expect(s.server, 1);
    s.point(ScoreAction.server); expect(s.points, [0, 1]);
  });
  test('deuce, advantage, deuce and receiver game', () {
    final s = TennisScore(noAd: false, points: [3, 3]);
    s.point(ScoreAction.leader); expect(s.points, [3, 3]);
    s.point(ScoreAction.server); expect(s.label(0), 'AD');
    s.point(ScoreAction.receiver); expect(s.deuce, isTrue);
    s.point(ScoreAction.receiver); expect(s.point(ScoreAction.leader), 1);
    expect(s.games, [0, 1]); expect(s.server, 1);
  });
  test('no-ad wins the game on the next point after 40:40', () {
    final s = TennisScore(points: [3, 3]);
    expect(s.point(ScoreAction.server), 0);
    expect(s.games, [1, 0]);
    expect(s.points, [0, 0]);
  });
  test('center is a shortcut only when a valid leader exists', () {
    for (final p in [[0, 0], [1, 0], [2, 1], [3, 0], [3, 1], [3, 3]]) {
      final s = TennisScore(noAd: false, points: p); s.point(ScoreAction.leader);
      expect(s.points, p); expect(s.games, [0, 0]);
    }
    for (final p in [[3, 2], [2, 3], [4, 3], [3, 4]]) {
      final s = TennisScore(noAd: false, points: p); final winner = p[0] > p[1] ? 0 : 1;
      expect(s.point(ScoreAction.leader), winner); expect(s.games[winner], 1);
    }
  });
  test('snapshot restores score and rejects impossible state', () {
    final s = TennisScore(noAd: false, points: [3, 2], games: [2, 1], server: 1);
    final restored = TennisScore.fromJson(s.toJson());
    expect(restored.points, [3, 2]); expect(restored.games, [2, 1]); expect(restored.server, 1);
    expect(() => TennisScore.fromJson({'server': 0, 'points': [4, 0], 'games': [0, 0]}), throwsFormatException);
  });
}
