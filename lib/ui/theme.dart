/// NekoTheme —— DSH Remote 的视觉系统。
///
/// 设计简报：动漫主题、清新可爱风，配色取「花哨 ↔ 克制」的中间态。
/// 参考宿主 Web GUI 的浅蓝猫娘女仆视觉：冷调粉彩为底，蓝/粉双色点睛。
///
/// - 色板：牛奶蓝 primary + 樱花粉 secondary + 薄荷绿（状态），冷白底、墨青文字
/// - 形状：统一 16~20 圆角，聊天气泡带「猫耳」小角
/// - 签名元素：猫娘 mascot（CustomPainter 手绘）+ 猫耳气泡 + 爪印发送钮
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class NekoColors {
  NekoColors._();

  // 浅色主题
  static const milkBlue = Color(0xFF5E9FD6); // 牛奶蓝：主色
  static const sakuraPink = Color(0xFFF2A0B5); // 樱花粉：辅色/用户气泡
  static const mint = Color(0xFF7FC8A9); // 薄荷：运行/成功状态
  static const creamBg = Color(0xFFF6F8FB); // 冷白底
  static const ink = Color(0xFF3E4756); // 墨青正文
  static const outlineSoft = Color(0xFFC9D4E2); // 柔边线
  static const bubblePink = Color(0xFFFCE9EF); // 用户气泡底
  static const onBubblePink = Color(0xFF7A3550); // 用户气泡文字
  static const bubbleBlue = Color(0xFFEFF6FC); // 助手气泡底

  // 深色主题（柔和暗夜粉彩）
  static const nightBg = Color(0xFF252B38);
  static const nightSurface = Color(0xFF2F3646);
  static const nightBlue = Color(0xFF8FC1E8);
  static const nightPink = Color(0xFFE8A2B6);
  static const nightInk = Color(0xFFE4E9F2);
}

class NekoTheme {
  NekoTheme._();

