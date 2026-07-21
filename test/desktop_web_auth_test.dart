import 'package:erebrus_drop/features/gateway/desktop_web_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(DesktopWebAuth.clearPendingState);

  test('accepts a browser social session without a linked wallet', () {
    final loginUri = Uri.parse(DesktopWebAuth.buildLoginUrl());
    final state = loginUri.queryParameters['state']!;
    final callbackUri = Uri.parse('erebrusdrop://auth').replace(
      queryParameters: {
        'token': 'v4.public.session-token',
        'user_id': 'social-user',
        'wallet': '',
        'role': 'user',
        'state': state,
      },
    );

    final callback = DesktopWebAuth.parseCallback(callbackUri.toString());

    expect(callback, isNotNull);
    expect(callback!.isValid, isTrue);
    expect(callback.walletAddress, isEmpty);
    expect(() => DesktopWebAuth.validateState(callback.state), returnsNormally);
  });

  test('still rejects callbacks without an account id', () {
    final loginUri = Uri.parse(DesktopWebAuth.buildLoginUrl());
    final state = loginUri.queryParameters['state']!;
    final callbackUri = Uri.parse('erebrusdrop://auth').replace(
      queryParameters: {'token': 'v4.public.session-token', 'state': state},
    );

    final callback = DesktopWebAuth.parseCallback(callbackUri.toString());

    expect(callback, isNotNull);
    expect(callback!.isValid, isFalse);
  });
}
