import 'package:myemail_power/myemail_power.dart';

/// Whether Android lets MyEmail run in the background, and asking it to.
///
/// Push and the five-minute mode live in a foreground service, and Android
/// refuses to start one from the background unless the app is exempt from
/// battery optimisation ("Unrestricted" in the app's battery settings). The
/// app starts the service itself when it is on screen, which is allowed;
/// the exemption is for the times it starts again on its own, after Android
/// or a reboot has stopped it.
abstract class BackgroundAllowance {
  /// Whether the app is exempt.
  Future<bool> isExempt();

  /// Show Android's dialog asking for the exemption. Whether it could be
  /// shown; the answer comes later, through [isExempt].
  Future<bool> requestExemption();
}

class AndroidBackgroundAllowance implements BackgroundAllowance {
  const AndroidBackgroundAllowance([this._power = const MyEmailPower()]);

  final MyEmailPower _power;

  @override
  Future<bool> isExempt() => _power.isIgnoringBatteryOptimizations();

  @override
  Future<bool> requestExemption() => _power.requestIgnoreBatteryOptimizations();
}

/// For tests and the browser preview. Records what it was asked.
class FakeBackgroundAllowance implements BackgroundAllowance {
  FakeBackgroundAllowance({this.exempt = true, this.grantsWhenAsked = true});

  bool exempt;

  /// Whether saying yes is what the person does when asked.
  bool grantsWhenAsked;

  int requests = 0;

  @override
  Future<bool> isExempt() async => exempt;

  @override
  Future<bool> requestExemption() async {
    requests++;
    if (grantsWhenAsked) exempt = true;
    return true;
  }
}
