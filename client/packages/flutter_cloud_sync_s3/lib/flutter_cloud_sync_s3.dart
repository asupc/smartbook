/// S3 provider for flutter_cloud_sync
///
/// Supports all S3-compatible storage services:
/// - AWS S3
/// - Cloudflare R2
/// - Backblaze B2
/// - MinIO (self-hosted)
/// - Aliyun OSS
/// - Tencent COS
/// - Qiniu Kodo
///
/// ## Usage
///
/// ```dart
/// import 'package:flutter_cloud_sync_s3/flutter_cloud_sync_s3.dart';
///
/// final provider = S3Provider();
/// await provider.initialize({
///   'endpoint': '<account-id>.r2.cloudflarestorage.com',
///   'region': 'auto',
///   'accessKey': 'your-access-key',
///   'secretKey': 'your-secret-key',
///   'bucket': 'smartbook-data',
///   'useSSL': true,
/// });
/// ```
library;

export 'src/s3_provider.dart';
export 'src/s3_exceptions.dart';
