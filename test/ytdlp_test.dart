import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:toolbox/core/paths.dart';
import 'package:toolbox/tools/downloader/engine.dart';
import 'package:toolbox/tools/downloader/ytdlp.dart';

void main() {
  group('downloadArgs', () {
    test('video merges best streams into mp4 with a height cap', () {
      final a = downloadArgs(
        DownloadOptions(url: 'U', kind: MediaKind.video, quality: '720'),
        homeDir: '/h',
      );
      expect(a, containsAllInOrder(['-f', 'bv*+ba/b', '-S', 'res:720,ext:mp4:m4a', '--merge-output-format', 'mp4']));
      expect(a.last, 'U');
      expect(a, contains('--no-playlist'));
      expect(a, containsAllInOrder(['-P', 'home:/h']));
    });

    test('mp3 extracts audio at the chosen bitrate', () {
      final a = downloadArgs(
        DownloadOptions(url: 'U', kind: MediaKind.mp3, bitrate: '320'),
        homeDir: '/h',
      );
      expect(a, containsAllInOrder(['-x', '--audio-format', 'mp3', '--audio-quality', '320K']));
    });

    test('without ffmpeg: mp3 becomes m4a, video uses single-file formats', () {
      final mp3 = downloadArgs(
        DownloadOptions(url: 'U', kind: MediaKind.mp3),
        homeDir: '/h',
        hasFfmpeg: false,
      );
      expect(mp3, isNot(contains('mp3')));
      final v = downloadArgs(
        DownloadOptions(url: 'U', kind: MediaKind.video, quality: '480'),
        homeDir: '/h',
        hasFfmpeg: false,
      );
      expect(v, containsAllInOrder(['-f', 'b[height<=480][ext=mp4]/b[height<=480]/b']));
    });

    test('playlist mode keeps going on errors', () {
      final a = downloadArgs(
        DownloadOptions(url: 'U', kind: MediaKind.m4a, playlist: true),
        homeDir: '/h',
      );
      expect(a, containsAll(['--yes-playlist', '--ignore-errors']));
    });
  });

  group('parseLine', () {
    test('progress', () {
      final e = parseLine('@@P|downloading|500|1000|NA|250.5|2') as ProgressEvent;
      expect(e.fraction, 0.5);
      expect(e.speed, 250.5);
      expect(e.eta, 2);
    });
    test('progress with estimate only', () {
      final e = parseLine('@@P|downloading|10|NA|100|NA|NA') as ProgressEvent;
      expect(e.fraction, closeTo(0.1, 1e-9));
      expect(e.speed, isNull);
    });
    test('file + postprocess', () {
      expect((parseLine('@@F|C:\\x\\a b.mp4') as FileEvent).path, 'C:\\x\\a b.mp4');
      expect(parseLine('@@PP|started|ExtractAudio'), isA<ProcessingEvent>());
      expect(parseLine('[youtube] abc: Downloading webpage'), isNull);
    });
  });

  test('parseSearch reads flat ytsearch output', () {
    const json =
        '{"_type":"playlist","entries":[{"id":"abc","title":"Song","url":"https://www.youtube.com/watch?v=abc",'
        '"channel":"Ch","duration":215.0,"view_count":1234},{"id":"def","title":null}]}';
    final r = parseSearch('noise\n$json\n');
    expect(r, hasLength(2));
    expect(r.first.title, 'Song');
    expect(r.first.thumbnail, 'https://i.ytimg.com/vi/abc/mqdefault.jpg');
    expect(r[1].title, 'def');
    expect(r[1].url, contains('def'));
  });

  test('cleanError strips boilerplate', () {
    expect(
      cleanError('WARNING: x\nERROR: [youtube] abc: Video unavailable; please report this issue on https://...'),
      '[youtube] abc: Video unavailable',
    );
  });

  test('formatting', () {
    expect(formatDuration(65), '1:05');
    expect(formatDuration(3725), '1:02:05');
    expect(formatBytes(1536), '1.5 KB');
  });

  // Real end-to-end run of the desktop engine against a local HTTP server.
  group('desktop engine (needs yt-dlp + ffmpeg on PATH)', () {
    final hasTools = findTool('yt-dlp') != null && findTool('ffmpeg') != null;
    late HttpServer server;
    late Directory tmp;
    late String url;

    setUpAll(() async {
      if (!hasTools) return;
      tmp = await Directory.systemTemp.createTemp('tbx');
      final clip = p.join(tmp.path, 'clip.mp4');
      final r = await Process.run('ffmpeg', [
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc=duration=3:size=320x240:rate=15',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=3',
        '-shortest',
        '-c:v',
        'libx264',
        '-c:a',
        'aac',
        clip,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final f = File(clip);
        req.response.headers.contentType = ContentType('video', 'mp4');
        req.response.contentLength = f.lengthSync();
        await req.response.addStream(f.openRead());
        await req.response.close();
      });
      url = 'http://127.0.0.1:${server.port}/clip.mp4';
    });

    tearDownAll(() async {
      if (!hasTools) return;
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    for (final kind in MediaKind.values) {
      test('downloads ${kind.name}', () async {
        final engine = DesktopYtDlp();
        final home = p.join(tmp.path, kind.folder);
        final args = downloadArgs(
          DownloadOptions(url: url, kind: kind),
          homeDir: home,
        );
        final files = <String>[];
        var sawProgress = false;
        final res = await engine.run(
          'job-${kind.name}',
          args,
          onLine: (l) {
            final e = parseLine(l);
            if (e is FileEvent) files.add(e.path);
            if (e is ProgressEvent) sawProgress = true;
          },
        );
        expect(res.ok, isTrue, reason: res.err);
        expect(sawProgress, isTrue);
        expect(files, hasLength(1));
        final ext = {MediaKind.video: '.mp4', MediaKind.mp3: '.mp3', MediaKind.m4a: '.m4a'}[kind];
        expect(p.extension(files.single), ext);
        expect(File(files.single).lengthSync(), greaterThan(1000));
      }, skip: hasTools ? false : 'yt-dlp/ffmpeg not installed');
    }

    test('info + cancel', () async {
      final engine = DesktopYtDlp();
      final info = await engine.info(url);
      expect(info.title, 'clip');
      // Cancel a running job.
      final future = engine.run(
        'c',
        downloadArgs(
          DownloadOptions(url: url, kind: MediaKind.video),
          homeDir: p.join(tmp.path, 'cancel'),
          tempDir: p.join(tmp.path, 'ctmp'),
        ),
      );
      await engine.cancel('c');
      await expectLater(future, throwsA(isA<CancelledException>()));
    }, skip: hasTools ? false : 'yt-dlp/ffmpeg not installed');
  });
}
