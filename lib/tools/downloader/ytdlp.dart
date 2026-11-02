// Pure Dart: builds yt-dlp command lines and parses its output.
// The same arguments run on Windows (yt-dlp.exe) and Android (youtubedl-android).

import 'dart:convert';

enum MediaKind { video, mp3, m4a }

extension MediaKindX on MediaKind {
  String get label => switch (this) {
    MediaKind.video => 'Video (MP4)',
    MediaKind.mp3 => 'Audio (MP3)',
    MediaKind.m4a => 'Audio (M4A)',
  };

  /// Subfolder inside the download folder. Keeping kinds apart also stops
  /// yt-dlp from treating an earlier same-named video as the source for an
  /// audio extraction (and then deleting it).
  String get folder => switch (this) {
    MediaKind.video => 'Video',
    MediaKind.mp3 => 'MP3',
    MediaKind.m4a => 'M4A',
  };

  String get id => name;

  static MediaKind parse(String? s) => MediaKind.values.firstWhere((k) => k.name == s, orElse: () => MediaKind.mp3);
}

const videoQualities = ['best', '2160', '1440', '1080', '720', '480', '360'];
const mp3Bitrates = ['320', '256', '192', '128'];

String qualityLabel(String q) => q == 'best' ? 'Best available' : '${q}p';

class SearchResult {
  SearchResult({
    required this.id,
    required this.title,
    required this.url,
    this.channel = '',
    this.duration,
    this.views,
  });

  final String id;
  final String title;
  final String url;
  final String channel;
  final double? duration;
  final int? views;

  String get thumbnail => 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
}

class MediaInfo {
  MediaInfo({
    required this.url,
    required this.title,
    this.uploader = '',
    this.duration,
    this.thumbnail,
    this.site = '',
    this.isPlaylist = false,
    this.entryCount = 0,
  });

  final String url;
  final String title;
  final String uploader;
  final double? duration;
  final String? thumbnail;
  final String site;
  final bool isPlaylist;
  final int entryCount;
}

class DownloadOptions {
  DownloadOptions({
    required this.url,
    required this.kind,
    this.quality = '1080',
    this.bitrate = '192',
    this.playlist = false,
  });

  final String url;
  final MediaKind kind;
  final String quality;
  final String bitrate;
  final bool playlist;
}

/// Markers we ask yt-dlp to print so we can parse its output reliably.
const _p = '@@P|';
const _pp = '@@PP|';
const _f = '@@F|';

List<String> commonArgs() => ['--no-warnings', '--encoding', 'utf-8'];

List<String> searchArgs(String query, {int limit = 20}) => [
  ...commonArgs(),
  '-J',
  '--flat-playlist',
  'ytsearch$limit:$query',
];

List<String> infoArgs(String url) => [...commonArgs(), '-J', '--flat-playlist', url];

/// [homeDir] is where finished files go, [tempDir] (optional) for partial files.
List<String> downloadArgs(DownloadOptions o, {required String homeDir, String? tempDir, bool hasFfmpeg = true}) {
  var template = '%(title).150B [%(id)s].%(ext)s';
  if (o.playlist) {
    template = '%(playlist_title|Playlist).80B/%(playlist_index)03d - $template';
  }
  final kind = (!hasFfmpeg && o.kind == MediaKind.mp3) ? MediaKind.m4a : o.kind;
  final args = <String>[
    ...commonArgs(),
    '-P',
    'home:$homeDir',
    if (tempDir != null) ...['-P', 'temp:$tempDir'],
    '-o',
    template,
    '--windows-filenames',
    '--no-mtime',
    '--newline',
    '--progress',
    '--no-simulate',
    '--progress-template',
    'download:$_p%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|'
        '%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s',
    '--progress-template',
    'postprocess:$_pp%(progress.status)s|%(progress.postprocessor)s',
    '--print',
    'after_move:$_f%(filepath)s',
    o.playlist ? '--yes-playlist' : '--no-playlist',
    if (o.playlist) '--ignore-errors',
  ];

  switch (kind) {
    case MediaKind.video:
      if (hasFfmpeg) {
        // Best separate video+audio streams merged into MP4. At equal resolution
        // prefer MP4/M4A (H.264/AAC) so files play everywhere.
        final res = o.quality == 'best' ? 'res' : 'res:${o.quality}';
        args.addAll(['-f', 'bv*+ba/b', '-S', '$res,ext:mp4:m4a', '--merge-output-format', 'mp4']);
      } else {
        final limit = o.quality == 'best' ? '' : '[height<=${o.quality}]';
        args.addAll(['-f', 'b$limit[ext=mp4]/b$limit/b']);
      }
    case MediaKind.mp3:
      args.addAll([
        '-f',
        'ba/b',
        '-x',
        '--audio-format',
        'mp3',
        '--audio-quality',
        '${o.bitrate}K',
        '--embed-metadata',
        '--embed-thumbnail',
      ]);
    case MediaKind.m4a:
      args.addAll(['-f', 'ba[ext=m4a]/ba[acodec^=mp4a]/ba/b']);
      if (hasFfmpeg) args.addAll(['-x', '--audio-format', 'm4a', '--embed-metadata']);
  }
  args.add(o.url);
  return args;
}

