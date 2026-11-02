import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/paths.dart';
import 'core/settings.dart';
import 'core/ui.dart';
import 'tools/downloader/download_manager.dart';
import 'tools/downloader/downloader_page.dart';
import 'tools/downloader/engine.dart';
import 'tools/downloader/ytdlp.dart';
import 'tools/voice/voice_controller.dart';
import 'tools/voice/voice_engine.dart';
import 'tools/voice/voice_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.instance.load();
  runApp(const ToolboxApp());
}

/// Everything shared into the app from other apps (Android share sheet).
class ShareHub {
  static const _ch = MethodChannel('toolbox/share');
  final _files = StreamController<List<String>>.broadcast();
  final _urls = StreamController<String>.broadcast();

  Stream<List<String>> get files => _files.stream;
  Stream<String> get urls => _urls.stream;

  void start() {
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async => _handle(call.arguments as Map?));
    _ch.invokeMapMethod<String, dynamic>('takePending').then(_handle);
  }

  void _handle(Map? m) {
    if (m == null) return;
    final files = (m['files'] as List?)?.cast<String>() ?? const [];
    final text = m['text'] as String?;
    if (files.isNotEmpty) _files.add(files);
    if (text != null && text.trim().isNotEmpty) {
      final url = RegExp(r'https?://\S+').firstMatch(text)?.group(0);
      if (url != null) _urls.add(url);
    }
  }
}

class ToolboxApp extends StatefulWidget {
  const ToolboxApp({super.key});

  @override
  State<ToolboxApp> createState() => _ToolboxAppState();
}

class _ToolboxAppState extends State<ToolboxApp> {
  final _nav = GlobalKey<NavigatorState>();
  final _share = ShareHub();
  late final DownloadManager downloads = DownloadManager(YtDlpEngine.create());
  late final VoiceController voice = VoiceController(VoiceEngine.create());

  @override
  void initState() {
    super.initState();
    _share.files.listen((paths) {
      voice.importShared(paths);
      _open(VoicePage(controller: voice));
    });
    _share.urls.listen((url) => _open(DownloaderPage(manager: downloads, initialUrl: url)));
    _share.start();
    _autoUpdateEngine();
  }

  /// Sites change often; keep yt-dlp fresh (Android: in-app engine; Windows: yt-dlp.exe -U).
  Future<void> _autoUpdateEngine() async {
    final s = Settings.instance;
    final age = DateTime.now().millisecondsSinceEpoch - s.lastEngineUpdate;
    if (age < const Duration(days: 3).inMilliseconds) return;
    try {
      await downloads.engine.update();
      s.lastEngineUpdate = DateTime.now().millisecondsSinceEpoch;
    } catch (_) {
      // Offline or read-only install: try again next launch.
    }
  }

  void _open(Widget page) {
    final nav = _nav.currentState;
    if (nav == null) return;
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    const seed = Colors.deepPurple;
    return MaterialApp(
      title: appName,
      navigatorKey: _nav,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(downloads: downloads, voice: voice),
    );
  }
}

