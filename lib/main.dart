import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'score.dart';

void main() => runApp(const TennisApp());

class TennisApp extends StatelessWidget {
  const TennisApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '코트 콜',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFD7FA65),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF101B18),
    ),
    home: const MatchPage(),
  );
}

class MatchPage extends StatefulWidget {
  const MatchPage({super.key});
  @override
  State<MatchPage> createState() => _MatchPageState();
}

class _MatchPageState extends State<MatchPage> with WidgetsBindingObserver {
  TennisScore score = TennisScore();
  final history = <TennisScore>[];
  List<String> names = ['홈팀', '원정팀'];
  final bindings = <String, String>{
    'server': 'key:${LogicalKeyboardKey.arrowUp.keyId}',
    'receiver': 'key:${LogicalKeyboardKey.arrowDown.keyId}',
    'leader': 'key:${LogicalKeyboardKey.enter.keyId}',
  };
  final tts = FlutterTts();
  SharedPreferences? prefs;
  bool ready = false,
      paused = false,
      sound = true,
      remoteSettings = false,
      dialogOpen = false;
  bool speechReady = false;
  bool noAd = true;
  String message = '위: 서버 득점 · 아래: 리시버 득점';
  String? error, learning;
  String lastInput = '아직 수신된 키 입력이 없습니다';
  Timer? learnTimeout;
  int speechVersion = 0;
  Future<void> writes = Future.value();
  bool get blocked => paused || remoteSettings || dialogOpen || !ready;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(onKey);
    unawaited(initialize());
  }

  Future<void> initialize() async {
    try {
      prefs = await SharedPreferences.getInstance();
      final raw = prefs!.getString('match.v1');
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final restored = TennisScore.fromJson(
          data['score'] as Map<String, dynamic>,
        );
        final ns = List<String>.from(data['names'] as List);
        final hs = (data['history'] as List)
            .map((s) => TennisScore.fromJson(s as Map<String, dynamic>))
            .toList();
        final bs = Map<String, String>.from(data['bindings'] as Map);
        final audio = data['sound'] as bool;
        if (ns.length != 2 ||
            ns.any((n) => n.trim().isEmpty) ||
            bs.values.toSet().length != bs.length ||
            bs.keys.any((k) => !ScoreAction.values.any((a) => a.name == k))) {
          throw const FormatException('Invalid settings');
        }
        score = restored;
        names = ns;
        history.addAll(hs);
        bindings
          ..clear()
          ..addAll(bs);
        sound = audio;
        noAd = restored.noAd;
        message = '이전 경기 복원 · ${score.announcement(names)}';
      }
    } catch (_) {
      error = '저장된 경기를 불러오지 못했습니다. 화면의 점수를 확인해 주세요.';
    }
    if (!mounted) return;
    setState(() => ready = true);
    await keepAwake();
    try {
      if (await tts.isLanguageAvailable('ko-KR') != true) {
        throw StateError('Korean TTS voice is unavailable');
      }
      await tts.setLanguage('ko-KR');
      await tts.setSpeechRate(0.45);
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        await tts.setSharedInstance(true);
        await tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [IosTextToSpeechAudioCategoryOptions.duckOthers],
          IosTextToSpeechAudioMode.defaultMode,
        );
      }
      tts.setErrorHandler(
        (_) => showError('음성 재생에 실패했습니다. 음량과 음성 설정을 확인해 주세요.'),
      );
      if (mounted) setState(() => speechReady = true);
    } catch (_) {
      showError('한국어 음성을 준비하지 못했습니다. 기기의 TTS 한국어 음성을 설치하고 앱을 다시 여세요.');
    }
  }

  Future<void> keepAwake() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {
      showError('화면 자동 잠금 방지에 실패했습니다. 경기 중 화면을 켜두세요.');
    }
  }

  void showError(String value) {
    if (mounted) setState(() => error = value);
  }

  void save() {
    final raw = jsonEncode({
      'score': score.toJson(),
      'names': names,
      'history': history.map((s) => s.toJson()).toList(),
      'bindings': bindings,
      'sound': sound,
      'noAd': noAd,
    });
    writes = writes
        .then((_) async {
          if (prefs == null || !await prefs!.setString('match.v1', raw)) {
            throw StateError('Save failed');
          }
        })
        .catchError((Object _) {
          showError('경기 저장에 실패했습니다. 앱을 닫기 전에 점수를 기록해 주세요.');
        });
  }

  Future<void> speak(String text) async {
    final version = ++speechVersion;
    if (!sound || !speechReady) return;
    try {
      await tts.stop();
      if (!mounted || version != speechVersion || !sound) return;
      if (await tts.speak(text) != 1) {
        showError('음성을 재생하지 못했습니다. 다시 듣기를 눌러 주세요.');
      }
    } catch (_) {
      showError('음성 재생에 실패했습니다. 점수는 정상 반영했습니다.');
    }
  }

  void apply(ScoreAction action) {
    if (blocked) return;
    if (action == ScoreAction.leader && score.shortcutWinner == null) {
      setState(() => message = score.announcement(names));
      unawaited(speak(message));
      return;
    }
    history.add(score.copy());
    // ponytail: last 100 points only; add full match logs if needed.
    if (history.length > 100) history.removeAt(0);
    setState(() {
      final winner = score.point(action);
      message = winner == null
          ? score.announcement(names)
          : '${names[winner]} 게임! 게임 스코어 ${names[0]} ${score.games[0]}, ${names[1]} ${score.games[1]}. 다음 서버 ${names[score.server]}. 러브 올';
    });
    save();
    unawaited(speak(message));
  }

  void undo() {
    if (history.isEmpty || !ready || remoteSettings || dialogOpen) return;
    setState(() {
      score = history.removeLast();
      message = '되돌렸습니다. ${score.announcement(names)}';
    });
    save();
    unawaited(speak(message));
  }

  bool onKey(KeyEvent event) {
    if (event.synthesized || !ready || dialogOpen) return false;
    final token = 'key:${event.logicalKey.keyId}';
    final known = bindings.containsValue(token);
    if (event is! KeyDownEvent) return known && !remoteSettings;
    if (remoteSettings && learning == null) return false;
    setState(
      () => lastInput =
          '${event.logicalKey.debugName ?? event.logicalKey.keyLabel} (${event.logicalKey.keyId})',
    );
    if (learning != null) {
      if (bindings.entries.any((e) => e.key != learning && e.value == token)) {
        showError('다른 버튼과 같은 신호입니다. 리모컨 모드를 바꾸고 다시 등록하세요.');
        return true;
      }
      setState(() {
        bindings[learning!] = token;
        learning = null;
      });
      learnTimeout?.cancel();
      save();
      return true;
    }
    if (remoteSettings || !known) return false;
    apply(ScoreAction.values.firstWhere((a) => bindings[a.name] == token));
    return true;
  }

  void learn(ScoreAction action) {
    learnTimeout?.cancel();
    setState(() {
      learning = action.name;
      error = null;
    });
    learnTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted) {
        setState(() {
          learning = null;
          error =
              '키 입력이 수신되지 않았습니다. 리모컨 모드를 확인하세요. 화면 스와이프·볼륨 전용 신호는 현재 지원하지 않습니다.';
        });
      }
    });
  }

  Future<void> newMatch() async {
    learnTimeout?.cancel();
    setState(() {
      dialogOpen = true;
      learning = null;
    });
    final a = TextEditingController(text: names[0]),
        b = TextEditingController(text: names[1]);
    var first = 0;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('새 경기'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('현재 점수와 되돌리기 기록을 초기화합니다.'),
                TextField(
                  controller: a,
                  maxLength: 16,
                  decoration: const InputDecoration(labelText: '선수 A 이름'),
                ),
                TextField(
                  controller: b,
                  maxLength: 16,
                  decoration: const InputDecoration(labelText: '선수 B 이름'),
                ),
                DropdownButton<int>(
                  value: first,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('선수 A가 첫 서브')),
                    DropdownMenuItem(value: 1, child: Text('선수 B가 첫 서브')),
                  ],
                  onChanged: (v) => update(() => first = v!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('경기 시작'),
            ),
          ],
        ),
      ),
    );
    if (mounted) {
      setState(() {
        dialogOpen = false;
        if (accepted == true) {
          names = [
            a.text.trim().isEmpty ? '선수 A' : a.text.trim(),
            b.text.trim().isEmpty ? '선수 B' : b.text.trim(),
          ];
          score = TennisScore(server: first, noAd: noAd);
          history.clear();
          paused = false;
          message = '${names[first]} 서브. 러브 올';
        }
      });
      if (accepted == true) {
        save();
        unawaited(speak(message));
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    a.dispose();
    b.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(keepAwake());
    } else {
      speechVersion++;
      unawaited(tts.stop());
    }
  }

  @override
  void dispose() {
    learnTimeout?.cancel();
    HardwareKeyboard.instance.removeHandler(onKey);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(tts.stop());
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  Widget player(int index) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        child: Column(
          children: [
            Text(
              index == score.server ? '● SERVER' : 'RECEIVER',
              style: TextStyle(
                color: index == score.server
                    ? const Color(0xFFD7FA65)
                    : Colors.white54,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              names[index],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20),
            ),
            Text(
              score.label(index),
              style: const TextStyle(fontSize: 68, fontWeight: FontWeight.w800),
            ),
            Text(
              '게임 ${score.games[index]}',
              style: const TextStyle(fontSize: 18),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('코트 콜'),
      actions: [
        IconButton(
          tooltip: sound ? '음성 끄기' : '음성 켜기',
          icon: Icon(sound ? Icons.volume_up : Icons.volume_off),
          onPressed: !ready
              ? null
              : () {
                  setState(() => sound = !sound);
                  save();
                  speechVersion++;
                  unawaited(tts.stop());
                },
        ),
        IconButton(
          tooltip: '새 경기',
          onPressed: ready ? newMatch : null,
          icon: const Icon(Icons.restart_alt),
        ),
      ],
    ),
    body: !ready
        ? const Center(child: CircularProgressIndicator())
        : SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'GAME ${score.games[0] + score.games[1] + 1}  /  ${paused ? '일시 정지' : '경기 중'}',
                  style: const TextStyle(
                    color: Color(0xFFD7FA65),
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [player(score.server), player(score.receiver)],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('노애드(어드밴티지 없음)'),
                  subtitle: const Text('40:40에서 다음 포인트를 딴 선수가 바로 게임 승리'),
                  value: noAd,
                  onChanged: blocked
                      ? null
                      : (value) {
                          setState(() {
                            noAd = value;
                            score.noAd = value;
                            message = score.announcement(names);
                          });
                          save();
                        },
                ),
                if (score.deuce || (!noAd && score.advantage))
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      score.deuce
                          ? (noAd
                                ? 'NO-AD DEUCE · 다음 포인트 게임'
                                : 'DEUCE · 두 점 차로 승리')
                          : 'ADVANTAGE',
                      textAlign: TextAlign.center,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(message, style: const TextStyle(fontSize: 17)),
                ),
                FilledButton.icon(
                  key: const Key('serverPoint'),
                  onPressed: blocked ? null : () => apply(ScoreAction.server),
                  icon: const Icon(Icons.arrow_upward),
                  label: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('${names[score.server]} · 서버 +1'),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('receiverPoint'),
                  onPressed: blocked ? null : () => apply(ScoreAction.receiver),
                  icon: const Icon(Icons.arrow_downward),
                  label: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('${names[score.receiver]} · 리시버 +1'),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: history.isEmpty || remoteSettings
                          ? null
                          : undo,
                      icon: const Icon(Icons.undo),
                      label: const Text('1점 되돌리기'),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => paused = !paused),
                      icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                      label: Text(paused ? '재개' : '일시 정지'),
                    ),
                    TextButton.icon(
                      onPressed: speechReady
                          ? () => speak(score.announcement(names))
                          : null,
                      icon: const Icon(Icons.volume_up),
                      label: const Text('다시 듣기'),
                    ),
                  ],
                ),
                if (error != null)
                  Card(
                    color: const Color(0xFF583D22),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(error!),
                    ),
                  ),
                const Divider(height: 32),
                ExpansionTile(
                  title: const Text('리모컨 버튼 등록'),
                  subtitle: Text(
                    '${bindings.length}/3 설정 · 기본 키: ↑ / ↓ / Enter',
                  ),
                  onExpansionChanged: (open) {
                    setState(() {
                      remoteSettings = open;
                      learning = null;
                    });
                    learnTimeout?.cancel();
                  },
                  children: [
                    const Text(
                      '① 휴대폰 설정 → Bluetooth에서 SOBTR1 연결\n② 등록을 누른 뒤 리모컨 버튼을 한 번 누르세요.\n등록 중에는 득점하지 않습니다.\n에뮬레이터: PC 키보드 ↑ / ↓ / Enter로 테스트',
                    ),
                    for (final action in ScoreAction.values)
                      ListTile(
                        title: Text(switch (action) {
                          ScoreAction.server => '위 버튼 · 서버 득점',
                          ScoreAction.receiver => '아래 버튼 · 리시버 득점',
                          ScoreAction.leader => '가운데 버튼 · 앞선 선수 득점',
                        }),
                        subtitle: Text(
                          learning == action.name
                              ? '버튼을 눌러 주세요 (15초)'
                              : bindings[action.name] ?? '등록 전',
                        ),
                        trailing: TextButton(
                          onPressed: () => learn(action),
                          child: const Text('등록'),
                        ),
                      ),
                    Text(
                      lastInput,
                      style: const TextStyle(color: Colors.white60),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          bindings.clear();
                          learning = null;
                        });
                        learnTimeout?.cancel();
                        save();
                      },
                      child: const Text('버튼 등록 초기화'),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        '키보드형 입력을 지원합니다. 화면 스와이프나 볼륨 신호만 보내면 등록되지 않을 수 있습니다. 실물 검증 전에는 화면 버튼을 사용할 수 있습니다.',
                      ),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    '경기 중 앱 화면을 켜두세요. 화면 자동 잠금을 방지합니다.\nMVP: 일반 게임 누적 · 세트/타이브레이크 제외',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
  );
}
