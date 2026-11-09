import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'candle_chart_test.dart' show fakeCandles, loadFonts;

void main() {
  test('grid spacing thins at zoom out and adapts to chart width', () {
    expect(adaptiveGridBarStep(30,300),10);
    expect(adaptiveGridBarStep(120,300),60);
    expect(adaptiveGridBarStep(30,600),5);
    expect(adaptiveGridBarStep(0,0),1);
  });
  testWidgets('preview dotted grid normal, zoomed, panned, price-scaled', (t) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    t.view.physicalSize=const Size(780,1688);
    t.view.devicePixelRatio=2;
    addTearDown(t.view.reset);
    final data=fakeCandles(240);
    final key=GlobalKey();
    await t.pumpWidget(RepaintBoundary(key:key,child:MaterialApp(debugShowCheckedModeBanner:false,home:FullscreenChartPage(
      loader:(_) async=>data,
      livePrice:data.last.close,
      rangeMode:true,
      marketSnapshot:()=>ChartMarketSnapshot(price:data.last.close,fresh:true,bid:data.last.close-.18,ask:data.last.close+.17),
      onTradeSide:(_){},
    ))));
    await t.pumpAndSettle();
    final panel=t.state<CandleChartPanelState>(find.byType(CandleChartPanel));
    Future<void> capture(String name) async {
      await t.pumpAndSettle();
      expect(t.takeException(),isNull);
      await t.runAsync(() async {
        final img=await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio:2);
        final bytes=await img.toByteData(format:ui.ImageByteFormat.png);
        final png=bytes!.buffer.asUint8List();
        await File('/tmp/sona-grid-$name.png').writeAsBytes(png);
        await expectLater(png,matchesGoldenFile('goldens/adaptive_grid_$name.png'));
      });
    }
    panel.debugSetView(visibleCount:90,scroll:0);
    await capture('normal');
    panel.debugSetView(visibleCount:35,scroll:0);
    await capture('zoomed');
    panel.debugSetView(visibleCount:35,scroll:50);
    await capture('panned');
    final rect=t.getRect(find.byType(CandleChartPanel));
    final g=await t.startGesture(Offset(rect.right-20,rect.center.dy-60));
    await t.pump();
    for(int i=0;i<10;i++){await g.moveBy(const Offset(0,12));await t.pump();}
    await g.up();await t.pumpAndSettle();
    expect(panel.debugPriceScale,greaterThan(1));
    await capture('price-scaled');
  });
}
