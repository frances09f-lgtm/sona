import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/practice_screen.dart';

/// Wick investigation capture: renders the practice screen mid-replay
/// (the state in the user's Nov 2 screenshot) with (A) REAL market 15m
/// bars from Oct 30 and (B) flat/degenerate bars matching what the phone
/// showed. No-op unless WICK_CAPTURE=1.
  List<Candle> realFixture() {
    return [
      Candle(time: DateTime.utc(2026,10,30,0,0), open: 4019.80, high: 4021.50, low: 4015.30, close: 4021.40),
      Candle(time: DateTime.utc(2026,10,30,0,15), open: 4021.40, high: 4024.90, low: 4018.30, close: 4023.70),
      Candle(time: DateTime.utc(2026,10,30,0,30), open: 4023.30, high: 4029.00, low: 4017.10, close: 4027.60),
      Candle(time: DateTime.utc(2026,10,30,0,45), open: 4027.80, high: 4030.80, low: 4018.80, close: 4019.20),
      Candle(time: DateTime.utc(2026,10,30,1,0), open: 4015.30, high: 4017.90, low: 4006.90, close: 4011.60),
      Candle(time: DateTime.utc(2026,10,30,1,15), open: 4012.50, high: 4021.10, low: 4008.70, close: 4020.40),
      Candle(time: DateTime.utc(2026,10,30,1,30), open: 4014.80, high: 4018.00, low: 4007.20, close: 4011.00),
      Candle(time: DateTime.utc(2026,10,30,1,45), open: 4010.70, high: 4020.60, low: 4006.40, close: 4017.80),
      Candle(time: DateTime.utc(2026,10,30,2,0), open: 4018.30, high: 4023.80, low: 4016.20, close: 4022.30),
      Candle(time: DateTime.utc(2026,10,30,2,15), open: 4022.10, high: 4024.70, low: 4015.00, close: 4015.30),
      Candle(time: DateTime.utc(2026,10,30,2,30), open: 4013.30, high: 4015.60, low: 4011.50, close: 4012.10),
      Candle(time: DateTime.utc(2026,10,30,2,45), open: 4011.70, high: 4012.70, low: 4007.10, close: 4008.20),
      Candle(time: DateTime.utc(2026,10,30,3,0), open: 4007.90, high: 4009.80, low: 4002.90, close: 4003.40),
      Candle(time: DateTime.utc(2026,10,30,3,15), open: 4003.60, high: 4012.00, low: 4002.00, close: 4011.10),
      Candle(time: DateTime.utc(2026,10,30,3,30), open: 4010.80, high: 4010.80, low: 4003.10, close: 4004.30),
      Candle(time: DateTime.utc(2026,10,30,3,45), open: 4002.10, high: 4004.10, low: 4000.10, close: 4004.00),
      Candle(time: DateTime.utc(2026,10,30,4,0), open: 4003.80, high: 4004.20, low: 3997.00, close: 4002.70),
      Candle(time: DateTime.utc(2026,10,30,4,15), open: 4002.70, high: 4003.80, low: 4000.40, close: 4003.80),
      Candle(time: DateTime.utc(2026,10,30,4,30), open: 4003.90, high: 4005.80, low: 3998.50, close: 4000.80),
      Candle(time: DateTime.utc(2026,10,30,4,45), open: 4000.60, high: 4006.40, low: 4000.30, close: 4005.60),
      Candle(time: DateTime.utc(2026,10,30,5,0), open: 4007.80, high: 4011.40, low: 4006.30, close: 4008.80),
      Candle(time: DateTime.utc(2026,10,30,5,15), open: 4008.50, high: 4016.20, low: 4008.00, close: 4016.10),
      Candle(time: DateTime.utc(2026,10,30,5,30), open: 4015.90, high: 4021.20, low: 4011.50, close: 4011.80),
      Candle(time: DateTime.utc(2026,10,30,5,45), open: 4012.00, high: 4013.70, low: 3997.70, close: 4001.20),
      Candle(time: DateTime.utc(2026,10,30,6,0), open: 4001.30, high: 4002.70, low: 3996.00, close: 3998.20),
      Candle(time: DateTime.utc(2026,10,30,6,15), open: 3998.40, high: 4003.20, low: 3995.70, close: 4002.00),
      Candle(time: DateTime.utc(2026,10,30,6,30), open: 4002.10, high: 4003.40, low: 3992.50, close: 3996.30),
      Candle(time: DateTime.utc(2026,10,30,6,45), open: 3996.20, high: 3996.60, low: 3987.60, close: 3992.30),
      Candle(time: DateTime.utc(2026,10,30,7,0), open: 3992.30, high: 3995.00, low: 3988.90, close: 3995.00),
      Candle(time: DateTime.utc(2026,10,30,7,15), open: 3994.90, high: 3997.60, low: 3991.90, close: 3994.20),
      Candle(time: DateTime.utc(2026,10,30,7,30), open: 3994.30, high: 3995.20, low: 3988.70, close: 3990.20),
      Candle(time: DateTime.utc(2026,10,30,7,45), open: 3990.00, high: 3990.90, low: 3974.70, close: 3984.60),
      Candle(time: DateTime.utc(2026,10,30,8,0), open: 3984.30, high: 3996.00, low: 3982.20, close: 3992.90),
      Candle(time: DateTime.utc(2026,10,30,8,15), open: 3992.60, high: 3999.90, low: 3992.40, close: 3995.40),
      Candle(time: DateTime.utc(2026,10,30,8,30), open: 3995.00, high: 3999.60, low: 3994.70, close: 3998.10),
      Candle(time: DateTime.utc(2026,10,30,8,45), open: 4003.30, high: 4009.20, low: 4003.10, close: 4007.20),
      Candle(time: DateTime.utc(2026,10,30,9,0), open: 4006.50, high: 4008.60, low: 4000.40, close: 4001.20),
      Candle(time: DateTime.utc(2026,10,30,9,15), open: 4001.60, high: 4004.00, low: 3999.70, close: 4001.00),
      Candle(time: DateTime.utc(2026,10,30,9,30), open: 4000.60, high: 4002.20, low: 3998.20, close: 3999.70),
      Candle(time: DateTime.utc(2026,10,30,9,45), open: 3999.40, high: 4003.10, low: 3997.40, close: 4002.10),
      Candle(time: DateTime.utc(2026,10,30,10,0), open: 4001.70, high: 4002.00, low: 3992.80, close: 3993.00),
      Candle(time: DateTime.utc(2026,10,30,10,15), open: 3992.60, high: 3997.00, low: 3990.70, close: 3990.70),
      Candle(time: DateTime.utc(2026,10,30,10,30), open: 3990.80, high: 3994.00, low: 3989.80, close: 3990.10),
      Candle(time: DateTime.utc(2026,10,30,10,45), open: 3989.80, high: 3990.10, low: 3984.20, close: 3989.60),
      Candle(time: DateTime.utc(2026,10,30,11,0), open: 3989.60, high: 3992.90, low: 3986.70, close: 3987.20),
      Candle(time: DateTime.utc(2026,10,30,11,15), open: 3987.10, high: 3987.10, low: 3976.60, close: 3984.70),
      Candle(time: DateTime.utc(2026,10,30,11,30), open: 3984.40, high: 3989.20, low: 3979.90, close: 3980.80),
      Candle(time: DateTime.utc(2026,10,30,11,45), open: 3980.90, high: 3981.60, low: 3973.70, close: 3976.50),
      Candle(time: DateTime.utc(2026,10,30,12,0), open: 3975.80, high: 3977.50, low: 3969.40, close: 3970.40),
      Candle(time: DateTime.utc(2026,10,30,12,15), open: 3970.30, high: 3977.50, low: 3968.50, close: 3972.80),
      Candle(time: DateTime.utc(2026,10,30,12,30), open: 3972.90, high: 3980.10, low: 3964.40, close: 3966.70),
      Candle(time: DateTime.utc(2026,10,30,12,45), open: 3966.90, high: 3968.90, low: 3963.00, close: 3963.60),
      Candle(time: DateTime.utc(2026,10,30,13,0), open: 3963.60, high: 3964.80, low: 3946.00, close: 3954.10),
      Candle(time: DateTime.utc(2026,10,30,13,15), open: 3954.20, high: 3957.30, low: 3949.70, close: 3953.70),
      Candle(time: DateTime.utc(2026,10,30,13,30), open: 3954.00, high: 3956.00, low: 3933.40, close: 3937.90),
      Candle(time: DateTime.utc(2026,10,30,13,45), open: 3937.80, high: 3940.60, low: 3924.70, close: 3929.30),
      Candle(time: DateTime.utc(2026,10,30,14,0), open: 3929.00, high: 3930.20, low: 3913.40, close: 3914.40),
      Candle(time: DateTime.utc(2026,10,30,14,15), open: 3914.40, high: 3918.20, low: 3900.90, close: 3914.70),
      Candle(time: DateTime.utc(2026,10,30,14,30), open: 3915.90, high: 3926.60, low: 3907.70, close: 3925.90),
      Candle(time: DateTime.utc(2026,10,30,14,45), open: 3926.20, high: 3928.20, low: 3918.90, close: 3927.20),
      Candle(time: DateTime.utc(2026,10,30,15,0), open: 3926.90, high: 3933.20, low: 3917.50, close: 3919.80),
      Candle(time: DateTime.utc(2026,10,30,15,15), open: 3919.80, high: 3923.00, low: 3915.60, close: 3916.70),
      Candle(time: DateTime.utc(2026,10,30,15,30), open: 3916.60, high: 3916.70, low: 3907.50, close: 3909.10),
      Candle(time: DateTime.utc(2026,10,30,15,45), open: 3908.90, high: 3909.90, low: 3905.70, close: 3907.70),
      Candle(time: DateTime.utc(2026,10,30,16,0), open: 3907.00, high: 3912.60, low: 3904.80, close: 3905.30),
      Candle(time: DateTime.utc(2026,10,30,16,15), open: 3905.40, high: 3909.90, low: 3903.90, close: 3909.60),
      Candle(time: DateTime.utc(2026,10,30,16,30), open: 3909.50, high: 3911.20, low: 3902.70, close: 3904.50),
      Candle(time: DateTime.utc(2026,10,30,16,45), open: 3904.20, high: 3907.60, low: 3901.40, close: 3905.80),
      Candle(time: DateTime.utc(2026,10,30,17,0), open: 3905.50, high: 3906.20, low: 3897.70, close: 3898.40),
      Candle(time: DateTime.utc(2026,10,30,17,15), open: 3898.60, high: 3903.50, low: 3895.10, close: 3899.00),
      Candle(time: DateTime.utc(2026,10,30,17,30), open: 3899.20, high: 3900.10, low: 3889.40, close: 3893.50),
      Candle(time: DateTime.utc(2026,10,30,17,45), open: 3893.40, high: 3894.50, low: 3888.20, close: 3893.10),
      Candle(time: DateTime.utc(2026,10,30,18,0), open: 3893.00, high: 3893.20, low: 3886.00, close: 3889.60),
      Candle(time: DateTime.utc(2026,10,30,18,15), open: 3889.70, high: 3891.20, low: 3885.90, close: 3889.40),
      Candle(time: DateTime.utc(2026,10,30,18,30), open: 3889.10, high: 3894.00, low: 3888.30, close: 3891.80),
      Candle(time: DateTime.utc(2026,10,30,18,45), open: 3891.80, high: 3893.70, low: 3887.00, close: 3889.20),
      Candle(time: DateTime.utc(2026,10,30,19,0), open: 3889.30, high: 3890.30, low: 3885.60, close: 3887.80),
      Candle(time: DateTime.utc(2026,10,30,19,15), open: 3887.80, high: 3890.30, low: 3884.00, close: 3885.00),
      Candle(time: DateTime.utc(2026,10,30,19,30), open: 3884.70, high: 3888.50, low: 3879.50, close: 3879.90),
      Candle(time: DateTime.utc(2026,10,30,19,45), open: 3879.60, high: 3894.50, low: 3879.30, close: 3892.80),
      Candle(time: DateTime.utc(2026,10,30,20,0), open: 3892.80, high: 3897.40, low: 3889.40, close: 3891.40),
      Candle(time: DateTime.utc(2026,10,30,20,15), open: 3891.90, high: 3892.80, low: 3885.90, close: 3889.50),
      Candle(time: DateTime.utc(2026,10,30,20,30), open: 3889.30, high: 3889.50, low: 3882.30, close: 3882.50),
      Candle(time: DateTime.utc(2026,10,30,20,45), open: 3882.70, high: 3898.90, low: 3881.30, close: 3898.90),
    ];
  }

  /// Mirrors the phone screenshot: bodies alternate ~0.13 around 3875.3-4,
  /// green highs pin to ~3875.56, red lows pin to ~3875.21.
  List<Candle> flatFixture() {
    final t0 = DateTime.utc(2026, 10, 30, 20, 0);
    return [
      for (var i = 0; i < 120; i++)
        () {
          final up = i.isEven;
          final o = up ? 3875.31 : 3875.44;
          final c = up ? 3875.44 : 3875.31;
          final j = (i % 3) * 0.02;
          return Candle(
            time: t0.add(Duration(minutes: 15 * i)),
            open: o,
            high: up ? 3875.56 + j : 3875.44,
            low: up ? 3875.31 : 3875.21 - j,
            close: c,
          );
        }(),
    ];
  }

void main() {
  final capture = Platform.environment['WICK_CAPTURE'] == '1';

  setUpAll(() async {
    if (!capture) return;
    final roboto = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
    await roboto.load();
    await icons.load();
  });

  Future<void> pumpReplay(WidgetTester tester, List<Candle> cs) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final screen = PracticeScreen(loadCandles: () async => cs, randomSeed: 7);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
      home: Builder(
        builder: (ctx) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => screen));
          });
          return const Scaffold(backgroundColor: Color(0xFF0F1115));
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1x'));
    await tester.pump();
    await tester.tap(find.text('Start replay'));
    await tester.pump();
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('wick capture: real market bars', (tester) async {
    if (!capture) return;
    await pumpReplay(tester, realFixture());
    expect(find.text('Replaying...'), findsOneWidget);
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/wick_real.png'));
  });

  testWidgets('wick capture: flat degenerate bars', (tester) async {
    if (!capture) return;
    await pumpReplay(tester, flatFixture());
    expect(find.text('Replaying...'), findsOneWidget);
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/wick_flat.png'));
  });
}
