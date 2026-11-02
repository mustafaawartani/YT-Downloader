// Where voice notes come from: single shared files, exported WhatsApp chats
// (zip with a .txt that says who sent what), or the Voice Notes folder.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

enum ItemState { idle, queued, decoding, transcribing, translating, done, error }

extension ItemStateX on ItemState {
  bool get active =>
      this == ItemState.queued ||
      this == ItemState.decoding ||
      this == ItemState.transcribing ||
      this == ItemState.translating;
}

class VoiceItem {
  VoiceItem({
    required this.id,
    required this.source,
    required this.fileName,
    required this.sizeBytes,
    this.sender,
    this.dateLabel = '',
    this.sortKey = 0,
  });

  final String id;

  /// File path, or a content:// uri on Android.
  final String source;
  final String fileName;
  final int sizeBytes;
  final String? sender;
  final String dateLabel;
  final int sortKey;

  ItemState state = ItemState.idle;
  int progress = 0;
  String? original;
  String? english;
  String? arabic;
  String? error;

  String get cacheKey => '$fileName|$sizeBytes';
}

class ImportResult {
  ImportResult(this.items, this.label, this.senders);
  final List<VoiceItem> items;
  final String label;
  final List<String> senders;
}

const audioExtensions = {'opus', 'ogg', 'oga', 'm4a', 'aac', 'mp3', 'amr', 'wav', '3gp', 'mp4', 'webm', 'flac'};

bool isAudioName(String name) => audioExtensions.contains(p.extension(name).replaceFirst('.', '').toLowerCase());

final _ptt = RegExp(r'(\d{8})-WA(\d+)');

int pttKey(String name) {
  final m = _ptt.firstMatch(name);
  if (m == null) return 0;
  return int.parse(m.group(1)!) * 100000 + int.parse(m.group(2)!);
}

String? pttDate(String name) {
  final d = _ptt.firstMatch(name)?.group(1);
  if (d == null) return null;
  return '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)}';
}

class ChatEntry {
  ChatEntry(this.date, this.sender, this.order);
  final String date;
  final String? sender;
  final int order;
}

/// Reads "WhatsApp Chat with X.txt" to find who sent each voice note and when.
class ChatParser {
  static final _attachment = RegExp(r'([\w\-]+\.(?:opus|ogg|oga|m4a|aac|mp3|amr|wav|3gp))', caseSensitive: false);
  static final _invisible = RegExp('[\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]');

  static Map<String, ChatEntry> parse(String text) {
    final map = <String, ChatEntry>{};
    final lines = const LineSplitter().convert(text);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].replaceAll(_invisible, '').trim();
      final file = _attachment.firstMatch(line)?.group(1);
      if (file == null) continue;
      String date;
      String rest;
      if (line.startsWith('[') && line.contains(']')) {
        // iPhone: [07/10/2026, 14:32:05] Maria: <attached: 00000012-AUDIO-2026-10-07.opus>
        final close = line.indexOf(']');
        date = line.substring(1, close);
        rest = line.substring(close + 1).trim();
      } else {
        // Android: 07/10/2026, 14:32 - Maria: PTT-20261007-WA0012.opus (file attached)
        final dash = line.indexOf(' - ');
        date = dash > 0 ? line.substring(0, dash) : '';
        rest = dash > 0 ? line.substring(dash + 3) : line;
      }
      final colon = rest.indexOf(': ');
      final sender = colon > 0 ? rest.substring(0, colon).trim() : null;
      map[file] = ChatEntry(date.trim(), sender, index);
    }
    return map;
  }
}

/// Turns picked/shared files (audio, chat .txt, or exported-chat .zip) into voice items.
/// Zip contents are extracted into [workDir].
Future<ImportResult> importFiles(List<String> paths, Directory workDir) async {
  await workDir.create(recursive: true);
  String? chatText;
  String? chatName;
  final audio = <File>[];

  for (final path in paths) {
    final name = p.basename(path);
    final lower = name.toLowerCase();
    if (lower.endsWith('.zip')) {
      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final entry in archive) {
          if (!entry.isFile) continue;
          final entryName = p.basename(entry.name);
          if (entryName.toLowerCase().endsWith('.txt')) {
            chatText = utf8.decode(entry.content, allowMalformed: true);
            chatName = entryName;
          } else if (isAudioName(entryName)) {
            final out = File(p.join(workDir.path, entryName));
            await out.writeAsBytes(entry.content);
            audio.add(out);
          }
        }
      } finally {
        await input.close();
      }
    } else if (lower.endsWith('.txt')) {
      chatText = await File(path).readAsString().catchError((_) => '');
      chatName = name;
    } else if (isAudioName(name)) {
      audio.add(File(path));
    }
  }

  final entries = chatText == null ? <String, ChatEntry>{} : ChatParser.parse(chatText);
  final items = [
    for (final f in audio)
      () {
        final n = p.basename(f.path);
        final e = entries[n];
        return VoiceItem(
          id: f.path,
          source: f.path,
          fileName: n,
          sizeBytes: f.existsSync() ? f.lengthSync() : 0,
          sender: e?.sender,
          dateLabel: e?.date ?? pttDate(n) ?? _fileDate(f),
          sortKey: e?.order ?? (pttKey(n) != 0 ? pttKey(n) : _mtime(f)),
        );
      }(),
  ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));

  final label =
      chatName?.replaceAll(RegExp(r'\.txt$', caseSensitive: false), '') ??
      (items.length == 1 ? 'Voice note' : 'Files (${items.length})');
  final senders = (items.map((i) => i.sender).whereType<String>().toSet().toList()..sort());
  return ImportResult(items, label, senders);
}

int _mtime(File f) {
  try {
    return f.lastModifiedSync().millisecondsSinceEpoch;
  } catch (_) {
    return 0;
  }
}

String _fileDate(File f) {
  try {
    final d = f.lastModifiedSync();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  } catch (_) {
    return '';
  }
}
