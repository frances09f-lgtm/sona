import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/update/app_update.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('compareVersions', () {
    test('numeric compare with v prefix and build suffix', () {
      expect(compareVersions('1.0.91', '1.0.90'), greaterThan(0));
      expect(compareVersions('v1.0.90', '1.0.90'), 0);
      expect(compareVersions('1.0.90+90', '1.0.91'), lessThan(0));
      expect(compareVersions('1.1', '1.0.99'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
    });
  });

  group('fetchLatest', () {
    UpdateChecker checker(String body, int code, String current) =>
        UpdateChecker(
          client: MockClient((req) async {
            expect(req.url.path, contains('releases/latest'));
            return http.Response(body, code);
          }),
          currentVersion: () async => current,
        );

    const release = '''
      {"tag_name":"v1.0.91","body":"Sona 1.0.91\\n\\n- in-app updates",
       "assets":[{"name":"Sona.apk","browser_download_url":"https://github.com/x/Sona.apk"},
                  {"name":"notes.txt","browser_download_url":"https://github.com/x/notes.txt"}]}''';

    test('returns info when the release is newer', () async {
      final info = await checker(release, 200, '1.0.90').fetchLatest();
      expect(info, isNotNull);
      expect(info!.version, '1.0.91');
      expect(info.notes, contains('in-app updates'));
      expect(info.apkUrl, endsWith('Sona.apk'));
    });

    test(
      'null when not newer, when the request fails, or no apk asset',
      () async {
        expect(await checker(release, 200, '1.0.91').fetchLatest(), isNull);
        expect(
          await checker('rate limited', 403, '1.0.90').fetchLatest(),
          isNull,
        );
        expect(
          await checker(
            '{"tag_name":"v1.0.91","body":"","assets":[]}',
            200,
            '1.0.90',
          ).fetchLatest(),
          isNull,
        );
      },
    );
  });

  group('fetchLatestDetailed', () {
    UpdateChecker checker(String body, int code, String current) =>
        UpdateChecker(
          client: MockClient((req) async => http.Response(body, code)),
          currentVersion: () async => current,
        );

    const release = '''
      {"tag_name":"v1.0.91","body":"notes",
       "assets":[{"name":"Sona.apk","browser_download_url":"https://github.com/x/Sona.apk"}]}''';

    test('available on newer release', () async {
      final r = await checker(release, 200, '1.0.90').fetchLatestDetailed();
      expect(r.status, UpdateCheckStatus.updateAvailable);
      expect(r.info!.version, '1.0.91');
    });

    test('upToDate when nothing newer', () async {
      final r = await checker(release, 200, '1.0.91').fetchLatestDetailed();
      expect(r.status, UpdateCheckStatus.upToDate);
      expect(r.info, isNull);
    });

    test('failed on non-200, bad payload, missing apk, offline', () async {
      expect(
        (await checker('rate limited', 403, '1.0.90').fetchLatestDetailed())
            .status,
        UpdateCheckStatus.failed,
      );
      expect(
        (await checker('not json', 200, '1.0.90').fetchLatestDetailed())
            .status,
        UpdateCheckStatus.failed,
      );
      expect(
        (await checker('{"tag_name":"v9.9.9","body":"","assets":[]}', 200,
                    '1.0.90')
                .fetchLatestDetailed())
            .status,
        UpdateCheckStatus.failed,
      );
      final offline = UpdateChecker(
        client: MockClient((_) async => throw const SocketException('down')),
        currentVersion: () async => '1.0.90',
      );
      expect(
        (await offline.fetchLatestDetailed()).status,
        UpdateCheckStatus.failed,
      );
      // Legacy contract unchanged: fetchLatest stays null on failure.
      expect(await offline.fetchLatest(), isNull);
    });
  });

  group('autoCheck interval', () {
    test('skips within 6h, stamps even on failure', () async {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      final now = DateTime(2026, 10, 20, 0, 30);
      final c = UpdateChecker(
        client: MockClient((_) async {
          calls++;
          return http.Response('nope', 500);
        }),
        currentVersion: () async => '1.0.90',
        clock: () => now,
      );
      expect(await c.autoCheck(), isNull); // stamps despite failure
      expect(calls, 1);
      expect(await c.autoCheck(), isNull); // inside 6h: no second call
      expect(calls, 1);
      final later = UpdateChecker(
        client: MockClient((_) async {
          calls++;
          return http.Response('nope', 500);
        }),
        currentVersion: () async => '1.0.90',
        clock: () => now.add(const Duration(hours: 7)),
      );
      expect(await later.autoCheck(), isNull);
      expect(calls, 2);
    });
  });

  group('download', () {
    test('streams bytes with progress and returns the file', () async {
      final bytes = List<int>.generate(5000, (i) => i % 251);
      final tmp = await Directory.systemTemp.createTemp('upd');
      final seen = <(int, int?)>[];
      final c = UpdateChecker(
        client: MockClient.streaming((req, _) async {
          return http.StreamedResponse(
            Stream.value(bytes),
            200,
            contentLength: bytes.length,
          );
        }),
        cacheDir: () async => tmp,
      );
      const info = UpdateInfo(
        version: '1.0.91',
        notes: '',
        apkUrl: 'https://x/Sona.apk',
      );
      final f = await c.download(info, onProgress: (r, t) => seen.add((r, t)));
      expect(await f.length(), bytes.length);
      expect(f.path, contains('sona-1.0.91.apk'));
      expect(seen.last, (bytes.length, bytes.length));
      await tmp.delete(recursive: true);
    });
  });

  group('dialog', () {
    const info = UpdateInfo(
      version: '1.0.91',
      notes: 'Sona 1.0.91\n\n- in-app updates\n- chart fixes',
      apkUrl: 'https://x/Sona.apk',
    );

    testWidgets('available state shows version, notes, Update button', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () => showUpdateDialog(
                ctx,
                info,
                checker: UpdateChecker(currentVersion: () async => '1.0.90'),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Software Update'), findsOneWidget);
      expect(find.text('Sona 1.0.91 is available'), findsOneWidget);
      expect(find.text("What's new"), findsOneWidget);
      expect(find.textContaining('in-app updates'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
    });

    testWidgets('Update without install permission asks for it in-app', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () => showUpdateDialog(
                ctx,
                info,
                checker: UpdateChecker(
                  currentVersion: () async => '1.0.90',
                  canInstall: () async => false,
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Update'));
      await t.pumpAndSettle();
      expect(find.text('One permission needed'), findsOneWidget);
      expect(find.textContaining('Allow from this source'), findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
    });

    testWidgets('download progress then install intent, never a browser', (
      t,
    ) async {
      // No real file IO here: widget tests run in fake async,
      // where real IO completions never arrive. Fake path, fake installer.
      final installed = <String>[];
      final checker = UpdateChecker(
        currentVersion: () async => '1.0.90',
        canInstall: () async => true,
        downloader: (info, {onProgress, cancelToken}) async {
          onProgress?.call(1000, 2000);
          await Future<void>.delayed(Duration.zero);
          onProgress?.call(2000, 2000);
          return File('/tmp/fake-sona-1.0.91.apk');
        },
        installer: (path) async => installed.add(path),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () => showUpdateDialog(ctx, info, checker: checker),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Update'));
      await t.pump(); // permission check
      await t.pump(); // download starts
      expect(find.text('Downloading sona 1.0.91...'), findsOneWidget);
      // The determinate bar still animates; use bounded pumps, not settle.
      for (var i = 0; i < 20 && installed.isEmpty; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(installed, hasLength(1));
      expect(installed.single, contains('sona-1.0.91.apk'));
    });
  });
}
