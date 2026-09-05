import 'dart:convert';

import 'package:drift/drift.dart' as d;
import '../data/db.dart';
import '../data/repositories/base_repository.dart';
import '../data/repositories/transaction_repository.dart'
    show BatchAttachmentData;
import 'currency/rate_math.dart';
import 'system/logger_service.dart';
import 'automation/auto_book_event.dart';
import 'automation/auto_book_event_store.dart';

/// 统一的数据导入服务
///
/// 用于CSV导入和云端恢复，确保两者使用相同的导入逻辑

// --- 导入数据模型 ---

/// 导入账户数据
class ImportAccount {
  final String name;
  final String? type;
  final String? currency;
  final double? initialBalance;

  const ImportAccount({
    required this.name,
    this.type,
    this.currency,
    this.initialBalance,
  });
}

/// 导入分类数据
class ImportCategory {
  final String name;
  final String kind; // 'income' or 'expense'
  final int level; // 1 or 2
  final int sortOrder; // 排序顺序
  final String? icon;
  final String? parentName; // 二级分类的父分类名称
  final String? iconType; // 图标类型: material / custom / community
  final String? customIconPath; // 自定义图标路径
  final String? communityIconId; // 社区图标ID

  const ImportCategory({
    required this.name,
    required this.kind,
    this.level = 1,
    this.sortOrder = 0,
    this.icon,
    this.parentName,
    this.iconType,
    this.customIconPath,
    this.communityIconId,
  });
}

/// 导入标签数据
class ImportTag {
  final String name;
  final String? color;

  const ImportTag({
    required this.name,
    this.color,
  });
}

/// 导入附件数据
class ImportAttachment {
  final String fileName;
  final String? originalName;
  final int? fileSize;
  final int? width;
  final int? height;
  final int sortOrder;
  final String? cloudFileId;
  final String? cloudSha256;

  const ImportAttachment({
    required this.fileName,
    this.originalName,
    this.fileSize,
    this.width,
    this.height,
    this.sortOrder = 0,
    this.cloudFileId,
    this.cloudSha256,
  });
}

/// 导入交易数据
class ImportTransaction {
  final String type; // 'income', 'expense', 'transfer'
  final double amount;
  final String? categoryName;
  final String? categoryKind;
  final DateTime happenedAt;
  final String? note;
  final String? accountName; // 普通账户（收入/支出）
  final String? fromAccountName; // 转出账户（转账）
  final String? toAccountName; // 转入账户（转账）
  final List<String>? tagNames; // 标签名称列表
  final int? categoryId; // 预解析的分类ID（优先于categoryName）
  final List<ImportAttachment>? attachments; // 附件元数据列表
  final String? syncId; // 跨设备同步唯一标识
  /// v30 多币种:CSV 币种列(反馈10)。null → 账户币种/账本本位币兜底。
  final String? currencyCode;

  /// 支付平台/导入来源(如 alipay、wechat、bank_csv)。
  final String? provider;

  /// 交易号/订单号/流水号。只用于本地导入幂等，不写入 syncId。
  final String? externalId;

  /// 原始状态(成功/退款/待支付/关闭等)，非成功状态不直接落库。
  final String? status;

  /// 成功退款金额(部分平台会单独提供)，用于把退款行归一为收入。
  final double? refundAmount;

  /// 文件内稳定行 hash；无 externalId 时用于重复导入识别。
  final String? sourceRowHash;

  const ImportTransaction({
    required this.type,
    required this.amount,
    this.currencyCode,
    this.categoryName,
    this.categoryKind,
    required this.happenedAt,
    this.note,
    this.accountName,
    this.fromAccountName,
    this.toAccountName,
    this.tagNames,
    this.categoryId,
    this.attachments,
    this.syncId,
    this.provider,
    this.externalId,
    this.status,
    this.refundAmount,
    this.sourceRowHash,
  });
}

/// 统一的导入数据格式
class ImportData {
  final List<ImportAccount> accounts;
  final List<ImportCategory> categories;
  final List<ImportTag> tags;
  final List<ImportTransaction> transactions;

  /// 账本名称（可选，用于更新账本信息）
  final String? ledgerName;

  /// 货币（可选，用于更新账本信息）
  final String? currency;

  const ImportData({
    this.accounts = const [],
    this.categories = const [],
    this.tags = const [],
    this.transactions = const [],
    this.ledgerName,
    this.currency,
  });
}

/// 导入结果
class ImportResult {
  final int inserted;
  final int failed;
  final int duplicated;
  final int ignored;
  final int invalid;

