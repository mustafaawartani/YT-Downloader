import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/settings.dart';
import 'groq.dart';
import 'voice_engine.dart';
import 'voice_sources.dart';

class VoiceController extends ChangeNotifier {
  VoiceController(this.engine) {
    _checkModel();
  }

  final VoiceEngine engine;

  List<VoiceItem> _all = [];
  List<String> senders = [];
  String? senderFilter;
  String sourceLabel = '';
  bool loading = false;
  String? message;

  // one-time setup
  bool modelReady = false;
  bool settingUp = false;
  double? setupProgress;
  String setupText = '';

  String? playingId;

  final _queue = Queue<String>();
  bool _working = false;

  Settings get _s => Settings.instance;
  String get language => _s.prefs.getString('voice.lang') ?? 'es';
  set language(String v) {
    _s.prefs.setString('voice.lang', v);
    notifyListeners();
  }

  TranslateTarget get target => _s.translateTarget;
  set target(TranslateTarget t) {
    _s.translateTarget = t;
    for (final i in _all.where((i) => i.state == ItemState.done && _needsTranslation(i))) {
      _enqueue(i);
    }
    notifyListeners();
  }

  bool get wantEnglish => (target == TranslateTarget.en || target == TranslateTarget.both) && language != 'en';
  bool get wantArabic => (target == TranslateTarget.ar || target == TranslateTarget.both) && language != 'ar';

  List<VoiceItem> get items => senderFilter == null ? _all : _all.where((i) => i.sender == senderFilter).toList();

  bool get busy => _all.any((i) => i.state.active);

  void _say(String msg) {
    message = msg;
    notifyListeners();
  }

  // ------------------------------------------------------------------ setup

  GroqClient? get _groq {
    final key = _s.groqKey;
    return (_s.useGroq && key != null) ? GroqClient(key) : null;
  }

  bool get usingGroq => _groq != null;

  /// Ready to transcribe: either Groq is set up or the offline model is downloaded.
  bool get ready => usingGroq || modelReady;

  Future<bool> checkGroqKey() async {
    final key = _s.groqKey;
    if (key == null) return false;
    final ok = await GroqClient(key).checkKey();
    notifyListeners();
    return ok;
  }

  Future<void> _checkModel() async {
    _s.addListener(notifyListeners);
    modelReady = await SpeechModel.isReady();
    setupText =
        'Best accuracy: add your free Groq API key in Settings (cloud, Whisper large-v3).\n'
        'Or download the offline model (82 MB${engine.canBrowseFolder ? ' + ~60 MB translation packs' : ''}): '
        'works without internet, but is less accurate.';
    notifyListeners();
  }

