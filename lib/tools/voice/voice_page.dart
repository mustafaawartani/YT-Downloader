import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/settings.dart';
import '../../core/ui.dart';
import 'voice_controller.dart';
import 'voice_engine.dart';
import 'voice_sources.dart';

class VoicePage extends StatefulWidget {
  const VoicePage({super.key, required this.controller});

  final VoiceController controller;

  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> {
  VoiceController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    c.engine.stop();
    super.dispose();
  }

  void _onChange() {
    final msg = c.message;
    if (msg != null && mounted) {
      c.message = null;
      toast(context, msg);
    }
  }

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Pick voice notes or an exported chat (.zip)',
      type: FileType.any,
    );
    final paths = files.map((f) => f.path).whereType<String>().toList();
    if (paths.isNotEmpty) await c.importShared(paths);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final items = c.items;
        final pending = items.where((i) => i.state == ItemState.idle || i.state == ItemState.error).length;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Voice notes'),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'Voice language',
                icon: const Icon(Icons.translate),
                initialValue: c.language,
                onSelected: (v) => c.language = v,
                itemBuilder: (_) => [
                  for (final e in voiceLanguages.entries)
                    PopupMenuItem(value: e.key, child: Text('Voice notes in ${e.value}')),
                ],
              ),
            ],
          ),
          floatingActionButton: pending > 1
              ? FloatingActionButton.extended(
                  onPressed: c.transcribeAll,
                  icon: const Icon(Icons.subtitles),
                  label: Text('Transcribe all ($pending)'),
                )
              : null,
          body: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                sliver: SliverList.list(
                  children: [
                    if (!c.ready) _setupCard(),
                    _controls(),
                    if (c.sourceLabel.isNotEmpty) _sourceRow(),
                    if (c.loading)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
              if (items.isEmpty && !c.loading)
                SliverFillRemaining(hasScrollBody: false, child: _empty())
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                  sliver: SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) => _VoiceTile(item: items[i], c: c),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _setupCard() {
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(c.setupText),
            if (c.settingUp) ...[const SizedBox(height: 10), LinearProgressIndicator(value: c.setupProgress)],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: c.settingUp ? null : c.downloadModels,
                icon: const Icon(Icons.download),
                label: const Text('Download offline model'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (c.engine.canBrowseFolder)
              FilledButton.tonalIcon(
                onPressed: () => c.openFolder(),
                onLongPress: () => c.openFolder(forcePicker: true),
                icon: const Icon(Icons.folder),
                label: const Text('Voice notes folder'),
              ),
            FilledButton.tonalIcon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.attach_file),
              label: const Text('Open files / chat .zip'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text('Translate to:', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 10),
            Expanded(
              child: SegmentedButton<TranslateTarget>(
                segments: const [
                  ButtonSegment(value: TranslateTarget.en, label: Text('English')),
                  ButtonSegment(value: TranslateTarget.ar, label: Text('العربية')),
                  ButtonSegment(value: TranslateTarget.both, label: Text('Both')),
                ],
                selected: {c.target},
                onSelectionChanged: (v) => c.target = v.first,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Voice notes in ${voiceLanguages[c.language]} · ' +
              (c.usingGroq
                  ? 'Speech-to-text and translation by Groq (cloud, Whisper large-v3).'
                  : 'On-device speech-to-text. ${c.engine.translationNote}'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _sourceRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          const Icon(Icons.chat_outlined, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(c.sourceLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (c.senders.length > 1)
            DropdownButton<String?>(
              value: c.senderFilter,
              hint: const Text('Everyone'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Everyone')),
                for (final s in c.senders) DropdownMenuItem<String?>(value: s, child: Text(s)),
              ],
              onChanged: c.setSenderFilter,
            ),
        ],
      ),
    );
  }

  Widget _empty() {
    final android = c.engine.canBrowseFolder;
    return EmptyState(
      icon: Icons.record_voice_over,
      text: android
          ? 'In WhatsApp, long-press a voice note → Share → Toolbox.\n\n'
                'For everything from one contact: chat → ⋮ → More → Export chat → Include media → Toolbox.\n\n'
                'Or tap "Voice notes folder" to browse all of them.'
          : 'Open voice notes (.opus, .ogg, .m4a…) or a WhatsApp exported chat (.zip).\n\n'
                'To export from your phone: chat → ⋮ → More → Export chat → Include media.',
    );
  }
}

class _VoiceTile extends StatelessWidget {
  const _VoiceTile({required this.item, required this.c});

  final VoiceItem item;
  final VoiceController c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = [item.sender, item.dateLabel].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final status = switch (item.state) {
      ItemState.queued => 'Waiting…',
      ItemState.decoding => 'Reading audio…',
      ItemState.transcribing => 'Transcribing… ${item.progress}%',
      ItemState.translating => 'Translating…',
      _ => null,
    };
    final playing = c.playingId == item.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title.isEmpty ? item.fileName : title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        item.fileName,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: playing ? 'Stop' : 'Play',
                  icon: Icon(playing ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                  onPressed: () => c.togglePlay(item),
                ),
                if (item.original != null)
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: c.copyText(item)));
                      toast(context, 'Copied');
                    },
                  ),
                if (item.state == ItemState.idle || item.state == ItemState.error)
                  FilledButton(onPressed: () => c.transcribe(item), child: const Text('Transcribe')),
              ],
            ),
            if (status != null) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: item.state == ItemState.transcribing && item.progress > 0 ? item.progress / 100 : null,
              ),
              const SizedBox(height: 4),
              Text(status, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (item.original != null) _block(context, voiceLanguages[c.language] ?? '', item.original!, false),
            if (c.wantEnglish && item.english != null) _block(context, 'English', item.english!, false),
            if (c.wantArabic && item.arabic != null) _block(context, 'العربية', item.arabic!, true),
            if (item.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(item.error!, style: TextStyle(color: scheme.error, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _block(BuildContext context, String label, String text, bool rtl) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
          ),
          SelectableText(text, textDirection: rtl ? TextDirection.rtl : TextDirection.ltr),
        ],
      ),
    );
  }
}
