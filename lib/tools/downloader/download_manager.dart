import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'engine.dart';
import 'ytdlp.dart';

enum JobState { queued, starting, downloading, processing, done, failed, cancelled }

class DownloadJob extends ChangeNotifier {
  DownloadJob({required this.id, required this.options, required this.title, this.thumbnail});

  final String id;
  final DownloadOptions options;
  final String title;
  final String? thumbnail;

  JobState state = JobState.queued;
  double? fraction;
  String status = 'Queued';
  final files = <String>[];

  bool get finished => state == JobState.done || state == JobState.failed || state == JobState.cancelled;

  void _update(JobState s, String msg, [double? f]) {
    state = s;
    status = msg;
    fraction = f;
    notifyListeners();
  }
}

/// Queue of downloads; runs up to [maxParallel] at once.
class DownloadManager extends ChangeNotifier {
  DownloadManager(this.engine);

  final YtDlpEngine engine;
  static const maxParallel = 2;

  final jobs = <DownloadJob>[];
  int _running = 0;
  int _counter = 0;

  int get activeCount => jobs.where((j) => !j.finished).length;

  DownloadJob add(DownloadOptions options, {required String title, String? thumbnail}) {
    final job = DownloadJob(
      id: '${DateTime.now().millisecondsSinceEpoch}-${_counter++}',
      options: options,
      title: title,
      thumbnail: thumbnail,
    );
    jobs.insert(0, job);
    notifyListeners();
    _pump();
    return job;
  }

  void remove(DownloadJob job) {
    if (!job.finished) return;
    jobs.remove(job);
    notifyListeners();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.finished);
    notifyListeners();
  }

  Future<void> cancel(DownloadJob job) async {
    if (job.finished) return;
    if (job.state == JobState.queued) {
      job._update(JobState.cancelled, 'Cancelled');
      notifyListeners();
      return;
    }
    job._update(job.state, 'Cancelling…');
    await engine.cancel(job.id);
  }

  void _pump() {
    while (_running < maxParallel) {
      final next = jobs.lastWhere((j) => j.state == JobState.queued, orElse: () => _none);
      if (identical(next, _none)) return;
      _running++;
      unawaited(
        _run(next).whenComplete(() {
          _running--;
          notifyListeners();
          _pump();
        }),
      );
    }
  }

  static final _none = DownloadJob(
    id: '',
    options: DownloadOptions(url: '', kind: MediaKind.video),
    title: '',
  );

  Future<void> _run(DownloadJob job) async {
    job._update(JobState.starting, 'Starting…');
    final kind = job.options.kind;
    try {
      final args = downloadArgs(
        job.options,
        homeDir: await engine.homeDir(job.id, kind),
        tempDir: await engine.tempDir(job.id),
        hasFfmpeg: engine.hasFfmpeg,
      );
      final produced = <String>[];
      var lastUi = DateTime(0);
      final result = await engine.run(
        job.id,
        args,
        onLine: (line) {
          final ev = parseLine(line);
          switch (ev) {
            case ProgressEvent e:
              final now = DateTime.now();
              if (now.difference(lastUi).inMilliseconds < 250 && (e.fraction ?? 0) < 1) return;
              lastUi = now;
              job._update(JobState.downloading, _progressText(e), e.fraction);
            case ProcessingEvent _:
              job._update(JobState.processing, 'Processing…');
            case FileEvent f:
              produced.add(f.path);
            case null:
              break;
          }
        },
      );
      if (!result.ok && produced.isEmpty) {
        job._update(JobState.failed, 'Failed: ${cleanError(result.err)}');
        return;
      }
      job._update(JobState.processing, 'Saving…');
      for (final f in produced) {
        job.files.add(await engine.finalize(f, kind));
      }
      final where = job.files.isEmpty
          ? 'already downloaded'
          : (job.files.length == 1 ? p.basename(job.files.first) : '${job.files.length} files');
      job._update(JobState.done, 'Done · $where', 1);
    } on CancelledException {
      job._update(JobState.cancelled, 'Cancelled');
    } catch (e) {
      job._update(JobState.failed, 'Failed: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      await engine.cleanup(job.id);
    }
  }

  static String _progressText(ProgressEvent e) {
    final parts = <String>[
      if (e.fraction != null) '${(e.fraction! * 100).toStringAsFixed(0)}%',
      '${formatBytes(e.downloaded)} / ${formatBytes(e.total)}',
      if (e.speed != null) '${formatBytes(e.speed)}/s',
      if (e.eta != null) 'ETA ${formatDuration(e.eta).isEmpty ? '0:00' : formatDuration(e.eta)}',
    ];
    return parts.join(' · ');
  }
}
