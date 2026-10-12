import 'dart:convert';

import '../core/exceptions.dart';

/// 云服务后端类型
enum CloudBackendType {
  local, // 本地存储(不同步)
  smartbookCloud, // SmartBook Cloud（自建云服务）
  supabase, // Supabase (自建)
  webdav, // WebDAV (坚果云、Nextcloud、群晖等)
  icloud, // iCloud (iOS only)
  s3, // S3 协议（AWS S3、Cloudflare R2、MinIO等）
}

class CloudServiceConfig {
  final CloudBackendType type;
  final String name; // UI 展示名称

  // SmartBook Cloud 配置
  final String? smartbookCloudBaseUrl;
  final String? smartbookCloudApiPrefix;
  final String? smartbookCloudEmail; // 保存的账号（用于记住账号功能）
  final String? smartbookCloudPassword; // 保存的密码（用于记住账号功能）

  // Supabase 配置
  final String? supabaseUrl;
  final String? supabaseAnonKey;
  final String? supabaseBucket; // Storage bucket 名称
  final String? supabaseEmail; // 保存的账号（用于记住账号功能）
  final String? supabasePassword; // 保存的密码（用于记住账号功能）

  // WebDAV 配置
  final String? webdavUrl;
  final String? webdavUsername;
  final String? webdavPassword;
  final String? webdavRemotePath;

  // S3 配置
  final String? s3Endpoint;
  final String? s3Region;
  final String? s3AccessKey;
  final String? s3SecretKey;
  final String? s3Bucket;
  final bool? s3UseSSL;
  final int? s3Port;

  const CloudServiceConfig({
    required this.type,
    required this.name,
    // SmartBook Cloud
    this.smartbookCloudBaseUrl,
    this.smartbookCloudApiPrefix,
    this.smartbookCloudEmail,
    this.smartbookCloudPassword,
    // Supabase
    this.supabaseUrl,
    this.supabaseAnonKey,
    this.supabaseBucket,
    this.supabaseEmail,
    this.supabasePassword,
    // WebDAV
    this.webdavUrl,
    this.webdavUsername,
    this.webdavPassword,
    this.webdavRemotePath,
    // S3
    this.s3Endpoint,
    this.s3Region,
    this.s3AccessKey,
    this.s3SecretKey,
    this.s3Bucket,
    this.s3UseSSL,
    this.s3Port,
  });

  String get id => type.name; // 使用类型作为id

  /// Whether the config carries usable connection details.
  ///
  /// Values are trimmed: a field holding only whitespace ('  ' / '\t' / '\n')
  /// is "not configured", not a valid address. Previously such configs passed
  /// validation, and the failure only surfaced later as an opaque
  /// "switch cloud service failed" after the provider tried to initialize.
  bool get valid {
    bool filled(String? v) => v != null && v.trim().isNotEmpty;
    switch (type) {
      case CloudBackendType.local:
        return true; // 本地存储始终有效
      case CloudBackendType.smartbookCloud:
        return filled(smartbookCloudBaseUrl);
      case CloudBackendType.supabase:
        return filled(supabaseUrl) && filled(supabaseAnonKey);
      case CloudBackendType.webdav:
        return filled(webdavUrl) &&
            filled(webdavUsername) &&
            filled(webdavPassword);
      case CloudBackendType.icloud:
        return true; // iCloud 无需配置，始终有效
      case CloudBackendType.s3:
        return filled(s3Endpoint) &&
            filled(s3AccessKey) &&
            filled(s3SecretKey) &&
            filled(s3Bucket);
    }
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'name': name,
        // SmartBook Cloud
        'smartbookCloudBaseUrl': smartbookCloudBaseUrl,
        'smartbookCloudApiPrefix': smartbookCloudApiPrefix,
        'smartbookCloudEmail': smartbookCloudEmail,
        'smartbookCloudPassword': smartbookCloudPassword,
        // Supabase
        'supabaseUrl': supabaseUrl,
        'supabaseAnonKey': supabaseAnonKey,
        'supabaseBucket': supabaseBucket,
        'supabaseEmail': supabaseEmail,
        'supabasePassword': supabasePassword,
        // WebDAV
        'webdavUrl': webdavUrl,
        'webdavUsername': webdavUsername,
        'webdavPassword': webdavPassword,
        'webdavRemotePath': webdavRemotePath,
        // S3
        's3Endpoint': s3Endpoint,
        's3Region': s3Region,
        's3AccessKey': s3AccessKey,
        's3SecretKey': s3SecretKey,
        's3Bucket': s3Bucket,
        's3UseSSL': s3UseSSL,
        's3Port': s3Port,
      };

