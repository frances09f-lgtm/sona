// Orion design system for Sona — palette, shapes and reusable widgets.
// Values are a 1:1 port of the approved preview (App.tsx + style.css).
import 'package:flutter/material.dart';

class O {
  O._();

  /// Notifies the app shell to rebuild the MaterialApp theme on toggle.
  static final ValueNotifier<bool> themeTick = ValueNotifier(false);
  // Surfaces (dark, default)
  // Theme-switchable palette (approved preview has a working light/dark
  // toggle; values from the approved style.css). Dark is the default.
  static bool light = false;
  static var bg = const Color(0xFF14110F);
  static var panel = const Color(0xFF211D19);
  static var panel2 = const Color(0xFF2A2521);
  static var dock = const Color(0xFF221E1A);
  static var ink = const Color(0xFFF2EDE6);
  static var soft = const Color(0xFFB4ABA0);
  static var muted = const Color(0xFF9C9287);
  static var line = const Color(0x0FFFFFFF); // rgba(255,255,255,.06)
  static var line2 = const Color(0x12FFFFFF); // rgba(255,255,255,.09)

  /// Apply the approved light or dark palette. Pastel card colors
  /// (sun/mint/lav/peach/sky) and card inks are theme-independent in the
  /// approved CSS, so they stay fixed.
  static void applyLight(bool v) {
    light = v;
    themeTick.value = v;
    if (v) {
      bg = const Color(0xFFFAF7F2);
      panel = const Color(0xFFFFFFFF);
      panel2 = const Color(0xFFEDE8E0);
      dock = const Color(0xFFFFFFFF);
      ink = const Color(0xFF201A17);
      soft = const Color(0xFF6F675F);
      muted = const Color(0xFF8A8078);
      line = const Color(0x14201A17);
      line2 = const Color(0x1F201A17);
    } else {
      bg = const Color(0xFF14110F);
      panel = const Color(0xFF211D19);
      panel2 = const Color(0xFF2A2521);
      dock = const Color(0xFF221E1A);
      ink = const Color(0xFFF2EDE6);
      soft = const Color(0xFFB4ABA0);
      muted = const Color(0xFF9C9287);
      line = const Color(0x0FFFFFFF);
      line2 = const Color(0x12FFFFFF);
    }
  }

  // Pastels (card backgrounds; text on them is cardInk)
  static const sun = Color(0xFFF7F0C8);
  static const mint = Color(0xFFD8F0DC);
  static const lav = Color(0xFFE9E2FB);
  static const peach = Color(0xFFFFE4CE);
  static const sky = Color(0xFFD9EAFB);
  static const cardInk = Color(0xFF201A17);
  static const cardSoft = Color(0xFF584F44);
  static const cardLine = Color(0x29201A17); // rgba(32,26,23,.16)
  static const cardChip = Color(0x80201A17); // rgba(32,26,23,.5)

  // Trading
  static const buy = Color(0xFF1E8F68);
  static const sell = Color(0xFFD6336C);
  static const chartUp = Color(0xFF3DDBA4);
  static const chartDn = Color(0xFFFF6B81);
  static const gold = Color(0xFFF5C242);
  static const warn = Color(0xFFFFD88A);
  static const chartBox = Colors.black;

  // Shape
  static const rCard = 26.0;
  static const rHero = 32.0;
  static const rSmall = 16.0;
  static const rChip = 12.0;
  static const rRound = 999.0;

  static BorderRadius cardRadius([double r = rCard]) =>
      BorderRadius.circular(r);
}

TextStyle oText({
  double size = 13,
  FontWeight weight = FontWeight.w500,
  Color? color,
  double? height,
}) =>
    TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color ?? O.ink,
        height: height);

// Section label: 11px uppercase letterspaced soft label.
Widget oSect(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.7,
          color: Color(0xFF1E8F68),
        ),
      ),
    );

// Dark panel card (26px radius, panel fill, thin line border).
Widget oPanel(Widget child,
        {EdgeInsets padding = const EdgeInsets.all(16),
        double radius = O.rCard}) =>
    Container(
      padding: padding,
      decoration: BoxDecoration(
        color: O.panel,
        borderRadius: O.cardRadius(radius),
        border: Border.all(color: O.line),
      ),
      child: child,
    );

