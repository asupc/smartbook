import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 's3_client.dart';
import 's3_exceptions.dart';

/// S3 认证服务实现
///
/// S3 使用 Access Key 认证，无传统的登录/登出概念
class S3AuthService implements CloudAuthService {
  final S3Client client;
  final String bucket;

  S3AuthService(this.client, this.bucket);

  @override
  Future<CloudUser?> getCurrentUser() async {
    // S3 使用 Access Key 认证，无用户概念
    // 直接返回用户信息，不需要网络验证（类似 WebDAV）
    // 实际的连接验证在 provider.initialize() 时已完成
    return CloudUser(
      id: 's3-${client.accessKey}',
      email: null, // S3 无 email
      metadata: {
        'bucket': bucket,
        'endpoint': client.endpoint,
        'region': client.region,
      },
    );
  }

  @override
  Future<void> signIn(Map<String, dynamic> credentials) async {
    // S3 在 initialize 时已完成认证和连接验证
    // 这里不需要额外的网络请求
    // 如果需要验证连接，应该由调用方在 provider.initialize() 时完成
  }

  @override
  Future<void> signOut() async {
    // S3 无需登出操作
    // 认证信息在 provider dispose 时清除
  }

  @override
  Future<void> refreshToken() async {
    // S3 Access Key 不需要刷新
  }

  @override
  bool get isAuthenticated {
    // 简单判断：如果 client 存在，认为已认证
    // 实际验证在 getCurrentUser() 中进行
    return true;
  }

  @override
  Stream<CloudUser?> get authStateChanges {
    // S3 无状态变化概念，返回固定流
    return Stream.value(CloudUser(
      id: 's3-${client.accessKey}',
      email: null,
      metadata: {
        'bucket': bucket,
        'endpoint': client.endpoint,
        'region': client.region,
      },
    ));
  }

  @override
  Future<CloudUser?> get currentUser async {
    return getCurrentUser();
  }

  @override
  Future<CloudUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    throw CloudAuthException('S3 does not support email authentication');
  }

  @override
  Future<CloudUser> signUpWithEmail({
    required String email,
    required String password,
    Map<String, dynamic>? metadata,
  }) async {
    throw CloudAuthException('S3 does not support email registration');
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {
    throw CloudAuthException('S3 does not support password reset');
  }

  @override
  Future<void> resendEmailVerification({required String email}) async {
    throw CloudAuthException('S3 does not support email verification');
  }
}
