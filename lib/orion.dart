// Orion design system for Sona — palette, shapes and reusable widgets.
// Values are a 1:1 port of the approved preview (App.tsx + style.css).
import 'package:flutter/material.dart';

class O {
  O._();
  // Surfaces (dark, default)
  static const bg = Color(0xFF14110F);
  static const panel = Color(0xFF211D19);
  static const panel2 = Color(0xFF2A2521);
  static const dock = Color(0xFF221E1A);
  static const ink = Color(0xFFF2EDE6);
  static const soft = Color(0xFFB4ABA0);
  static const muted = Color(0xFF9C9287);
  static const line = Color(0x0FFFFFFF); // rgba(255,255,255,.06)
  static const line2 = Color(0x12FFFFFF); // rgba(255,255,255,.09)

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
  Color color = O.ink,
  double? height,
}) =>
    TextStyle(fontSize: size, fontWeight: weight, color: color, height: height);

// Section label: 11px uppercase letterspaced soft label.
Widget oSect(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.7,
          color: O.soft,
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
      child: child,
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
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label) in options)
            GestureDetector(
              onTap: () => onChanged(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                  color: v == value ? O.panel : Colors.transparent,
                  borderRadius: O.cardRadius(O.rRound),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    color: v == value ? O.ink : O.soft,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Floating dock: dark pill, selected tab gets mint pill with icon + label.
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
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: O.dock,
        borderRadius: O.cardRadius(O.rRound),
        border: Border.all(color: O.line2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < tabs.length; i++)
            _ODockItem(
              icon: tabs[i].$1,
              label: tabs[i].$2,
              selected: i == index,
              onTap: () => onChanged(i),
              iconBuilder:
                  badgeIcon != null ? (ic) => badgeIcon!(i, ic) : null,
            ),
        ],
      ),
    );
  }
}

class _ODockItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget Function(Widget icon)? iconBuilder;
  const _ODockItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.iconBuilder,
  });
  @override
  Widget build(BuildContext context) {
    final ic = Icon(icon, size: 19, color: selected ? O.cardInk : O.soft);
    final wrapped = iconBuilder != null ? iconBuilder!(ic) : ic;
    return Semantics(
      label: 'Tab $label',
      button: true,
      child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: EdgeInsets.symmetric(
            horizontal: selected ? 14 : 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? O.mint : Colors.transparent,
          borderRadius: O.cardRadius(O.rRound),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            wrapped,
            if (selected) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: O.cardInk),
              ),
            ],
          ],
        ),
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
        width: 42,
        height: 24,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value ? O.mint : O.panel2,
          borderRadius: O.cardRadius(O.rRound),
          border: Border.all(color: value ? Colors.transparent : O.line),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 140),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: value ? O.cardInk : O.soft,
              borderRadius: O.cardRadius(O.rRound),
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
      decoration: const BoxDecoration(
        color: O.panel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
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
