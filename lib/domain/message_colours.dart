import 'dart:math' as math;

/// A message's own colours, turned for a dark page.
///
/// A message that sets its own colours was written for a white page. Left
/// as it is, it sits in the dark theme as a white sheet; darkened underneath
/// without touching its colours, its black text vanishes. So each colour is
/// turned according to what it paints, the way Outlook's app does it:
///
///  * a light background turns dark, white landing exactly on [page];
///  * dark text turns light, black landing exactly on [text];
///  * a line (a border, an outline) is turned over, so a pale rule that was
///    barely there on white is barely there on the dark, and a black one
///    shows;
///  * a background that is already dark, and text that is already light,
///    are left as the sender chose them. White text on a blue banner, or a
///    newsletter designed dark, comes through unchanged.
///
/// Hue is kept: a blue header stays blue, only darker. Pictures are not
/// touched at all.
///
/// [page] and [text] are 0xRRGGBB. Anything this does not recognise as a
/// colour is left exactly as written.
String darkenMessageColours(
  String html, {
  required int page,
  required int text,
}) {
  final palette = _Palette(page: page, text: text);
  return html
      .replaceAllMapped(
        _styleElement,
        (m) => '${m[1]}${_darkenCss(m[2]!, palette)}${m[3]}',
      )
      .replaceAllMapped(
        _tag,
        (m) => '<${m[1]}${_darkenAttributes(m[2]!, palette)}>',
      );
}

/// [html] ready to show either way: wherever [darkenMessageColours] would
/// change a colour, the element is marked `data-mt-colours` and carries the
/// dark version beside the original, as `data-mt-dark-<attribute>`, or
/// `data-mt-dark-css` on a `<style>` for its text. With [dark] the dark
/// version is the one in place and the original waits in
/// `data-mt-light-<attribute>`; without, the original is in place.
///
/// For the compose editor. Its document is what gets sent, so the quote
/// cannot simply be recoloured: the editor's script swaps the two as the
/// theme changes, and puts the originals back in what it hands over.
String markDarkColours(
  String html, {
  required int page,
  required int text,
  required bool dark,
}) {
  final palette = _Palette(page: page, text: text);
  String marks(String name, String light, String turned,
          String Function(String) escape) =>
      ' data-mt-dark-$name="${escape(turned)}"'
      '${dark ? ' data-mt-light-$name="${escape(light)}"' : ''}';
  return html
      .replaceAllMapped(_styleElement, (m) {
        final css = m[2]!;
        final turned = _darkenCss(css, palette);
        if (turned == css) return m[0]!;
        // `<style` is six characters, whatever its case.
        return '<style data-mt-colours${marks('css', css, turned, _escapeCss)}'
            '${m[1]!.substring(6)}${dark ? turned : css}${m[3]}';
      })
      .replaceAllMapped(_tag, (m) {
        // Done above, and its marks hold CSS that is no attribute's.
        if (m[1]!.toLowerCase() == 'style') return m[0]!;
        final added = StringBuffer();
        final turned = _darkenAttributes(
          m[2]!,
          palette,
          (name, light, darkened) =>
              added.write(marks(name, light, darkened, _escapeQuotes)),
        );
        if (added.isEmpty) return m[0]!;
        return '<${m[1]} data-mt-colours$added${dark ? turned : m[2]}>';
      });
}

/// An attribute's value as the source wrote it is already escaped, except
/// for a double quote inside single ones.
String _escapeQuotes(String value) => value.replaceAll('"', '&quot;');

/// A style sheet's text is not escaped at all.
String _escapeCss(String css) =>
    css.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

