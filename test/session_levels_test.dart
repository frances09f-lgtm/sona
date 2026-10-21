import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/session_levels.dart';
import 'package:sona/market_data/models.dart';

import 'candle_chart_test.dart' show loadFonts;

Candle c(DateTime t, double o, double h, double l, double cl) =>
    Candle(time: t, open: o, high: h, low: l, close: cl);

void main() {
  test('US DST boundaries (2026: Mar 8 - Nov 1)', () {
    expect(isUsDaylightTime(DateTime.utc(2026, 3, 7, 12)), isFalse);
    expect(isUsDaylightTime(DateTime.utc(2026, 3, 8, 8)), isTrue);
    expect(isUsDaylightTime(DateTime.utc(2026, 10, 21, 12)), isTrue);
    expect(isUsDaylightTime(DateTime.utc(2026, 11, 1, 7)), isFalse);
    expect(nyCloseHourUtc(DateTime.utc(2026, 10, 21)), 21);
    expect(nyCloseHourUtc(DateTime.utc(2026, 12, 15)), 22);
  });

  test('NY day key splits at 5pm ET (21:00 UTC in EDT)', () {
    // Wednesday Oct 21 2026.
    expect(nyDayKey(DateTime.utc(2026, 10, 21, 20, 59)),
        DateTime.utc(2026, 10, 20));
    expect(nyDayKey(DateTime.utc(2026, 10, 21, 21, 0)),
        DateTime.utc(2026, 10, 21));
  });

  test('NY week key opens Sunday 5pm ET', () {
    // Sun Oct 18 2026 22:00 UTC is after the 21:00 open -> week of Oct 18.
    expect(nyWeekKey(DateTime.utc(2026, 10, 18, 22)),
        DateTime.utc(2026, 10, 18));
    // Sun Oct 18 20:00 UTC is still the PREVIOUS week (opened Oct 11).
    expect(nyWeekKey(DateTime.utc(2026, 10, 18, 20)),
        DateTime.utc(2026, 10, 11));
  });

  test('previousDayHL returns last complete NY day high/low', () {
    final now = DateTime.utc(2026, 10, 21, 16, 0); // Wed, in current day
    final candles = <Candle>[
      // Previous NY day = Oct 20 21:00 UTC .. Oct 21 21:00 UTC? No:
      // day key Oct 20 = Oct 20 21:00 -> Oct 21 21:00... key Oct 20 means
      // times from Oct 20 21:00 UTC exclusive... use simple hours:
      c(DateTime.utc(2026, 10, 19, 22, 0), 100, 110, 95, 105), // key Oct 19
      c(DateTime.utc(2026, 10, 20, 10, 0), 105, 112, 90, 100), // key Oct 19
      c(DateTime.utc(2026, 10, 20, 22, 0), 100, 120, 98, 110), // key Oct 20
      c(DateTime.utc(2026, 10, 21, 9, 0), 110, 125, 108, 120), // key Oct 20
      c(DateTime.utc(2026, 10, 21, 15, 0), 120, 130, 118, 128), // key Oct 20
    ];
    // current day key at 16:00 UTC Oct 21 = Oct 20 (closes 21:00 UTC).
    // previous complete day = key Oct 19: candles 19 22:00, 20 10:00.
    final hl = previousDayHL(candles, now: now);
    expect(hl, isNotNull);
    expect(hl!.$1, 112);
    expect(hl.$2, 90);
  });

  test('previousWeekHL returns last complete week high/low', () {
    final now = DateTime.utc(2026, 10, 21, 16, 0); // week opened Oct 18
    final candles = <Candle>[
      c(DateTime.utc(2026, 10, 13, 12, 0), 100, 140, 80, 120), // wk Oct 11
      c(DateTime.utc(2026, 10, 15, 12, 0), 120, 150, 110, 130), // wk Oct 11
      c(DateTime.utc(2026, 10, 20, 12, 0), 130, 135, 125, 132), // wk Oct 18
    ];
    final hl = previousWeekHL(candles, now: now);
    expect(hl, isNotNull);
    expect(hl!.$1, 150);
    expect(hl.$2, 80);
  });

  test('sessionsAt maps UTC hours to sessions, weekends closed', () {
    expect(sessionsAt(DateTime.utc(2026, 10, 21, 3)), [ChartSession.asia]);
    expect(sessionsAt(DateTime.utc(2026, 10, 21, 8, 30)),
        [ChartSession.asia, ChartSession.london]);
    expect(sessionsAt(DateTime.utc(2026, 10, 21, 10)), [ChartSession.london]);
    expect(sessionsAt(DateTime.utc(2026, 10, 21, 14)),
        [ChartSession.london, ChartSession.newYork]);
    expect(sessionsAt(DateTime.utc(2026, 10, 21, 20)), [ChartSession.newYork]);
    expect(sessionsAt(DateTime.utc(2026, 10, 21, 23)), isEmpty);
    expect(sessionsAt(DateTime.utc(2026, 10, 24, 14)), isEmpty); // Saturday
  });

  testWidgets('chart renders session shading + PD/PW levels (golden)',
      (t) async {
    await loadFonts();
    // Wed Oct 21 2026 00:00 UTC + 96 x 15min = 24h: Asia, London, NY bands.
    final base = DateTime.utc(2026, 10, 21);
    double px = 4120;
    final candles = List.generate(96, (i) {
      final o = px;
      final cl = o + ((i % 7) - 3) * 1.3;
      px = cl;
      return Candle(
        time: base.add(Duration(minutes: 15 * i)),
        open: o,
        high: o + 2.5 + (i % 3),
        low: o - 2.5 - (i % 2),
        close: cl,
      );
    });
    final painter = CandlePainter(
      candles: candles,
      sessionShading: true,
      prevDayHL: (4158.20, 4104.60),
      prevWeekHL: (4171.45, 4098.10),
    );
    await t.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: const Color(0xFF0F1115),
            body: Center(
              child: SizedBox(
                width: 380,
                height: 300,
                child: CustomPaint(size: const Size(380, 300), painter: painter),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await expectLater(
      find.byType(CustomPaint).last,
      matchesGoldenFile('goldens/chart_sessions_prevlevels.png'),
    );
    expect(t.takeException(), isNull);
  });
}
