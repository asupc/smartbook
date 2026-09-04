import '../../data/db.dart';
import '../system/logger_service.dart';

/// v1.15.0 账户独立改造迁移服务
///
/// 功能：
/// 1. 将账户从依附于账本改为独立实体
/// 2. 为账户添加币种字段（从账本继承）
/// 3. 提供测试用的迁移和回滚方法
class AccountMigrationService {
  final BeeDatabase db;

  AccountMigrationService(this.db);

  /// 检查是否需要迁移到 v1.15.0
  Future<bool> needsMigration() async {
    try {
      // 只检查 schema_migrations 表，这是唯一可靠的迁移状态标记
      final migrationVersion = await _getMigrationVersion();

      if (migrationVersion >= 2) {
        // schema_migrations中有version=2记录，说明已完成迁移
        return false;
      }

      // 没有迁移记录，需要执行迁移
      // 注意：即使currency字段已存在，也可能数据不正确（Drift自动填充的默认值）
      logger.info('MigrationService', '检测到需要执行v1.15.0迁移（schema_migrations未记录version=2）');
      return true;
    } catch (e) {
      logger.error('MigrationService', '检查迁移状态失败', e);
      // 出错时保守处理，执行迁移以确保数据正确
      return true;
    }
  }

  /// 获取当前迁移版本
  Future<int> _getMigrationVersion() async {
    try {
      final result = await db.customSelect(
        'SELECT MAX(version) as version FROM schema_migrations',
      ).getSingle();

      final version = result.data['version'];
      if (version == null) return 0;
      if (version is int) return version;
      if (version is BigInt) return version.toInt();
      if (version is num) return version.toInt();
      return 0;
    } catch (e) {
      // schema_migrations 表不存在，说明是 v1
      return 0;
    }
  }

  /// 检查 accounts 表是否有 currency 字段
  Future<bool> _checkAccountsTableHasCurrency() async {
    try {
      final tableInfo = await db.customSelect(
        "PRAGMA table_info(accounts)",
      ).get();

      return tableInfo.any((row) => row.data['name'] == 'currency');
    } catch (e) {
      return false;
    }
  }

  /// 检查是否有账户的 currency 为 null
  Future<bool> _hasAccountsWithNullCurrency() async {
    try {
      // 先检查 currency 字段是否存在
      final hasCurrencyField = await _checkAccountsTableHasCurrency();
      if (!hasCurrencyField) {
        return false; // 字段都没有，不存在 null 的问题
      }

      // 检查是否有 currency 为 null 的账户
      final result = await db.customSelect(
        'SELECT COUNT(*) as count FROM accounts WHERE currency IS NULL',
      ).getSingle();

      final count = result.data['count'];
      if (count == null) return false;
      if (count is int) return count > 0;
      if (count is BigInt) return count > BigInt.zero;
      if (count is num) return count > 0;
      return false;
    } catch (e) {
      logger.error('MigrationService', '检查 null currency 失败', e);
      return false;
    }
  }

  /// 执行 v1.15.0 迁移
  ///
  /// 迁移步骤：
  /// 1. 备份原始表
  /// 2. 创建新表结构
  /// 3. 迁移数据（从账本继承currency）
  /// 4. 替换旧表
  /// 5. 创建索引并验证
  Future<MigrationResult> migrateToV2() async {
    logger.info('MigrationService', '🚀 开始 v1.15.0 账户独立迁移（完整迁移）...');

    try {
      // 总是执行完整迁移，确保数据正确
      await _fullMigration();

      return MigrationResult(
        success: true,
        message: '迁移成功完成',
      );
    } catch (e, stack) {
      logger.error('MigrationService', '❌ 迁移失败', e, stack);

      return MigrationResult(
        success: false,
        message: '迁移失败: $e',
        error: e,
      );
    }
  }

  /// 轻量迁移：更新所有账户的 currency（从账本继承）
  Future<void> _lightweightMigration() async {
    logger.info('MigrationService', '📦 执行轻量迁移（currency 字段已存在）...');

    await db.transaction(() async {
      // 更新所有账户的currency，从账本继承正确的币种
      // 注意：不仅更新null值，因为Drift可能已自动填充了错误的默认值
      logger.info('MigrationService', '📊 更新所有账户的currency（从账本继承）...');
      await db.customStatement('''
        UPDATE accounts
        SET currency = COALESCE(
          (SELECT currency FROM ledgers WHERE ledgers.id = accounts.ledger_id),
          'CNY'
        )
        WHERE ledger_id IS NOT NULL
      ''');

      // 记录迁移版本
      logger.info('MigrationService', '📝 记录迁移版本...');
      await db.customStatement('''
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
      ''');

      await db.customStatement('''
        INSERT OR REPLACE INTO schema_migrations (version, applied_at)
        VALUES (2, datetime('now'))
      ''');

      logger.info('MigrationService', '✅ 轻量迁移完成');
    });
  }

