/// How important the sender marked a message: Outlook's High and Low
/// Importance. Almost all mail is normal.
enum Importance {
  low('Low'),
  normal('Normal'),
  high('High');

  const Importance(this.label);

  final String label;

  /// From the headers a message carries, the first that says: `Importance`
  /// (what Outlook writes), then `X-Priority` (1 and 2 high, 4 and 5 low),
  /// then `Priority` (urgent, non-urgent), then `X-MSMail-Priority`.
  static Importance fromHeaders({
    String? importance,
    String? xPriority,
    String? priority,
    String? msMailPriority,
  }) {
    switch (importance?.trim().toLowerCase()) {
      case 'high':
        return Importance.high;
      case 'low':
        return Importance.low;
      case 'normal':
        return Importance.normal;
    }
    final number = RegExp(r'^\s*([1-5])').firstMatch(xPriority ?? '');
    if (number != null) {
      return switch (number.group(1)) {
        '1' || '2' => Importance.high,
        '4' || '5' => Importance.low,
        _ => Importance.normal,
      };
    }
    switch (priority?.trim().toLowerCase()) {
      case 'urgent':
        return Importance.high;
      case 'non-urgent':
        return Importance.low;
    }
    return switch (msMailPriority?.trim().toLowerCase()) {
      'high' => Importance.high,
      'low' => Importance.low,
      _ => Importance.normal,
    };
  }

  /// From Microsoft Graph's `importance`: `low`, `normal` or `high`.
  static Importance fromGraph(Object? value) => switch ('$value'.toLowerCase()) {
        'high' => Importance.high,
        'low' => Importance.low,
        _ => Importance.normal,
      };

  /// The headers a message sent at this importance carries, as Outlook
  /// writes them. None for normal.
  Map<String, String> get headers => switch (this) {
        Importance.high => const {
            'Importance': 'High',
            'X-Priority': '1 (Highest)',
          },
        Importance.low => const {
            'Importance': 'Low',
            'X-Priority': '5 (Lowest)',
          },
        Importance.normal => const {},
      };

  /// The names of the headers [fromHeaders] reads, as they are asked for.
  static const headerNames = [
    'Importance',
    'X-Priority',
    'Priority',
    'X-MSMail-Priority',
  ];

  /// [fromHeaders] on what a header lookup found, keyed by name in lower
  /// case.
  static Importance fromHeaderMap(Map<String, String> found) => fromHeaders(
        importance: found['importance'],
        xPriority: found['x-priority'],
        priority: found['priority'],
        msMailPriority: found['x-msmail-priority'],
      );
}