/// A message's `prefers-color-scheme` queries, answered by the app.
///
/// The WebView answers them from Android's dark theme setting, which is not
/// the app's once the app has a setting of its own. A message with a dark
/// design of its own would show it in a light app, or hold it back in a
/// dark one. The query is replaced by one that is always true, `(color)`,
/// or never, `(monochrome)`, on a phone's screen.
String answerColourSchemeQueries(String html, {required bool dark}) {
  String answer(String css) => css.replaceAllMapped(
        _schemeQuery,
        (m) => (m[1]!.toLowerCase() == 'dark') == dark ? 'color' : 'monochrome',
      );
  return html
      .replaceAllMapped(_styleElement, (m) => answer(m[0]!))
      // A <style media> or a <picture>'s <source media>.
      .replaceAllMapped(_mediaAttribute, (m) => '${m[1]}${answer(m[2]!)}');
}

final _schemeQuery = RegExp(
  r'prefers-color-scheme\s*:\s*(dark|light)',
  caseSensitive: false,
);

final _mediaAttribute = RegExp(
  r'''(\bmedia\s*=\s*)("[^"]*"|'[^']*')''',
  caseSensitive: false,
);

final _styleElement = RegExp(
  r'(<style\b[^>]*>)([\s\S]*?)(</style\s*>)',
  caseSensitive: false,
);

/// An opening tag, with a `>` inside a quoted value not taken as its end.
final _tag = RegExp(r'''<([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>''');

/// One attribute and its value. Each match consumes the value whole, so a
/// name inside someone else's value (a data: URI, a title) is never seen.
final _attribute = RegExp(
  r'''([\w:-]+)(\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''',
);

/// What a colour paints decides which way it turns.
enum _Role { background, text, line }

const _attributeRoles = {
  'bgcolor': _Role.background,
  'color': _Role.text,
  // On <body>: its text and its links.
  'text': _Role.text,
  'link': _Role.text,
  'vlink': _Role.text,
  'alink': _Role.text,
  'bordercolor': _Role.line,
};

/// [attributes] with their colours darkened, telling [changed] of each one
/// that differs: its name, its value as written, and darkened.
String _darkenAttributes(
  String attributes,
  _Palette palette, [
  void Function(String name, String light, String dark)? changed,
]) =>
    attributes.replaceAllMapped(_attribute, (m) {
      final name = m[1]!.toLowerCase();
      final role = _attributeRoles[name];
      if (role == null && name != 'style') return m[0]!;
      final quote = m[3] != null
          ? '"'
          : m[4] != null
              ? "'"
              : '';
      final value = m[3] ?? m[4] ?? m[5]!;
      final turned = role == null
          ? _darkenCss(value, palette)
          : _darkenValue(value, role, palette);
      if (turned != value) changed?.call(name, value, turned);
      return '${m[1]}${m[2]}$quote$turned$quote';
    });

/// A declaration of a property that carries a colour. Not one that only
/// ends in a colour property's name (`mso-border-alt`, a `.color` class),
/// and not `border-collapse` or `background-image`, which carry none.
final _declaration = RegExp(
  r'(?<![-\w.#])('
  r'background-color|background|'
  r'border(?:-(?:top|right|bottom|left))?(?:-color)?|'
  r'outline(?:-color)?|column-rule(?:-color)?|'
  r'color|text-decoration(?:-color)?|-webkit-text-fill-color|caret-color'
  r')(\s*:\s*)([^;{}]+)',
  caseSensitive: false,
);

String _darkenCss(String css, _Palette palette) =>
    css.replaceAllMapped(_declaration, (m) {
      final property = m[1]!.toLowerCase();
      final role = property.startsWith('background')
          ? _Role.background
          : property.startsWith('border') ||
                  property.startsWith('outline') ||
                  property.startsWith('column-rule')
              ? _Role.line
              : _Role.text;
      return '${m[1]}${m[2]}${_darkenValue(m[3]!, role, palette)}';
    });

final _url = RegExp(r'url\([^)]*\)', caseSensitive: false);

