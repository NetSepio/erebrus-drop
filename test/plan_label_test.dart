import 'package:erebrus_drop/features/gateway/gateway_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('organization renders family-qualified plan labels', () {
    final org = DropOrg.fromJson({
      'id': 'org-1',
      'name': 'Acme',
      'slug': 'acme',
      'plan': 'business.scale',
    });

    expect(org.plan, 'business.scale');
    expect(org.planLabel, 'Business · Scale');
  });
}
