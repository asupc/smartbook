import '../core/exceptions.dart';

/// Retry configuration
class RetryConfig {
  /// Maximum number of retry attempts
  final int maxAttempts;

  /// Initial delay between retries
  final Duration initialDelay;

  /// Maximum delay between retries
  final Duration maxDelay;

  /// Backoff multiplier (exponential backoff)
  final double backoffMultiplier;

  /// List of exception types that should trigger a retry
  final List<Type>? retryableExceptions;

  /// Callback to determine if an exception should trigger a retry
  final bool Function(Exception)? shouldRetry;

  const RetryConfig({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
    this.retryableExceptions,
    this.shouldRetry,
  });

  /// Default configuration for network operations
  static const network = RetryConfig(
    maxAttempts: 3,
    initialDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 10),
    backoffMultiplier: 2.0,
  );

  /// Aggressive retry for critical operations
  static const aggressive = RetryConfig(
    maxAttempts: 5,
    initialDelay: Duration(milliseconds: 500),
    maxDelay: Duration(seconds: 20),
    backoffMultiplier: 2.0,
  );

  /// Conservative retry for non-critical operations
  static const conservative = RetryConfig(
    maxAttempts: 2,
    initialDelay: Duration(seconds: 2),
    maxDelay: Duration(seconds: 5),
    backoffMultiplier: 1.5,
  );
}

/// Retry helper for executing operations with automatic retry logic
class RetryHelper {
  /// Execute an operation with automatic retry on failure
  ///
  /// [operation] - The async operation to execute
  /// [config] - Retry configuration (defaults to network config)
  /// [onRetry] - Optional callback invoked before each retry
  ///
  /// Returns the result of the successful operation.
  /// Throws the last exception if all retries are exhausted.
  ///
  /// Example:
  /// ```dart
  /// final result = await RetryHelper.execute(
  ///   () => httpClient.get(url),
  ///   config: RetryConfig.network,
  ///   onRetry: (attempt, error) {
  ///     print('Retry attempt $attempt after error: $error');
  ///   },
  /// );
  /// ```
  static Future<T> execute<T>(
    Future<T> Function() operation, {
    RetryConfig config = RetryConfig.network,
    void Function(int attempt, Exception error)? onRetry,
  }) async {
    int attempt = 0;
    Duration currentDelay = _clampDelay(config.initialDelay, config);
    Exception? lastException;

    while (attempt < config.maxAttempts) {
      attempt++;

      try {
        return await operation();
      } on Exception catch (e) {
        lastException = e;

        // Check if we should retry this exception
        if (!_shouldRetryException(e, config)) {
          rethrow;
        }

        // Check if we've exhausted all attempts
        if (attempt >= config.maxAttempts) {
          rethrow;
        }

        // Notify retry callback
        onRetry?.call(attempt, e);

        // Wait before retrying
        await Future.delayed(currentDelay);

        // Calculate next delay with exponential backoff.
        //
        // `currentDelay` is always kept within maxDelay: the initial delay is
        // clamped on the first pass too (previously an `initialDelay` above
        // `maxDelay` — or a huge one — was slept verbatim), and a degenerate
        // multiplier cannot collapse the delay to zero, which would turn the
        // retry loop into an unthrottled request storm.
        currentDelay = _nextDelay(currentDelay, config);
      }
    }

    // This should never be reached, but just in case
    throw lastException ??
        CloudSyncException('Retry exhausted with no exception recorded');
  }