  /// 完整迁移：重建表并迁移数据
  Future<void> _fullMigration() async {
    logger.info('MigrationService', '📦 执行完整迁移（重建表）...');

    await db.transaction(() async {
        // Step 1: 备份原始表
        logger.info('MigrationService', '📦 Step 1: 备份 accounts 表...');
        // 先删除旧备份（如果存在）
        await db.customStatement('DROP TABLE IF EXISTS accounts_backup');
        await db.customStatement(
          'CREATE TABLE accounts_backup AS SELECT * FROM accounts',
        );

        // Step 2: 创建新的 accounts 表
        logger.info('MigrationService', '🔨 Step 2: 创建新的 accounts 表...');
        await db.customStatement('''
          CREATE TABLE accounts_new (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_id INTEGER,
            name TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'cash',
            currency TEXT NOT NULL DEFAULT 'CNY',
            initial_balance REAL NOT NULL DEFAULT 0.0,
            created_at INTEGER,
            updated_at INTEGER
          )
        ''');

        // Step 3: 迁移数据（从账本继承币种，确保created_at非空）
        logger.info('MigrationService', '📊 Step 3: 迁移数据（从账本继承币种，确保created_at非空）...');

        // 检查原表是否有 created_at 字段
        final backupTableInfo = await db.customSelect('PRAGMA table_info(accounts_backup)').get();
        final hasCreatedAtInBackup = backupTableInfo.any((row) => row.data['name'] == 'created_at');

        if (hasCreatedAtInBackup) {
          // 保留原有的 created_at，如果为null则用当前时间
          await db.customStatement('''
            INSERT INTO accounts_new (id, ledger_id, name, type, currency, initial_balance, created_at)
            SELECT
              a.id,
              a.ledger_id,
              a.name,
              a.type,
              COALESCE(l.currency, 'CNY') AS currency,
              a.initial_balance,
              COALESCE(a.created_at, CAST(strftime('%s', 'now') AS INTEGER)) AS created_at
            FROM accounts_backup a
            LEFT JOIN ledgers l ON a.ledger_id = l.id
          ''');
        } else {
          // 设置新的创建时间
          await db.customStatement('''
            INSERT INTO accounts_new (id, ledger_id, name, type, currency, initial_balance, created_at)
            SELECT
              a.id,
              a.ledger_id,
              a.name,
              a.type,
              COALESCE(l.currency, 'CNY') AS currency,
              a.initial_balance,
              CAST(strftime('%s', 'now') AS INTEGER) AS created_at
            FROM accounts_backup a
            LEFT JOIN ledgers l ON a.ledger_id = l.id
          ''');
        }

        // Step 4: 替换旧表
        logger.info('MigrationService', '🔄 Step 4: 替换旧表...');
        await db.customStatement('DROP TABLE accounts');
        await db.customStatement('ALTER TABLE accounts_new RENAME TO accounts');

        // Step 5: 创建索引
        logger.info('MigrationService', '📇 Step 5: 创建索引...');
        await db.customStatement(
          'CREATE INDEX idx_accounts_currency ON accounts(currency)',
        );

        // Step 6: 验证数据完整性
        logger.info('MigrationService', '✅ Step 6: 验证数据完整性...');
        final accountCount = await db.customSelect(
          'SELECT COUNT(*) as count FROM accounts',
        ).getSingle();
        final backupCount = await db.customSelect(
          'SELECT COUNT(*) as count FROM accounts_backup',
        ).getSingle();

        final accountNum = accountCount.data['count'] as int;
        final backupNum = backupCount.data['count'] as int;

        if (accountNum != backupNum) {
          throw Exception('账户数量不匹配: $accountNum != $backupNum');
        }

        // Step 7: 记录迁移版本
        logger.info('MigrationService', '📝 Step 7: 记录迁移版本...');
        await db.customStatement('''
          CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
          )
        ''');

        await db.customStatement('''
          INSERT OR REPLACE INTO schema_migrations (version, applied_at)
          VALUES (2, datetime('now'))
        ''');

        // Step 8: 自动清理备份表（迁移成功后）
        logger.info('MigrationService', '🗑️  Step 8: 清理备份表...');
        await db.customStatement('DROP TABLE IF EXISTS accounts_backup');

        logger.info('MigrationService', '✅ 完整迁移完成！账户数量: $accountNum');
      });
  }