/// Every colour in a value, and nothing inside a `url(...)`: a picture's
/// address can hold a `#` or the word white.
String _darkenValue(String value, _Role role, _Palette palette) {
  final out = StringBuffer();
  var at = 0;
  for (final url in _url.allMatches(value)) {
    out
      ..write(_darkenColours(value.substring(at, url.start), role, palette))
      ..write(url[0]);
    at = url.end;
  }
  out.write(_darkenColours(value.substring(at), role, palette));
  return out.toString();
}

final _colourWord = RegExp(
  r'#[0-9a-f]{3,8}\b|\b(?:rgb|hsl)a?\([^)]*\)|\b(?:'
  '${_named.keys.join('|')}'
  r')\b',
  caseSensitive: false,
);

String _darkenColours(String text, _Role role, _Palette palette) =>
    text.replaceAllMapped(_colourWord, (m) {
      final colour = _Colour.parse(m[0]!);
      if (colour == null) return m[0]!;
      final turned = palette.turn(colour, role);
      // One left as it was keeps the way it was written, too.
      return identical(turned, colour) ? m[0]! : turned.css;
    });

/// The dark page and its text, in OKLab: a space where lightness is what
/// the eye sees as lightness, so turning it keeps the hue.
class _Palette {
  _Palette({required int page, required int text})
      : page = _Lab.of(_Colour.rgb(page)),
        text = _Lab.of(_Colour.rgb(text));

  final _Lab page;
  final _Lab text;

  /// Where turning over leaves a lightness where it was. Below it a
  /// background is already dark; above it, text is already light.
  late final double pivot = text.l / (1 + text.l - page.l);

  /// Text below this is too dark to read on the page and is lifted above
  /// it; at or above, it reads well enough already and is left alone.
  static const textFloor = 0.62;

  /// Black lands on [text], white on [page], the rest in between, darkest
  /// last.
  double _turnedOver(double l) => text.l - (text.l - page.l) * l;

  _Colour turn(_Colour colour, _Role role) {
    final lab = _Lab.of(colour);
    switch (role) {
      case _Role.background:
        if (lab.l <= pivot) return colour;
        // Toward the page's own tint as it nears white, so a white table
        // cell is the page and not a grey a shade off it.
        final t = (lab.l - pivot) / (1 - pivot);
        // A vivid one stays as far above the page as it is colourful.
        // Turned over like the rest, a yellow highlight came out as dark
        // as the page, and with no room left for its colour it vanished.
        final chroma = math.sqrt(lab.a * lab.a + lab.b * lab.b);
        return _Lab(
          math.max(_turnedOver(lab.l), page.l + chroma),
          lab.a + page.a * t,
          lab.b + page.b * t,
        ).toColour(colour.alpha);
      case _Role.text:
        if (lab.l >= textFloor) return colour;
        final t = 1 - lab.l / textFloor;
        return _Lab(
          text.l - (text.l - textFloor) * (lab.l / textFloor),
          lab.a + text.a * t,
          lab.b + text.b * t,
        ).toColour(colour.alpha);
      case _Role.line:
        return _Lab(_turnedOver(lab.l), lab.a, lab.b).toColour(colour.alpha);
    }
  }
}

/// A colour in sRGB, each channel 0 to 1.
class _Colour {
  const _Colour(this.red, this.green, this.blue, [this.alpha = 1]);

  _Colour.rgb(int rgb)
      : red = (rgb >> 16 & 0xff) / 255,
        green = (rgb >> 8 & 0xff) / 255,
        blue = (rgb & 0xff) / 255,
        alpha = 1;

  final double red, green, blue, alpha;