  const ImportResult({
    required this.inserted,
    required this.failed,
    this.duplicated = 0,
    this.ignored = 0,
    this.invalid = 0,
  });

  int get handled => inserted + duplicated + ignored + invalid;
}

enum ImportPreviewStatus { newRow, duplicate, ignored, invalid }

class ImportPreviewRow {
  final int index;
  final ImportPreviewStatus status;
  final String reason;
  final String? eventKey;

  const ImportPreviewRow({
    required this.index,
    required this.status,
    required this.reason,
    this.eventKey,
  });
}

/// 导入前的只读差异预览。它不 claim、不写 event store，也不创建交易。
class ImportPreview {
  final List<ImportPreviewRow> rows;

  const ImportPreview(this.rows);

  int get newCount =>
      rows.where((row) => row.status == ImportPreviewStatus.newRow).length;
  int get duplicateCount =>
      rows.where((row) => row.status == ImportPreviewStatus.duplicate).length;
  int get ignoredCount =>
      rows.where((row) => row.status == ImportPreviewStatus.ignored).length;
  int get invalidCount =>
      rows.where((row) => row.status == ImportPreviewStatus.invalid).length;
}

// --- 数据导入服务 ---

/// 通用数据导入服务
///
/// 提供统一的导入逻辑，支持：
/// - 账户创建（全局按名称去重）
/// - 分类创建（先一级后二级）
/// - 标签创建
/// - 交易插入（批量写入）
/// - 标签关联
class DataImportService {
  /// 计算导入差异预览。只读，不会 claim 事件或写入交易。
  Future<ImportPreview> previewTransactions(
    BaseRepository repo,
    int ledgerId,
    List<ImportTransaction> transactions, {
    AutoBookEventStore? eventStore,
    String provider = 'import',
    String? batchKey,
  }) async {
    final rows = <ImportPreviewRow>[];
    final seen = <String>{};
    for (var index = 0; index < transactions.length; index++) {
      final tx = transactions[index];
      final amount = tx.refundAmount != null && tx.refundAmount!.abs() > 0
          ? tx.refundAmount!.abs()
          : tx.amount.abs();
      final effectiveType =
          isRefundStatus(tx.status) || (tx.refundAmount?.abs() ?? 0) > 0
              ? 'income'
              : tx.type;
      final validDate = tx.happenedAt.year > 1970 &&
          tx.happenedAt.year <= DateTime.now().year + 1;
      if (!tx.amount.isFinite ||
          !amount.isFinite ||
          amount <= 0 ||
          !validDate ||
          !const {'income', 'expense', 'transfer'}.contains(effectiveType)) {
        rows.add(ImportPreviewRow(
          index: index,
          status: ImportPreviewStatus.invalid,
          reason: 'invalid_amount_or_date',
        ));
        continue;
      }
      if (isNonBookableStatus(tx.status)) {
        rows.add(ImportPreviewRow(
          index: index,
          status: ImportPreviewStatus.ignored,
          reason: 'non_bookable_status',
        ));
        continue;
      }

      final eventKey = importEventKey(
        ledgerId: ledgerId,
        provider: tx.provider ?? provider,
        transaction: tx,
        batchKey: batchKey,
      );
      if (!seen.add(eventKey)) {
        rows.add(ImportPreviewRow(
          index: index,
          status: ImportPreviewStatus.duplicate,
          reason: 'duplicate_in_batch',
          eventKey: eventKey,
        ));
        continue;
      }
      if (eventStore != null &&
          await eventStore.findByEventKey(eventKey) != null) {
        rows.add(ImportPreviewRow(
          index: index,
          status: ImportPreviewStatus.duplicate,
          reason: 'already_imported',
          eventKey: eventKey,
        ));
        continue;
      }
      rows.add(ImportPreviewRow(
        index: index,
        status: ImportPreviewStatus.newRow,
        reason: 'new',
        eventKey: eventKey,
      ));
    }
    return ImportPreview(List.unmodifiable(rows));
  }

