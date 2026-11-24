import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Investing.com's hosted "Technical Charts" webmaster widget (free embed),
/// shown unmodified with its own attribution (the Investing.com logo on the
/// chart and the "powered by Investing.com & TradingView" credit line).
///
/// Embedded in the Trade tab as the third chart choice
/// [Sona chart | TradingView | Investing]. The user asked for it on
/// Nov 24, 2026 ("Add this chart in sona") after approving the placement
/// mockup and hearing that the widget is light-only, uses a separate price
/// feed, and cannot show Sona's signal boxes or order lines.
///
/// Data note: the widget uses Investing.com's own XAU/USD feed, NOT Sona's
/// Twelve Data candles, so prices can differ and Sona's signal boxes stay
/// on the Sona chart. Needs internet. Light theme only: the widget has no
/// dark mode (verified live Nov 24, 2026 - the builder offers no theme
/// option and a theme=dark URL parameter is ignored).
class InvestingChartView extends StatefulWidget {
  const InvestingChartView({super.key});

  @override
  State<InvestingChartView> createState() => InvestingChartViewState();
}

class InvestingChartViewState extends State<InvestingChartView> {
  // WebView exists only on Android here; elsewhere show an honest note.
  static final bool _supported = Platform.isAndroid;

  // pair_ID 68 = XAU/USD (verified by the rendered widget title),
  // interval 300 = 5-minute candles. The widget enforces a ~500 CSS px
  // minimum layout width and ignores narrower width/height parameters
  // (verified live Nov 24, 2026), so on a phone it is zoomed to fit
  // after load.
  static const String _url =
      'https://ssltvc.investing.com/?pair_ID=68&height=560&width=500'
      '&interval=300&plotStyle=candles&domain_ID=1&lang_ID=1&timezone_ID=55';

  // Scale the page to the WebView's actual width so the ~500 px widget
  // fits a phone screen without horizontal scrolling.
  static const String _fitJs = '(function(){'
      'var z=Math.min(1,window.innerWidth/500);'
      'document.body.style.zoom=z;'
      'document.body.style.margin="0";'
      '})();';

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
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _controller.runJavaScript(_fitJs);
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
        color: Color(0xFFFFFFFF),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Investing.com chart is available in the Android app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          // Same gesture contract as the TradingView box: claim vertical
          // drags eagerly so chart pans reach the widget inside the Trade
          // tab's ListView; page scrolling still starts outside the box.
          child: WebViewWidget(
            controller: _controller,
            gestureRecognizers: {
              Factory<VerticalDragGestureRecognizer>(
                () => VerticalDragGestureRecognizer(),
              ),
            },
          ),
        ),
        if (_loading)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0xFFFFFFFF),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        if (_failed)
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0xFFFFFFFF),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Could not load the chart. Check internet.',
                      style: TextStyle(color: Colors.black54),
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