class ToolInfo {
  const ToolInfo(this.title, this.subtitle, this.icon, this.color, this.builder, {this.badge});
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Widget Function() builder;
  final Listenable? badge;
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.downloads, required this.voice});

  final DownloadManager downloads;
  final VoiceController voice;

  @override
  Widget build(BuildContext context) {
    final tools = [
      ToolInfo(
        'Downloader',
        'Video & audio from YouTube, TikTok, Instagram and 1,800+ sites',
        Icons.download_for_offline,
        Colors.red,
        () => DownloaderPage(manager: downloads),
        badge: downloads,
      ),
      ToolInfo(
        'Voice notes',
        'Transcribe WhatsApp voice notes and translate them to English / Arabic',
        Icons.record_voice_over,
        Colors.teal,
        () => VoicePage(controller: voice),
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName, style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsPage(downloads: downloads, voice: voice),
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final cols = (box.maxWidth / 340).floor().clamp(1, 4);
          return GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: cols,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: cols == 1 ? 2.8 : 1.8,
            children: [for (final t in tools) _ToolCard(tool: t, downloads: downloads)],
          );
        },
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.tool, required this.downloads});

  final ToolInfo tool;
  final DownloadManager downloads;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => tool.builder())),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: tool.color.withValues(alpha: 0.15),
                child: Icon(tool.icon, color: tool.color, size: 30),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tool.title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(tool.subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 3),
                  ],
                ),
              ),
              if (tool.badge != null)
                ListenableBuilder(
                  listenable: tool.badge!,
                  builder: (_, _) => downloads.activeCount > 0
                      ? Badge(label: Text('${downloads.activeCount}'))
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.downloads, required this.voice});

  final DownloadManager downloads;
  final VoiceController voice;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Settings get s => Settings.instance;
  String _version = '…';
  bool _updating = false;
  late final _groqKey = TextEditingController(text: s.groqKey ?? '');
  bool _showKey = false;

  YtDlpEngine get engine => widget.downloads.engine;

  @override
  void initState() {
    super.initState();
    engine
        .version()
        .then((v) {
          if (mounted) setState(() => _version = v);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _groqKey.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    setState(() => _updating = true);
    try {
      final msg = await engine.update();
      s.lastEngineUpdate = DateTime.now().millisecondsSinceEpoch;
      _version = await engine.version();
      if (mounted) toast(context, msg);
    } catch (e) {
      if (mounted) toast(context, 'Update failed: $e');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _pickDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose download folder');
    if (dir != null) setState(() => s.downloadDir = dir);
  }

  Future<void> _saveKey() async {
    final key = _groqKey.text.trim();
    s.groqKey = key.isEmpty ? null : key;
    if (key.isEmpty) {
      toast(context, 'Groq key removed - using on-device speech-to-text');
      return;
    }
    toast(context, 'Checking key…');
    final ok = await widget.voice.checkGroqKey();
    if (mounted) toast(context, ok ? 'Groq key works ✔' : 'Groq rejected this key - check it and try again');
  }

  @override
  Widget build(BuildContext context) {
    final tools = Platform.isAndroid
        ? null
        : {
            'yt-dlp': findTool('yt-dlp'),
            'FFmpeg': findTool('ffmpeg'),
            'Deno': findTool('deno'),
            'whisper-cli': findTool('whisper-cli'),
          };
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _section('Voice notes · speech-to-text', [
              const Text(
                'For the best accuracy, add a free Groq API key (console.groq.com → API Keys). '
                'Voice notes are then sent to Groq and transcribed with Whisper large-v3, which is much more '
                'accurate than the small on-device model. Without a key, everything stays on this device.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _groqKey,
                obscureText: !_showKey,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Groq API key',
                  hintText: 'gsk_…',
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Paste',
                        icon: const Icon(Icons.content_paste),
                        onPressed: () async {
                          final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
                          if (t != null) _groqKey.text = t;
                        },
                      ),
                      IconButton(
                        tooltip: _showKey ? 'Hide' : 'Show',
                        icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(onPressed: _saveKey, child: const Text('Save key')),
              ),
              if (s.groqKey != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use Groq (cloud, most accurate)'),
                  subtitle: Text(
                    s.useGroq
                        ? 'Audio is sent to Groq. Translation also uses Groq.'
                        : 'Off: speech-to-text runs on this device (offline, less accurate).',
                  ),
                  value: s.useGroq,
                  onChanged: (v) => s.useGroq = v,
                ),
            ]),
            _section('Downloads', [
              FutureBuilder(
                future: downloadRoot(),
                builder: (_, snap) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder),
                  title: const Text('Download folder'),
                  subtitle: Text(snap.data ?? '…'),
                  trailing: Platform.isAndroid ? null : TextButton(onPressed: _pickDir, child: const Text('Change')),
                ),
              ),
              _dropdown('Default video quality', s.videoQuality, {
                for (final q in videoQualities) q: qualityLabel(q),
              }, (v) => s.videoQuality = v),
              _dropdown('Default MP3 bitrate', s.mp3Bitrate, {
                for (final b in mp3Bitrates) b: '$b kbps',
              }, (v) => s.mp3Bitrate = v),
              _dropdown('Quick audio button saves as', s.audioKind.name, {
                'mp3': 'MP3',
                'm4a': 'M4A (original, no re-encoding)',
              }, (v) => s.audioKind = MediaKindX.parse(v)),
            ]),
            _section('Download engine', [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.memory),
                title: Text('yt-dlp $_version'),
                subtitle: const Text('Updates itself every few days. Tap Update if a site stops working.'),
                trailing: _updating
                    ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(onPressed: _update, child: const Text('Update')),
              ),
              if (tools != null)
                for (final e in tools.entries)
                  Row(
                    children: [
                      Icon(
                        e.value != null ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: e.value != null ? Colors.green : Colors.amber,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text('${e.key}: ${e.value ?? 'missing'}', style: const TextStyle(fontSize: 12))),
                    ],
                  ),
            ]),
            _section('About', [
              const Text(
                'Only download content you own or have permission to download, and respect each '
                "platform's terms and copyright law.",
                style: TextStyle(fontSize: 12),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );

  Widget _dropdown(String label, String value, Map<String, String> options, void Function(String) onChanged) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) => v == null ? null : onChanged(v),
    ),
  );
}
