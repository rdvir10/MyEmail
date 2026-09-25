import 'package:flutter/foundation.dart';

/// Which service an account talks to. Round one ships Gmail only; the enum
/// exists so that provider-specific behaviour (folder capabilities, Archive
/// conventions, auth strategy) has somewhere to hang other than an `if`.
enum MailProvider {
  gmail('Gmail'),
  outlook('Outlook');

  const MailProvider(this.label);
  final String label;
}

/// How an account proves who it is.
///
/// Round one implements [appPassword] only. An app password never expires, so
/// nothing here deals with refresh; [oauth] is declared so that adding it later
/// does not mean reshaping the account model.
enum AuthMethod { appPassword, oauth }

/// [accounts] in the order [ids] names, then any not named, in the order
/// they had. Ids that name no account are passed over. What a drag of an
/// account heading in the folder list settles on.
List<Account> accountsInOrder(List<Account> accounts, List<String> ids) {
  final byId = {for (final a in accounts) a.id: a};
  final named = <Account>[];
  for (final id in ids) {
    final account = byId.remove(id);
    if (account != null) named.add(account);
  }
  return [...named, for (final a in accounts) if (byId.containsKey(a.id)) a];
}

@immutable
class Account {
  const Account({
    required this.id,
    required this.displayName,
    required this.emailAddress,
    required this.provider,
    required this.authMethod,
    required this.colorValue,
    this.chosenSenderName,
  });

  final String id;
  final String displayName;
  final String emailAddress;
  final MailProvider provider;
  final AuthMethod authMethod;

  /// Accent used to tell accounts apart in the tree and in unified views.
  final int colorValue;

  /// A sender name chosen for this account, or null for none.
  ///
  /// Read through [senderName], which falls back. This is the raw choice,
  /// and exists separately so a settings screen can tell "not set" from
  /// "set to the same thing as the label".
  final String? chosenSenderName;

  /// The name on mail sent from this account.
  ///
  /// Separate from [displayName] because they answer different questions.
  /// The tree label is for the person reading it — "Hadco", "Personal" —
  /// and wants to be short. The sender name is what everyone else sees at
  /// the top of a message from you, and wants to be your name.
  ///
  /// Unset, it falls back to the tree label, which is what every account
  /// sent under before this was a choice.
  String get senderName {
    final chosen = chosenSenderName?.trim() ?? '';
    return chosen.isEmpty ? displayName : chosen;
  }

  /// Whether a name of its own has been chosen, for a settings screen that
  /// must tell "not set" from "set to the same thing".
  bool get hasOwnSenderName => (chosenSenderName?.trim() ?? '').isNotEmpty;

  /// Only the two things a person may change after the fact.
  ///
  /// The address, provider and auth method are deliberately not here. They
  /// are what the stored secret was proved against and what the cache is
  /// keyed on, so changing one is adding a different account, not editing
  /// this one.
  ///
  /// [authMethod] can change, once: an account added with an app password
  /// that signs in with Google from then on is the same account, with the
  /// same cache under it.
  Account copyWith({
    String? displayName,
    int? colorValue,
    String? senderName,
    AuthMethod? authMethod,
  }) =>
      Account(
        id: id,
        displayName: displayName ?? this.displayName,
        emailAddress: emailAddress,
        provider: provider,
        authMethod: authMethod ?? this.authMethod,
        colorValue: colorValue ?? this.colorValue,
        chosenSenderName: senderName ?? chosenSenderName,
      );

  @override
  bool operator ==(Object other) => other is Account && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