  /// `#fff`, `#ffffff` (with or without alpha), `rgb()`, `rgba()`, `hsl()`,
  /// `hsla()` in either the comma or the space syntax, or a name. Null for
  /// anything else, which is then left as it was.
  static _Colour? parse(String word) {
    final s = word.trim().toLowerCase();
    if (s.startsWith('#')) return _hex(s.substring(1));
    final call = RegExp(r'^(rgb|hsl)a?\((.*)\)$').firstMatch(s);
    if (call != null) {
      final parts = call[2]!
          .split(RegExp(r'[\s,/]+'))
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.length != 3 && parts.length != 4) return null;
      try {
        final alpha = parts.length == 4 ? _fraction(parts[3], 1) : 1.0;
        return call[1] == 'rgb'
            ? _Colour(
                _fraction(parts[0], 255),
                _fraction(parts[1], 255),
                _fraction(parts[2], 255),
                alpha,
              )
            : _hsl(_degrees(parts[0]), _fraction(parts[1], 100),
                _fraction(parts[2], 100), alpha);
      } on FormatException {
        return null;
      }
    }
    final named = _named[s];
    return named == null ? null : _Colour.rgb(named);
  }

  static _Colour? _hex(String digits) {
    if (![3, 4, 6, 8].contains(digits.length)) return null;
    final full = digits.length <= 4
        ? digits.split('').map((d) => '$d$d').join()
        : digits;
    final value = int.tryParse(full, radix: 16);
    if (value == null) return null;
    final rgb = full.length == 8 ? value >> 8 : value;
    final alpha = full.length == 8 ? (value & 0xff) / 255 : 1.0;
    final c = _Colour.rgb(rgb);
    return _Colour(c.red, c.green, c.blue, alpha);
  }

  /// A number out of [scale], or a percentage, as 0 to 1.
  static double _fraction(String part, double scale) {
    if (part == 'none') return 0;
    final percent = part.endsWith('%');
    final n = double.parse(percent ? part.substring(0, part.length - 1) : part);
    return (percent ? n / 100 : n / scale).clamp(0.0, 1.0);
  }

  static double _degrees(String part) {
    for (final (unit, toDegrees) in [
      ('grad', 0.9),
      ('turn', 360.0),
      ('rad', 180 / math.pi),
      ('deg', 1.0),
    ]) {
      if (part.endsWith(unit)) {
        return double.parse(part.substring(0, part.length - unit.length)) *
            toDegrees;
      }
    }
    return double.parse(part);
  }

  static _Colour _hsl(double hue, double s, double l, double alpha) {
    final h = (hue % 360) / 360;
    if (s == 0) return _Colour(l, l, l, alpha);
    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    double channel(double t) {
      t = t < 0 ? t + 1 : (t > 1 ? t - 1 : t);
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }

    return _Colour(channel(h + 1 / 3), channel(h), channel(h - 1 / 3), alpha);
  }

  /// As CSS: hex where it is opaque, rgba() where it is not.
  String get css {
    int byte(double v) => (v * 255).round().clamp(0, 255);
    String hex(double v) => byte(v).toRadixString(16).padLeft(2, '0');
    if (alpha >= 1) return '#${hex(red)}${hex(green)}${hex(blue)}';
    final a = double.parse(alpha.toStringAsFixed(3));
    return 'rgba(${byte(red)},${byte(green)},${byte(blue)},$a)';
  }
}

/// OKLab, after Björn Ottosson: L is lightness from 0 to 1, a and b the
/// colour's direction away from grey.
class _Lab {
  const _Lab(this.l, this.a, this.b);

  factory _Lab.of(_Colour c) {
    final r = _linear(c.red), g = _linear(c.green), b = _linear(c.blue);
    final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return _Lab(
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    );
  }

  final double l, a, b;

  /// Back to sRGB. Where the colour at this lightness is more vivid than a
  /// screen can show, it is made less vivid until it fits: cutting each
  /// channel off at its limit would change the hue and the lightness too.
  _Colour toColour(double alpha) {
    var rgb = _rgb(1);
    if (!_fits(rgb)) {
      var low = 0.0, high = 1.0;
      for (var i = 0; i < 16; i++) {
        final mid = (low + high) / 2;
        if (_fits(_rgb(mid))) {
          low = mid;
        } else {
          high = mid;
        }
      }
      rgb = _rgb(low);
    }
    double clamp(double v) => v.clamp(0.0, 1.0);
    return _Colour(clamp(rgb.$1), clamp(rgb.$2), clamp(rgb.$3), alpha);
  }

