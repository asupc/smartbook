# SmartBook Cloud Sync Integration Guide

本文档说明如何将新的 `flutter_cloud_sync` 包集成到 SmartBook 主应用中。

## 目录

1. [集成策略](#集成策略)
2. [依赖配置](#依赖配置)
3. [数据序列化器实现](#数据序列化器实现)
4. [Provider 配置](#provider-配置)
5. [SyncService 实现](#syncservice-实现)
6. [迁移步骤](#迁移步骤)
7. [测试验证](#测试验证)

## 集成策略

### 方案选择

**推荐方案：渐进式集成**

保持现有 `SyncService` 接口不变，用新的 `flutter_cloud_sync` 作为底层实现。这样可以：
- ✅ 最小化代码改动
- ✅ 保持向后兼容
- ✅ 逐步迁移，降低风险
- ✅ 复用现有的序列化逻辑

### 架构对比

**现有架构**:
```
SyncService (interface)
├── SupabaseSyncService
├── WebDAVSyncService
└── LocalOnlySyncService
```

**新架构**:
```
SyncService (interface)
└── CloudSyncServiceImpl (使用 flutter_cloud_sync)
    ├── CloudProvider (from flutter_cloud_sync)
    │   ├── SupabaseProvider
    │   ├── WebDAVProvider
    │   └── NoopProvider (for local-only)
    └── DataSerializer<int> (ledgerId)
```

## 依赖配置

### 1. 修改 pubspec.yaml

在 SmartBook 的 `pubspec.yaml` 中添加：

```yaml
dependencies:
  # 云同步核心包
  flutter_cloud_sync:
    path: packages/flutter_cloud_sync

  # 云服务 providers（按需添加）
  flutter_cloud_sync_supabase:
    path: packages/flutter_cloud_sync_supabase
  flutter_cloud_sync_webdav:
    path: packages/flutter_cloud_sync_webdav

  # 现有的 supabase_flutter 保留（用于兼容）
  supabase_flutter: ^2.5.6
```

### 2. 安装依赖

```bash
cd /Users/matrix/code/mine/SmartBook
flutter pub get
```

## 数据序列化器实现

创建 `lib/cloud/transaction_serializer.dart`:

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import '../data/db.dart';
import '../data/repository.dart';
import 'sync.dart'; // 复用现有的导出/导入逻辑

/// SmartBook 的数据序列化器
/// T = int (ledgerId)
class TransactionSerializer implements DataSerializer<int> {
  final BeeDatabase db;

  TransactionSerializer(this.db);

  @override
  Future<String> serialize(int ledgerId) async {
    // 复用现有的导出逻辑
    return await exportTransactionsJson(db, ledgerId);
  }

  @override
  Future<int> deserialize(String data) async {
    // JSON 中包含 ledgerId
    final json = jsonDecode(data) as Map<String, dynamic>;
    return json['ledgerId'] as int;
  }

  @override
  String fingerprint(String data) {
    // 使用 SHA256 计算指纹
    final bytes = utf8.encode(data);
    return sha256.convert(bytes).toString();
  }
}
```

## Provider 配置

创建 `lib/cloud/cloud_provider_factory.dart`:

```dart
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_supabase/flutter_cloud_sync_supabase.dart';
import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';

import 'cloud_service_config.dart';

/// 根据 CloudServiceConfig 创建 CloudProvider
Future<CloudProvider> createCloudProvider(CloudServiceConfig config) async {
  switch (config.type) {
    case CloudBackendType.local:
      // 本地存储，不需要云 provider
      // 返回一个 Noop provider 或抛出异常
      throw UnsupportedError('Local storage does not use cloud provider');

    case CloudBackendType.supabase:
      final provider = SupabaseProvider();
      await provider.initialize({
        'url': config.supabaseUrl!,
        'anonKey': config.supabaseAnonKey!,
        'bucket': 'smartbook-data', // 自定义 bucket 名称
      });
      return provider;

    case CloudBackendType.webdav:
      final provider = WebDAVProvider();
      await provider.initialize({
        'url': config.webdavUrl!,
        'username': config.webdavUsername!,
        'password': config.webdavPassword!,
        'remotePath': config.webdavRemotePath ?? '/SmartBook/',
      });
      return provider;
  }
}
```

## SyncService 实现

创建 `lib/cloud/cloud_sync_service_impl.dart`:

```dart
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;

import '../data/db.dart';
import '../data/repository.dart';
import 'sync.dart';
import 'transaction_serializer.dart';
import 'cloud_provider_factory.dart';
import 'cloud_service_config.dart';

/// 使用 flutter_cloud_sync 的 SyncService 实现
class CloudSyncServiceImpl implements SyncService {
  final BeeDatabase db;
  final BeeRepository repo;
  final CloudServiceConfig config;

  late final fcs.CloudProvider _provider;
  late final fcs.CloudSyncManager<int> _syncManager;

  // 本地缓存：ledgerId -> SyncStatus
  final Map<int, _CachedStatus> _statusCache = {};

  CloudSyncServiceImpl({
    required this.db,
    required this.repo,
    required this.config,
  });

  /// 初始化 provider 和 sync manager
  Future<void> initialize() async {
    _provider = await createCloudProvider(config);
    _syncManager = fcs.CloudSyncManager<int>(
      provider: _provider,
      serializer: TransactionSerializer(db),
      logger: fcs.CloudSyncLogger(
        onLog: (level, message) {
          print('[CloudSync] [$level] $message');
        },
      ),
      cacheTTL: const Duration(seconds: 30),
    );
  }

  String _pathForLedger(int ledgerId) => 'ledgers/$ledgerId.json';

  @override
  Future<void> uploadCurrentLedger({required int ledgerId}) async {
    try {
      await _syncManager.upload(
        data: ledgerId,
        path: _pathForLedger(ledgerId),
        metadata: {
          'version': '2',
          'uploadedAt': DateTime.now().toIso8601String(),
        },
      );

      // 上传后清除缓存
      _statusCache.remove(ledgerId);
    } on fcs.CloudNotAuthenticatedException {
      throw Exception('User not authenticated');
    } on fcs.CloudStorageException catch (e) {
      throw Exception('Upload failed: ${e.message}');
    }
  }

  @override
  Future<({int inserted, int skipped, int deletedDup})>
      downloadAndRestoreToCurrentLedger({required int ledgerId}) async {
    try {
      // 下载数据（返回 ledgerId，实际数据已在 deserialize 中处理）
      final downloadedLedgerId = await _syncManager.download(
        path: _pathForLedger(ledgerId),
      );

      if (downloadedLedgerId == null) {
        throw Exception('No remote backup found');
      }

      // 实际导入逻辑需要重新实现
      // 因为 deserialize 只返回 ledgerId，不能直接导入
      // 需要在 download 之前先获取原始 JSON

      // 方案：使用 provider.storage 直接下载
      final jsonStr = await _provider.storage.download(
        path: _pathForLedger(ledgerId),
      );

      if (jsonStr == null) {
        throw Exception('No remote backup found');
      }

      // 使用现有的导入逻辑
      final result = await importTransactionsJson(
        repo,
        ledgerId,
        jsonStr,
      );

      // 导入后执行本地去重
      final deletedDup = await repo.deduplicateTransactions(ledgerId);

      // 清除缓存
      _statusCache.remove(ledgerId);

      return (
        inserted: result.inserted,
        skipped: result.skipped,
        deletedDup: deletedDup,
      );
    } on fcs.CloudNotAuthenticatedException {
      throw Exception('User not authenticated');
    } on fcs.CloudStorageException catch (e) {
      throw Exception('Download failed: ${e.message}');
    }
  }

  @override
  Future<SyncStatus> getStatus({required int ledgerId}) async {
    // 检查缓存
    final cached = _statusCache[ledgerId];
    if (cached != null &&
        DateTime.now().difference(cached.timestamp) <
            const Duration(seconds: 30)) {
      return cached.status;
    }

    try {
      // 获取本地数据
      final localJson = await exportTransactionsJson(db, ledgerId);
      final localData = jsonDecode(localJson) as Map<String, dynamic>;
      final localCount = localData['count'] as int;
      final localFingerprint = _syncManager.serializer.fingerprint(localJson);

      // 获取云端状态
      final fcsStatus = await _syncManager.getStatus(
        data: ledgerId,
        path: _pathForLedger(ledgerId),
      );

      // 转换为 SmartBook 的 SyncStatus
      final status = _convertSyncStatus(
        fcsStatus,
        localCount,
        localFingerprint,
      );

      // 更新缓存
      _statusCache[ledgerId] = _CachedStatus(
        status: status,
        timestamp: DateTime.now(),
      );

      return status;
    } catch (e) {
      return SyncStatus(
        diff: SyncDiff.error,
        localCount: 0,
        localFingerprint: '',
        message: e.toString(),
      );
    }
  }

  @override
  Future<({String? fingerprint, int? count, DateTime? exportedAt})>
      refreshCloudFingerprint({required int ledgerId}) async {
    try {
      // 强制刷新云端状态
      final fcsStatus = await _syncManager.getStatus(
        data: ledgerId,
        path: _pathForLedger(ledgerId),
        forceRefresh: true,
      );

      // 如果有云端指纹，下载完整数据获取 count 和 exportedAt
      if (fcsStatus.cloudFingerprint != null) {
        final jsonStr = await _provider.storage.download(
          path: _pathForLedger(ledgerId),
        );

        if (jsonStr != null) {
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          return (
            fingerprint: fcsStatus.cloudFingerprint,
            count: data['count'] as int?,
            exportedAt: data['exportedAt'] != null
                ? DateTime.parse(data['exportedAt'] as String)
                : null,
          );
        }
      }

      return (
        fingerprint: fcsStatus.cloudFingerprint,
        count: null,
        exportedAt: null,
      );
    } catch (e) {
      return (fingerprint: null, count: null, exportedAt: null);
    }
  }

  @override
  void markLocalChanged({required int ledgerId}) {
    _statusCache.remove(ledgerId);
    _syncManager.clearCache();
  }

  @override
  Future<void> deleteRemoteBackup({required int ledgerId}) async {
    try {
      await _syncManager.deleteRemote(
        path: _pathForLedger(ledgerId),
      );
      _statusCache.remove(ledgerId);
    } on fcs.CloudStorageException catch (e) {
      // 忽略 404
      if (!e.message.contains('404')) {
        throw Exception('Delete failed: ${e.message}');
      }
    }
  }

  /// 转换 flutter_cloud_sync 的 SyncStatus 到 SmartBook 的 SyncStatus
  SyncStatus _convertSyncStatus(
    fcs.SyncStatus fcsStatus,
    int localCount,
    String localFingerprint,
  ) {
    // 映射 SyncState -> SyncDiff
    final diff = switch (fcsStatus.state) {
      fcs.SyncState.notConfigured => SyncDiff.notConfigured,
      fcs.SyncState.notAuthenticated => SyncDiff.notLoggedIn,
      fcs.SyncState.localOnly => SyncDiff.noRemote,
      fcs.SyncState.synced => SyncDiff.inSync,
      fcs.SyncState.outOfSync => SyncDiff.different,
      fcs.SyncState.error => SyncDiff.error,
      _ => SyncDiff.different,
    };

    return SyncStatus(
      diff: diff,
      localCount: localCount,
      cloudCount: null, // 需要额外请求获取
      localFingerprint: localFingerprint,
      cloudFingerprint: fcsStatus.cloudFingerprint,
      cloudExportedAt: null, // 需要额外请求获取
      message: fcsStatus.message,
    );
  }
}

class _CachedStatus {
  final SyncStatus status;
  final DateTime timestamp;

  _CachedStatus({required this.status, required this.timestamp});
}
```

## Provider 配置

创建 `lib/providers/cloud_sync_providers.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;

import '../cloud/cloud_sync_service_impl.dart';
import '../cloud/cloud_service_config.dart';
import '../cloud/sync.dart';
import '../data/repository.dart';
import 'repository_provider.dart';
import 'cloud_service_providers.dart'; // 现有的 cloud service provider

/// 云同步服务 Provider（新版）
final cloudSyncServiceProvider = FutureProvider.family<SyncService, CloudServiceConfig>(
  (ref, config) async {
    if (config.type == CloudBackendType.local) {
      return LocalOnlySyncService();
    }

    final repo = await ref.watch(repositoryProvider.future);
    final service = CloudSyncServiceImpl(
      db: repo.db,
      repo: repo,
      config: config,
    );

    await service.initialize();
    return service;
  },
);

/// 当前活跃的云同步服务
final activeSyncServiceProvider = FutureProvider<SyncService>((ref) async {
  final config = await ref.watch(currentCloudConfigProvider.future);
  return ref.watch(cloudSyncServiceProvider(config).future);
});
```

## 迁移步骤

### Phase 1: 准备阶段（1-2天）

1. ✅ **添加依赖**
   ```bash
   cd /Users/matrix/code/mine/SmartBook
   # 编辑 pubspec.yaml 添加新包
   flutter pub get
   ```

2. ✅ **创建新文件**
   - `lib/cloud/transaction_serializer.dart`
   - `lib/cloud/cloud_provider_factory.dart`
   - `lib/cloud/cloud_sync_service_impl.dart`
   - `lib/providers/cloud_sync_providers.dart`

3. ✅ **编译检查**
   ```bash
   flutter analyze
   dart format lib/cloud/*.dart
   ```

### Phase 2: 并行测试（2-3天）

1. **创建测试环境**
   - 使用新的 `CloudSyncServiceImpl` 进行独立测试
   - 不影响现有功能

2. **功能测试**
   - 上传/下载
   - 同步状态检查
   - 去重逻辑
   - 错误处理

3. **性能对比**
   - 对比新旧实现的性能
   - 确保没有性能退化

### Phase 3: 逐步替换（3-5天）

1. **UI 层保持不变**
   - 只替换 `sync_providers.dart` 中的实现
   - UI 继续使用 `SyncService` 接口

2. **逐个 backend 迁移**
   - 先迁移 WebDAV（风险较低）
   - 再迁移 Supabase
   - 最后处理 local-only

3. **监控和回滚**
   - 添加日志和错误追踪
   - 准备快速回滚方案

### Phase 4: 清理和优化（1-2天）

1. **删除旧代码**
   - 删除 `lib/cloud/supabase_sync.dart`
   - 删除 `lib/cloud/webdav_sync.dart`
   - 保留 `lib/cloud/sync.dart`（接口）

2. **代码优化**
   - 简化 provider 结构
   - 优化错误处理
   - 更新文档和注释

3. **发布测试**
   - 完整的端到端测试
   - 准备发布 notes

## 测试验证

### 单元测试

创建 `test/cloud/cloud_sync_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
// ... 测试用例

void main() {
  group('CloudSyncServiceImpl', () {
    test('should upload and download transactions', () async {
      // TODO: 实现测试
    });

    test('should detect sync status correctly', () async {
      // TODO: 实现测试
    });

    test('should handle errors gracefully', () async {
      // TODO: 实现测试
    });
  });
}
```

### 集成测试

创建 `integration_test/cloud_sync_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// ... 集成测试用例

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Cloud Sync Integration', () {
    testWidgets('full sync workflow', (tester) async {
      // TODO: 完整的同步流程测试
    });
  });
}
```

### 手动测试清单

- [ ] Supabase 上传/下载
- [ ] WebDAV 上传/下载
- [ ] 同步状态正确显示
- [ ] 去重逻辑正常工作
- [ ] 错误提示清晰
- [ ] 网络错误重试
- [ ] 离线模式处理
- [ ] 账户切换处理
- [ ] 多账本切换

## 优势总结

### 使用新包的好处

1. **统一架构**
   - 统一的接口和抽象
   - 易于添加新的 provider
   - 代码复用度高

2. **更好的错误处理**
   - 类型化的异常
   - 清晰的错误信息
   - 自动重试机制

3. **内置功能**
   - 指纹对比
   - 状态缓存
   - 路径管理
   - 日志系统

4. **可测试性**
   - 接口清晰
   - 易于 mock
   - 独立测试

5. **可维护性**
   - 关注点分离
   - 代码组织清晰
   - 文档完善

## 注意事项

1. **向后兼容**
   - 保持现有的 JSON 格式不变
   - 保持现有的路径结构
   - 保持现有的 UI 接口

2. **数据安全**
   - 先备份现有数据
   - 测试去重逻辑
   - 验证指纹计算

3. **用户体验**
   - 同步速度不变或更快
   - 错误提示更清晰
   - 状态显示更准确

4. **回滚计划**
   - 保留旧代码分支
   - 快速切换机制
   - 监控和告警

## 参考资料

- [flutter_cloud_sync README](README.md)
- [flutter_cloud_sync USAGE_GUIDE](USAGE_GUIDE.md)
- [Supabase Provider README](../flutter_cloud_sync_supabase/README.md)
- [WebDAV Provider README](../flutter_cloud_sync_webdav/README.md)
- [SmartBook Architecture](../../.docs/architecture.md)