// Pastel card: muted mint by default, darker pastel variants on demand.
Widget oPastel(
  Widget child, {
  Color color = O.mint,
  bool muted = true,
  bool darkInk = false,
  EdgeInsets padding = const EdgeInsets.all(14),
  double radius = O.rCard,
}) {
  final bg = muted ? Color.alphaBlend(color.withOpacity(0.45), O.panel) : color;
  final mutedInk = muted ? O.ink : O.cardInk;
  final mutedSoft = muted ? O.soft : O.cardSoft;
  return _PastelScope(
    ink: mutedInk,
    soft: mutedSoft,
    line: muted ? O.line : O.cardLine,
    child: Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: O.cardRadius(radius),
        border: Border.all(color: muted ? O.line : O.cardLine),
      ),
      child: darkInk
          ? DefaultTextStyle.merge(
              style: TextStyle(color: mutedInk),
              child: IconTheme.merge(
                data: IconThemeData(color: mutedInk),
                child: child,
              ),
            )
          : child,
    ),
  );
}

// Lets children inside a pastel card read the right ink/soft/line values.
class _PastelScope extends InheritedWidget {
  final Color ink;
  final Color soft;
  final Color line;
  const _PastelScope(
      {required this.ink,
      required this.soft,
      required this.line,
      required super.child});
  static _PastelScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PastelScope>();
  static Color inkOf(BuildContext context) => of(context)?.ink ?? O.ink;
  static Color softOf(BuildContext context) => of(context)?.soft ?? O.soft;
  static Color lineOf(BuildContext context) => of(context)?.line ?? O.line;
  @override
  bool updateShouldNotify(_PastelScope old) =>
      ink != old.ink || soft != old.soft || line != old.line;
}

// Chip: 11px 700 rounded-999, thin border.
Widget oChip(
  BuildContext context,
  String text, {
  bool filled = false,
  Color? fg,
  Color? bg,
  Color? border,
}) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg ??
            (filled ? _PastelScope.inkOf(context) : Colors.transparent),
        borderRadius: O.cardRadius(O.rRound),
        border: Border.all(
            color: border ??
                (filled ? Colors.transparent : _PastelScope.lineOf(context))),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg ??
              (filled
                  ? O.panel
                  : _PastelScope.softOf(context)),
        ),
      ),
    );

// Round icon button: 34px (size param) circular, track fill, ink glyph.
class ORoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final Color? bg;
  final Color? fg;
  const ORoundBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 34,
    this.bg,
    this.fg,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bg ?? O.panel2,
          borderRadius: O.cardRadius(O.rRound),
          border: Border.all(color: O.line),
        ),
        child: Icon(icon, size: size * 0.5, color: fg ?? O.ink),
      ),
    );
  }
}

// Segmented control: pill container, selected segment gets panel2 fill.
class OSeg<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final double fontSize;
  const OSeg({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.fontSize = 12,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: O.panel2,
        borderRadius: O.cardRadius(O.rRound),
        border: Border.all(color: O.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          for (final (v, label) in options)
            Expanded(
              child: GestureDetector(
              onTap: () => onChanged(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                  color: v == value ? O.ink : Colors.transparent,
                  borderRadius: O.cardRadius(O.rRound),
                ),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    color: v == value ? O.bg : O.soft,
                  ),
                ),
              ),
              ),
            ),
        ],
      ),
    );
  }
}

// Floating dock: dark bar, selected tab's mint pill slides between slots.
class ODock extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;
  final List<(IconData, String)> tabs; // (icon, label)
  final Widget Function(int index, Widget icon)? badgeIcon;
  const ODock({
    super.key,
    required this.index,
    required this.onChanged,
    required this.tabs,
    this.badgeIcon,
  });

  static const double _slotMax = 54;
  static const double _barHeight = 56;
  static const double _iconSize = 24;
  static const TextStyle _labelStyle = TextStyle(
      fontSize: 13.5, fontWeight: FontWeight.w700, color: O.cardInk);

  double _labelWidth(String s) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: _labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  Widget _dockIcon(int i, Color color) {
    final ic = Icon(tabs[i].$1, size: _iconSize, color: color);
    return badgeIcon != null ? badgeIcon!(i, ic) : ic;
  }

  @override
  Widget build(BuildContext context) {
    final n = tabs.length;
    final avail = MediaQuery.sizeOf(context).width - 48 - 16;
    final slot = avail / n > _slotMax ? _slotMax : avail / n;
    // Pill carries the selected icon + label and slides slot to slot; it is
    // clamped so it never escapes the bar's inner bounds.
    final pillW = 16 + _iconSize + 8 + _labelWidth(tabs[index].$2) + 18;
    var left = slot * index + slot / 2 - pillW / 2;
    if (left < 0) left = 0;
    final maxLeft = slot * n - pillW;
    if (left > maxLeft) left = maxLeft < 0 ? 0 : maxLeft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: O.dock,
        borderRadius: O.cardRadius(O.rRound),
        border: Border.all(color: O.line2),
      ),
      child: SizedBox(
        width: slot * n,
        height: _barHeight,
        child: Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < n; i++)
                  SizedBox(
                    width: slot,
                    height: _barHeight,
                    child: Semantics(
                      label: 'Tab ${tabs[i].$2}',
                      button: true,
                      onTap: () => onChanged(i),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(i),
                        child: Center(child: _dockIcon(i, O.soft)),
                      ),
                    ),
                  ),
              ],
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              left: left,
              width: pillW,
              top: 6,
              bottom: 6,
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    color: O.mint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _dockIcon(index, O.cardInk),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          tabs[index].$2,
                          style: _labelStyle,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Thin divider using panel line color.