  static ThemeData light() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: NekoColors.milkBlue,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFD8E9F7),
      onPrimaryContainer: Color(0xFF1D4560),
      secondary: NekoColors.sakuraPink,
      onSecondary: Colors.white,
      secondaryContainer: NekoColors.bubblePink,
      onSecondaryContainer: NekoColors.onBubblePink,
      tertiary: NekoColors.mint,
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFDFF2E9),
      onTertiaryContainer: Color(0xFF1F4D3A),
      error: Color(0xFFD97A7A),
      onError: Colors.white,
      errorContainer: Color(0xFFF9E3E3),
      onErrorContainer: Color(0xFF6B2B2B),
      surface: Colors.white,
      onSurface: NekoColors.ink,
      surfaceDim: Color(0xFFE9EEF5),
      surfaceBright: Colors.white,
      surfaceContainerLowest: NekoColors.creamBg,
      surfaceContainerLow: Color(0xFFF0F4F9),
      surfaceContainer: Color(0xFFEAF0F6),
      surfaceContainerHigh: Color(0xFFE3EAF2),
      surfaceContainerHighest: Color(0xFFDCE4EE),
      onSurfaceVariant: Color(0xFF66707F),
      outline: NekoColors.outlineSoft,
      outlineVariant: Color(0xFFE2E9F1),
      shadow: Color(0x1A3E4756),
      scrim: Color(0x80000000),
      inverseSurface: Color(0xFF323A48),
      onInverseSurface: Color(0xFFEDF1F7),
      inversePrimary: Color(0xFFA8CCE8),
      surfaceTint: NekoColors.milkBlue,
    );
    return _base(scheme);
  }

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: NekoColors.nightBlue,
      onPrimary: Color(0xFF173041),
      primaryContainer: Color(0xFF3A5A75),
      onPrimaryContainer: Color(0xFFD6E8F7),
      secondary: NekoColors.nightPink,
      onSecondary: Color(0xFF44202D),
      secondaryContainer: Color(0xFF54313E),
      onSecondaryContainer: Color(0xFFF7D9E1),
      tertiary: Color(0xFF93CFB2),
      onTertiary: Color(0xFF17352A),
      tertiaryContainer: Color(0xFF35534A),
      onTertiaryContainer: Color(0xFFDBF1E4),
      error: Color(0xFFE39A9A),
      onError: Color(0xFF421C1C),
      errorContainer: Color(0xFF59333A),
      onErrorContainer: Color(0xFFF6DADA),
      surface: NekoColors.nightBg,
      onSurface: NekoColors.nightInk,
      surfaceDim: Color(0xFF1F242E),
      surfaceBright: Color(0xFF3A4150),
      surfaceContainerLowest: Color(0xFF20252F),
      surfaceContainerLow: NekoColors.nightBg,
      surfaceContainer: NekoColors.nightSurface,
      surfaceContainerHigh: Color(0xFF383F4E),
      surfaceContainerHighest: Color(0xFF414959),
      onSurfaceVariant: Color(0xFFB4BDCB),
      outline: Color(0xFF5A6373),
      outlineVariant: Color(0xFF3A4150),
      shadow: Color(0x66000000),
      scrim: Color(0xB3000000),
      inverseSurface: Color(0xFFE4E9F2),
      onInverseSurface: Color(0xFF2A2F3B),
      inversePrimary: NekoColors.milkBlue,
      surfaceTint: NekoColors.nightBlue,
    );
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    final textTheme = _textTheme(scheme);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surfaceContainerLowest,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          textStyle: textTheme.labelLarge,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        labelStyle: textTheme.bodySmall,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  /// 克制的字阶：display 用微扩字距的大号粗体，正文清晰，caption 柔和。
  static TextTheme _textTheme(ColorScheme scheme) {
    final base = TextTheme(
      displaySmall: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: scheme.onSurface,
        height: 1.2,
      ),
      titleLarge: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.15,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        color: scheme.onSurfaceVariant,
      ),
      bodyLarge: TextStyle(fontSize: 15.5, height: 1.55, color: scheme.onSurface),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: scheme.onSurface),
      bodySmall: TextStyle(fontSize: 12, height: 1.45, color: scheme.onSurfaceVariant),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.3),
    );
    return base;
  }
}

/// 签名元素①：猫耳气泡形状（用户消息用）。
/// 在圆角矩形的右上/左上顶出一只小三角耳，俏皮但不吵。
class CatEarBubbleShape extends RoundedRectangleBorder {
  const CatEarBubbleShape({this.earOnLeft = false, super.borderRadius, super.side});

  final bool earOnLeft;

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final rrect = borderRadius.resolve(textDirection).toRRect(rect);
    final path = Path()..addRRect(rrect);
    const ear = 10.0;
    final top = rect.top;
    if (earOnLeft) {
      final x = rect.left + 14;
      path
        ..moveTo(x, top + 2)
        ..lineTo(x + ear * 0.6, top - ear)
        ..lineTo(x + ear * 1.4, top + 2)
        ..close();
    } else {
      final x = rect.right - 14;
      path
        ..moveTo(x, top + 2)
        ..lineTo(x - ear * 0.6, top - ear)
        ..lineTo(x - ear * 1.4, top + 2)
        ..close();
    }
    return path;
  }
}

/// 签名元素②：手绘猫娘 mascot（线稿风猫脸 + 耳 + 胡须）。
/// 用在设置页 hero 与空状态，是这套 UI 的记忆点。
class NekoMascot extends StatelessWidget {
  const NekoMascot({super.key, this.size = 96, this.color, this.blush = true});

  final double size;
  final Color? color;

  /// 两团腮红，可爱的来源。
  final bool blush;

  @override
  Widget build(BuildContext context) {
    final lineColor = color ?? Theme.of(context).colorScheme.onSurface;
    return CustomPaint(
      size: Size.square(size),
      painter: _NekoMascotPainter(lineColor: lineColor, blush: blush),
    );
  }
}

class _NekoMascotPainter extends CustomPainter {
  _NekoMascotPainter({required this.lineColor, required this.blush});

