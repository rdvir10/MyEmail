import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ai/on_device_ai.dart';
import 'message_keeping.dart' show notRetried;

/// The phone's own AI; a fake in tests.
final onDeviceAiProvider =
    Provider<OnDeviceAi>((ref) => const AndroidOnDeviceAi());

/// Whether [AiFeature] can be used on this phone, asked once and kept: a
/// phone does not gain Gemini Nano while the app is open. Asked again
/// after a download.
final aiReadinessProvider =
    FutureProvider.family<AiReadiness, AiFeature>((ref, feature) {
  return ref.watch(onDeviceAiProvider).readiness(feature);
}, retry: notRetried);