Widget oDivider({double indent = 0}) => Container(
      height: 1,
      margin: EdgeInsets.only(left: indent),
      color: O.line,
    );

// 24px rounded-7 track switch, ink knob on mint fill when on.
class OSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const OSwitch({super.key, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 56,
        height: 32,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: value ? const Color(0xFF1D5A96) : const Color(0x80FFFFFF),
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 140),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

// 46px circular gold/plus button (Add tab style CTA).
class OPlusBtn extends StatelessWidget {
  final VoidCallback? onTap;
  final Color bg;
  const OPlusBtn({super.key, this.onTap, this.bg = O.gold});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: O.cardRadius(O.rRound),
        ),
        child: const Icon(Icons.add, size: 26, color: O.cardInk),
      ),
    );
  }
}

// Sona logo mark: rounded square with gold candlesticks (from preview logo()).
Widget oLogo({double size = 40}) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: O.panel2,
      borderRadius: O.cardRadius(14),
      border: Border.all(color: O.line),
    ),
    child: CustomPaint(painter: _LogoPainter()),
  );
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = O.gold
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    // Three candlestick glyphs like the preview SVG (20x20 viewBox scaled).
    canvas.scale(w / 20);
    canvas.drawLine(const Offset(5, 4), const Offset(5, 6.5), p);
    canvas.drawRect(Rect.fromLTWH(3.2, 6.5, 3.6, 6), p..style = PaintingStyle.fill);
    canvas.drawLine(const Offset(5, 12.5), const Offset(5, 15), p..style = PaintingStyle.stroke);
    canvas.drawLine(const Offset(10, 2.5), const Offset(10, 5), p);
    canvas.drawRect(Rect.fromLTWH(8.2, 5, 3.6, 4.5), p..style = PaintingStyle.fill);
    canvas.drawLine(const Offset(10, 9.5), const Offset(10, 12), p..style = PaintingStyle.stroke);
    canvas.drawLine(const Offset(15, 7), const Offset(15, 9.5), p);
    canvas.drawRect(Rect.fromLTWH(13.2, 9.5, 3.6, 5.5), p..style = PaintingStyle.fill);
    canvas.drawLine(const Offset(15, 15), const Offset(15, 17.5), p..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Bottom sheet scaffold: grabber handle, title, close X, mint/ink CTA.
class OSheet extends StatelessWidget {
  final String title;
  final Widget child;
  final String? cta;
  final bool ctaDisabled;
  final VoidCallback? onCta;
  const OSheet({
    super.key,
    required this.title,
    required this.child,
    this.cta,
    this.ctaDisabled = false,
    this.onCta,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.84),
      decoration: BoxDecoration(
        color: O.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: O.line)),
      ),
      padding: EdgeInsets.only(
        top: 8,
        left: 18,
        right: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: O.panel2,
                    borderRadius: O.cardRadius(O.rRound),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: oText(size: 19, weight: FontWeight.w700)),
                  ),
                  ORoundBtn(
                      icon: Icons.close,
                      size: 30,
                      onTap: () => Navigator.of(context).pop()),
                ],
              ),
              const SizedBox(height: 12),
              child,
              if (cta != null) ...[
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: ctaDisabled ? null : onCta,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: O.ink.withOpacity(ctaDisabled ? 0.4 : 1),
                      borderRadius: O.cardRadius(O.rRound),
                    ),
                    alignment: Alignment.center,
                    child: Text(cta!,
                        style: oText(
                            size: 14,
                            weight: FontWeight.w700,
                            color: O.cardInk)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