  /// In sRGB with the colourfulness scaled by [chroma].
  (double, double, double) _rgb(double chroma) {
    final ca = a * chroma, cb = b * chroma;
    final l_ = l + 0.3963377774 * ca + 0.2158037573 * cb;
    final m_ = l - 0.1055613458 * ca - 0.0638541728 * cb;
    final s_ = l - 0.0894841775 * ca - 1.2914855480 * cb;
    final lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_;
    return (
      _gamma(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
      _gamma(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
      _gamma(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc),
    );
  }

  static bool _fits((double, double, double) rgb) {
    const slack = 0.5 / 255;
    bool ok(double v) => v >= -slack && v <= 1 + slack;
    return ok(rgb.$1) && ok(rgb.$2) && ok(rgb.$3);
  }

  static double _linear(double c) => c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  static double _gamma(double c) => c <= 0.0031308
      ? 12.92 * c
      : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

  static double _cbrt(double v) =>
      v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
}

/// CSS's named colours, and the old system colours Outlook writes
/// (`windowtext` above all) at the values they have on a light page.
const _named = {
  'aliceblue': 0xf0f8ff, 'antiquewhite': 0xfaebd7, 'aqua': 0x00ffff,
  'aquamarine': 0x7fffd4, 'azure': 0xf0ffff, 'beige': 0xf5f5dc,
  'bisque': 0xffe4c4, 'black': 0x000000, 'blanchedalmond': 0xffebcd,
  'blue': 0x0000ff, 'blueviolet': 0x8a2be2, 'brown': 0xa52a2a,
  'burlywood': 0xdeb887, 'cadetblue': 0x5f9ea0, 'chartreuse': 0x7fff00,
  'chocolate': 0xd2691e, 'coral': 0xff7f50, 'cornflowerblue': 0x6495ed,
  'cornsilk': 0xfff8dc, 'crimson': 0xdc143c, 'cyan': 0x00ffff,
  'darkblue': 0x00008b, 'darkcyan': 0x008b8b, 'darkgoldenrod': 0xb8860b,
  'darkgray': 0xa9a9a9, 'darkgreen': 0x006400, 'darkgrey': 0xa9a9a9,
  'darkkhaki': 0xbdb76b, 'darkmagenta': 0x8b008b,
  'darkolivegreen': 0x556b2f, 'darkorange': 0xff8c00,
  'darkorchid': 0x9932cc, 'darkred': 0x8b0000, 'darksalmon': 0xe9967a,
  'darkseagreen': 0x8fbc8f, 'darkslateblue': 0x483d8b,
  'darkslategray': 0x2f4f4f, 'darkslategrey': 0x2f4f4f,
  'darkturquoise': 0x00ced1, 'darkviolet': 0x9400d3,
  'deeppink': 0xff1493, 'deepskyblue': 0x00bfff, 'dimgray': 0x696969,
  'dimgrey': 0x696969, 'dodgerblue': 0x1e90ff, 'firebrick': 0xb22222,
  'floralwhite': 0xfffaf0, 'forestgreen': 0x228b22, 'fuchsia': 0xff00ff,
  'gainsboro': 0xdcdcdc, 'ghostwhite': 0xf8f8ff, 'gold': 0xffd700,
  'goldenrod': 0xdaa520, 'gray': 0x808080, 'green': 0x008000,
  'greenyellow': 0xadff2f, 'grey': 0x808080, 'honeydew': 0xf0fff0,
  'hotpink': 0xff69b4, 'indianred': 0xcd5c5c, 'indigo': 0x4b0082,
  'ivory': 0xfffff0, 'khaki': 0xf0e68c, 'lavender': 0xe6e6fa,
  'lavenderblush': 0xfff0f5, 'lawngreen': 0x7cfc00,
  'lemonchiffon': 0xfffacd, 'lightblue': 0xadd8e6, 'lightcoral': 0xf08080,
  'lightcyan': 0xe0ffff, 'lightgoldenrodyellow': 0xfafad2,
  'lightgray': 0xd3d3d3, 'lightgreen': 0x90ee90, 'lightgrey': 0xd3d3d3,
  'lightpink': 0xffb6c1, 'lightsalmon': 0xffa07a,
  'lightseagreen': 0x20b2aa, 'lightskyblue': 0x87cefa,
  'lightslategray': 0x778899, 'lightslategrey': 0x778899,
  'lightsteelblue': 0xb0c4de, 'lightyellow': 0xffffe0, 'lime': 0x00ff00,
  'limegreen': 0x32cd32, 'linen': 0xfaf0e6, 'magenta': 0xff00ff,
  'maroon': 0x800000, 'mediumaquamarine': 0x66cdaa,
  'mediumblue': 0x0000cd, 'mediumorchid': 0xba55d3,
  'mediumpurple': 0x9370db, 'mediumseagreen': 0x3cb371,
  'mediumslateblue': 0x7b68ee, 'mediumspringgreen': 0x00fa9a,
  'mediumturquoise': 0x48d1cc, 'mediumvioletred': 0xc71585,
  'midnightblue': 0x191970, 'mintcream': 0xf5fffa,
  'mistyrose': 0xffe4e1, 'moccasin': 0xffe4b5, 'navajowhite': 0xffdead,
  'navy': 0x000080, 'oldlace': 0xfdf5e6, 'olive': 0x808000,
  'olivedrab': 0x6b8e23, 'orange': 0xffa500, 'orangered': 0xff4500,
  'orchid': 0xda70d6, 'palegoldenrod': 0xeee8aa, 'palegreen': 0x98fb98,
  'paleturquoise': 0xafeeee, 'palevioletred': 0xdb7093,
  'papayawhip': 0xffefd5, 'peachpuff': 0xffdab9, 'peru': 0xcd853f,
  'pink': 0xffc0cb, 'plum': 0xdda0dd, 'powderblue': 0xb0e0e6,
  'purple': 0x800080, 'rebeccapurple': 0x663399, 'red': 0xff0000,
  'rosybrown': 0xbc8f8f, 'royalblue': 0x4169e1, 'saddlebrown': 0x8b4513,
  'salmon': 0xfa8072, 'sandybrown': 0xf4a460, 'seagreen': 0x2e8b57,
  'seashell': 0xfff5ee, 'sienna': 0xa0522d, 'silver': 0xc0c0c0,
  'skyblue': 0x87ceeb, 'slateblue': 0x6a5acd, 'slategray': 0x708090,
  'slategrey': 0x708090, 'snow': 0xfffafa, 'springgreen': 0x00ff7f,
  'steelblue': 0x4682b4, 'tan': 0xd2b48c, 'teal': 0x008080,
  'thistle': 0xd8bfd8, 'tomato': 0xff6347, 'turquoise': 0x40e0d0,
  'violet': 0xee82ee, 'wheat': 0xf5deb3, 'white': 0xffffff,
  'whitesmoke': 0xf5f5f5, 'yellow': 0xffff00, 'yellowgreen': 0x9acd32,
  // System colours, as a light page has them.
  'windowtext': 0x000000, 'window': 0xffffff, 'canvastext': 0x000000,
  'canvas': 0xffffff, 'buttontext': 0x000000, 'buttonface': 0xf0f0f0,
  'captiontext': 0x000000, 'infotext': 0x000000,
  'infobackground': 0xffffe1, 'menutext': 0x000000, 'menu': 0xffffff,
  'graytext': 0x6d6d6d,
};
