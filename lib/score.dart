enum ScoreAction { server, receiver, leader }

class TennisScore {
  TennisScore({this.server = 0, this.noAd = true, List<int>? points, List<int>? games})
    : points = List.of(points ?? [0, 0]),
      games = List.of(games ?? [0, 0]);
  int server;
  bool noAd;
  final List<int> points;
  final List<int> games;
  int get receiver => 1 - server;
  bool get deuce => points[0] >= 3 && points[0] == points[1];
  bool get advantage => !noAd && points[0] >= 3 && points[1] >= 3 && !deuce;
  int? get shortcutWinner {
    if (points[0] == points[1]) return null;
    final leader = points[0] > points[1] ? 0 : 1;
    return points[leader] >= 3 && points[1 - leader] >= 2 ? leader : null;
  }

  TennisScore copy() =>
      TennisScore(server: server, noAd: noAd, points: points, games: games);
  String label(int player) {
    if (deuce) return '40';
    if (advantage) return points[player] > points[1 - player] ? 'AD' : '40';
    return ['0', '15', '30', '40'][points[player]];
  }

  String announcement(List<String> names) {
    if (deuce) return noAd ? '노애드 듀스' : '듀스';
    if (advantage) return '${names[points[0] > points[1] ? 0 : 1]} 어드밴티지';
    const words = ['러브', '피프틴', '써티', '포티'];
    return '${names[server]} 서브. ${words[points[server]]}, ${words[points[receiver]]}';
  }

  // Returns the game winner, if this point completed a game.
  int? point(ScoreAction action) {
    final player = switch (action) {
      ScoreAction.server => server,
      ScoreAction.receiver => receiver,
      ScoreAction.leader => shortcutWinner,
    };
    if (player == null) return null;
    final wasDeuce = deuce;
    points[player]++;
    if ((noAd && wasDeuce) ||
        (!noAd && points[player] >= 4 && points[player] - points[1 - player] >= 2) ||
        (noAd && points[player] >= 4 && points[player] - points[1 - player] >= 2)) {
      games[player]++;
      points.fillRange(0, 2, 0);
      server = receiver;
      return player;
    }
    if (!noAd && deuce) points.fillRange(0, 2, 3);
    return null;
  }

  Map<String, dynamic> toJson() => {
    'server': server,
    'points': points,
    'games': games,
    'noAd': noAd,
  };
  factory TennisScore.fromJson(Map<String, dynamic> json) {
    final score = TennisScore(
      server: json['server'] as int,
      noAd: json['noAd'] as bool? ?? true,
      points: List<int>.from(json['points'] as List),
      games: List<int>.from(json['games'] as List),
    );
    if (score.server < 0 ||
        score.server > 1 ||
        score.points.length != 2 ||
        score.games.length != 2 ||
        score.points.any((p) => p < 0 || p > 4) ||
        score.games.any((g) => g < 0) ||
        (score.points.contains(4) &&
            score.points.reduce((a, b) => a < b ? a : b) != 3)) {
      throw const FormatException('Invalid match state');
    }
    return score;
  }
}
