import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:toolbox/tools/voice/groq.dart';
import 'package:toolbox/tools/voice/voice_sources.dart';

void main() {
  group('ChatParser', () {
    test('android export lines', () {
      final m = ChatParser.parse(
        '07/10/2026, 14:32 - Maria: ‎PTT-20261007-WA0012.opus (file attached)\n'
        '07/10/2026, 14:33 - Juan: hola\n'
        '07/10/2026, 14:40 - Juan: PTT-20261007-WA0013.opus (archivo adjunto)\n',
      );
      expect(m['PTT-20261007-WA0012.opus']!.sender, 'Maria');
      expect(m['PTT-20261007-WA0012.opus']!.date, '07/10/2026, 14:32');
      expect(m['PTT-20261007-WA0013.opus']!.sender, 'Juan');
    });

    test('iphone export lines', () {
      final m = ChatParser.parse('[07/10/2026, 14:32:05] Maria: <attached: 00000012-AUDIO-2026-10-07-14-32-05.opus>');
      expect(m['00000012-AUDIO-2026-10-07-14-32-05.opus']!.sender, 'Maria');
    });
  });

  test('importFiles reads an exported chat zip with senders', () async {
    final tmp = await Directory.systemTemp.createTemp('vz');
    final zipPath = p.join(tmp.path, 'chat.zip');
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'WhatsApp Chat with Maria.txt',
          '07/10/2026, 14:32 - Maria: PTT-20261007-WA0012.opus (file attached)\n'
              '08/10/2026, 09:00 - Me: PTT-20261008-WA0001.opus (file attached)\n',
        ),
      )
      ..add(ArchiveFile.bytes('PTT-20261007-WA0012.opus', List.filled(500, 1)))
      ..add(ArchiveFile.bytes('PTT-20261008-WA0001.opus', List.filled(700, 2)))
      ..add(ArchiveFile.bytes('IMG-1.jpg', List.filled(10, 3)));
    File(zipPath).writeAsBytesSync(ZipEncoder().encodeBytes(archive));

    final r = await importFiles([zipPath], Directory(p.join(tmp.path, 'work')));
    expect(r.label, 'WhatsApp Chat with Maria');
    expect(r.items, hasLength(2));
    expect(r.items.first.fileName, 'PTT-20261008-WA0001.opus'); // newest first
    expect(r.items.first.sender, 'Me');
    expect(r.senders, ['Maria', 'Me']);
    expect(File(r.items.last.source).lengthSync(), 500);
    await tmp.delete(recursive: true);
  });

  test('importFiles takes loose audio files', () async {
    final tmp = await Directory.systemTemp.createTemp('va');
    final f = File(p.join(tmp.path, 'PTT-20261007-WA0012.opus'))..writeAsBytesSync([1, 2, 3]);
    final r = await importFiles([f.path, p.join(tmp.path, 'notes.pdf')], Directory(p.join(tmp.path, 'w')));
    expect(r.items.single.dateLabel, '2026-10-07');
    await tmp.delete(recursive: true);
  });

  group('GroqClient', () {
    test('transcribes with whisper-large-v3 and renames .opus to .ogg', () async {
      late http.BaseRequest seen;
      final mock = MockClient.streaming((req, body) async {
        seen = req;
        final bytes = await body.toBytes();
        final text = latin1.decode(bytes);
        expect(text, contains('name="model"\r\n\r\nwhisper-large-v3'));
        expect(text, contains('name="language"\r\n\r\nes'));
        expect(text, contains('filename="note.ogg"'));
        return http.StreamedResponse(Stream.value(utf8.encode('{"text":" Hola, ¿qué tal? "}')), 200);
      });
      final tmp = await Directory.systemTemp.createTemp('g');
      final f = File(p.join(tmp.path, 'note.opus'))..writeAsBytesSync([1, 2, 3]);
      final text = await GroqClient('k', client: mock).transcribe(f, 'es');
      expect(text, 'Hola, ¿qué tal?');
      expect(seen.headers['Authorization'], 'Bearer k');
      expect(seen.url.path, '/openai/v1/audio/transcriptions');
      await tmp.delete(recursive: true);
    });

    test('translate picks the best available model and strips <think>', () async {
      final mock = MockClient((req) async {
        if (req.url.path.endsWith('/models')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'whisper-large-v3'},
                {'id': 'llama-3.3-70b-versatile'},
              ],
            }),
            200,
          );
        }
        final body = jsonDecode(req.body) as Map;
        expect(body['model'], 'llama-3.3-70b-versatile');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '<think>hmm</think>مرحبا'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      expect(await GroqClient('k', client: mock).translate('hola', 'Spanish', 'Arabic'), 'مرحبا');
    });

    test('bad key gives a clear error', () async {
      final mock = MockClient((_) async => http.Response('{"error":{"message":"Invalid API Key"}}', 401));
      expect(await GroqClient('bad', client: mock).checkKey(), isFalse);
      final tmp = await Directory.systemTemp.createTemp('g');
      final f = File(p.join(tmp.path, 'a.ogg'))..writeAsBytesSync([1]);
      await expectLater(
        GroqClient('bad', client: mock).transcribe(f, 'es'),
        throwsA(isA<GroqException>().having((e) => e.message, 'message', contains('API key'))),
      );
      await tmp.delete(recursive: true);
    });
  });
}
