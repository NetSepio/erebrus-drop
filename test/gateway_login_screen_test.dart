import 'package:erebrus_drop/features/gateway/drop_auth_client.dart';
import 'package:erebrus_drop/features/gateway/drop_auth_service.dart';
import 'package:erebrus_drop/features/gateway/login_screen.dart';
import 'package:erebrus_drop/features/wallet/solana_wallet_service.dart';
import 'package:erebrus_drop/ui/theme/drop_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('continue as guest is available on mobile and closes login', (
    tester,
  ) async {
    var loginClosed = false;
    final auth = DropAuthService(solana: SolanaWalletService());

    await tester.pumpWidget(
      MaterialApp(
        theme: DropTheme.dark(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => GatewayLoginScreen(auth: auth),
                ),
              );
              loginClosed = true;
            },
            child: const Text('Open login'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open login'));
    await tester.pumpAndSettle();
    expect(find.text('Continue as guest'), findsOneWidget);

    await tester.tap(find.text('Continue as guest'));
    await tester.pumpAndSettle();
    expect(loginClosed, isTrue);
    expect(find.text('Open login'), findsOneWidget);
  });

  testWidgets('shows Apple first on macOS when enabled by the gateway', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final auth = DropAuthService(solana: SolanaWalletService());
    auth.authMethods.value = const DropAuthMethods(apple: true);
    auth.appleDeviceReady.value = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: DropTheme.dark(),
        home: GatewayLoginScreen(auth: auth),
      ),
    );

    final apple = find.text('Continue with Apple');
    final browser = find.text('Sign in with browser');
    expect(find.text('Continue as guest'), findsOneWidget);
    expect(apple, findsOneWidget);
    expect(browser, findsOneWidget);
    expect(
      tester.getTopLeft(apple).dy,
      lessThan(tester.getTopLeft(browser).dy),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('hides Apple on macOS when omitted by the gateway', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final auth = DropAuthService(solana: SolanaWalletService());
    auth.authMethods.value = const DropAuthMethods(apple: false);
    auth.appleDeviceReady.value = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: DropTheme.dark(),
        home: GatewayLoginScreen(auth: auth),
      ),
    );

    expect(find.text('Continue with Apple'), findsNothing);
    expect(find.text('Sign in with browser'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