  /// Compute the next backoff delay, clamped to `[min, maxDelay]`.
  ///
  /// Defensive against hostile / misconfigured `RetryConfig` values:
  /// * `initialDelay > maxDelay` (including multi-year values) → clamped;
  /// * `backoffMultiplier` of 0 / NaN / Infinity / negative is rejected and
  ///   replaced by 1.0 (constant delay), so every retry is separated by at
  ///   least `initialDelay` instead of degrading into an unthrottled storm.
  static Duration _nextDelay(Duration currentDelay, RetryConfig config) {
    final multiplier = config.backoffMultiplier;
    final effectiveMultiplier =
        (multiplier.isFinite && multiplier >= 1.0) ? multiplier : 1.0;

    final baseMs = _nonNegativeMs(currentDelay);
    double scaled = baseMs * effectiveMultiplier;
    if (!scaled.isFinite) {
      scaled = _maxDelayMs(config).toDouble();
    }
    return _clampDelay(Duration(milliseconds: scaled.round()), config);
  }

  /// Clamp [delay] into `[Duration.zero, config.maxDelay]`.
  ///
  /// Guards every wait (including the very first one) so a single sleep can
  /// never exceed `maxDelay`.
  static Duration _clampDelay(Duration delay, RetryConfig config) {
    final maxMs = _maxDelayMs(config);
    final ms = _nonNegativeMs(delay);
    return Duration(milliseconds: ms > maxMs ? maxMs : ms);
  }

  static int _maxDelayMs(RetryConfig config) {
    final maxMs = config.maxDelay.inMilliseconds;
    return maxMs < 0 ? 0 : maxMs;
  }

  static int _nonNegativeMs(Duration d) {
    final ms = d.inMilliseconds;
    return ms < 0 ? 0 : ms;
  }

  /// Execute an operation with a simple retry count
  ///
  /// Simplified version that only accepts max attempts.
  ///
  /// Example:
  /// ```dart
  /// final result = await RetryHelper.executeSimple(
  ///   () => cloudStorage.upload(data),
  ///   maxAttempts: 3,
  /// );
  /// ```
  static Future<T> executeSimple<T>(
    Future<T> Function() operation, {
    int maxAttempts = 3,
  }) async {
    return execute(
      operation,
      config: RetryConfig(maxAttempts: maxAttempts),
    );
  }

  /// Execute with exponential backoff
  ///
  /// Uses exponential backoff strategy with configurable parameters.
  ///
  /// Example:
  /// ```dart
  /// final result = await RetryHelper.executeWithBackoff(
  ///   () => api.call(),
  ///   maxAttempts: 5,
  ///   initialDelay: Duration(milliseconds: 500),
  ///   maxDelay: Duration(seconds: 30),
  /// );
  /// ```
  static Future<T> executeWithBackoff<T>(
    Future<T> Function() operation, {
    int maxAttempts = 3,
    Duration initialDelay = const Duration(seconds: 1),
    Duration maxDelay = const Duration(seconds: 30),
    double backoffMultiplier = 2.0,
  }) async {
    return execute(
      operation,
      config: RetryConfig(
        maxAttempts: maxAttempts,
        initialDelay: initialDelay,
        maxDelay: maxDelay,
        backoffMultiplier: backoffMultiplier,
      ),
    );
  }

  /// Check if an exception should trigger a retry
  static bool _shouldRetryException(Exception exception, RetryConfig config) {
    // Use custom shouldRetry callback if provided
    if (config.shouldRetry != null) {
      return config.shouldRetry!(exception);
    }

    // Check against retryable exception types if provided
    if (config.retryableExceptions != null) {
      return config.retryableExceptions!
          .any((type) => exception.runtimeType == type);
    }

    // Terminal HTTP 4xx responses (validation failures, 404, 422, …) will not
    // succeed on replay: retrying them just repeats an invalid request. 408
    // (request timeout) and 429 (too many requests) are transient and remain
    // retryable — see CloudSyncException.isClientError.
    if (exception is CloudSyncException && exception.isClientError) {
      return false;
    }

    // Default behavior: retry on CloudStorageException but not on auth errors
    if (exception is CloudNotAuthenticatedException) {
      return false;
    }

    if (exception is CloudConfigurationException) {
      return false;
    }

    if (exception is CloudAuthException) {
      return false;
    }

    if (exception is CloudStorageException) {
      return true;
    }

    // By default, don't retry unknown exceptions
    return false;
  }
}
