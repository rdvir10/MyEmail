import 'package:flutter/material.dart';

import '../../domain/time_zones.dart';

/// What [pickTimeZone] answers: a zone, by its IANA name, or none.
typedef ZoneChoice = ({String? zone});

/// A zone chosen from the world's, searched by place: Outlook's Time zones.
/// [none] names the choice that is no zone ("None", "Your own"), offered
/// first. Null if backed out of.
Future<ZoneChoice?> pickTimeZone(
  BuildContext context, {
  String? current,
  required String none,
}) =>
    showModalBottomSheet<ZoneChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ZonePicker(current: current, none: none),
    );

class _ZonePicker extends StatefulWidget {
  const _ZonePicker({required this.current, required this.none});

  final String? current;
  final String none;

  @override
  State<_ZonePicker> createState() => _ZonePickerState();
}

class _ZonePickerState extends State<_ZonePicker> {
  final _search = TextEditingController();
  late final List<String> _all = allTimeZones();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final q = _query.trim().toLowerCase().replaceAll(' ', '_');
    final shown = [
      for (final z in _all)
        if (q.isEmpty || z.toLowerCase().contains(q)) z,
    ];
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                key: const ValueKey('zone-search'),
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'A city: New York, London, Jerusalem',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (q.isEmpty)
                    ListTile(
                      key: const ValueKey('zone-none'),
                      title: Text(widget.none),
                      trailing: widget.current == null
                          ? Icon(Icons.check, color: theme.colorScheme.primary)
                          : null,
                      onTap: () => Navigator.of(context).pop((zone: null)),
                    ),
                  for (final z in shown)
                    ListTile(
                      key: ValueKey('zone:$z'),
                      title: Text(placeOf(z)),
                      subtitle: Text('$z · ${offsetOf(z, now)}'),
                      trailing: z == widget.current
                          ? Icon(Icons.check, color: theme.colorScheme.primary)
                          : null,
                      onTap: () => Navigator.of(context).pop((zone: z)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
