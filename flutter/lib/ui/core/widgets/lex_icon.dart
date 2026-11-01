/// The icon widget and the SVG-path interpreter behind it.
///
/// The web build inlined a `<path d="...">` per icon and let the browser parse
/// it. Flutter has no SVG, so this file parses the same path strings once and
/// caches the resulting [Path] on a 24x24 grid. The strings themselves live in
/// `icon_paths.dart`, generated from the web source, so the two builds cannot
/// drift apart.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'icon_paths.dart';

/// Icon names, mirroring the `IconName` union in the web build.
///
/// A `String`-typed API would have let a typo compile; these constants keep the
/// call sites as terse as the TS did while staying checked.
abstract final class Ic {
  static const words = 'words';
  static const cards = 'cards';
  static const quiz = 'quiz';
  static const stats = 'stats';
  static const settings = 'settings';
  static const search = 'search';
  static const plus = 'plus';
  static const star = 'star';
  static const starFilled = 'star-filled';
  static const trash = 'trash';
  static const edit = 'edit';
  static const play = 'play';
  static const volume = 'volume';
  static const check = 'check';
  static const x = 'x';
  static const chevronLeft = 'chevron-left';
  static const chevronRight = 'chevron-right';
  static const chevronDown = 'chevron-down';
  static const flame = 'flame';
  static const clock = 'clock';
  static const more = 'more';
  static const upload = 'upload';
  static const download = 'download';
  static const sparkles = 'sparkles';
  static const filter = 'filter';
  static const arrowRight = 'arrow-right';
  static const refresh = 'refresh';
  static const book = 'book';
  static const layers = 'layers';
  static const target = 'target';
  static const calendar = 'calendar';
  static const keyboard = 'keyboard';
  static const info = 'info';
  static const alert = 'alert';
  static const sun = 'sun';
  static const moon = 'moon';
  static const undo = 'undo';
  static const cloud = 'cloud';
  static const list = 'list';
  static const minimize = 'minimize';
  static const maximize = 'maximize';
  static const restore = 'restore';

  /// Every name, for tests and for the icon-gallery check.
  static const all = <String>[
    words, cards, quiz, stats, settings, search, plus, star, starFilled,
    trash, edit, play, volume, check, x, chevronLeft, chevronRight, chevronDown,
    flame, clock, more, upload, download, sparkles, filter, arrowRight, refresh,
    book, layers, target, calendar, keyboard, info, alert, sun, moon, undo,
    cloud, list, minimize, maximize, restore,
  ];
}

/// Parsed paths, keyed by name. The strings are constants, so one parse per
/// icon per process is enough; a page rebuild must not pay for it again.
final Map<String, Path> _cache = <String, Path>{};

Path _pathFor(String name) => _cache.putIfAbsent(name, () {
      final d = kIconPath[name];
      if (d == null) throw ArgumentError.value(name, 'name', 'unknown icon');
      return SvgPathParser.parse(d);
    });

/// Draws one icon from the set.
///
/// Mirrors the web `Icon` component: a 24x24 viewBox scaled to [size], stroked
/// in [color] with round caps and joins. Pass [filled] for the two glyphs that
/// are solids (`star-filled` is filled automatically, as in the web build).
class LexIcon extends StatelessWidget {
  const LexIcon(
    this.name, {
    super.key,
    this.size = 18,
    this.color,
    this.filled,
    this.strokeWidth = 1.7,
    this.semanticLabel,
  });

  final String name;
  final double size;
  final Color? color;
  final bool? filled;
  final double strokeWidth;

