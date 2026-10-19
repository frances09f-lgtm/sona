import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-app self-update: checks the latest GitHub release, shows a
/// "Software Update" dialog with release notes, downloads the APK in-app
/// with a progress bar, and hands it to the Android package installer.
/// No browser is ever opened.

const kUpdateRepo = 'frances09f-lgtm/sona';
const kAutoCheckInterval = Duration(hours: 6);
const _kLastCheckKey = 'sona_update_last_check_ms';

class UpdateInfo {
  final String version; // e.g. 1.0.91 (tag without the leading v)
  final String notes; // release body ("What's new")
  final String apkUrl; // browser_download_url of the .apk asset
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.apkUrl,
  });
}

/// Numeric semver-ish compare: returns >0 when a > b. Ignores a leading v
/// and any +build suffix; missing segments count as 0.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('+')
      .first
      .split('.')
      .map((s) => int.tryParse(s) ?? 0)
      .toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

class UpdateChecker {
  UpdateChecker({
    http.Client? client,
    Future<String> Function()? currentVersion,
    Future<void> Function(String apkPath)? installer,
    Future<bool> Function()? canInstall,
    Future<void> Function()? openInstallSettings,
    Future<Directory> Function()? cacheDir,
    DateTime Function()? clock,
    Future<File> Function(
      UpdateInfo info, {
      void Function(int received, int? total)? onProgress,
      Stream<void>? cancelToken,
    })?
    downloader,
  }) : _client = client ?? http.Client(),
       _currentVersion =
           currentVersion ??
           (() async => (await PackageInfo.fromPlatform()).version),
       _installer = installer ?? _nativeInstall,
       _canInstall = canInstall ?? _nativeCanInstall,
       _openInstallSettings = openInstallSettings ?? _nativeOpenSettings,
       _cacheDir = cacheDir ?? getTemporaryDirectory,
       _downloader = downloader,
       _clock = clock ?? DateTime.now;

  static const _channel = MethodChannel('oro/update');
  final http.Client _client;
  final Future<String> Function() _currentVersion;
  final Future<void> Function(String) _installer;
  final Future<bool> Function() _canInstall;
  final Future<void> Function() _openInstallSettings;
  final Future<Directory> Function() _cacheDir;
  final Future<File> Function(
    UpdateInfo info, {
    void Function(int received, int? total)? onProgress,
    Stream<void>? cancelToken,
  })?
  _downloader;
  final DateTime Function() _clock;

  static Future<bool> _nativeCanInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _nativeOpenSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } catch (_) {}
  }

  static Future<void> _nativeInstall(String path) async {
    await _channel.invokeMethod<void>('installApk', {'path': path});
  }

  /// Latest published release, or null when there is nothing newer or the
  /// check fails (offline, rate limit): callers treat null as "no update".
  Future<UpdateInfo?> fetchLatest() async {
    try {
      final res = await _client
          .get(
            Uri.parse(
              'https://api.github.com/repos/$kUpdateRepo/releases/latest',
            ),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'sona-app',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (j['tag_name'] as String? ?? '').trim();
      if (tag.isEmpty) return null;
      String? apk;
      for (final a in (j['assets'] as List? ?? const [])) {
        final name = (a as Map)['name'] as String? ?? '';
        if (name.toLowerCase().endsWith('.apk')) {
          apk = a['browser_download_url'] as String?;
          break;
        }
      }
      if (apk == null) return null;
      final info = UpdateInfo(
        version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
        notes: (j['body'] as String? ?? '').trim(),
        apkUrl: apk,
      );
      final current = await _currentVersion();
      return compareVersions(info.version, current) > 0 ? info : null;
    } catch (_) {
      return null;
    }
  }

  /// Auto check on app start: at most once per [kAutoCheckInterval].
  Future<UpdateInfo?> autoCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_kLastCheckKey) ?? 0;
    if (_clock().millisecondsSinceEpoch - last <
        kAutoCheckInterval.inMilliseconds) {
      return null;
    }
    final info = await fetchLatest();
    // Stamp even failures so an offline stretch does not poll every launch.
    await prefs.setInt(_kLastCheckKey, _clock().millisecondsSinceEpoch);
    return info;
  }

  /// Download the APK to the cache dir with byte progress. [onProgress]
  /// gets (received, total-or-null). Cancel by closing [cancelToken].
  Future<File> download(
    UpdateInfo info, {
    void Function(int received, int? total)? onProgress,
    Stream<void>? cancelToken,
  }) async {
    if (_downloader != null) {
      return _downloader(
        info,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }
    final req = http.Request('GET', Uri.parse(info.apkUrl));
    req.headers['User-Agent'] = 'sona-app';
    final res = await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw StateError('download failed (HTTP ${res.statusCode})');
    }
    final dir = Directory(
      '${(await _cacheDir()).path}${Platform.pathSeparator}updates',
    );
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}sona-${info.version}.apk',
    );
    final sink = file.openWrite();
    var received = 0;
    final sub = cancelToken?.listen((_) => res.stream.listen(null).cancel());
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, res.contentLength);
      }
    } finally {
      await sub?.cancel();
      await sink.flush();
      await sink.close();
    }
    return file;
  }

  Future<void> install(File apk) => _installer(apk.path);
  Future<bool> canInstall() => _canInstall();
  Future<void> openInstallSettings() => _openInstallSettings();
}

