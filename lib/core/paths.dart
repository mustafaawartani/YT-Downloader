import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'settings.dart';

const appName = 'Toolbox';
const appFolderName = 'Toolbox';

/// Helper programs ship in a "tools" folder next to the app's .exe on Windows.
Directory get bundledToolsDir => Directory(p.join(File(Platform.resolvedExecutable).parent.path, 'tools'));

/// Finds a helper program: bundled tools folder first, then the system PATH.
String? findTool(String name) {
  final exe = Platform.isWindows ? '$name.exe' : name;
  final bundled = File(p.join(bundledToolsDir.path, exe));
  if (bundled.existsSync()) return bundled.path;
  final pathVar = Platform.environment['PATH'] ?? '';
  for (final dir in pathVar.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    final f = File(p.join(dir, exe));
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Desktop: user's choice or ~/Downloads/Toolbox. Android: shown as a label only
/// (files go to the public Download/Toolbox folder through MediaStore).
Future<String> downloadRoot() async {
  if (Platform.isAndroid) return 'Download/$appFolderName';
  final custom = Settings.instance.downloadDir;
  if (custom != null && custom.isNotEmpty) return custom;
  Directory? dl;
  try {
    dl = await getDownloadsDirectory();
  } catch (_) {}
  final base =
      dl?.path ?? p.join(Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.', 'Downloads');
  return p.join(base, appFolderName);
}

/// App-private folder for models and caches.
Future<Directory> appDataDir(String sub) async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, sub));
  await dir.create(recursive: true);
  return dir;
}