  /// 反序列化。
  ///
  /// 类型契约是**严格**的:结构性字段(`type` / `name` / `s3Port` / `s3UseSSL`)
  /// 类型不符时抛 [CloudConfigurationException](可分类的包异常),不再让裸
  /// `_TypeError`(Error 家族,`catch(Exception)` 捕获不到)穿透。
  /// 唯一的容错是 `type` 的旧品牌枚举名映射(见 [_legacyBackendTypeNames]),
  /// 那是品牌更名遗留数据的兼容路径。
  static CloudServiceConfig fromJson(Map<String, dynamic> j) {
    // 自动清理 S3 endpoint 中的协议前缀
    String? s3Endpoint = _asString(j['s3Endpoint']);
    if (s3Endpoint != null && s3Endpoint.isNotEmpty) {
      s3Endpoint = s3Endpoint.replaceFirst(RegExp(r'^https?://'), '');
    }

    return CloudServiceConfig(
      type: _parseBackendType(j['type']),
      name: _requireString(j['name'], 'name'),
      // SmartBook Cloud
      smartbookCloudBaseUrl: _asString(j['smartbookCloudBaseUrl']),
      smartbookCloudApiPrefix: _asString(j['smartbookCloudApiPrefix']),
      smartbookCloudEmail: _asString(j['smartbookCloudEmail']),
      smartbookCloudPassword: _asString(j['smartbookCloudPassword']),
      // Supabase
      supabaseUrl: _asString(j['supabaseUrl']),
      supabaseAnonKey: _asString(j['supabaseAnonKey']),
      supabaseBucket: _asString(j['supabaseBucket']),
      supabaseEmail: _asString(j['supabaseEmail']),
      supabasePassword: _asString(j['supabasePassword']),
      // WebDAV
      webdavUrl: _asString(j['webdavUrl']),
      webdavUsername: _asString(j['webdavUsername']),
      webdavPassword: _asString(j['webdavPassword']),
      webdavRemotePath: _asString(j['webdavRemotePath']),
      // S3
      s3Endpoint: s3Endpoint,
      s3Region: _asString(j['s3Region']),
      s3AccessKey: _asString(j['s3AccessKey']),
      s3SecretKey: _asString(j['s3SecretKey']),
      s3Bucket: _asString(j['s3Bucket']),
      s3UseSSL: _requireBool(j['s3UseSSL'], 's3UseSSL'),
      s3Port: _requireInt(j['s3Port'], 's3Port'),
    );
  }

  // 本地存储配置(默认)
  static CloudServiceConfig localStorage() => const CloudServiceConfig(
        type: CloudBackendType.local,
        name: '__LOCAL_STORAGE__',
      );