  /// 导入数据到指定账本
  ///
  /// [repo] - 数据仓库
  /// [ledgerId] - 目标账本ID
  /// [data] - 导入数据
  /// [defaultCurrency] - 默认货币（用于创建账户）
  /// [onProgress] - 进度回调 (done, total)
  /// [recordChanges] - 默认 true,会调 repo.insertTransactionsBatch 时登记
  ///   changeTracker。FullPull 路径传 false,避免"从云端拉下来的数据又反向推
  ///   回去"。
  Future<ImportResult> importData(
    BaseRepository repo,
    int ledgerId,
    ImportData data, {
    String defaultCurrency = 'CNY',
    void Function(int done, int total)? onProgress,
    bool recordChanges = true,
    AutoBookEventStore? eventStore,
    String provider = 'import',
    String? batchKey,
  }) async {
    // 1. 更新账本信息（如果提供）
    if (data.ledgerName != null || data.currency != null) {
      try {
        await repo.updateLedger(
          id: ledgerId,
          name: data.ledgerName,
          currency: data.currency,
        );
      } catch (_) {}
    }

    // 2. 导入账户
    final accountNameToId = await importAccounts(
      repo,
      data.accounts,
      defaultCurrency: data.currency ?? defaultCurrency,
    );

    // 3. 导入分类
    final categoryCache = await importCategories(repo, data.categories);

    // 4. 导入标签
    final tagNameToId = await importTags(repo, data.tags);

    // 5. 导入交易
    final result = await importTransactions(
      repo,
      ledgerId,
      data.transactions,
      accountNameToId: accountNameToId,
      categoryCache: categoryCache,
      tagNameToId: tagNameToId,
      onProgress: onProgress,
      recordChanges: recordChanges,
      eventStore: eventStore,
      provider: provider,
      batchKey: batchKey,
    );

    return result;
  }