  Future<void> downloadModels() async {
    if (settingUp) return;
    settingUp = true;
    setupProgress = 0;
    setupText = 'Downloading speech model…';
    notifyListeners();
    try {
      if (!await SpeechModel.isReady()) {
        await SpeechModel.download((f) {
          setupProgress = f;
          setupText = 'Downloading speech model… ${(f * 100).toStringAsFixed(0)}%';
          notifyListeners();
        });
      }
      setupProgress = null;
      setupText = 'Preparing translation…';
      notifyListeners();
      await engine.prepareTranslation(language);
      modelReady = true;
      _say('Ready! Speech-to-text now works offline.');
    } catch (e) {
      setupText = 'Download failed (${_msg(e)}). Check your internet connection and try again.';
    } finally {
      settingUp = false;
      setupProgress = null;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ loading

  Future<void> importShared(List<String> paths) async {
    loading = true;
    notifyListeners();
    try {
      final work = Directory(
        p.join((await getTemporaryDirectory()).path, 'imported', DateTime.now().millisecondsSinceEpoch.toString()),
      );
      final result = await importFiles(paths, work);
      if (result.items.isEmpty) {
        loading = false;
        _say('No voice notes found. When exporting a chat, choose "Include media".');
        return;
      }
      _setItems(result.items, result.label, result.senders);
      if (result.items.length == 1) transcribe(result.items.first);
    } catch (e) {
      loading = false;
      _say("Couldn't open that: ${_msg(e)}");
    }
  }

  Future<void> openFolder({bool forcePicker = false}) async {
    var uri = _s.voiceFolder;
    if (forcePicker || uri == null || !await engine.hasFolderAccess(uri)) {
      _say('Open the "WhatsApp Voice Notes" folder and tap "Use this folder"');
      uri = await engine.pickFolder();
      if (uri == null) return;
      _s.voiceFolder = uri;
    }
    loading = true;
    notifyListeners();
    try {
      final entries = await engine.listFolder(uri);
      String two(int n) => n.toString().padLeft(2, '0');
      final items = [
        for (final e in entries)
          () {
            final d = DateTime.fromMillisecondsSinceEpoch(e.modified);
            return VoiceItem(
              id: e.uri,
              source: e.uri,
              fileName: e.name,
              sizeBytes: e.size,
              dateLabel: '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}',
              sortKey: e.modified,
            );
          }(),
      ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));
      if (items.isEmpty) message = 'No voice notes there. Pick the "WhatsApp Voice Notes" folder.';
      _setItems(items, 'All voice notes (${items.length})', const []);
    } catch (e) {
      loading = false;
      _say("Couldn't read that folder: ${_msg(e)}");
    }
  }

  void _setItems(List<VoiceItem> items, String label, List<String> s) {
    for (final i in items) {
      _applyCache(i);
    }
    _all = items;
    senders = s;
    senderFilter = null;
    sourceLabel = label;
    loading = false;
    notifyListeners();
  }

  void setSenderFilter(String? s) {
    senderFilter = s;
    notifyListeners();
  }

  // ------------------------------------------------------------------ queue

  void transcribe(VoiceItem item) {
    if (item.state.active) return;
    if (item.original == null && !ready) {
      _say('Add a Groq key in Settings, or tap "Download offline model" (one time only).');
      return;
    }
    _enqueue(item);
  }

  void transcribeAll() {
    for (final i in items.where((i) => i.state == ItemState.idle || i.state == ItemState.error)) {
      transcribe(i);
    }
  }

  void _enqueue(VoiceItem item) {
    item
      ..state = ItemState.queued
      ..error = null
      ..progress = 0;
    _queue.add(item.id);
    notifyListeners();
    _drain();
  }

  Future<void> _drain() async {
    if (_working) return;
    _working = true;
    while (_queue.isNotEmpty) {
      final id = _queue.removeFirst();
      final item = _all.where((i) => i.id == id).firstOrNull;
      if (item != null) await _process(item);
    }
    _working = false;
    notifyListeners();
  }

  bool _needsTranslation(VoiceItem i) =>
      (i.original?.isNotEmpty ?? false) && ((wantEnglish && i.english == null) || (wantArabic && i.arabic == null));

  Future<void> _process(VoiceItem item) async {
    try {
      if (item.original == null) {
        item.state = ItemState.transcribing;
        notifyListeners();
        final groq = _groq;
        String text;
        if (groq != null) {
          item.progress = 0;
          text = await groq.transcribe(await engine.localFile(item.source), language);
        } else {
          var last = -1;
          text = await engine.transcribe(item.source, language, (pct) {
            if (pct == last) return;
            last = pct;
            item.progress = pct;
            notifyListeners();
          });
        }
        if (text.isEmpty) throw Exception('No speech found in this voice note');
        item.original = text;
      }
      String? warning;
      if (_needsTranslation(item)) {
        item.state = ItemState.translating;
        notifyListeners();
        if (wantEnglish && item.english == null) {
          try {
            item.english = await _translate(item.original!, 'en');
          } catch (e) {
            warning = 'English translation failed: ${_msg(e)}';
          }
        }
        if (wantArabic && item.arabic == null) {
          try {
            item.arabic = await _translate(item.original!, 'ar');
          } catch (e) {
            warning = 'Arabic translation failed: ${_msg(e)}';
          }
        }
      }
      item
        ..state = ItemState.done
        ..error = warning;
      _saveCache(item);
    } catch (e) {
      item
        ..state = ItemState.error
        ..error = _msg(e);
    }
    notifyListeners();
  }

  /// Groq LLM when available (better quality), otherwise the platform translator.
  Future<String> _translate(String text, String to) async {
    final groq = _groq;
    if (groq != null) {
      try {
        return await groq.translate(text, voiceLanguages[language] ?? language, voiceLanguages[to] ?? to);
      } catch (_) {
        // fall through to the on-device / free translator
      }
    }
    return engine.translate(text, language, to);
  }

  // ------------------------------------------------------------------ playback

  Future<void> togglePlay(VoiceItem item) async {
    if (playingId == item.id) {
      await engine.stop();
      playingId = null;
    } else {
      try {
        await engine.play(item.source);
        playingId = Platform.isAndroid ? item.id : null;
      } catch (e) {
        _say("Can't play this file: ${_msg(e)}");
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ cache

  String _key(VoiceItem i) => 'voice.cache.$language.${i.cacheKey}';

  void _applyCache(VoiceItem i) {
    final raw = _s.prefs.getString(_key(i));
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      i
        ..original = m['o'] as String?
        ..english = m['en'] as String?
        ..arabic = m['ar'] as String?
        ..state = m['o'] != null ? ItemState.done : ItemState.idle;
    } catch (_) {}
  }

  void _saveCache(VoiceItem i) {
    _s.prefs.setString(_key(i), jsonEncode({'o': i.original, 'en': i.english, 'ar': i.arabic}));
  }

  String copyText(VoiceItem i) {
    final lang = voiceLanguages[language] ?? language;
    return [
      if (i.original != null) '$lang:\n${i.original}',
      if (wantEnglish && i.english != null) 'English:\n${i.english}',
      if (wantArabic && i.arabic != null) 'Arabic:\n${i.arabic}',
    ].join('\n\n');
  }

  static String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');
}