  String obfuscatedUrl() {
    switch (type) {
      case CloudBackendType.local:
        return '__LOCAL_DEVICE__';
      case CloudBackendType.smartbookCloud:
        if (smartbookCloudBaseUrl == null || smartbookCloudBaseUrl!.isEmpty) {
          return '__NOT_CONFIGURED__';
        }
        try {
          final uri = Uri.parse(smartbookCloudBaseUrl!);
          if (uri.host.isEmpty) return smartbookCloudBaseUrl!;
          return uri.host;
        } catch (_) {
          return smartbookCloudBaseUrl!;
        }
      case CloudBackendType.supabase:
        if (supabaseUrl == null || supabaseUrl!.isEmpty) {
          return '__NOT_CONFIGURED__'; // 特殊标记，在UI层处理本地化
        }
        // 仅显示域名部分（隐藏具体 path / 项目 id）
        try {
          final uri = Uri.parse(supabaseUrl!);
          if (uri.host.isEmpty) return supabaseUrl!; // 如果没有host，返回原始URL
          return uri.host; // 不展示 scheme 与后缀
        } catch (_) {
          return supabaseUrl!; // 解析失败，返回原始URL
        }

      case CloudBackendType.webdav:
        if (webdavUrl == null || webdavUrl!.isEmpty) {
          return '__NOT_CONFIGURED__';
        }
        // 显示WebDAV服务器地址的域名部分
        try {
          final uri = Uri.parse(webdavUrl!);
          if (uri.host.isEmpty) return webdavUrl!; // 如果没有host，返回原始URL
          return uri.host;
        } catch (_) {
          return webdavUrl!; // 解析失败，返回原始URL
        }

      case CloudBackendType.icloud:
        return 'iCloud Drive';

      case CloudBackendType.s3:
        if (s3Endpoint == null || s3Endpoint!.isEmpty) {
          return '__NOT_CONFIGURED__';
        }
        // 显示 endpoint / bucket
        final bucket = s3Bucket ?? '';
        return bucket.isEmpty ? s3Endpoint! : '$s3Endpoint / $bucket';
    }
  }
}

String encodeCloudConfig(CloudServiceConfig c) => jsonEncode(c.toJson());
CloudServiceConfig decodeCloudConfig(String raw) =>
    CloudServiceConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);

/// Legacy backend enum names (pre-rename brand) mapped to their current value.
///
/// The active-type value and the prefs key prefix were migrated when the
/// product was renamed, but the enum name stored *inside* the config body was
/// not. Such a config previously decoded to a StateError, which
/// `CloudServiceStore` swallowed into a silent fallback to local — i.e. the
/// user's cloud sync "disappeared". These names now decode to their current
/// equivalent, at the same level as the key / activeType migration.
const Map<String, CloudBackendType> _legacyBackendTypeNames =
    <String, CloudBackendType>{
  'beecountCloud': CloudBackendType.smartbookCloud,
  'beecountCloudSync': CloudBackendType.smartbookCloud,
};

/// Resolve the stored backend `type` name.
///
/// Legacy brand names are migrated; names this build does not know raise a
/// [CloudConfigurationException] (a classified package exception) instead of
/// `StateError`, so callers can tell "unknown backend" apart from other
/// failures instead of only being able to catch `Error`.
CloudBackendType _parseBackendType(Object? raw) {
  if (raw is! String) {
    throw CloudConfigurationException(
        'Invalid cloud config: field "type" must be a string');
  }
  final legacy = _legacyBackendTypeNames[raw];
  if (legacy != null) return legacy;
  for (final candidate in CloudBackendType.values) {
    if (candidate.name == raw) return candidate;
  }
  throw CloudConfigurationException('Unknown cloud backend type: "$raw"');
}

/// Fallback display name when the stored config has no (or a non-string)
/// `name`. Keeps the decoded object usable instead of throwing, and stays
/// recognisable in the UI.
String encodeBackendFallbackName(Object? type) =>
    type is String && type.isNotEmpty ? type : '__UNNAMED__';

String? _asString(Object? v) => v is String ? v : null;

String _requireString(Object? v, String field) {
  if (v is String) return v;
  throw CloudConfigurationException(
      'Invalid cloud config: field "$field" must be a string');
}

bool? _requireBool(Object? v, String field) {
  if (v == null || v is bool) return v as bool?;
  if (v is String) {
    final lower = v.trim().toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
  }
  throw CloudConfigurationException(
      'Invalid cloud config: field "$field" must be a boolean');
}

/// Strict int extraction for numeric JSON fields such as `s3Port`.
///
/// This package always *writes* an `int` for these fields, so anything else
/// (a `double` such as `9000.0`, a non-numeric string, Infinity) means the
/// stored config is malformed — raise a classified
/// [CloudConfigurationException] instead of letting the bare `_TypeError`
/// family (which `catch (Exception)` cannot see) escape.
int? _requireInt(Object? v, String field) {
  if (v == null || v is int) return v as int?;
  throw CloudConfigurationException(
      'Invalid cloud config: field "$field" must be an integer');
}
