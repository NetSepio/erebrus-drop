import 'dart:convert';

import 'package:erebrus_drop/features/wallet/solana_wallet_card.dart';
import 'package:erebrus_drop/features/wallet/solana_wallet_service.dart';
import 'package:erebrus_drop/ui/theme/drop_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/solana.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('truncateWalletAddress shortens long addresses', () {
    expect(
      truncateWalletAddress('AbCdEfGhIjKlMnOpQrStUvWxYz1234567890'),
      'AbCd…7890',
    );
  });

  testWidgets('shows connect wallet when disconnected', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = SolanaWalletService(preferences: prefs);

    await tester.pumpWidget(
      MaterialApp(
        theme: DropTheme.dark(),
        home: Scaffold(body: SolanaWalletCard(walletService: service)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Connect wallet'), findsOneWidget);
    expect(find.textContaining('connected'), findsNothing);
  });

  testWidgets('shows connected address when session is restored', (
    tester,
  ) async {
    final keypair = await Ed25519HDKeyPair.random();
    final publicKey = keypair.publicKey.bytes;
    SharedPreferences.setMockInitialValues({
      'solana_wallet_auth_token': 'test-token',
      'solana_wallet_public_key_b64': base64Encode(publicKey),
      'solana_wallet_package_name': 'com.solanamobile.wallet',
      'solana_wallet_name': 'Seed Vault',
      'solana_wallet_is_seed_vault': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final service = SolanaWalletService(preferences: prefs);

    await tester.pumpWidget(
      MaterialApp(
        theme: DropTheme.dark(),
        home: Scaffold(body: SolanaWalletCard(walletService: service)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('connected'), findsOneWidget);
    expect(find.byTooltip('Connect wallet'), findsNothing);
    expect(find.textContaining('…'), findsOneWidget);
  });
}