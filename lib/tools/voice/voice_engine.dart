// Speech-to-text + translation, per platform.
// Android: whisper.cpp (JNI) + MediaCodec decoding + ML Kit on-device translation.
// Windows: whisper-cli.exe + ffmpeg.exe (bundled), translation via Google Translate (text only).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/paths.dart';

/// Whisper "base" multilingual model, 8-bit quantized (82 MB).
class SpeechModel {
  static const name = 'ggml-base-q8_0.bin';
  static const url = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$name';
  static const minSize = 50000000;

  static Future<File> file() async => File(p.join((await appDataDir('models')).path, name));

  static Future<bool> isReady() async {
    final f = await file();
    return f.existsSync() && f.lengthSync() > minSize;
  }

  static Future<void> download(void Function(double fraction) onProgress) async {
    final target = await file();
    final tmp = File('${target.path}.part');
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) throw Exception('Server answered ${resp.statusCode}');
      final total = resp.contentLength ?? 0;
      var done = 0;
      final sink = tmp.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        done += chunk.length;
        if (total > 0) onProgress(done / total);
      }
      await sink.close();
    } finally {
      client.close();
    }
    if (tmp.lengthSync() < minSize) {
      tmp.deleteSync();
      throw Exception('Download incomplete');
    }
    if (target.existsSync()) target.deleteSync();
    tmp.renameSync(target.path);
  }
}

/// Languages offered for the voice notes (Whisper and ML Kit share these codes).
const voiceLanguages = {
  'es': 'Spanish',
  'en': 'English',
  'ar': 'Arabic',
  'fr': 'French',
  'de': 'German',
  'it': 'Italian',
  'pt': 'Portuguese',
};

class FolderEntry {
  FolderEntry(this.uri, this.name, this.modified, this.size);
  final String uri;
  final String name;
  final int modified;
  final int size;
}

abstract class VoiceEngine {
  static VoiceEngine create() => Platform.isAndroid ? AndroidVoice() : DesktopVoice();

  /// Android can browse WhatsApp's Voice Notes folder directly.
  bool get canBrowseFolder;

  /// One line for the UI explaining where translation happens.
  String get translationNote;

  Future<String?> pickFolder() async => null;
  Future<bool> hasFolderAccess(String uri) async => false;
  Future<List<FolderEntry>> listFolder(String uri) async => const [];

  /// Download offline translation packs (Android). No-op elsewhere.
  Future<void> prepareTranslation(String from) async {}

  Future<String> transcribe(String source, String language, void Function(int percent) onProgress);

  Future<String> translate(String text, String from, String to);

  Future<void> play(String source);
  Future<void> stop() async {}

  /// A real file for [source] (Android copies content:// uris into the cache).
  Future<File> localFile(String source) async => File(source);
}

// ----------------------------------------------------------------------- Android

class AndroidVoice extends VoiceEngine {
  AndroidVoice() {
    _ch.setMethodCallHandler((call) async {
      final m = (call.arguments as Map?) ?? const {};
      if (call.method == 'progress') _progress[m['id']]?.call(m['p'] as int);
    });
  }

  static const _ch = MethodChannel('toolbox/voice');
  final _progress = <String, void Function(int)>{};
  int _n = 0;

  @override
  bool get canBrowseFolder => true;

  @override
  String get translationNote => 'Everything runs on your phone. Audio and text never leave it.';

  @override
  Future<String?> pickFolder() => _ch.invokeMethod<String>('pickFolder');

  @override
  Future<bool> hasFolderAccess(String uri) async =>
      await _ch.invokeMethod<bool>('hasFolderAccess', {'uri': uri}) ?? false;

  @override
  Future<List<FolderEntry>> listFolder(String uri) async {
    final list = await _ch.invokeListMethod<Map>('listFolder', {'uri': uri}) ?? const [];
    return [
      for (final m in list)
        FolderEntry(
          m['uri'] as String,
          m['name'] as String,
          (m['modified'] as num).toInt(),
          (m['size'] as num).toInt(),
        ),
    ];
  }

  @override
  Future<void> prepareTranslation(String from) => _ch.invokeMethod('prepareTranslation', {'from': from});