  final Color lineColor;
  final bool blush;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final stroke = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.035
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final center = Offset(w / 2, w * 0.56);
    final r = w * 0.34;

    // 两只三角耳（略带圆润的尖）
    final earPath = Path()
      ..moveTo(center.dx - r * 0.95, center.dy - r * 0.55)
      ..quadraticBezierTo(
          center.dx - r * 0.95, center.dy - r * 1.25, center.dx - r * 0.35, center.dy - r * 0.95)
      ..moveTo(center.dx + r * 0.95, center.dy - r * 0.55)
      ..quadraticBezierTo(
          center.dx + r * 0.95, center.dy - r * 1.25, center.dx + r * 0.35, center.dy - r * 0.95);
    canvas.drawPath(earPath, stroke);

    // 圆脸（留出耳位，用弧线）
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      math.pi * 1.18,
      math.pi * 0.64,
      false,
      stroke,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      -math.pi * 0.18,
      math.pi * 1.36,
      false,
      stroke,
    );

    // 眼睛：两只弯弯的笑眼
    final eyeY = center.dy - r * 0.05;
    for (final dx in [-r * 0.42, r * 0.42]) {
      canvas.drawArc(
        Rect.fromCenter(center: Offset(center.dx + dx, eyeY), width: r * 0.42, height: r * 0.3),
        math.pi * 1.08,
        math.pi * 0.84,
        false,
        stroke,
      );
    }

    // 小嘴：ω 形
    final mouthY = center.dy + r * 0.32;
    final mouth = Path()
      ..moveTo(center.dx - r * 0.16, mouthY)
      ..quadraticBezierTo(center.dx - r * 0.08, mouthY + r * 0.12, center.dx, mouthY)
      ..quadraticBezierTo(center.dx + r * 0.08, mouthY + r * 0.12, center.dx + r * 0.16, mouthY);
    canvas.drawPath(mouth, stroke);

    // 胡须
    final whiskerY = center.dy + r * 0.2;
    for (final (dy, tilt) in [(0.0, -0.06), (r * 0.18, 0.08)]) {
      canvas.drawLine(
        Offset(center.dx - r * 1.05, whiskerY + dy + r * tilt * 2),
        Offset(center.dx - r * 0.62, whiskerY + dy),
        stroke,
      );
      canvas.drawLine(
        Offset(center.dx + r * 0.62, whiskerY + dy),
        Offset(center.dx + r * 1.05, whiskerY + dy + r * tilt * 2),
        stroke,
      );
    }

    // 腮红
    if (blush) {
      final blushPaint = Paint()
        ..color = NekoColors.sakuraPink.withValues(alpha: 0.45)
        ..style = PaintingStyle.fill;
      for (final dx in [-r * 0.55, r * 0.55]) {
        canvas.drawOval(
          Rect.fromCenter(
              center: Offset(center.dx + dx, center.dy + r * 0.28), width: r * 0.34, height: r * 0.16),
          blushPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_NekoMascotPainter oldDelegate) =>
      oldDelegate.lineColor != lineColor || oldDelegate.blush != blush;
}

/// 签名元素③：爪印图标（发送按钮 / 点缀）。
class PawIcon extends StatelessWidget {
  const PawIcon({super.key, this.size = 20, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _PawPainter(color: color ?? Theme.of(context).colorScheme.onPrimary),
    );
  }
}

class _PawPainter extends CustomPainter {
  _PawPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final paint = Paint()..color = color;
    // 主肉垫
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.5, w * 0.62), width: w * 0.52, height: w * 0.44),
      paint,
    );
    // 四颗小趾垫
    for (final (x, y, r) in [
      (0.2, 0.32, 0.10),
      (0.4, 0.18, 0.105),
      (0.62, 0.18, 0.105),
      (0.82, 0.32, 0.10),
    ]) {
      canvas.drawCircle(Offset(w * x, w * y), w * r, paint);
    }
  }

  @override
  bool shouldRepaint(_PawPainter oldDelegate) => oldDelegate.color != color;
}