  /// Icons are decoration unless a screen says otherwise; the surrounding
  /// control carries the label.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final isFilled = filled ?? name == Ic.starFilled;
    final resolved = color ?? DefaultTextStyle.of(context).style.color;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _IconPainter(
          name: name,
          color: resolved ?? const Color(0xFF1E221E),
          filled: isFilled,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _IconPainter extends CustomPainter {
  const _IconPainter({
    required this.name,
    required this.color,
    required this.filled,
    required this.strokeWidth,
  });

  final String name;
  final Color color;
  final bool filled;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _pathFor(name);
    canvas.save();
    // The source grid is 24x24; scale it to whatever box the caller asked for.
    canvas.scale(size.width / 24, size.height / 24);

    if (filled) {
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.name != name ||
      old.color != color ||
      old.filled != filled ||
      old.strokeWidth != strokeWidth;
}

/// A tolerant interpreter for the SVG `d` subset the icon set uses.
///
/// Commands present in the set: `M m L l H h V v C c A a Z z`. Absolute and
/// relative forms both appear, arcs appear in four icons. Anything else throws
/// at parse time instead of drawing something subtly wrong — the input is a
/// constant, so a throw here is a build-time bug, not a runtime one.
abstract final class SvgPathParser {
  static Path parse(String d) {
    final path = Path();
    final tokens = _tokenize(d);
    var i = 0;

    double nx() => tokens[i++] as double;

    var current = Offset.zero;
    var startOfSubpath = Offset.zero;
    var lastCommand = '';

    while (i < tokens.length) {
      final t = tokens[i];
      String command;
      if (t is String) {
        command = t;
        i++;
      } else {
        // Implicit repetition: repeat the previous command, with `M` meaning
        // line-to for subsequent pairs (per the SVG spec).
        if (lastCommand.isEmpty) throw FormatException('path starts with a number: $d');
        command = lastCommand == 'M' ? 'L' : (lastCommand == 'm' ? 'l' : lastCommand);
      }
      final relative = command == command.toLowerCase();
      final op = command.toUpperCase();

      switch (op) {
        case 'M':
          final x = nx(), y = nx();
          current = relative ? current + Offset(x, y) : Offset(x, y);
          startOfSubpath = current;
          path.moveTo(current.dx, current.dy);
        case 'L':
          final x = nx(), y = nx();
          current = relative ? current + Offset(x, y) : Offset(x, y);
          path.lineTo(current.dx, current.dy);
        case 'H':
          final x = nx();
          current = Offset(relative ? current.dx + x : x, current.dy);
          path.lineTo(current.dx, current.dy);
        case 'V':
          final y = nx();
          current = Offset(current.dx, relative ? current.dy + y : y);
          path.lineTo(current.dx, current.dy);
        case 'C':
          final x1 = nx(), y1 = nx(), x2 = nx(), y2 = nx(), x = nx(), y = nx();
          final c1 = relative ? current + Offset(x1, y1) : Offset(x1, y1);
          final c2 = relative ? current + Offset(x2, y2) : Offset(x2, y2);
          final end = relative ? current + Offset(x, y) : Offset(x, y);
          path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
          current = end;
        case 'A':
          final rx = nx(), ry = nx(), rotation = nx();
          final largeArc = nx() != 0, sweep = nx() != 0;
          final x = nx(), y = nx();
          final end = relative ? current + Offset(x, y) : Offset(x, y);
          _arcTo(path, current, end, rx, ry, rotation, largeArc, sweep);
          current = end;
        case 'Z':
          path.close();
          current = startOfSubpath;
        default:
          throw FormatException('unsupported SVG command "$command" in: $d');
      }
      lastCommand = command;
    }
    return path;
  }

  /// Arc → cubic segments, using the endpoint parameterisation from the SVG
  /// spec (appendix F.6). Enough for the icon set's rounded corner arcs.
  static void _arcTo(
    Path path,
    Offset from,
    Offset to,
    double rxIn,
    double ryIn,
    double rotationDeg,
    bool largeArc,
    bool sweep,
  ) {
    if (rxIn == 0 || ryIn == 0) {
      path.lineTo(to.dx, to.dy);
      return;
    }
    var rx = rxIn.abs();
    var ry = ryIn.abs();
    final phi = rotationDeg * 3.141592653589793 / 180;
    final cosPhi = _cos(phi), sinPhi = _sin(phi);

    final dx2 = (from.dx - to.dx) / 2;
    final dy2 = (from.dy - to.dy) / 2;
    final x1p = cosPhi * dx2 + sinPhi * dy2;
    final y1p = -sinPhi * dx2 + cosPhi * dy2;

    // Scale the radii up if they cannot span the chord.
    final lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
      final s = _sqrt(lambda);
      rx *= s;
      ry *= s;
    }

    final rx2 = rx * rx, ry2 = ry * ry;
    final num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
    final den = rx2 * y1p * y1p + ry2 * x1p * x1p;
    var coef = den == 0 ? 0.0 : _sqrt(num <= 0 ? 0 : num / den);
    if (largeArc == sweep) coef = -coef;

    final cxp = coef * rx * y1p / ry;
    final cyp = -coef * ry * x1p / rx;
    final cx = cosPhi * cxp - sinPhi * cyp + (from.dx + to.dx) / 2;
    final cy = sinPhi * cxp + cosPhi * cyp + (from.dy + to.dy) / 2;

    final theta1 = _angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dtheta = _angle(
      (x1p - cxp) / rx,
      (y1p - cyp) / ry,
      (-x1p - cxp) / rx,
      (-y1p - cyp) / ry,
    );
    if (!sweep && dtheta > 0) dtheta -= 2 * 3.141592653589793;
    if (sweep && dtheta < 0) dtheta += 2 * 3.141592653589793;

    // A cubic approximates at most a quarter turn well.
    final segments = (dtheta.abs() / (3.141592653589793 / 2)).ceil().clamp(1, 8);
    final delta = dtheta / segments;
    final alpha = 4 / 3 * _tan(delta / 4);

    var theta = theta1;
    var p0 = _onEllipse(cx, cy, rx, ry, cosPhi, sinPhi, theta);
    for (var s = 0; s < segments; s++) {
      final theta2 = theta + delta;
      final p3 = _onEllipse(cx, cy, rx, ry, cosPhi, sinPhi, theta2);
      final t1 = _derivative(rx, ry, cosPhi, sinPhi, theta);
      final t2 = _derivative(rx, ry, cosPhi, sinPhi, theta2);
      path.cubicTo(
        p0.dx + alpha * t1.dx,
        p0.dy + alpha * t1.dy,
        p3.dx - alpha * t2.dx,
        p3.dy - alpha * t2.dy,
        p3.dx,
        p3.dy,
      );
      theta = theta2;
      p0 = p3;
    }
  }

  static Offset _onEllipse(
    double cx,
    double cy,
    double rx,
    double ry,
    double cosPhi,
    double sinPhi,
    double theta,
  ) {
    final x = rx * _cos(theta);
    final y = ry * _sin(theta);
    return Offset(cx + cosPhi * x - sinPhi * y, cy + sinPhi * x + cosPhi * y);
  }

  static Offset _derivative(
    double rx,
    double ry,
    double cosPhi,
    double sinPhi,
    double theta,
  ) {
    final dx = -rx * _sin(theta);
    final dy = ry * _cos(theta);
    return Offset(cosPhi * dx - sinPhi * dy, sinPhi * dx + cosPhi * dy);
  }

  static double _angle(double ux, double uy, double vx, double vy) {
    final dot = ux * vx + uy * vy;
    final len = _sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    if (len == 0) return 0;
    var a = _acos((dot / len).clamp(-1.0, 1.0));
    if (ux * vy - uy * vx < 0) a = -a;
    return a;
  }

  static double _cos(double x) => math.cos(x);
  static double _sin(double x) => math.sin(x);
  static double _tan(double x) => math.tan(x);
  static double _acos(double x) => math.acos(x);
  static double _sqrt(double x) => x <= 0 ? 0 : math.sqrt(x);

  /// Splits a `d` string into command letters and numbers.
  static List<Object> _tokenize(String d) {
    final out = <Object>[];
    final buffer = StringBuffer();
    var sawDot = false;

    void flush() {
      if (buffer.isEmpty) return;
      out.add(double.parse(buffer.toString()));
      buffer.clear();
      sawDot = false;
    }

    for (var i = 0; i < d.length; i++) {
      final ch = d[i];
      if (ch == ' ' || ch == ',' || ch == '\n' || ch == '\t' || ch == '\r') {
        flush();
      } else if (ch == '-' || ch == '+') {
        // A sign always starts a new number, except after an exponent.
        final last = buffer.isEmpty ? '' : buffer.toString().substring(buffer.length - 1);
        if (last == 'e' || last == 'E') {
          buffer.write(ch);
        } else {
          flush();
          buffer.write(ch);
        }
      } else if (ch == '.') {
        if (sawDot) {
          flush();
        }
        sawDot = true;
        buffer.write(ch);
      } else if (RegExp(r'[0-9]').hasMatch(ch)) {
        buffer.write(ch);
      } else if (RegExp(r'[A-Za-z]').hasMatch(ch)) {
        flush();
        out.add(ch);
      } else {
        throw FormatException('unexpected character "$ch" in path: $d');
      }
    }
    flush();
    return out;
  }
}
