import 'dart:io';

import 'package:flutter/material.dart';

import 'paths.dart';

void toast(BuildContext context, String msg, {SnackBarAction? action}) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(msg), action: action, duration: const Duration(seconds: 3)));
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: c),
            ),
          ],
        ),
      ),
    );
  }
}

/// Network thumbnail with a fixed box and a fallback icon.
class MediaThumb extends StatelessWidget {
  const MediaThumb({super.key, required this.url, required this.width, required this.height, required this.icon});

  final String? url;
  final double width;
  final double height;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    final fallback = Center(child: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant));
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        height: height,
        color: bg,
        child: url == null ? fallback : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

Future<String> downloadRootLabel() => downloadRoot();

Future<void> openFolder(String path) async {
  await Directory(path).create(recursive: true);
  if (Platform.isWindows) {
    await Process.start('explorer', [path]);
  } else if (Platform.isMacOS) {
    await Process.start('open', [path]);
  } else {
    await Process.start('xdg-open', [path]);
  }
}

Future<void> revealFile(String path) async {
  if (Platform.isWindows) {
    await Process.start('explorer', ['/select,', path]);
  } else {
    await openFolder(File(path).parent.path);
  }
}

Future<void> openFile(String path) async {
  if (Platform.isWindows) {
    await Process.start('cmd', ['/c', 'start', '', path]);
  } else if (Platform.isMacOS) {
    await Process.start('open', [path]);
  } else {
    await Process.start('xdg-open', [path]);
  }
}
