// Runs yt-dlp. Desktop: a child process (bundled yt-dlp.exe + ffmpeg + deno).
// Android: youtubedl-android (embedded Python + ffmpeg + QuickJS) over a method channel.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/paths.dart';
import 'ytdlp.dart';

class YtResult {
  YtResult(this.exitCode, this.out, this.err);
  final int exitCode;
  final String out;
  final String err;
  bool get ok => exitCode == 0;
}

class CancelledException implements Exception {}

abstract class YtDlpEngine {
  static YtDlpEngine create() => Platform.isAndroid ? AndroidYtDlp() : DesktopYtDlp();

  /// Whether HD merging and MP3 conversion are possible.
  bool get hasFfmpeg;

  Future<void> ensureReady();

  Future<YtResult> run(String jobId, List<String> args, {void Function(String line)? onLine});

  Future<void> cancel(String jobId);

  Future<String> version();

  /// Updates yt-dlp to the newest release. Returns a human readable status.
  Future<String> update();

  /// Folder yt-dlp should write into for this job.
  Future<String> homeDir(String jobId, MediaKind kind);

  /// Optional folder for partial files.
  Future<String?> tempDir(String jobId);

  /// Moves a finished file to its final public place; returns where it ended up.
  Future<String> finalize(String path, MediaKind kind);

  /// Clean-up after a job (successful or not).
  Future<void> cleanup(String jobId);

  Future<List<SearchResult>> search(String query) async {
    final r = await run('search', searchArgs(query));
    if (!r.ok) throw Exception(cleanError(r.err));
    return parseSearch(r.out);
  }

  Future<MediaInfo> info(String url) async {
    final r = await run('info', infoArgs(url));
    if (!r.ok) throw Exception(cleanError(r.err));
    return parseInfo(url, r.out);
  }
}

// ----------------------------------------------------------------------- desktop

class DesktopYtDlp extends YtDlpEngine {
  final _procs = <String, Process>{};
  final _cancelled = <String>{};

  String get _ytdlp => findTool('yt-dlp') ?? 'yt-dlp';
  String? get _ffmpeg => findTool('ffmpeg');
  String? get _deno => findTool('deno');

  @override
  bool get hasFfmpeg => _ffmpeg != null;

  @override
  Future<void> ensureReady() async {}

  List<String> _extra() => [
    if (_ffmpeg != null) ...['--ffmpeg-location', _ffmpeg!],
    if (_deno != null) ...['--js-runtimes', 'deno:${_deno!}'],
  ];

  @override
  Future<YtResult> run(String jobId, List<String> args, {void Function(String line)? onLine}) async {
    final Process proc;
    try {
      proc = await Process.start(
        _ytdlp,
        [..._extra(), ...args],
        environment: {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
      );
    } on ProcessException {
      throw Exception('yt-dlp was not found. On Windows it ships in the "tools" folder next to the app.');
    }
    _procs[jobId] = proc;
    // Cancel may have been requested while the process was still starting.
    if (_cancelled.contains(jobId)) await _kill(proc);
    final out = StringBuffer();
    final err = StringBuffer();
    final outDone = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
          out.writeln(line);
          onLine?.call(line);
        });
    final errDone = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(err.write);
    final code = await proc.exitCode;
    await Future.wait([outDone, errDone]);
    _procs.remove(jobId);
    if (_cancelled.remove(jobId)) throw CancelledException();
    return YtResult(code, out.toString(), err.toString());
  }

  @override
  Future<void> cancel(String jobId) async {
    _cancelled.add(jobId);
    final proc = _procs[jobId];
    if (proc != null) await _kill(proc);
  }

  Future<void> _kill(Process proc) async {
    if (Platform.isWindows) {
      // yt-dlp.exe spawns children (python, ffmpeg): kill the whole tree.
      await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
    } else {
      proc.kill();
    }
  }

  @override
  Future<String> version() async {
    try {
      final r = await Process.run(_ytdlp, ['--version']);
      return (r.stdout as String).trim();
    } catch (_) {
      return 'not found';
    }
  }

  @override
  Future<String> update() async {
    final r = await Process.run(_ytdlp, ['-U'], stdoutEncoding: utf8, stderrEncoding: utf8);
    final text = '${r.stdout}\n${r.stderr}'.trim();
    final last = const LineSplitter().convert(text).where((l) => l.trim().isNotEmpty);
    return last.isEmpty ? 'Done' : last.last;
  }

  @override
  Future<String> homeDir(String jobId, MediaKind kind) async => p.join(await downloadRoot(), kind.folder);

  @override
  Future<String?> tempDir(String jobId) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'toolbox-dl', jobId));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> finalize(String path, MediaKind kind) async => path;

  @override
  Future<void> cleanup(String jobId) async {
    final t = await tempDir(jobId);
    if (t != null) {
      try {
        await Directory(t).delete(recursive: true);
      } catch (_) {}
    }
  }
}

// ----------------------------------------------------------------------- android

class AndroidYtDlp extends YtDlpEngine {
  AndroidYtDlp() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'line') {
        final m = call.arguments as Map;
        _listeners[m['jobId']]?.call(m['line'] as String);
      }
    });
  }

  static const _channel = MethodChannel('toolbox/ytdlp');
  final _listeners = <String, void Function(String)>{};
  Future<void>? _ready;

  @override
  bool get hasFfmpeg => true; // bundled by youtubedl-android

  @override
  Future<void> ensureReady() => _ready ??= _channel.invokeMethod('init').catchError((Object e) {
    _ready = null;
    throw e;
  });

  @override
  Future<YtResult> run(String jobId, List<String> args, {void Function(String line)? onLine}) async {
    await ensureReady();
    if (onLine != null) _listeners[jobId] = onLine;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('run', {'jobId': jobId, 'args': args});
      if (m!['cancelled'] == true) throw CancelledException();
      return YtResult(m['exitCode'] as int, m['out'] as String? ?? '', m['err'] as String? ?? '');
    } finally {
      _listeners.remove(jobId);
    }
  }

  @override
  Future<void> cancel(String jobId) => _channel.invokeMethod('cancel', {'jobId': jobId});

  @override
  Future<String> version() async {
    await ensureReady();
    return await _channel.invokeMethod<String>('version') ?? '?';
  }

  @override
  Future<String> update() async {
    await ensureReady();
    return await _channel.invokeMethod<String>('update') ?? 'Done';
  }

  Future<String> _jobDir(String jobId) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'dl', jobId));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> homeDir(String jobId, MediaKind kind) => _jobDir(jobId);

  @override
  Future<String?> tempDir(String jobId) async => null;

  /// Copies into the public Download/Toolbox/<kind> folder via MediaStore.
  @override
  Future<String> finalize(String path, MediaKind kind) async {
    final where = await _channel.invokeMethod<String>('saveToDownloads', {
      'path': path,
      'folder': '$appFolderName/${kind.folder}',
    });
    return where ?? path;
  }

  @override
  Future<void> cleanup(String jobId) async {
    try {
      await Directory(await _jobDir(jobId)).delete(recursive: true);
    } catch (_) {}
  }
}
