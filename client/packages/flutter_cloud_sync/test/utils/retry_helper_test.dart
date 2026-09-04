import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RetryHelper - basic retry', () {
    test('should return result on first success', () async {
      var callCount = 0;
      final result = await RetryHelper.execute(
        () async {
          callCount++;
          return 'success';
        },
        config: const RetryConfig(maxAttempts: 3),
      );

      expect(result, equals('success'));
      expect(callCount, equals(1));
    });

    test('should retry on CloudStorageException and eventually succeed',
        () async {
      var callCount = 0;
      final result = await RetryHelper.execute(
        () async {
          callCount++;
          if (callCount < 3) {
            throw CloudStorageException('Temporary error');
          }
          return 'success';
        },
        config: const RetryConfig(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 10),
        ),
      );

      expect(result, equals('success'));
      expect(callCount, equals(3));
    });

    test('should throw exception after exhausting retries', () async {
      var callCount = 0;
      expect(
        () => RetryHelper.execute(
          () async {
            callCount++;
            throw CloudStorageException('Persistent error');
          },
          config: const RetryConfig(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 10),
          ),
        ),
        throwsA(isA<CloudStorageException>()),
      );

      await Future.delayed(const Duration(milliseconds: 100));
      expect(callCount, equals(3));
    });

    test('should not retry CloudNotAuthenticatedException', () async {
      var callCount = 0;
      expect(
        () => RetryHelper.execute(
          () async {
            callCount++;
            throw CloudNotAuthenticatedException();
          },
          config: const RetryConfig(maxAttempts: 3),
        ),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      expect(callCount, equals(1)); // Should not retry
    });

    test('should not retry CloudConfigurationException', () async {
      var callCount = 0;
      expect(
        () => RetryHelper.execute(
          () async {
            callCount++;
            throw CloudConfigurationException('Bad config');
          },
          config: const RetryConfig(maxAttempts: 3),
        ),
        throwsA(isA<CloudConfigurationException>()),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      expect(callCount, equals(1)); // Should not retry
    });

    test('should not retry CloudAuthException', () async {
      var callCount = 0;
      expect(
        () => RetryHelper.execute(
          () async {
            callCount++;
            throw CloudAuthException('Auth failed');
          },
          config: const RetryConfig(maxAttempts: 3),
        ),
        throwsA(isA<CloudAuthException>()),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      expect(callCount, equals(1)); // Should not retry
    });
  });

  group('RetryHelper - exponential backoff', () {
    test('should increase delay exponentially', () async {
      var callCount = 0;
      final delays = <Duration>[];
      var lastTime = DateTime.now();

      try {
        await RetryHelper.execute(
          () async {
            callCount++;
            if (callCount > 1) {
              final now = DateTime.now();
              delays.add(now.difference(lastTime));
              lastTime = now;
            }
            throw CloudStorageException('Error');
          },
          config: const RetryConfig(
            maxAttempts: 4,
            initialDelay: Duration(milliseconds: 10),
            backoffMultiplier: 2.0,
          ),
        );
      } catch (e) {
        // Expected to fail
      }

      expect(callCount, equals(4));
      expect(delays.length, equals(3));

      // Check that delays increase (with some tolerance for timing)
      expect(delays[1].inMilliseconds,
          greaterThan(delays[0].inMilliseconds * 1.5));
      expect(delays[2].inMilliseconds,
          greaterThan(delays[1].inMilliseconds * 1.5));
    });

    test('should respect maxDelay', () async {
      var callCount = 0;
      final delays = <Duration>[];
      var lastTime = DateTime.now();

      try {
        await RetryHelper.execute(
          () async {
            callCount++;
            if (callCount > 1) {
              final now = DateTime.now();
              delays.add(now.difference(lastTime));
              lastTime = now;
            }
            throw CloudStorageException('Error');
          },
          config: const RetryConfig(
            maxAttempts: 5,
            initialDelay: Duration(milliseconds: 10),
            maxDelay: Duration(milliseconds: 30),
            backoffMultiplier: 3.0,
          ),
        );
      } catch (e) {
        // Expected to fail
      }

      // All delays should be <= maxDelay (with tolerance)
      for (final delay in delays) {
        expect(delay.inMilliseconds, lessThanOrEqualTo(50)); // 30ms + tolerance
      }
    });
  });

  group('RetryHelper - callback', () {
    test('should invoke onRetry callback', () async {
      final retryAttempts = <int>[];
      final retryErrors = <Exception>[];

      try {
        await RetryHelper.execute(
          () async => throw CloudStorageException('Error'),
          config: const RetryConfig(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 10),
          ),
          onRetry: (attempt, error) {
            retryAttempts.add(attempt);
            retryErrors.add(error);
          },
        );
      } catch (e) {
        // Expected to fail
      }

      expect(retryAttempts, equals([1, 2])); // Called before retry 2 and 3
      expect(retryErrors.length, equals(2));
      expect(retryErrors.every((e) => e is CloudStorageException), isTrue);
    });
  });

  group('RetryHelper - custom shouldRetry', () {
    test('should use custom shouldRetry callback', () async {
      var callCount = 0;

      final result = await RetryHelper.execute(
        () async {
          callCount++;
          if (callCount < 3) {
            throw FormatException('Custom error');
          }
          return 'success';
        },
        config: RetryConfig(
          maxAttempts: 3,
          initialDelay: const Duration(milliseconds: 10),
          shouldRetry: (e) => e is FormatException,
        ),
      );

      expect(result, equals('success'));
      expect(callCount, equals(3));
    });

    test('should not retry when shouldRetry returns false', () async {
      var callCount = 0;

      expect(
        () => RetryHelper.execute(
          () async {
            callCount++;
            throw FormatException('Custom error');
          },
          config: RetryConfig(
            maxAttempts: 3,
            shouldRetry: (e) => false, // Never retry
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      expect(callCount, equals(1));
    });
  });

  group('RetryHelper - retryableExceptions', () {
    test('should only retry specified exception types', () async {
      var storageCallCount = 0;
      var authCallCount = 0;

      // Test CloudStorageException (should retry)
      try {
        await RetryHelper.execute(
          () async {
            storageCallCount++;
            throw CloudStorageException('Storage error');
          },
          config: const RetryConfig(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 10),
            retryableExceptions: [CloudStorageException],
          ),
        );
      } catch (e) {
        // Expected
      }

      // Test CloudAuthException (should not retry)
      try {
        await RetryHelper.execute(
          () async {
            authCallCount++;
            throw CloudAuthException('Auth error');
          },
          config: const RetryConfig(
            maxAttempts: 3,
            retryableExceptions: [CloudStorageException],
          ),
        );
      } catch (e) {
        // Expected
      }

      expect(storageCallCount, equals(3)); // Should retry
      expect(authCallCount, equals(1)); // Should not retry
    });
  });

  group('RetryHelper - convenience methods', () {
    test('executeSimple should work', () async {
      var callCount = 0;
      final result = await RetryHelper.executeSimple(
        () async {
          callCount++;
          if (callCount < 2) {
            throw CloudStorageException('Error');
          }
          return 'success';
        },
        maxAttempts: 3,
      );

      expect(result, equals('success'));
      expect(callCount, equals(2));
    });

    test('executeWithBackoff should work', () async {
      var callCount = 0;
      final result = await RetryHelper.executeWithBackoff(
        () async {
          callCount++;
          if (callCount < 2) {
            throw CloudStorageException('Error');
          }
          return 'success';
        },
        maxAttempts: 3,
        initialDelay: const Duration(milliseconds: 10),
        maxDelay: const Duration(milliseconds: 100),
        backoffMultiplier: 2.0,
      );

      expect(result, equals('success'));
      expect(callCount, equals(2));
    });
  });

  group('RetryHelper - predefined configs', () {
    test('should use network config', () async {
      var callCount = 0;
      try {
        await RetryHelper.execute(
          () async {
            callCount++;
            throw CloudStorageException('Error');
          },
          config: RetryConfig.network,
        );
      } catch (e) {
        // Expected
      }

      expect(callCount, equals(3)); // network config has maxAttempts: 3
    });

    test('should use aggressive config', () async {
      var callCount = 0;
      try {
        await RetryHelper.execute(
          () async {
            callCount++;
            throw CloudStorageException('Error');
          },
          config: RetryConfig.aggressive,
        );
      } catch (e) {
        // Expected
      }

      expect(callCount, equals(5)); // aggressive config has maxAttempts: 5
    });

    test('should use conservative config', () async {
      var callCount = 0;
      try {
        await RetryHelper.execute(
          () async {
            callCount++;
            throw CloudStorageException('Error');
          },
          config: RetryConfig.conservative,
        );
      } catch (e) {
        // Expected
      }

      expect(callCount, equals(2)); // conservative config has maxAttempts: 2
    });
  });
}
