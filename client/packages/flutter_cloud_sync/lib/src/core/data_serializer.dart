/// Abstract interface for data serialization
///
/// Implemented by business layer to convert domain data to/from strings.
/// This allows the cloud sync package to be completely decoupled from
/// business logic.
abstract class DataSerializer<T> {
  /// Serialize business data to string
  ///
  /// [data] - Domain data to serialize
  ///
  /// Returns serialized string (typically JSON).
  ///
  /// Example:
  /// ```dart
  /// @override
  /// Future<String> serialize(int ledgerId) async {
  ///   final transactions = await db.getTransactions(ledgerId);
  ///   return jsonEncode({'ledgerId': ledgerId, 'items': transactions});
  /// }
  /// ```
  Future<String> serialize(T data);

  /// Deserialize string to business data
  ///
  /// [data] - Serialized string
  ///
  /// Returns deserialized domain data.
  ///
  /// Example:
  /// ```dart
  /// @override
  /// Future<int> deserialize(String data) async {
  ///   final json = jsonDecode(data);
  ///   return json['ledgerId'] as int;
  /// }
  /// ```
  Future<T> deserialize(String data);

  /// Calculate data fingerprint
  ///
  /// [data] - Serialized string
  ///
  /// Returns fingerprint (e.g., SHA256 hash).
  /// Used to determine if local and cloud data are identical.
  ///
  /// Example:
  /// ```dart
  /// @override
  /// String fingerprint(String data) {
  ///   final bytes = utf8.encode(data);
  ///   return sha256.convert(bytes).toString();
  /// }
  /// ```
  String fingerprint(String data);
}
