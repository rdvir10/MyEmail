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

@immutable
class Account {
  const Account({
    required this.id,
    required this.displayName,
    required this.emailAddress,
    required this.provider,
    required this.authMethod,
    required this.colorValue,
  });

  final String id;
  final String displayName;
  final String emailAddress;
  final MailProvider provider;
  final AuthMethod authMethod;

  /// Accent used to tell accounts apart in the tree and in unified views.
  final int colorValue;

  @override
  bool operator ==(Object other) => other is Account && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