  /// 导入账户(全局按名称去重)。public — sync_diff_service 也复用,避免维护两套。
  Future<Map<String, int>> importAccounts(
      BaseRepository repo, List<ImportAccount> accounts,
      {String defaultCurrency = 'CNY'}) async {
    final accountNameToId = <String, int>{};

    if (accounts.isEmpty) return accountNameToId;
    logger.info('AccountImport', '开始导入账户: ${accounts.length} 个');
    final sw = Stopwatch()..start();
    int created = 0;

    try {
      final existingAccounts = await repo.getAllAccounts();
      for (final acc in existingAccounts) {
        accountNameToId[acc.name] = acc.id;
      }

      for (final acc in accounts) {
        if (!accountNameToId.containsKey(acc.name)) {
          final id = await repo.createAccount(
            ledgerId: 0, // 账户独立,不绑定账本
            name: acc.name,
            type: acc.type ?? 'cash',
            currency: acc.currency ?? defaultCurrency,
            initialBalance: acc.initialBalance ?? 0.0,
          );
          accountNameToId[acc.name] = id;
          created++;
        }
      }
      logger.info('AccountImport',
          '账户导入完成: 新增=$created 已存在=${accounts.length - created} 耗时=${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      logger.error('AccountImport', '账户导入失败', e, st);
    }

    return accountNameToId;
  }

  /// 导入分类(先一级后二级)。public — sync_diff_service 复用。
  Future<Map<String, int>> importCategories(
    BaseRepository repo,
    List<ImportCategory> categories,
  ) async {
    final categoryCache = <String, int>{}; // key: kind|name -> id

    if (categories.isEmpty) return categoryCache;
    logger.info('CategoryImport', '开始导入分类: ${categories.length} 个');
    final sw = Stopwatch()..start();
    int created = 0;

    try {
      // 获取所有现有分类
      final existingExpense = await repo.getTopLevelCategories('expense');
      final existingIncome = await repo.getTopLevelCategories('income');
      final existingCategoryMap = <String, int>{};

      for (final cat in [...existingExpense, ...existingIncome]) {
        existingCategoryMap['${cat.kind}|${cat.name}'] = cat.id;
        // 获取子分类
        final subCats = await repo.getSubCategories(cat.id);
        for (final sub in subCats) {
          existingCategoryMap['${sub.kind}|${sub.name}'] = sub.id;
        }
      }

      // 分离一级和二级分类
      final level1 = categories
          .where((c) => c.level == 1 || c.parentName == null)
          .toList();
      final level2 = categories
          .where((c) => c.level == 2 && c.parentName != null)
          .toList();

      // 导入一级分类
      for (final cat in level1) {
        final key = '${cat.kind}|${cat.name}';
        if (existingCategoryMap.containsKey(key)) {
          categoryCache[key] = existingCategoryMap[key]!;
        } else {
          final id = await repo.createCategory(
            name: cat.name,
            kind: cat.kind,
            icon: cat.icon,
            sortOrder: cat.sortOrder,
          );
          categoryCache[key] = id;
          created++;

          // 如果有自定义图标信息，更新图标
          if (cat.iconType != null && cat.iconType != 'material') {
            await repo.updateCategoryIcon(
              id,
              iconType: cat.iconType!,
              icon: cat.icon,
              customIconPath: cat.customIconPath,
              communityIconId: cat.communityIconId,
            );
          }
        }
      }

      // 导入二级分类
      for (final cat in level2) {
        final key = '${cat.kind}|${cat.name}';
        if (existingCategoryMap.containsKey(key)) {
          categoryCache[key] = existingCategoryMap[key]!;
        } else {
          // 查找父分类ID
          final parentKey = '${cat.kind}|${cat.parentName}';
          final parentId = categoryCache[parentKey];
          if (parentId != null) {
            final id = await repo.createSubCategory(
              parentId: parentId,
              name: cat.name,
              kind: cat.kind,
              icon: cat.icon,
              sortOrder: cat.sortOrder,
            );
            categoryCache[key] = id;

            // 如果有自定义图标信息，更新图标
            if (cat.iconType != null && cat.iconType != 'material') {
              await repo.updateCategoryIcon(
                id,
                iconType: cat.iconType!,
                icon: cat.icon,
                customIconPath: cat.customIconPath,
                communityIconId: cat.communityIconId,
              );
            }
          }
        }
      }
      logger.info('CategoryImport',
          '分类导入完成: 新增=$created 已存在=${categories.length - created} 耗时=${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      logger.error('CategoryImport', '分类导入失败', e, st);
    }

    return categoryCache;
  }

  /// 导入标签。public — sync_diff_service 复用。
  Future<Map<String, int>> importTags(
    BaseRepository repo,
    List<ImportTag> tags,
  ) async {
    final tagNameToId = <String, int>{};

    if (tags.isEmpty) return tagNameToId;

    logger.info('TagImport', '开始导入标签: ${tags.length} 个');
    final sw = Stopwatch()..start();
    int created = 0;
    int updated = 0;

    try {
      final existingTags = await repo.getAllTags();
      final existingTagMap = <String, Tag>{};
      for (final tag in existingTags) {
        tagNameToId[tag.name] = tag.id;
        existingTagMap[tag.name] = tag;
      }

      // 单条 await 循环 — 标签量通常小(<100),没批量接口暂保持,但去掉 per-row
      // INFO 日志:N 个标签会打 3N 条 INFO,把 logger 队列冲爆,导致后续 import
      // 阶段的日志被淹没,用户感知"日志不全"。
      for (final tag in tags) {
        if (!tagNameToId.containsKey(tag.name)) {
          final id = await repo.createTag(name: tag.name, color: tag.color);
          tagNameToId[tag.name] = id;
          created++;
        } else if (tag.color != null) {
          final existingTag = existingTagMap[tag.name];
          if (existingTag != null && existingTag.color != tag.color) {
            await repo.updateTag(existingTag.id, color: tag.color);
            updated++;
          }
        }
      }
      logger.info('TagImport',
          '标签导入完成: 新增=$created 更新=$updated 耗时=${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      logger.error('TagImport', '标签导入失败', e, st);
    }

    return tagNameToId;
  }

  /// 生成导入行的本地幂等键。externalId 优先；没有外部 ID 时使用
  /// provider + batchKey + row hash，避免重复导入同一文件，又不把来源键
  /// 塞进 transactions.syncId。
  static String importEventKey({
    required int ledgerId,
    required String provider,
    required ImportTransaction transaction,
    String? batchKey,
  }) {
    final external = transaction.externalId?.trim();
    if (external != null && external.isNotEmpty) {
      return 'import:v1:$ledgerId:${provider.trim().toLowerCase()}:external:${_keyHash(external)}';
    }
    final row = transaction.sourceRowHash?.trim().isNotEmpty == true
        ? transaction.sourceRowHash!.trim()
        : _keyHash(_canonicalRow(transaction));
    final batch =
        batchKey?.trim().isNotEmpty == true ? batchKey!.trim() : 'adhoc';
    return 'import:v1:$ledgerId:${provider.trim().toLowerCase()}:$batch:$row';
  }

  static bool isNonBookableStatus(String? status) {
    final raw = status?.trim().toLowerCase() ?? '';
    if (raw.isEmpty) return false;
    return [
      '待支付',
      '待付款',
      '处理中',
      '失败',
      '关闭',
      '取消',
      '未支付',
      '交易关闭',
      '支付失败',
      '付款失败',
      '订单关闭',
      '账单汇总',
      '本期账单',
      'pending',
      'processing',
      'failed',
      'cancelled',
      'canceled',
      'closed',
    ].any(raw.contains);
  }

  static bool isRefundStatus(String? status) {
    final raw = status?.trim().toLowerCase() ?? '';
    return raw.contains('退款') || raw.contains('退费') || raw.contains('refund');
  }

  static String _keyHash(String value) {
    // 不依赖 Flutter crypto，导入服务在云恢复/测试环境也能使用。
    var hash = 0xcbf29ce484222325;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }

  static String _canonicalRow(ImportTransaction tx) => [
        tx.type,
        tx.amount.toStringAsFixed(8),
        tx.happenedAt.toIso8601String(),
        tx.note ?? '',
        tx.accountName ?? '',
        tx.fromAccountName ?? '',
        tx.toAccountName ?? '',
        tx.currencyCode ?? '',
        tx.status ?? '',
        tx.refundAmount?.toStringAsFixed(8) ?? '',
      ].join('|');

  /// 导入交易(统一 batch 路径,tag/attachment 跟 tx 一起 batch insert)
  ///
  /// **历史**:之前"有标签/附件"的 tx 走单条 await 路径,
  ///   `insertTransactionCompanion` → `updateTransactionTags` → `createAttachment`
  /// 各开自己的 BEGIN/COMMIT,N+1 + 嵌套事务双重放大,1 万条带标签数据要几十
  /// 分钟。
  ///
  /// **现在**:全部走 `insertTransactionsBatchWithRelations`,500 条 / 批,
  /// 一个 db.transaction 内 batch insert tx + tag + attachment + local_changes,
  /// 把 N 次 BEGIN/COMMIT/fsync 折叠成 1 次。
  ///
  /// public — sync_diff_service 复用。
  Future<ImportResult> importTransactions(
    BaseRepository repo,
    int ledgerId,
    List<ImportTransaction> transactions, {
    required Map<String, int> accountNameToId,
    required Map<String, int> categoryCache,
    required Map<String, int> tagNameToId,
    void Function(int done, int total)? onProgress,
    bool recordChanges = true,
    AutoBookEventStore? eventStore,
    String provider = 'import',
    String? batchKey,
  }) async {
    int inserted = 0;
    int duplicated = 0;
    int ignored = 0;
    int invalid = 0;
    int failed = 0;
    int processed = 0;
    final total = transactions.length;
    logger.info('TxImport', '开始导入交易: $total 条 (recordChanges=$recordChanges)');

    // v30 交易级多币种(02 §六导入修补):批量预取本位币/账户币种/有效汇率,
    // 逐条填 currencyCode + nativeAmount,不再落 NULL(NULL 行 L11 检测
    // 需 join 兜底,且外币账户导入折算会静默 1:1)。
    final ledger = await repo.getLedgerById(ledgerId);
    final ledgerBase =
        ((ledger?.currency.isNotEmpty ?? false) ? ledger!.currency : 'CNY')
            .toUpperCase();
    final accountCurrencyById = <int, String>{
      for (final a in await repo.getAllAccounts())
        a.id: (a.currency.isNotEmpty ? a.currency : ledgerBase).toUpperCase(),
    };
    Map<String, EffectiveRate> importRates = const {};
    try {
      final autos = await repo.getLatestAutoRates(ledgerBase);
      final overrides = await repo.getOverrides(ledgerBase);
      importRates = mergeEffectiveRates(
        autoRates: [
          for (final r in autos)
            (quote: r.quoteCurrency, rate: r.rate, rateDate: r.rateDate)
        ],
        overrides: [
          for (final o in overrides) (quote: o.quoteCurrency, rate: o.rate)
        ],
      );
    } catch (e) {
      logger.warning('TxImport', '导入取汇率失败,外币交易将按 1:1 待 L11 捞回: $e');
    }
    final overallSw = Stopwatch()..start();

    const batchSize = 500;
    // 批次缓冲:tx 列表 + 按 batch 内 index 索引的关联数据
    final batchTx = <TransactionsCompanion>[];
    final batchTagsByIndex = <int, List<int>>{};
    final batchAttachmentsByIndex = <int, List<BatchAttachmentData>>{};
    final batchEventRefs = <_ImportEventRef?>[];
    final seenEventKeys = <String>{};

    final localCategoryCache = Map<String, int>.from(categoryCache);

    Future<void> finishEvent(
      _ImportEventRef? ref, {
      required AutoBookState state,
      int? transactionId,
      String? reason,
    }) async {
      if (ref?.eventId == null || eventStore == null) return;
      try {
        await eventStore.mark(
          AutoBookEventUpdate(
            state: state,
            transactionId: transactionId,
            reason: reason,
            billJson: ref!.transaction.externalId == null
                ? null
                : jsonEncode({'external_id': ref.transaction.externalId}),
          ),
          eventId: ref.eventId!,
        );
      } catch (e, st) {
        logger.warning('TxImport', '更新导入事件状态失败(不影响批次)', '$e');
        logger.debug('TxImport', '导入事件状态堆栈', st);
      }
    }

    Future<void> finishEventItem(
      _ImportEventRef ref, {
      required int itemIndex,
      required AutoBookState state,
      int? transactionId,
      String? reason,
    }) async {
      if (eventStore == null || ref.eventId == null) return;
      final tx = ref.transaction;
      final amount = tx.refundAmount != null && tx.refundAmount!.abs() > 0
          ? tx.refundAmount!.abs()
          : tx.amount.abs();
      try {
        await eventStore.upsertItem(
          eventId: ref.eventId!,
          itemIndex: itemIndex,
          eventKind: isRefundStatus(tx.status) ? 'refund' : tx.type,
          settlementStatus: tx.status,
          amount: amount,
          currency: tx.currencyCode,
          merchant: tx.note,
          transactionId: transactionId,
          state: state.value,
          bill: {
            if (tx.externalId != null) 'external_id': tx.externalId,
            if (tx.provider != null) 'provider': tx.provider,
            if (tx.status != null) 'status': tx.status,
          },
          reason: reason,
        );
      } catch (e, st) {
        logger.warning('TxImport', '写入导入事件子项失败(不影响交易)', '$e');
        logger.debug('TxImport', '导入事件子项堆栈', st);
      }
    }

    // 把当前缓冲 flush 到 repo。捕获异常时整批算 failed,继续下一批。
    Future<void> flush() async {
      if (batchTx.isEmpty) return;
      final size = batchTx.length;
      final batchSw = Stopwatch()..start();
      try {
        final ids = await repo.insertTransactionsBatchWithRelations(
          transactions: List.of(batchTx),
          tagIdsByIndex: Map.of(batchTagsByIndex),
          attachmentsByIndex: Map.of(batchAttachmentsByIndex),
          recordChanges: recordChanges,
        );
        inserted += ids.length;
        if (ids.length < size) failed += size - ids.length;
        for (var i = 0; i < batchEventRefs.length; i++) {
          final ref = batchEventRefs[i];
          if (ref == null) continue;
          if (i < ids.length) {
            await finishEventItem(
              ref,
              itemIndex: i,
              state: AutoBookState.booked,
              transactionId: ids[i],
            );
            await finishEvent(
              ref,
              state: AutoBookState.booked,
              transactionId: ids[i],
            );
          } else {
            await finishEventItem(
              ref,
              itemIndex: i,
              state: AutoBookState.retry,
              reason: 'batch_result_short',
            );
            await finishEvent(
              ref,
              state: AutoBookState.retry,
              reason: 'batch_result_short',
            );
          }
        }
        logger.info('TxImport',
            'flush 批次: size=$size 耗时=${batchSw.elapsedMilliseconds}ms 累计=${processed + size}/$total');
      } catch (e, st) {
        logger.error('TxImport', '批次 flush 失败,本批 $size 条算 failed', e, st);
        failed += size;
        for (var i = 0; i < batchEventRefs.length; i++) {
          final ref = batchEventRefs[i];
          if (ref == null) continue;
          await finishEventItem(
            ref,
            itemIndex: i,
            state: AutoBookState.retry,
            reason: 'batch_exception',
          );
          await finishEvent(
            ref,
            state: AutoBookState.retry,
            reason: 'batch_exception',
          );
        }
      }
      processed += size;
      batchTx.clear();
      batchTagsByIndex.clear();
      batchAttachmentsByIndex.clear();
      batchEventRefs.clear();
      if (onProgress != null) onProgress(processed, total);
    }

    for (final tx in transactions) {
      _ImportEventRef? eventRef;
      final amount = tx.refundAmount != null && tx.refundAmount!.abs() > 0
          ? tx.refundAmount!.abs()
          : tx.amount.abs();
      final effectiveType =
          isRefundStatus(tx.status) || (tx.refundAmount?.abs() ?? 0) > 0
              ? 'income'
              : tx.type;
      final validDate = tx.happenedAt.year > 1970 &&
          tx.happenedAt.year <= DateTime.now().year + 1;
      if (!tx.amount.isFinite ||
          !amount.isFinite ||
          amount <= 0 ||
          !validDate ||
          !const {'income', 'expense', 'transfer'}.contains(effectiveType)) {
        invalid++;
        processed++;
        onProgress?.call(processed, total);
        continue;
      }
      if (isNonBookableStatus(tx.status)) {
        ignored++;
        processed++;
        onProgress?.call(processed, total);
        continue;
      }

      // 导入事件先 claim 再进入批次，重放时不会再次构造交易。
      final eventKey = importEventKey(
        ledgerId: ledgerId,
        provider: tx.provider ?? provider,
        transaction: tx,
        batchKey: batchKey,
      );
      if (!seenEventKeys.add(eventKey)) {
        duplicated++;
        processed++;
        onProgress?.call(processed, total);
        continue;
      }
      if (eventStore != null) {
        try {
          final claim = await eventStore.claim(
            AutoBookInput(
              eventKey: eventKey,
              source: AutoBookSource.import,
              captureIntent: AutoBookCaptureIntent.importData,
              ledgerId: ledgerId,
              capturedAt: DateTime.now(),
              sourceOccurredAt: tx.happenedAt,
              sourceChannel: tx.provider ?? provider,
              externalId: tx.externalId,
              contentHash: tx.sourceRowHash,
            ),
          );
          if (!claim.acquired) {
            final state = AutoBookStateValue.parse(claim.event.state);
            if (state == AutoBookState.ignored ||
                state == AutoBookState.expired) {
              ignored++;
            } else if (state == AutoBookState.retry ||
                state == AutoBookState.processing) {
              failed++;
            } else {
              duplicated++;
            }
            processed++;
            onProgress?.call(processed, total);
            continue;
          }
          eventRef = _ImportEventRef(
            eventId: claim.event.id,
            transaction: tx,
          );

          // 批量导入也可能在交易已写入、父事件尚未更新时被中断。
          // 先恢复该行已有的终态子项，避免 retry 再插入一笔；同时修复
          // 单行父事件状态，保证下一次导入能直接识别为 duplicate。
          try {
            final priorItems = await eventStore.itemsForEvent(claim.event.id);
            AutoBookEventItem? prior;
            for (final item in priorItems) {
              if (item.itemIndex == 0) {
                prior = item;
                break;
              }
            }
            if (prior != null) {
              final priorState = AutoBookStateValue.parse(prior.state);
              final priorTxId = prior.transactionId;
              if ((priorState == AutoBookState.booked ||
                      priorState == AutoBookState.duplicate) &&
                  priorTxId != null) {
                duplicated++;
                await finishEvent(
                  eventRef,
                  state: priorState,
                  transactionId:
                      priorState == AutoBookState.booked ? priorTxId : null,
                  reason: priorState == AutoBookState.duplicate
                      ? 'recovered_duplicate'
                      : 'recovered_booked',
                );
                processed++;
                onProgress?.call(processed, total);
                continue;
              }
              if (priorState == AutoBookState.ignored) {
                ignored++;
                await finishEvent(
                  eventRef,
                  state: AutoBookState.ignored,
                  reason: 'recovered_ignored',
                );
                processed++;
                onProgress?.call(processed, total);
                continue;
              }
            }
          } catch (e, st) {
            // 事件子项不可读时宁可保守重试，也不冒险创建无法追踪的重复交易。
            failed++;
            await finishEvent(
              eventRef,
              state: AutoBookState.retry,
              reason: 'event_item_read_failed',
            );
            logger.error('TxImport', '读取导入事件子项失败,跳过该行', e, st);
            processed++;
            onProgress?.call(processed, total);
            continue;
          }
        } catch (e, st) {
          // 幂等状态不可用时宁可不导入，也不冒险生成无法追踪的重复交易。
          failed++;
          processed++;
          logger.error('TxImport', '创建导入事件失败,跳过该行', e, st);
          onProgress?.call(processed, total);
          continue;
        }
      }

      // 解析分类ID
      int? categoryId;
      if (tx.categoryId != null) {
        categoryId = tx.categoryId;
      } else if (tx.categoryName != null && tx.categoryKind != null) {
        final key = '${tx.categoryKind}|${tx.categoryName}';
        categoryId = localCategoryCache[key];
        if (categoryId == null && effectiveType != 'transfer') {
          try {
            categoryId = await repo.upsertCategory(
              name: tx.categoryName!,
              kind: tx.categoryKind!,
            );
            localCategoryCache[key] = categoryId;
          } catch (_) {}
        }
      }

      // 解析账户ID
      int? accountId;
      int? toAccountId;
      if (effectiveType == 'transfer') {
        if (tx.fromAccountName != null) {
          accountId = accountNameToId[tx.fromAccountName];
          if (accountId == null) {
            failed++;
            await finishEvent(
              eventRef,
              state: AutoBookState.retry,
              reason: 'missing_from_account',
            );
            processed++;
            onProgress?.call(processed, total);
            continue;
          }
        }
        if (tx.toAccountName != null) {
          toAccountId = accountNameToId[tx.toAccountName];
          if (toAccountId == null) {
            failed++;
            await finishEvent(
              eventRef,
              state: AutoBookState.retry,
              reason: 'missing_to_account',
            );
            processed++;
            onProgress?.call(processed, total);
            continue;
          }
        }
      } else {
        if (tx.accountName != null) {
          accountId = accountNameToId[tx.accountName];
        }
      }

      // 解析标签ID — toSet().toList() 去重,因为底层 batch insert 不查重
      final tagIds = <int>[];
      if (tx.tagNames != null) {
        for (final tagName in tx.tagNames!) {
          var tagId = tagNameToId[tagName];
          if (tagId == null) {
            try {
              final existingTag = await repo.getTagByName(tagName);
              if (existingTag != null) {
                tagId = existingTag.id;
              } else {
                tagId = await repo.createTag(name: tagName);
              }
              tagNameToId[tagName] = tagId;
            } catch (_) {}
          }
          if (tagId != null) {
            tagIds.add(tagId);
          }
        }
      }
      final uniqueTagIds = tagIds.toSet().toList();

      // v30:交易币种 = CSV 币种列(显式,反馈10)?? 账户币种 ?? 本位币;
      // 折算快照同币种 = amount,外币按有效汇率,取不到 = amount(L11 可捞回)。
      final txCurrency =
          ((tx.currencyCode?.isNotEmpty ?? false) ? tx.currencyCode! : null) ??
              (accountId != null ? accountCurrencyById[accountId] : null) ??
              ledgerBase;
      final txNative = txCurrency == ledgerBase
          ? amount
          : (computeNativeAmount(
                  amount: amount,
                  accountCurrency: txCurrency,
                  ledgerBase: ledgerBase,
                  rates: importRates) ??
              amount);

      // 构建交易记录
      final txCompanion = TransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: effectiveType,
        amount: amount,
        categoryId: d.Value(effectiveType == 'transfer' ? null : categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        happenedAt: d.Value(tx.happenedAt),
        note: d.Value(tx.note),
        syncId: d.Value(tx.syncId),
        currencyCode: d.Value(txCurrency),
        nativeAmount: d.Value(txNative),
      );

      final indexInBatch = batchTx.length;
      batchTx.add(txCompanion);
      batchEventRefs.add(eventRef);
      if (uniqueTagIds.isNotEmpty) {
        batchTagsByIndex[indexInBatch] = uniqueTagIds;
      }
      if (tx.attachments != null && tx.attachments!.isNotEmpty) {
        batchAttachmentsByIndex[indexInBatch] = tx.attachments!
            .map((a) => BatchAttachmentData(
                  fileName: a.fileName,
                  originalName: a.originalName,
                  fileSize: a.fileSize,
                  width: a.width,
                  height: a.height,
                  sortOrder: a.sortOrder,
                  cloudFileId: a.cloudFileId,
                  cloudSha256: a.cloudSha256,
                ))
            .toList();
      }

      if (batchTx.length >= batchSize) {
        await flush();
      }
    }

    // 刷剩余
    await flush();

    logger.info('TxImport',
        '交易导入完成: 总数=$total 成功=$inserted 失败=$failed 重复=$duplicated 忽略=$ignored 无效=$invalid 总耗时=${overallSw.elapsedMilliseconds}ms');
    return ImportResult(
      inserted: inserted,
      failed: failed,
      duplicated: duplicated,
      ignored: ignored,
      invalid: invalid,
    );
  }
}

class _ImportEventRef {
  final int? eventId;
  final ImportTransaction transaction;

  const _ImportEventRef({required this.eventId, required this.transaction});
}

/// 全局单例
final dataImportService = DataImportService();
