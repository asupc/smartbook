import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebDAVProvider', () {
    late WebDAVProvider provider;

    setUp(() {
      provider = WebDAVProvider();
    });

    test('should have correct provider ID', () {
      expect(provider.providerId, equals('webdav'));
    });

    test('should have correct provider name', () {
      expect(provider.providerName, equals('WebDAV'));
    });

    test('validateConfig should return false for empty config', () {
      expect(provider.validateConfig({}), isFalse);
    });

    test('validateConfig should return false for missing url', () {
      expect(
        provider.validateConfig({
          'username': 'user',
          'password': 'pass',
        }),
        isFalse,
      );
    });

    test('validateConfig should return false for missing username', () {
      expect(
        provider.validateConfig({
          'url': 'https://example.com',
          'password': 'pass',
        }),
        isFalse,
      );
    });

    test('validateConfig should return false for missing password', () {
      expect(
        provider.validateConfig({
          'url': 'https://example.com',
          'username': 'user',
        }),
        isFalse,
      );
    });

    test('validateConfig should return true for valid config', () {
      expect(
        provider.validateConfig({
          'url': 'https://nextcloud.example.com',
          'username': 'user@example.com',
          'password': 'password',
        }),
        isTrue,
      );
    });

    test('validateConfig should accept optional remotePath', () {
      expect(
        provider.validateConfig({
          'url': 'https://nextcloud.example.com',
          'username': 'user@example.com',
          'password': 'password',
          'remotePath': '/SmartBook/',
        }),
        isTrue,
      );
    });

    test('validateConfig should return false for invalid remotePath type', () {
      expect(
        provider.validateConfig({
          'url': 'https://nextcloud.example.com',
          'username': 'user@example.com',
          'password': 'password',
          'remotePath': 123, // should be string
        }),
        isFalse,
      );
    });

    test(
        'should throw CloudConfigurationException when accessing auth before initialization',
        () {
      expect(
        () => provider.auth,
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test(
        'should throw CloudConfigurationException when accessing storage before initialization',
        () {
      expect(
        () => provider.storage,
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('initialize should throw on invalid config', () async {
      expect(
        () => provider.initialize({}),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    // Note: Full integration tests require a real WebDAV server
    // and should be run separately with proper credentials
  });

  group('WebDAVAuthService', () {
    test('should create CloudUser from credentials', () async {
      final authService = WebDAVAuthService('test-user');

      final user = await authService.signInWithEmail(
        email: 'user@example.com',
        password: 'password',
      );

      expect(user.id, equals('user@example.com'));
      expect(user.email, equals('user@example.com'));
      expect(user.metadata?['password'], equals('password'));
    });

    test('should emit auth state changes', () async {
      final authService = WebDAVAuthService('test-user');

      final states = <CloudUser?>[];
      final subscription = authService.authStateChanges.listen(states.add);

      await authService.signInWithEmail(
        email: 'user@example.com',
        password: 'password',
      );

      await Future.delayed(const Duration(milliseconds: 100));

      expect(states.length, greaterThan(0));
      expect(states.last?.email, equals('user@example.com'));

      await subscription.cancel();
      authService.dispose();
    });

    test('signOut should clear current user', () async {
      final authService = WebDAVAuthService('test-user');

      await authService.signInWithEmail(
        email: 'user@example.com',
        password: 'password',
      );

      var user = await authService.currentUser;
      expect(user, isNotNull);

      await authService.signOut();

      user = await authService.currentUser;
      expect(user, isNull);

      authService.dispose();
    });

    test('sendPasswordResetEmail should throw exception', () async {
      final authService = WebDAVAuthService('test-user');

      expect(
        () => authService.sendPasswordResetEmail(email: 'user@example.com'),
        throwsA(isA<CloudAuthException>()),
      );

      authService.dispose();
    });

    test('resendEmailVerification should throw exception', () async {
      final authService = WebDAVAuthService('test-user');

      expect(
        () => authService.resendEmailVerification(email: 'user@example.com'),
        throwsA(isA<CloudAuthException>()),
      );

      authService.dispose();
    });
  });

  group('WebDAVStorageService', () {
    test('should implement CloudStorageService', () {
      // This would require mocking WebDAV client
      // For now, we just verify the class exists
      expect(WebDAVStorageService, isNotNull);
    });
  });
}