  @override
  Future<String> transcribe(String source, String language, void Function(int) onProgress) async {
    final id = 't${_n++}';
    _progress[id] = onProgress;
    try {
      final model = await SpeechModel.file();
      return await _ch.invokeMethod<String>('transcribe', {
            'id': id,
            'source': source,
            'model': model.path,
            'language': language,
          }) ??
          '';
    } on PlatformException catch (e) {
      throw Exception(e.message ?? e.code);
    } finally {
      _progress.remove(id);
    }
  }

  @override
  Future<String> translate(String text, String from, String to) async {
    try {
      return await _ch.invokeMethod<String>('translate', {'text': text, 'from': from, 'to': to}) ?? '';
    } on PlatformException catch (e) {
      throw Exception(e.message ?? e.code);
    }
  }

  @override
  Future<void> play(String source) => _ch.invokeMethod('play', {'source': source});

  @override
  Future<void> stop() => _ch.invokeMethod('stop');

  @override
  Future<File> localFile(String source) async {
    if (!source.startsWith('content:')) return File(source);
    final path = await _ch.invokeMethod<String>('copyToCache', {'source': source});
    return File(path!);
  }
}

// ----------------------------------------------------------------------- desktop

class DesktopVoice extends VoiceEngine {
  @override
  bool get canBrowseFolder => false;

  @override
  String get translationNote => 'Speech-to-text runs on this PC. Translation sends only the text to Google Translate.';

  @override
  Future<String> transcribe(String source, String language, void Function(int) onProgress) async {
    final ffmpeg = findTool('ffmpeg');
    final whisper = findTool('whisper-cli');
    if (ffmpeg == null) throw Exception('FFmpeg not found (it ships in the "tools" folder next to the app).');
    if (whisper == null) throw Exception('whisper-cli not found (it ships in the "tools" folder next to the app).');

    final tmp = await Directory((await getTemporaryDirectory()).path).createTemp('voice');
    try {
      final wav = p.join(tmp.path, 'in.wav');
      final dec = await Process.run(ffmpeg, [
        '-nostdin',
        '-y',
        '-i',
        source,
        '-ar',
        '16000',
        '-ac',
        '1',
        '-c:a',
        'pcm_s16le',
        wav,
      ]);
      if (dec.exitCode != 0 || !File(wav).existsSync()) {
        throw Exception("Couldn't read this audio file");
      }
      final outBase = p.join(tmp.path, 'out');
      final threads = Platform.numberOfProcessors.clamp(1, 8);
      final proc = await Process.start(whisper, [
        '-m',
        (await SpeechModel.file()).path,
        '-f',
        wav,
        '-l',
        language,
        '-t',
        '$threads',
        '-nt',
        '-pp',
        '-otxt',
        '-of',
        outBase,
      ]);
      final progressRe = RegExp(r'progress\s*=\s*(\d+)%');
      final err = StringBuffer();
      final errDone = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach((chunk) {
        err.write(chunk);
        for (final m in progressRe.allMatches(chunk)) {
          onProgress(int.parse(m.group(1)!));
        }
      });
      final outDone = proc.stdout.drain<void>();
      final code = await proc.exitCode;
      await Future.wait([errDone, outDone]);
      final txt = File('$outBase.txt');
      if (code != 0 || !txt.existsSync()) {
        throw Exception('Transcription failed (code $code)');
      }
      return (await txt.readAsString()).replaceAll(RegExp(r'\s+'), ' ').trim();
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<String> translate(String text, String from, String to) async {
    if (text.trim().isEmpty || from == to) return text;
    final uri = Uri.parse(
      'https://translate.googleapis.com/translate_a/single'
      '?client=gtx&sl=$from&tl=$to&dt=t',
    );
    final resp = await http.post(uri, body: {'q': text}).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) throw Exception('Translation service answered ${resp.statusCode}');
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
    final parts = (data.first as List?) ?? const [];
    return parts.map((s) => (s as List).first ?? '').join().trim();
  }

  @override
  Future<void> play(String source) async {
    if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', source]);
    } else {
      await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [source]);
    }
  }
}
