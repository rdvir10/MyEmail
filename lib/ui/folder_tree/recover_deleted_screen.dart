import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/folder_role.dart';
import '../../domain/recoverable_message.dart';
import '../../state/folder_tree.dart' show kUnifiedInboxId;
import '../../state/message_providers.dart';
import '../../state/providers.dart';
import '../common/bottom_message.dart';
import '../messages/date_format.dart';

/// Open Recover Deleted Items for [accountId].
Future<void> openRecoverDeleted(BuildContext context, String accountId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecoverDeletedScreen(accountId: accountId),
      ),
    );

/// Recover Deleted Items, as Outlook has it: the mail emptied out of a
/// Microsoft account's Deleted Items in the last few weeks, which Exchange
/// keeps out of sight, ticked and put back.
///
/// Back into the Inbox, as Outlook on the web puts back what it cannot
/// tell the folder of. Newest received first, more as the list is scrolled,
/// and a search over all of it.
class RecoverDeletedScreen extends ConsumerStatefulWidget {
  const RecoverDeletedScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<RecoverDeletedScreen> createState() =>
      _RecoverDeletedScreenState();
}

class _RecoverDeletedScreenState extends ConsumerState<RecoverDeletedScreen> {
  static const _page = 50;

  final _items = <RecoverableMessage>[];
  final _ticked = <String>{};
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';
  bool _loading = true;
  bool _more = false;
  bool _restoring = false;
  Object? _error;

  /// Which load is the latest: one overtaken by a search is let fall.
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearEnd);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _nearEnd() {
    if (!_more || _loading || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 300) _load();
  }

  Future<void> _load({bool reset = false}) async {
    final asked = ++_asked;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _ticked.clear();
        _more = false;
      }
    });
    try {
      final found = await ref.read(mailEngineProvider).recoverableMessages(
            widget.accountId,
            query: _query,
            offset: reset ? 0 : _items.length,
            limit: _page,
          );
      if (!mounted || asked != _asked) return;
      setState(() {
        final had = {for (final m in _items) m.id};
        _items.addAll(found.where((m) => !had.contains(m.id)));
        // A search answers once, in its own order; the list pages.
        _more = _query.isEmpty && found.length == _page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || asked != _asked) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _searchFor(String text) {
    final query = text.trim();
    if (query == _query) return;
    _query = query;
    _load(reset: true);
  }

  Future<void> _restore() async {
    final ids = [..._ticked];
    if (ids.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _restoring = true);
    String said;
    try {
      final n =
          await ref.read(mailEngineProvider).recoverMessages(widget.accountId, ids);
      said = n == ids.length
          ? (n == 1
              ? 'Restored to the Inbox.'
              : '$n messages restored to the Inbox.')
          : n == 0
              ? 'Could not restore them. Try again.'
              : 'Restored $n of ${ids.length} to the Inbox.';
      _rereadInbox();
    } catch (e) {
      said = 'Could not restore: $e';
    }
    if (!mounted) return;
    setState(() => _restoring = false);
    messenger?.showSnackBar(
      SnackBar(duration: kBottomMessage, content: Text(said)),
    );
    // Read again rather than guessed at: which ones went is the server's
    // to say, and a count does not say it.
    unawaited(_load(reset: true));
  }

  /// The Inbox the mail went back to, in every list that shows it.
  void _rereadInbox() {
    final inbox = ref
        .read(folderIndexProvider)
        .values
        .where(
          (f) => f.accountId == widget.accountId && f.role == FolderRole.inbox,
        )
        .firstOrNull;
    if (inbox != null) ref.invalidate(messagesProvider(inbox.id));
    ref.invalidate(messagesProvider(kUnifiedInboxId));
    unawaited(ref
        .read(foldersProvider.notifier)
        .refreshAccount(widget.accountId)
        .catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = (ref.watch(accountsProvider).value ?? const [])
        .where((a) => a.id == widget.accountId)
        .firstOrNull;
    final allTicked =
        _items.isNotEmpty && _items.every((m) => _ticked.contains(m.id));
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Recover deleted items'),
            if (account != null)
              Text(
                account.displayName,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              tooltip: allTicked ? 'Clear selection' : 'Select all',
              icon: Icon(allTicked ? Icons.deselect : Icons.select_all),
              onPressed: () => setState(() {
                if (allTicked) {
                  _ticked.clear();
                } else {
                  _ticked.addAll(_items.map((m) => m.id));
                }
              }),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                'Mail emptied out of Deleted Items in the last few weeks. '
                'What you restore goes back to the Inbox.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: _searchFor,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search deleted items',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            _searchFor('');
                          },
                        ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _list(theme)),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _ticked.isEmpty
                          ? 'Tick the messages to restore'
                          : '${_ticked.length} ticked',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('recover-restore'),
                    onPressed:
                        _ticked.isEmpty || _restoring ? null : _restore,
                    icon: _restoring
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.restore),
                    label: const Text('Restore'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(ThemeData theme) {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not read the deleted items. $_error',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _load(reset: true),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _query.isEmpty
                      ? 'Nothing to recover. Mail stays here for a few weeks '
                          'after Deleted Items is emptied.'
                      : 'Nothing found.',
                  textAlign: TextAlign.center,
                ),
              ),
      );
    }
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListView.separated(
      controller: _scroll,
      itemCount: _items.length + (_loading || _more ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final m = _items[i];
        final ticked = _ticked.contains(m.id);
        return InkWell(
          key: ValueKey('recoverable:${m.id}'),
          onTap: () => setState(() {
            if (!_ticked.remove(m.id)) _ticked.add(m.id);
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 16, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: ticked,
                  onChanged: (_) => setState(() {
                    if (!_ticked.remove(m.id)) _ticked.add(m.id);
                  }),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              m.from.display,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (m.hasAttachments)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.attach_file,
                                size: 14,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(width: 8),
                          Text(
                            formatMessageDate(m.received, use24h: use24h),
                            style: muted,
                          ),
                        ],
                      ),
                      Text(
                        m.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (m.deletedOn case final deleted?)
                        Text(
                          'Deleted ${formatMessageDate(deleted, use24h: use24h)}',
                          style: muted,
                        )
                      else if (m.preview.isNotEmpty)
                        Text(
                          m.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
