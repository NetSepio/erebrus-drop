import 'dart:convert';

import 'package:erebrus_drop/features/gateway/gateway_session_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native secure storage restores the complete replacement blob', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Dedicated test key; never inspect or modify the user's gateway session.
    const gateway = 'https://secure-storage-integration-test.invalid';
    final store = SecureGatewaySessionStore(gateway: gateway);
    try {
      final initial = {
        'session': {
          'access_token': 'integration-access-one',
          'refresh_token': 'integration-refresh-one',
          'expires_at': '2026-10-20T00:00:00Z',
          'refresh_expires_at': '2026-11-19T00:00:00Z',
          'session_id': 'integration-session',
        },
        'generation': 'integration-generation',
        'rotation_pending': true,
      };
      await store.write(jsonEncode(initial));
      final restored = SecureGatewaySessionStore(gateway: gateway);
      expect(jsonDecode((await restored.read())!), initial);

      final replacement = {
        ...initial,
        'session': {
          ...initial['session']! as Map,
          'access_token': 'integration-access-two',
          'refresh_token': 'integration-refresh-two',
          'expires_at': '2026-10-21T00:00:00Z',
          'refresh_expires_at': '2026-11-20T00:00:00Z',
        },
        'rotation_pending': false,
      };
      await restored.write(jsonEncode(replacement));
      expect(jsonDecode((await store.read())!), replacement);
    } finally {
      await store.write(jsonEncode({'session': null}));
    }
    expect(jsonDecode((await store.read())!), {'session': null});
  });
}
