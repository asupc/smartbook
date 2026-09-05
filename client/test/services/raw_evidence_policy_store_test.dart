import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartbook/services/privacy/raw_evidence_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults are privacy-safe and local/server switches are independent',
      () async {
    final policy = await RawEvidencePolicyStore().load();

    expect(policy.defaultPolicy.localEnabled, isFalse);
    expect(policy.defaultPolicy.serverEnabled, isFalse);
    expect(policy.defaultPolicy.localRetentionDays, 30);
    expect(policy.defaultPolicy.serverRetentionDays, 30);

    final serverOnly = policy.defaultPolicy.copyWith(
      localEnabled: false,
      serverEnabled: true,
    );
    expect(serverOnly.localEnabled, isFalse);
    expect(serverOnly.serverEnabled, isTrue);
  });

  test('per-source policy persists without changing the default policy',
      () async {
    final store = RawEvidencePolicyStore();
    final sms = const RawEvidenceSourcePolicy(
      localEnabled: true,
      localRetentionDays: 7,
      serverEnabled: false,
      serverRetentionDays: 30,
    );
    final notification = const RawEvidenceSourcePolicy(
      localEnabled: false,
      localRetentionDays: 1,
      serverEnabled: true,
      serverRetentionDays: 90,
    );

    await store.save(
      RawEvidencePolicy.defaults
          .withSourcePolicy('sms', sms)
          .withSourcePolicy('notification', notification),
    );
    final reloaded = await RawEvidencePolicyStore().load();

    expect(reloaded.defaultPolicy.localEnabled, isFalse);
    expect(reloaded.forSource('sms').localEnabled, isTrue);
    expect(reloaded.forSource('sms').localRetentionDays, 7);
    expect(reloaded.forSource('notification').localEnabled, isFalse);
    expect(reloaded.forSource('notification').serverEnabled, isTrue);
    expect(reloaded.forSource('notification').serverRetentionDays, 90);
  });

  test('capture plan keeps independent local and server expiry windows', () {
    final capturedAt = DateTime.utc(2026, 9, 5, 8);
    final policy = RawEvidencePolicy.defaults.withSourcePolicy(
      'screenText',
      const RawEvidenceSourcePolicy(
        localEnabled: true,
        localRetentionDays: 7,
        serverEnabled: true,
        serverRetentionDays: 30,
      ),
    );

    final plan = policy.planFor('screenText', capturedAt);

    expect(plan.localExpiresAt, capturedAt.add(const Duration(days: 7)));
    expect(plan.serverExpiresAt, capturedAt.add(const Duration(days: 30)));
    expect(plan.retentionUntil, capturedAt.add(const Duration(days: 30)));
    expect(plan.uploadState, RawEvidenceUploadState.pending);
  });

  test('legacy global keys are read once for compatibility', () async {
    SharedPreferences.setMockInitialValues({
      RawEvidencePolicyStore.localKey: true,
      RawEvidencePolicyStore.serverKey: true,
      RawEvidencePolicyStore.retentionKey: 180,
    });

    final policy = await RawEvidencePolicyStore().load();

    expect(policy.defaultPolicy.localEnabled, isTrue);
    expect(policy.defaultPolicy.serverEnabled, isTrue);
    expect(policy.defaultPolicy.localRetentionDays, 180);
    expect(policy.defaultPolicy.serverRetentionDays, 180);
  });
}