// --------------------------------------------------------------------- parsing

sealed class YtEvent {}

class ProgressEvent extends YtEvent {
  ProgressEvent({this.fraction, this.downloaded = 0, this.total, this.speed, this.eta});
  final double? fraction;
  final int downloaded;
  final int? total;
  final double? speed;
  final int? eta;
}

class ProcessingEvent extends YtEvent {
  ProcessingEvent(this.step);
  final String step;
}

class FileEvent extends YtEvent {
  FileEvent(this.path);
  final String path;
}

num? _num(String s) {
  if (s.isEmpty || s == 'NA' || s == 'None') return null;
  return num.tryParse(s);
}

/// Parses one line of yt-dlp output, or returns null if it's not ours.
YtEvent? parseLine(String raw) {
  final line = raw.trim();
  final i = line.indexOf('@@');
  if (i < 0) return null;
  final s = line.substring(i);
  if (s.startsWith(_f)) return FileEvent(s.substring(_f.length));
  if (s.startsWith(_pp)) {
    final parts = s.substring(_pp.length).split('|');
    return ProcessingEvent(parts.length > 1 ? parts[1] : '');
  }
  if (s.startsWith(_p)) {
    final parts = s.substring(_p.length).split('|');
    if (parts.length < 6) return null;
    if (parts[0] == 'finished') return ProcessingEvent('');
    final done = _num(parts[1])?.toInt() ?? 0;
    final total = (_num(parts[2]) ?? _num(parts[3]))?.toInt();
    return ProgressEvent(
      downloaded: done,
      total: total,
      fraction: (total != null && total > 0) ? (done / total).clamp(0.0, 1.0) : null,
      speed: _num(parts[4])?.toDouble(),
      eta: _num(parts[5])?.toInt(),
    );
  }
  return null;
}

Map<String, dynamic> _decodeJson(String out) {
  // yt-dlp prints a single JSON document; be tolerant of stray lines around it.
  final start = out.indexOf('{');
  final end = out.lastIndexOf('}');
  if (start < 0 || end < start) throw const FormatException('No JSON in yt-dlp output');
  return jsonDecode(out.substring(start, end + 1)) as Map<String, dynamic>;
}

List<SearchResult> parseSearch(String out) {
  final data = _decodeJson(out);
  final entries = (data['entries'] as List?) ?? const [];
  return [
    for (final e in entries.whereType<Map<String, dynamic>>())
      if (e['id'] != null)
        SearchResult(
          id: e['id'] as String,
          title: (e['title'] as String?) ?? e['id'] as String,
          url: (e['url'] as String?) ?? 'https://www.youtube.com/watch?v=${e['id']}',
          channel: (e['channel'] ?? e['uploader'] ?? '') as String,
          duration: (e['duration'] as num?)?.toDouble(),
          views: (e['view_count'] as num?)?.toInt(),
        ),
  ];
}

MediaInfo parseInfo(String url, String out) {
  final d = _decodeJson(out);
  final isPlaylist = d['_type'] == 'playlist';
  String? thumb = d['thumbnail'] as String?;
  final thumbs = d['thumbnails'];
  if (thumb == null && thumbs is List && thumbs.isNotEmpty) {
    thumb = (thumbs.last as Map)['url'] as String?;
  }
  return MediaInfo(
    url: url,
    title: (d['title'] as String?) ?? url,
    uploader: (d['uploader'] ?? d['channel'] ?? '') as String,
    duration: (d['duration'] as num?)?.toDouble(),
    thumbnail: thumb,
    site: (d['extractor_key'] as String?) ?? '',
    isPlaylist: isPlaylist,
    entryCount: isPlaylist ? ((d['entries'] as List?)?.length ?? 0) : 0,
  );
}

/// Last meaningful "ERROR:" line from yt-dlp's stderr, without the boilerplate.
String cleanError(String stderr) {
  final lines = const LineSplitter().convert(stderr).where((l) => l.trim().isNotEmpty).toList();
  var msg = lines.lastWhere((l) => l.contains('ERROR'), orElse: () => lines.isEmpty ? '' : lines.last);
  msg = msg.replaceFirst(RegExp(r'^.*?ERROR:\s*'), '');
  final cut = msg.indexOf('; please report this issue');
  if (cut > 0) msg = msg.substring(0, cut);
  msg = msg.trim();
  if (msg.length > 300) msg = '${msg.substring(0, 300)}…';
  return msg.isEmpty ? 'Unknown error' : msg;
}

String formatDuration(num? seconds) {
  if (seconds == null || seconds <= 0) return '';
  final s = seconds.toInt();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

String formatBytes(num? n) {
  if (n == null || n <= 0) return '?';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = n.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return u == 0 ? '${v.toInt()} B' : '${v.toStringAsFixed(1)} ${units[u]}';
}
