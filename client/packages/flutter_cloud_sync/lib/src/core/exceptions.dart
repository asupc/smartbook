/// Base exception for all cloud sync errors
///
/// ## Why `toString()` is deliberately terse
///
/// These exceptions travel into logs, UI banners and crash reports. The
/// `originalError` slot frequently holds an `http.Response` body, a decoded
/// JSON map or a `FormatException` — all of which may embed credentials or
/// arbitrary cloud content (`FormatException.toString()` appends a ~78 char
/// excerpt of the offending input). Interpolating such objects verbatim leaks
/// data, so [toString] only ever prints the type of a non-String
/// `originalError`, and redacts + truncates String ones.
class CloudSyncException implements Exception {
  final String message;
  final dynamic originalError;

  /// Explicit HTTP status code (when the failure came from an HTTP response).
  final int? _statusCode;

  CloudSyncException(this.message, [this.originalError, int? statusCode])
      : _statusCode = statusCode;

  /// HTTP status code of the failed request, when known.
  ///
  /// Three construction styles exist in the wild and all are honored, so the
  /// field is programmatically available regardless of call site age:
  ///   1. explicit `statusCode:` argument (preferred);
  ///   2. status code passed positionally as `originalError` (legacy);
  ///   3. status code embedded in the message, e.g. `'... (HTTP 422)'`
  ///      (legacy — the fallback exists precisely so callers never have to
  ///      parse [message] themselves).
  int? get statusCode {
    if (_statusCode != null) return _statusCode;
    if (originalError is int) return originalError as int;
    final match = _httpCodeInMessage.firstMatch(message);
    if (match != null) {
      // group(1) = 显式 `HTTP NNN` 形态;group(2) = 裸 `(NNN)` 括号兜底
      // (低-3(c) 拓宽,2026-10-11)。
      final parsed = int.tryParse(match.group(1) ?? match.group(2) ?? '');
      if (parsed != null && parsed >= 100 && parsed <= 599) {
        return parsed;
      }
    }
    return null;
  }

  /// Whether this failure came from an HTTP 4xx response.
  ///
  /// 408 (request timeout) and 429 (too many requests) are the two transient
  /// 4xx statuses and are deliberately excluded.
  bool get isClientError {
    final code = statusCode;
    if (code == null) return false;
    return code >= 400 && code < 500 && code != 408 && code != 429;
  }

  /// Diagnostic detail, safe to log / display.
  ///
  /// String details are redacted and truncated; anything else is reduced to its
  /// type name so payload excerpts can never escape.
  String? get safeDetail => _safeOriginalDetail(originalError);

  @override
  String toString() {
    final code = statusCode;
    final detail = safeDetail;
    final buffer = StringBuffer('CloudSyncException: $message');
    if (code != null) {
      buffer.write(' (HTTP $code)');
    }
    if (detail != null) {
      buffer.write(' (Original error: $detail)');
    }
    return buffer.toString();
  }
}

/// Thrown when user is not authenticated
class CloudNotAuthenticatedException extends CloudSyncException {
  CloudNotAuthenticatedException(
      [String? message, dynamic originalError, int? statusCode])
      : super(message ?? 'User not authenticated', originalError, statusCode);
}

/// Thrown when cloud service configuration is invalid
class CloudConfigurationException extends CloudSyncException {
  CloudConfigurationException(String message, [dynamic error])
      : super(message, error);
}

/// Thrown when storage operations fail
class CloudStorageException extends CloudSyncException {
  CloudStorageException(String message, [dynamic error, int? statusCode])
      : super(message, error, statusCode);
}

/// Thrown when authentication operations fail
class CloudAuthException extends CloudSyncException {
  CloudAuthException(String message, [dynamic error]) : super(message, error);
}

/// Maximum length of a String [CloudSyncException.originalError] that is echoed
/// by [CloudSyncException.toString].
const int kMaxErrorDetailLength = 200;

/// Matches legacy HTTP-status markers inside message strings (case-insensitive):
///   1. `HTTP <code>` / `(HTTP <code>)` / `HTTP_<code>`;
///   2. `(<code>)` — 裸括号三位数,如 `'... failed (404): gone'`。
///
/// 形态 2 是低-3(c) 的修复:vendor 不少 raise 点把状态码直接拼进消息
/// (`'Push entity changes failed (${response.statusCode}): ...'`)而不传
/// `statusCode:` 参数 —— 旧正则只认 `HTTP NNN` 形态,消息兜底解析全部
/// miss,`isClientError` 恒 false → RetryHelper 的 4xx 短路(408/429 除外)
/// 无法命中。为防误伤,形态 2 只在**显式 `HTTP` 形态未命中**时兜底,且要求
/// 三位数(100-599 域校验在 [CloudSyncException.statusCode] getter 内)。
final RegExp _httpCodeInMessage = RegExp(
  r'\(?HTTP[ _]?(\d{3})\)?|\((\d{3})\)',
  caseSensitive: false,
);

final List<RegExp> _sensitiveDetailPatterns = <RegExp>[
  RegExp(r'((?:access|refresh)[_-]?token"?\s*[:=]\s*"?)([^"\s,&}]+)',
      caseSensitive: false),
  RegExp(r'(token\s*[:=]\s*)([^"\s,&}]+)', caseSensitive: false),
  RegExp(r'(bearer\s+)([A-Za-z0-9\-._~+/]+=*)', caseSensitive: false),
  RegExp(r'((?:password|passwd|secret)"?\s*[:=]\s*"?)([^"\s,&}]+)',
      caseSensitive: false),
];

/// Redact credential-looking fragments from [text] and cap its length.
///
/// Used for diagnostics that must survive into logs / error chains while no
/// longer carrying tokens or passwords.
String redactSensitiveDetail(String text,
    {int maxLength = kMaxErrorDetailLength}) {
  var out = text;
  for (final pattern in _sensitiveDetailPatterns) {
    out = out.replaceAllMapped(pattern, (match) => '${match[1]}<redacted>');
  }
  if (out.length > maxLength) {
    out = '${out.substring(0, maxLength)}…';
  }
  return out;
}

String? _safeOriginalDetail(dynamic error) {
  if (error == null) return null;
  if (error is String) {
    return redactSensitiveDetail(error);
  }
  // Never interpolate arbitrary objects: FormatException embeds input
  // excerpts, Maps/Responses may embed credentials.
  return '<${error.runtimeType}>';
}

/// Build a diagnostic / UI string for [error] without echoing payload excerpts.
///
/// `FormatException` is the dangerous case: its `toString()` appends the first
/// ~78 characters of the offending input, which for this package is cloud
/// content (notes, card numbers). Every error surfacing path — UI messages and
/// logs alike — must go through this helper instead of `'$e'`.
String describeCloudError(Object error) {
  if (error is CloudSyncException) {
    return error.toString();
  }
  if (error is FormatException) {
    return 'malformed data (${error.runtimeType})';
  }
  return redactSensitiveDetail('$error');
}
