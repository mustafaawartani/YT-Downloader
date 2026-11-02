import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tools/downloader/ytdlp.dart';

enum TranslateTarget { en, ar, both }

/// App-wide settings, persisted with SharedPreferences.
class Settings extends ChangeNotifier {
  Settings._();
  static final instance = Settings._();

  late SharedPreferences _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
  }

  SharedPreferences get prefs => _prefs;

  String get videoQuality => _prefs.getString('dl.quality') ?? '1080';
  set videoQuality(String v) => _set('dl.quality', v);

  String get mp3Bitrate => _prefs.getString('dl.bitrate') ?? '192';
  set mp3Bitrate(String v) => _set('dl.bitrate', v);

  /// What the quick "audio" buttons produce.
  MediaKind get audioKind => MediaKindX.parse(_prefs.getString('dl.audioKind') ?? 'mp3');
  set audioKind(MediaKind v) => _set('dl.audioKind', v.name);

  /// Desktop only: custom download folder.
  String? get downloadDir => _prefs.getString('dl.dir');
  set downloadDir(String? v) => _set('dl.dir', v);

  TranslateTarget get translateTarget => TranslateTarget.values.firstWhere(
    (t) => t.name == _prefs.getString('voice.target'),
    orElse: () => TranslateTarget.both,
  );
  set translateTarget(TranslateTarget v) => _set('voice.target', v.name);

  /// Android: persisted SAF uri of the WhatsApp Voice Notes folder.
  String? get voiceFolder => _prefs.getString('voice.folder');
  set voiceFolder(String? v) => _set('voice.folder', v);

  /// Groq API key for accurate cloud speech-to-text (stored only on this device).
  String? get groqKey => _prefs.getString('voice.groqKey');
  set groqKey(String? v) => _set('voice.groqKey', v);

  /// Use Groq when a key is present (default on).
  bool get useGroq => groqKey != null && (_prefs.getBool('voice.useGroq') ?? true);
  set useGroq(bool v) {
    _prefs.setBool('voice.useGroq', v);
    notifyListeners();
  }

  /// Last time yt-dlp was auto-updated (ms since epoch).
  int get lastEngineUpdate => _prefs.getInt('dl.lastUpdate') ?? 0;
  set lastEngineUpdate(int v) {
    _prefs.setInt('dl.lastUpdate', v);
  }

  void _set(String key, String? value) {
    if (value == null) {
      _prefs.remove(key);
    } else {
      _prefs.setString(key, value);
    }
    notifyListeners();
  }
}
