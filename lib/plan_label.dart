const _planLabels = <String, String>{
  'personal.basic': 'Personal · Basic',
  'personal.starter': 'Personal · Starter',
  'personal.pro': 'Personal · Pro',
  'business.launch': 'Business · Launch',
  'business.scale': 'Business · Scale',
  'business.enterprise': 'Business · Enterprise',
};

String erebrusPlanLabel(String? plan, {String fallback = 'Free'}) {
  final value = plan?.trim().toLowerCase() ?? '';
  if (value.isEmpty) return fallback;
  final known = _planLabels[value];
  if (known != null) return known;
  return value.split('.').map(_titleCase).join(' · ');
}

String _titleCase(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
