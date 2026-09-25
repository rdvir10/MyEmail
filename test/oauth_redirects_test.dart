import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_redirects.dart';

/// The URL Android hands the app after a sign-in in the browser.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a redirect from the platform arrives as a URL', () async {
    final redirects = OAuthRedirects();
    final arrived = <Uri>[];
    final sub = redirects.arrivals.listen(arrived.add);
    addTearDown(sub.cancel);

    // What MainActivity does: one method, the URL as its argument.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      OAuthRedirects.channelName,
      const StandardMethodCodec().encodeMethodCall(const MethodCall(
        'redirect',
        'com.googleusercontent.apps.1-a:/oauth2redirect?code=c&state=s',
      )),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(arrived, hasLength(1));
    expect(arrived.single.scheme, 'com.googleusercontent.apps.1-a');
    expect(arrived.single.queryParameters['code'], 'c');
  });

  test('anything else on the channel is not taken', () async {
    final redirects = OAuthRedirects();
    final arrived = <Uri>[];
    final sub = redirects.arrivals.listen(arrived.add);
    addTearDown(sub.cancel);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      OAuthRedirects.channelName,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('somethingElse', 'x')),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(arrived, isEmpty);
  });
}