/// Auto-prompt entry point called once after the first frame.
Future<void> maybePromptUpdate(
  BuildContext context, {
  UpdateChecker? checker,
}) async {
  if (Platform.environment['FLUTTER_TEST'] == 'true') return;
  final c = checker ?? UpdateChecker();
  final info = await c.autoCheck();
  if (info != null && context.mounted) {
    await showUpdateDialog(context, info, checker: c);
  }
}

/// Manual "Check for updates": always fetches, reports when up to date.
Future<void> checkUpdateManually(
  BuildContext context, {
  UpdateChecker? checker,
}) async {
  if (Platform.environment['FLUTTER_TEST'] == 'true') return;
  final c = checker ?? UpdateChecker();
  final info = await c.fetchLatest();
  if (!context.mounted) return;
  if (info == null) {
    final v = await PackageInfo.fromPlatform()
        .then((p) => p.version)
        .catchError((_) => '');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          v.isEmpty ? 'No update available' : 'Sona $v is up to date',
        ),
      ),
    );
    return;
  }
  await showUpdateDialog(context, info, checker: c);
}

enum _Phase { available, downloading, needsPermission, installing, error }

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  UpdateChecker? checker,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _UpdateDialog(info: info, checker: checker ?? UpdateChecker()),
  );
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  final UpdateChecker checker;
  const _UpdateDialog({required this.info, required this.checker});
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Phase phase = _Phase.available;
  int received = 0;
  int? total;
  String? error;
  final _cancel = StreamController<void>();

  @override
  void dispose() {
    _cancel.close();
    super.dispose();
  }

  Future<void> _start() async {
    // The one Android requirement we cannot skip: "install unknown apps"
    // for Sona. Ask once, explain inside the dialog, then continue.
    if (!await widget.checker.canInstall()) {
      setState(() => phase = _Phase.needsPermission);
      return;
    }
    await _download();
  }

  Future<void> _download() async {
    setState(() {
      phase = _Phase.downloading;
      received = 0;
      total = null;
      error = null;
    });
    try {
      final apk = await widget.checker.download(
        widget.info,
        onProgress: (r, t) => setState(() {
          received = r;
          total = t;
        }),
        cancelToken: _cancel.stream,
      );
      if (!mounted) return;
      setState(() => phase = _Phase.installing);
      // Android always shows its own package-installer confirm screen; that
      // tap is the system's, not ours.
      await widget.checker.install(apk);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        phase = _Phase.error;
        error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const dim = Color(0xFF8A93A6);
    final v = widget.info.version;
    final progress = total != null && total! > 0
        ? (received / total!).clamp(0.0, 1.0)
        : null;
    return AlertDialog(
      backgroundColor: const Color(0xFF151A24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Software Update', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(switch (phase) {
              _Phase.available => 'Sona $v is available',
              _Phase.downloading => 'Downloading sona $v...',
              _Phase.needsPermission => 'One permission needed',
              _Phase.installing => 'Opening installer...',
              _Phase.error => 'Update failed',
            }, style: const TextStyle(color: dim, fontSize: 13)),
          ),
          if (phase == _Phase.downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 4),
            Text(
              total != null
                  ? '${(received / 1e6).toStringAsFixed(1)} / ${(total! / 1e6).toStringAsFixed(1)} MB'
                  : '${(received / 1e6).toStringAsFixed(1)} MB',
              style: const TextStyle(color: dim, fontSize: 11),
            ),
          ],
          if (phase == _Phase.needsPermission)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Android asks once: allow Sona to install app updates. '
                'On the next screen, turn on "Allow from this source", '
                'then come back and tap Update again.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          if (phase == _Phase.error)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error ?? 'Something went wrong.',
                style: const TextStyle(color: Color(0xFFE0654F), fontSize: 12),
              ),
            ),
          if (widget.info.notes.isNotEmpty &&
              phase != _Phase.needsPermission) ...[
            const SizedBox(height: 12),
            const Text(
              "What's new",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Text(
                  widget.info.notes,
                  style: const TextStyle(fontSize: 12, color: dim),
                ),
              ),
            ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        if (phase == _Phase.available) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton(onPressed: _start, child: const Text('Update')),
        ],
        if (phase == _Phase.downloading)
          TextButton(
            onPressed: () {
              _cancel.add(null);
              Navigator.of(context).pop();
            },
            child: const Text('Cancel'),
          ),
        if (phase == _Phase.needsPermission) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await widget.checker.openInstallSettings();
            },
            child: const Text('Open settings'),
          ),
        ],
        if (phase == _Phase.error) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(onPressed: _download, child: const Text('Retry')),
        ],
      ],
    );
  }
}
