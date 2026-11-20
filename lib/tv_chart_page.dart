import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// TradingView's hosted "Advanced Real-Time Chart" widget (free embed),
/// shown unmodified with its own attribution.
///
/// Two hosts:
///  * [TvChartPage] - separate full screen from the chart sigma menu
///    (added in 1.2.41).
///  * [TvChartView] - the same box embedded in the Trade tab behind the
///    [Sona chart | TradingView] toggle (1.2.42; user approved the toggle
///    mockup on WhatsApp Nov 20, 2026 with "Ok built").
///
/// Data note: the widget uses TradingView's own XAU/USD feed, NOT Sona's
/// Twelve Data candles, so prices can differ slightly and Sona's signal
/// boxes stay on the Sona chart. Needs internet. Choices made inside
/// the widget (e.g. added indicators) are session-scoped.
class TvChartView extends StatefulWidget {
  const TvChartView({super.key});

  @override
  State<TvChartView> createState() => TvChartViewState();
}

class TvChartViewState extends State<TvChartView> {
  // WebView exists only on Android here; elsewhere show an honest note.
  static final bool _supported = Platform.isAndroid;

  static const String _url =
      'https://www.tradingview.com/widgetembed/?symbol=OANDA%3AXAUUSD'
      '&interval=5&theme=dark&style=1&timezone=Asia%2FKolkata'
      '&withdateranges=1&hide_side_toolbar=false&allow_symbol_change=false'
      '&locale=en'
      // enabled_features is live-effective on this hosted widget (verified
      // by A/B on the exact embed URL): pinch_scale turns on pinch zoom on
      // touch; show_zoom_and_move_buttons_on_touch adds +/- zoom buttons on
      // time-scale tap. Pinch inside the Android WebView still needs
      // verification on a real phone; the +/- buttons are the fallback.
      '&enabled_features=%5B%22pinch_scale%22%2C'
      '%22show_zoom_and_move_buttons_on_touch%22%5D';

  late final WebViewController _controller;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!_supported) {
      _loading = false;
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (WebResourceError error) {
            if ((error.isForMainFrame ?? false) && mounted) {
              setState(() {
                _loading = false;
                _failed = true;
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(_url));
  }

  void retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    _controller.loadRequest(Uri.parse(_url));
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return const ColoredBox(
        color: Color(0xFF131722),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'TradingView chart is available in the Android app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _controller)),
        if (_loading)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0xFF131722),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        if (_failed)
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0xFF131722),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Could not load the chart. Check internet.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: retry,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Full-screen host reached from the chart sigma menu.
class TvChartPage extends StatelessWidget {
  const TvChartPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF121A2C),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('GOLD - TradingView chart',
            style: TextStyle(fontSize: 17)),
      ),
      body: const Column(
        children: [
          Expanded(child: TvChartView()),
          ColoredBox(
            color: Color(0xFF0D1420),
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  "TradingView's own XAU/USD feed - can differ slightly "
                  "from Sona's candles. Signal boxes stay on the Sona chart.",
                  style: TextStyle(color: Color(0xFF8A93A6), fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
