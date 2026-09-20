import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/print/message_printer.dart';

/// How a message is printed. main() overrides this with the Android print
/// sheet; tests and the browser preview record instead.
final messagePrinterProvider =
    Provider<MessagePrinter>((ref) => FakeMessagePrinter(supported: false));

final printingAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(messagePrinterProvider).available(),
);
