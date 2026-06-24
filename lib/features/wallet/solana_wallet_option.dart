class SolanaWalletOption {
  const SolanaWalletOption({
    required this.id,
    required this.name,
    required this.packageName,
    this.isSeedVault = false,
    this.iconBase64,
  });

  factory SolanaWalletOption.fromMap(Map<dynamic, dynamic> map) {
    return SolanaWalletOption(
      id: map['id'] as String,
      name: map['name'] as String,
      packageName: map['packageName'] as String,
      isSeedVault: map['isSeedVault'] as bool? ?? false,
      iconBase64: map['iconBase64'] as String?,
    );
  }

  final String id;
  final String name;
  final String packageName;
  final bool isSeedVault;
  final String? iconBase64;
}