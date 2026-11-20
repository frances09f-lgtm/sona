import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// TradingView's hosted "Advanced Real-Time Chart" widget (free embed),
/// shown unmodified with its own attribution, as a separate full screen.
///
/// Approved Nov 20, 2026 (user picked the dark whole box after preview):
/// dark theme, OANDA:XAUUSD, 5m default, IST, date ranges on, side toolbar
/// on, symbol change locked.
///
/// Data note: the widget uses TradingView's own XAU/USD feed, NOT Sona's
/// Twelve Data candles, so prices can differ slightly and Sona's signal
/// boxes stay on the existing chart. Needs internet. Choices made inside
/// the widget (e.g. added indicators) are session-scoped.
class TvChartPage extends StatefulWidget {
  const TvChartPage({super.key});

  @override
  State<TvChartPage> createState() => _TvChartPageState();
}

class _TvChartPageState extends State<TvChartPage> {
  static const String _url =
      'https://www.tradingview.com/widgetembed/?symbol=OANDA%3AXAUUSD'
      '&interval=5&theme=dark&style=1&timezone=Asia%2FKolkata'
      '&withdateranges=1&hide_side_toolbar=false&allow_symbol_change=false'
      '&locale=en';

  late final WebViewController _controller;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
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

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    _controller.loadRequest(Uri.parse(_url));
  }

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
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading)
                  const Center(child: CircularProgressIndicator()),
                if (_failed)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Could not load the chart. Check internet.',
                          style: TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _retry,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const ColoredBox(
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