  /// 回滚 v1.15.0 迁移
  ///
  /// 将数据库恢复到迁移前的状态
  Future<MigrationResult> rollbackV2() async {
    logger.info('MigrationService', '🔄 开始回滚 v1.15.0 迁移...');

    try {
      // 检查备份表是否存在
      final result = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='accounts_backup'",
      ).get();

      if (result.isEmpty) {
        return MigrationResult(
          success: false,
          message: '未找到备份表，无法回滚',
        );
      }

      await db.transaction(() async {
        // 删除新表
        logger.info('MigrationService', '🗑️  删除新的 accounts 表...');
        await db.customStatement('DROP TABLE IF EXISTS accounts');

        // 恢复备份
        logger.info('MigrationService', '📦 恢复备份表...');
        await db.customStatement('ALTER TABLE accounts_backup RENAME TO accounts');

        // 删除迁移记录
        logger.info('MigrationService', '📝 删除迁移记录...');
        await db.customStatement('DELETE FROM schema_migrations WHERE version = 2');

        logger.info('MigrationService', '✅ 回滚完成！');
      });

      return MigrationResult(
        success: true,
        message: '回滚成功完成',
      );
    } catch (e, stack) {
      logger.error('MigrationService', '❌ 回滚失败', e, stack);

      return MigrationResult(
        success: false,
        message: '回滚失败: $e',
        error: e,
      );
    }
  }

  /// 清理备份表（迁移成功且稳定运行后）
  Future<void> cleanupBackup() async {
    try {
      await db.customStatement('DROP TABLE IF EXISTS accounts_backup');
      logger.info('MigrationService', '🗑️  备份表已清理');
    } catch (e) {
      logger.error('MigrationService', '清理备份表失败', e);
    }
  }

  /// 获取迁移状态信息
  Future<MigrationStatus> getStatus() async {
    try {
      // 检查迁移版本（使用 schema_migrations 表）
      final migrationVersion = await _getMigrationVersion();

      // 检查备份表（仅用于显示，不用于判断迁移状态）
      final backupExists = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='accounts_backup'",
      ).get();

      // 检查 accounts 表结构
      final hasCurrencyField = await _checkAccountsTableHasCurrency();

      final tableInfo = await db.customSelect(
        "PRAGMA table_info(accounts)",
      ).get();
      final hasCreatedAtField = tableInfo.any((row) => row.data['name'] == 'created_at');

      // 统计账户数量
      final accountCount = await db.customSelect(
        'SELECT COUNT(*) as count FROM accounts',
      ).getSingle();

      return MigrationStatus(
        hasMigrated: migrationVersion >= 2,  // 使用版本号判断
        migrationVersion: migrationVersion,
        hasCurrencyField: hasCurrencyField,
        hasCreatedAtField: hasCreatedAtField,
        accountCount: accountCount.data['count'] as int,
        hasBackup: backupExists.isNotEmpty,
      );
    } catch (e) {
      logger.error('MigrationService', '获取迁移状态失败', e);
      return MigrationStatus(
        hasMigrated: false,
        migrationVersion: 0,
        hasCurrencyField: false,
        hasCreatedAtField: false,
        accountCount: 0,
        hasBackup: false,
      );
    }
  }
}

/// 迁移结果
class MigrationResult {
  final bool success;
  final String message;
  final Object? error;

  MigrationResult({
    required this.success,
    required this.message,
    this.error,
  });

  @override
  String toString() {
    return 'MigrationResult(success: $success, message: $message)';
  }
}

/// 迁移状态
class MigrationStatus {
  final bool hasMigrated;
  final int migrationVersion;
  final bool hasCurrencyField;
  final bool hasCreatedAtField;
  final int accountCount;
  final bool hasBackup;

  MigrationStatus({
    required this.hasMigrated,
    required this.migrationVersion,
    required this.hasCurrencyField,
    required this.hasCreatedAtField,
    required this.accountCount,
    required this.hasBackup,
  });

  @override
  String toString() {
    return 'MigrationStatus(\n'
        '  已迁移: $hasMigrated\n'
        '  迁移版本: $migrationVersion\n'
        '  有currency字段: $hasCurrencyField\n'
        '  有created_at字段: $hasCreatedAtField\n'
        '  账户数量: $accountCount\n'
        '  有备份表: $hasBackup\n'
        ')';
  }
}

