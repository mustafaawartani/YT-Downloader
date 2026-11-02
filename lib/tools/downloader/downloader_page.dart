import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/settings.dart';
import '../../core/ui.dart';
import 'download_manager.dart';
import 'ytdlp.dart';

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key, required this.manager, this.initialUrl});

  final DownloadManager manager;
  final String? initialUrl;

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  DownloadManager get manager => widget.manager;

  // search
  final _query = TextEditingController();
  List<SearchResult>? _results;
  bool _searching = false;
  String? _searchError;

  // link
  final _link = TextEditingController();
  MediaInfo? _info;
  bool _fetching = false;
  String? _linkError;

  @override
  void initState() {
    super.initState();
    if (widget.initialUrl != null) {
      _link.text = widget.initialUrl!;
      _tabs.index = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _query.dispose();
    _link.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ actions

  void _start(
    String url,
    MediaKind kind,
    String title,
    String? thumb, {
    String? quality,
    String? bitrate,
    bool playlist = false,
  }) {
    final s = Settings.instance;
    manager.add(
      DownloadOptions(
        url: url,
        kind: kind,
        quality: quality ?? s.videoQuality,
        bitrate: bitrate ?? s.mp3Bitrate,
        playlist: playlist,
      ),
      title: title,
      thumbnail: thumb,
    );
    if (kind == MediaKind.mp3 && !manager.engine.hasFfmpeg) {
      toast(context, 'FFmpeg not found - saving as M4A instead of MP3');
    } else {
      toast(
        context,
        'Downloading: $title',
        action: SnackBarAction(label: 'View', onPressed: () => _tabs.animateTo(2)),
      );
    }
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    if (q.startsWith('http://') || q.startsWith('https://')) {
      _link.text = q;
      _tabs.animateTo(1);
      return _fetch();
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final r = await manager.engine.search(q);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _searchError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) toast(context, 'Clipboard is empty');
      return;
    }
    _link.text = text;
    await _fetch();
  }

  Future<void> _fetch() async {
    final url = _link.text.trim();
    if (url.isEmpty) {
      toast(context, 'Paste a link first');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _fetching = true;
      _linkError = null;
      _info = null;
    });
    try {
      final info = await manager.engine.info(url);
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) setState(() => _linkError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  void _quickLink(MediaKind kind) {
    final url = _link.text.trim();
    if (url.isEmpty) {
      toast(context, 'Paste a link first');
      return;
    }
    final info = _info?.url == url ? _info : null;
    _start(url, kind, info?.title ?? url, info?.thumbnail, playlist: info?.isPlaylist ?? false);
  }

  Future<void> _askFormat(
    String url,
    String title,
    String? thumb, {
    bool isPlaylist = false,
    int entryCount = 0,
  }) async {
    final s = Settings.instance;
    var kind = MediaKind.video;
    var quality = s.videoQuality;
    var bitrate = s.mp3Bitrate;
    var whole = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Download as…'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 16),
                SegmentedButton<MediaKind>(
                  segments: const [
                    ButtonSegment(value: MediaKind.video, label: Text('Video'), icon: Icon(Icons.movie)),
                    ButtonSegment(value: MediaKind.mp3, label: Text('MP3'), icon: Icon(Icons.music_note)),
                    ButtonSegment(value: MediaKind.m4a, label: Text('M4A'), icon: Icon(Icons.audiotrack)),
                  ],
                  selected: {kind},
                  onSelectionChanged: (v) => setD(() => kind = v.first),
                ),
                const SizedBox(height: 16),
                if (kind == MediaKind.video)
                  DropdownButtonFormField<String>(
                    initialValue: quality,
                    decoration: const InputDecoration(labelText: 'Video quality', border: OutlineInputBorder()),
                    items: [for (final q in videoQualities) DropdownMenuItem(value: q, child: Text(qualityLabel(q)))],
                    onChanged: (v) => setD(() => quality = v ?? quality),
                  ),
                if (kind == MediaKind.mp3)
                  DropdownButtonFormField<String>(
                    initialValue: bitrate,
                    decoration: const InputDecoration(labelText: 'MP3 bitrate', border: OutlineInputBorder()),
                    items: [for (final b in mp3Bitrates) DropdownMenuItem(value: b, child: Text('$b kbps'))],
                    onChanged: (v) => setD(() => bitrate = v ?? bitrate),
                  ),
                if (kind == MediaKind.m4a)
                  Text(
                    'Original audio, no re-encoding - fastest and best quality.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                if (isPlaylist)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: whole,
                    onChanged: (v) => setD(() => whole = v ?? true),
                    title: Text('Whole playlist ($entryCount items)'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ],
        ),
      ),
    );
    if (go == true) {
      _start(url, kind, title, thumb, quality: quality, bitrate: bitrate, playlist: isPlaylist && whole);
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloader'),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            const Tab(icon: Icon(Icons.search), text: 'Search'),
            const Tab(icon: Icon(Icons.link), text: 'Link'),
            Tab(
              icon: ListenableBuilder(
                listenable: manager,
                builder: (_, _) => Badge(
                  isLabelVisible: manager.activeCount > 0,
                  label: Text('${manager.activeCount}'),
                  child: const Icon(Icons.download),
                ),
              ),
              text: 'Downloads',
            ),
          ],
        ),
      ),
      body: TabBarView(controller: _tabs, children: [_searchTab(), _linkTab(), _downloadsTab()]),
    );
  }

  Widget _searchTab() {
    final results = _results;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search YouTube…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
            ),
          ),
        ),
        Expanded(
          child: _searchError != null
              ? EmptyState(icon: Icons.error_outline, text: 'Search failed: $_searchError')
              : results == null
              ? const EmptyState(
                  icon: Icons.smart_display,
                  text:
                      'Search for a video, then tap 🎬 for video or 🎵 for audio.\n'
                      'Paste a link from any site in the Link tab.',
                )
              : results.isEmpty
              ? const EmptyState(icon: Icons.search_off, text: 'No results')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                  itemCount: results.length,
                  itemBuilder: (_, i) => _resultTile(results[i]),
                ),
        ),
      ],
    );
  }

  Widget _resultTile(SearchResult r) {
    final meta = [
      r.channel,
      formatDuration(r.duration),
      if (r.views != null) '${_compact(r.views!)} views',
    ].where((x) => x.isNotEmpty).join(' · ');
    final accent = Theme.of(context).colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MediaThumb(url: r.thumbnail, width: 128, height: 72, icon: Icons.smart_display),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Download video',
                        color: accent,
                        icon: const Icon(Icons.movie),
                        onPressed: () => _start(r.url, MediaKind.video, r.title, r.thumbnail),
                      ),
                      IconButton(
                        tooltip: 'Download audio',
                        color: accent,
                        icon: const Icon(Icons.music_note),
                        onPressed: () => _start(r.url, Settings.instance.audioKind, r.title, r.thumbnail),
                      ),
                      IconButton(
                        tooltip: 'Choose format…',
                        icon: const Icon(Icons.tune),
                        onPressed: () => _askFormat(r.url, r.title, r.thumbnail),
                      ),
                      IconButton(
                        tooltip: 'Open on YouTube',
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () => launchUrl(Uri.parse(r.url), mode: LaunchMode.externalApplication),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _linkTab() {
    final info = _info;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          controller: _link,
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _fetch(),
          decoration: const InputDecoration(
            labelText: 'Video or audio link',
            hintText: 'YouTube, TikTok, Instagram, Facebook, X, SoundCloud…',
            prefixIcon: Icon(Icons.link),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: const Text('Paste')),
            FilledButton.icon(onPressed: _fetch, icon: const Icon(Icons.search), label: const Text('Get info')),
            TextButton.icon(
              onPressed: () => _quickLink(MediaKind.video),
              icon: const Icon(Icons.movie),
              label: const Text('Quick video'),
            ),
            TextButton.icon(
              onPressed: () => _quickLink(Settings.instance.audioKind),
              icon: const Icon(Icons.music_note),
              label: const Text('Quick audio'),
            ),
            if (_fetching) const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 12),
        if (_linkError != null)
          Text("Couldn't read that link: $_linkError", style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (info != null) _previewCard(info),
        const SizedBox(height: 12),
        Text('Works with YouTube and 1,800+ other sites.', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _previewCard(MediaInfo info) {
    final sub = [
      info.site,
      info.uploader,
      formatDuration(info.duration),
      if (info.isPlaylist) 'Playlist · ${info.entryCount} items',
    ].where((x) => x.isNotEmpty).join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info.thumbnail != null)
              Center(
                child: MediaThumb(url: info.thumbnail!, width: 320, height: 180, icon: Icons.image),
              ),
            const SizedBox(height: 10),
            Text(info.title, style: Theme.of(context).textTheme.titleMedium),
            Text(sub, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () =>
                      _start(info.url, MediaKind.video, info.title, info.thumbnail, playlist: info.isPlaylist),
                  icon: const Icon(Icons.movie),
                  label: const Text('Video'),
                ),
                FilledButton.icon(
                  onPressed: () => _start(
                    info.url,
                    Settings.instance.audioKind,
                    info.title,
                    info.thumbnail,
                    playlist: info.isPlaylist,
                  ),
                  icon: const Icon(Icons.music_note),
                  label: const Text('Audio'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _askFormat(
                    info.url,
                    info.title,
                    info.thumbnail,
                    isPlaylist: info.isPlaylist,
                    entryCount: info.entryCount,
                  ),
                  icon: const Icon(Icons.tune),
                  label: const Text('More options'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloadsTab() {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final jobs = manager.jobs;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: FutureBuilder(
                      future: downloadRootLabel(),
                      builder: (_, snap) => Text(
                        'Saved to: ${snap.data ?? '…'}',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (!Platform.isAndroid)
                    IconButton(
                      tooltip: 'Open download folder',
                      icon: const Icon(Icons.folder_open),
                      onPressed: () async => openFolder(await downloadRootLabel()),
                    ),
                  IconButton(
                    tooltip: 'Clear finished',
                    icon: const Icon(Icons.clear_all),
                    onPressed: manager.clearFinished,
                  ),
                ],
              ),
            ),
            Expanded(
              child: jobs.isEmpty
                  ? const EmptyState(icon: Icons.download, text: 'No downloads yet')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      itemCount: jobs.length,
                      itemBuilder: (_, i) => _JobTile(job: jobs[i], manager: manager),
                    ),
            ),
          ],
        );
      },
    );
  }

  static String _compact(int n) {
    if (n >= 1000000000) return '${(n / 1e9).toStringAsFixed(1)}B';
    if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1e3).toStringAsFixed(0)}K';
    return '$n';
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.manager});

  final DownloadJob job;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = job.options.kind;
    final detail = switch (kind) {
      MediaKind.video => qualityLabel(job.options.quality),
      MediaKind.mp3 => '${job.options.bitrate} kbps',
      MediaKind.m4a => 'original quality',
    };
    final icon = kind == MediaKind.video ? Icons.movie : Icons.music_note;
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) {
        final color = switch (job.state) {
          JobState.done => Colors.green,
          JobState.failed => scheme.error,
          _ => scheme.onSurfaceVariant,
        };
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MediaThumb(url: job.thumbnail, width: 96, height: 54, icon: icon),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      Text('${kind.label} · $detail', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: job.finished ? (job.state == JobState.done ? 1 : 0) : job.fraction,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 4),
                      Text(job.status, style: TextStyle(fontSize: 12, color: color), maxLines: 3),
                    ],
                  ),
                ),
                Column(
                  children: [
                    IconButton(
                      tooltip: job.finished ? 'Remove from list' : 'Cancel',
                      icon: Icon(job.finished ? Icons.delete_outline : Icons.close),
                      onPressed: () => job.finished ? manager.remove(job) : manager.cancel(job),
                    ),
                    if (job.state == JobState.done && job.files.isNotEmpty && !Platform.isAndroid)
                      IconButton(
                        tooltip: 'Show in folder',
                        icon: const Icon(Icons.folder_open),
                        onPressed: () => revealFile(job.files.first),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
