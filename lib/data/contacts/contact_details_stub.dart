import '../../domain/synced_contact.dart' show ContactSide;
import 'contact_sync_planner.dart';

// Stand-ins for the planner's round that gives each held change its side
// and its clash (ContactDetailChange.side and .clash), so the runner can
// map them before that round is merged. This file goes when it is: the
// planner's fields then take the place of these getters.

/// Until the planner gives them: no side of its own (the item's stands
/// in), and no clash.
extension ContactDetailChangeSides on ContactDetailChange {
  ContactSide? get side => null;
  bool get clash => false;
}
