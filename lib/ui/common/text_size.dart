import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../state/display_providers.dart';

/// Settings, View, Text size, applied to everything below it.
///
/// It sits above the navigator, so every screen, dialog and sheet gets it
/// without asking. Android's own font size is multiplied, not replaced: the
/// phone's setting is somebody's eyesight, and this one is a preference on
/// top of it.
///
/// At the default size nothing is wrapped at all, so an install that never
/// touches the setting lays out exactly as it did before there was one.
class AppTextSize extends ConsumerWidget {
  const AppTextSize({super.key, required this.child});

  final Widget child;

  /// The multiplier in force here, or 1 where there is none.
  static double factorOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_TextSizeFactor>()
          ?.factor ??
      1.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factor =
        ref.watch(displayProvider.select((d) => d.textSize.factor));
    if (factor == 1.0) return _TextSizeFactor(factor: factor, child: child);
    final media = MediaQuery.of(context);
    return _TextSizeFactor(
      factor: factor,
      child: MediaQuery(
        data: media.copyWith(
          textScaler: multiplyTextScaler(media.textScaler, factor),
        ),
        child: child,
      ),
    );
  }
}

class _TextSizeFactor extends InheritedWidget {
  const _TextSizeFactor({required this.factor, required super.child});

  final double factor;

  @override
  bool updateShouldNotify(_TextSizeFactor old) => old.factor != factor;
}

/// [base] with every size multiplied by [factor].
///
/// Android 14 scales small text more than large, so the system's scaler is
/// not a single number; multiplying what it returns keeps that shape.
TextScaler multiplyTextScaler(TextScaler base, double factor) =>
    factor == 1.0 ? base : _MultipliedTextScaler(base, factor);

class _MultipliedTextScaler extends TextScaler {
  const _MultipliedTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  // Equal when made from the same parts, or MediaQuery would treat every
  // rebuild above it as a change of text size and relayout the whole app.
  @override
  bool operator ==(Object other) =>
      other is _MultipliedTextScaler &&
      other.base == base &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);

  @override
  String toString() => '$base × $factor';
}

/// The text zoom, in percent, for a WebView showing mail.
///
/// Android's WebView starts at the system font scale times 100, which is
/// how message bodies already grew with the phone's font size. This keeps
/// that and multiplies it by the app's own setting.
int webTextZoom({required double androidFontScale, required double factor}) =>
    (androidFontScale * factor * 100).round();

/// The zoom a WebView at [context] should have, or null to leave it alone.
///
/// Null until the setting is off its default, or has been: until then the
/// WebView's own starting zoom is already right, and leaving it alone means
/// a message looks exactly as it did before this setting existed. [applied]
/// says whether this WebView has been given a zoom before, which is what
/// brings it back to Android's size when the setting returns to Default.
///
/// Call from didChangeDependencies: it depends on the text size and on
/// Android's, so a change to either comes back there.
int? webTextZoomAt(BuildContext context, {required bool applied}) {
  final factor = AppTextSize.factorOf(context);
  MediaQuery.textScalerOf(context);
  if (factor == 1.0 && !applied) return null;
  // The linear scale, which is what the WebView starts from. Android 14's
  // scaler is steeper for small text than large, and asking it for any one
  // size would give a different number.
  return webTextZoom(
    androidFontScale: View.of(context).platformDispatcher.textScaleFactor,
    factor: factor,
  );
}

/// Replaces the platform call in tests, which have no Android WebView.
@visibleForTesting
void Function(WebViewController controller, int zoom)? debugWebTextZoom;

/// Sets a WebView's text zoom, where the platform allows it.
void applyWebTextZoom(WebViewController controller, int zoom) {
  if (debugWebTextZoom case final hook?) return hook(controller, zoom);
  final platform = controller.platform;
  if (kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      platform is! AndroidWebViewController) {
    return;
  }
  try {
    platform.setTextZoom(zoom);
  } catch (e) {
    debugPrint('[myemail] could not size the web view text: $e');
  }
}
