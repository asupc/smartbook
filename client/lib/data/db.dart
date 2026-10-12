import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../l10n/app_localizations.dart';
import '../services/data/category_service.dart';
import '../services/data/seed_service.dart';
import '../services/system/logger_service.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'db.g.dart';

// --- Tables ---

class Ledgers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  TextColumn get type =>
      text().withDefault(const Constant('personal'))(); // personal / shared
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // 跨设备同步唯一标识：跟 accounts/categories/tags 的 syncId 同语义，
  // 对齐 SmartBook Cloud server 的 ledger.external_id。device B 首次登录
  // 通过 readLedgers() 拉到的 ext_id 会写到这里，后续 push/pull 都用这个
  // 做设备间的 ledger 匹配，而不是本地 autoIncrement id（A/B 本地 id 必然
  // 不一致）。v21 migration 里已为旧数据把 id 回填成 syncId 以兼容。
  TextColumn get syncId => text().nullable()();
  // v24: 共享账本字段 — server 端 LedgerMember.role 同步下来
  TextColumn get myRole =>
      text().withDefault(const Constant('owner'))(); // owner / editor
  IntColumn get memberCount => integer().withDefault(const Constant(1))();
  BoolColumn get isShared => boolean().withDefault(const Constant(false))();
  TextColumn get ownerUserId => text().nullable()(); // 当前 Owner 是谁
  // v27: 自定义每月起始日(1-28),统计/预算/小部件按 [当月N日, 次月N日) 聚合,
  // 1=自然月。随 sync 跨设备(payload key `monthStartDay`,server 列
  // ledgers.month_start_day)。见 .docs/period-start-date/design.md。
  IntColumn get monthStartDay => integer().withDefault(const Constant(1))();
}

class Accounts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ledgerId => integer()(); // 保留用于v2迁移，后续会移除
  TextColumn get name => text()();
  TextColumn get type => text().withDefault(const Constant('cash'))();
  TextColumn get currency =>
      text().withDefault(const Constant('CNY'))(); // v1.15.0新增：币种
  RealColumn get initialBalance => real().withDefault(const Constant(0.0))();
  DateTimeColumn get createdAt =>
      dateTime().nullable()(); // v1.15.0: 改为可空，避免迁移问题
  DateTimeColumn get updatedAt => dateTime().nullable()();
  IntColumn get sortOrder =>
      integer().withDefault(const Constant(0))(); // 排序顺序，数字越小越靠前
  RealColumn get creditLimit => real().nullable()(); // 信用额度
  IntColumn get billingDay => integer().nullable()(); // 账单日 (1-28)
  IntColumn get paymentDueDay => integer().nullable()(); // 还款日 (1-28)
  TextColumn get bankName => text().nullable()(); // 开户行
  TextColumn get cardLastFour => text().nullable()(); // 卡号后四位
  TextColumn get note => text().nullable()(); // 备注
  TextColumn get syncId => text().nullable()(); // 跨设备同步唯一标识 (UUID)
  /// 隐藏:true 时该账户不再出现在记账/转账/周期选择器,账户管理页移入「已隐藏」分区。
  /// 仍计入账户余额、净资产、资产构成、净值趋势(.docs/account-archive/01 §二 D1)。
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();
}

/// 自动汇率本地缓存。日期键 append-only;可随时整表重建 → **不进同步**(README D2)。
/// 方向:1 quote = rate base(rate 为 decimal 字符串)。
class ExchangeRates extends Table {
  TextColumn get baseCurrency => text()();
  TextColumn get quoteCurrency => text()();
  TextColumn get rateDate => text()(); // 'YYYY-MM-DD',取源数据自带日期
  TextColumn get rate => text()();
  TextColumn get source => text()(); // 'server'|'fawazahmed0'|'frankfurter'
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {baseCurrency, quoteCurrency, rateDate};
}

/// 手动汇率覆盖:固定生效直到删除(README D9)。user-global 同步实体,
/// 字段约定对齐 Accounts(syncId UUID)。方向同 ExchangeRates:1 quote = rate base。
/// 业务唯一键 (baseCurrency, quoteCurrency),唯一索引在 v28 迁移建。
class ExchangeRateOverrides extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text().nullable()();
  TextColumn get baseCurrency => text()();
  TextColumn get quoteCurrency => text()();
  TextColumn get rate => text()();
  DateTimeColumn get updatedAt => dateTime().nullable()();
}

class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get kind => text()(); // expense / income
  TextColumn get icon => text().nullable()();
  IntColumn get sortOrder =>
      integer().withDefault(const Constant(0))(); // 排序顺序，数字越小越靠前
  IntColumn get parentId => integer().nullable()(); // 父分类ID，null 表示一级分类
  IntColumn get level =>
      integer().withDefault(const Constant(1))(); // 层级：1=一级，2=二级
  // v13: 自定义图标支持
  TextColumn get iconType => text().withDefault(
      const Constant('material'))(); // material / custom / community
  TextColumn get customIconPath => text().nullable()(); // 自定义图标本地路径
  TextColumn get communityIconId => text().nullable()(); // 社区图标ID（预留）
  TextColumn get syncId => text().nullable()(); // 跨设备同步唯一标识 (UUID)
}

class Transactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ledgerId => integer()();
  TextColumn get type => text()(); // expense / income / transfer
  RealColumn get amount => real()();
  IntColumn get categoryId => integer().nullable()();
  IntColumn get accountId => integer().nullable()();
  IntColumn get toAccountId => integer().nullable()();
  DateTimeColumn get happenedAt => dateTime().withDefault(currentDateAndTime)();
  // v40 记录时间:server 首次落库时刻(pull payload.createdAt),本地新建为
  // 写入时刻。存量行为 NULL,重复对比/详情里显示 "-"。本地不参与同步 push
  // (EntitySerializer 不序列化),以 server 为准。
  DateTimeColumn get recordedAt => dateTime().nullable()();
  TextColumn get note => text().nullable()();
  IntColumn get recurringId => integer().nullable()(); // 关联到重复交易模板
  TextColumn get syncId => text().nullable()(); // 跨设备同步唯一标识 (UUID)
  // v24: 共享账本"谁记的"显示
  TextColumn get createdByUserId => text().nullable()();
  TextColumn get lastEditedByUserId => text().nullable()();
  // v25: 共享账本 sync_id override(§7 决策)
  // Editor 在共享账本下记 tx 时,选 Owner 的 SharedLedger{Categories,Accounts,Tags}
  // 行,但本地 Categories/Accounts/Tags 主表没有对应 int id。这些 override
  // 字段直接存 Owner 的 syncId 字符串,categoryId / accountId 留 null;sync push
  // 时序列化优先用 override(server LWW key 是 syncId,主表 syncId 也是 string)。
  // Owner / 单人账本场景:override 字段为 null,走老路径(categoryId int 反查
  // Categories.syncId)。
  TextColumn get categorySyncIdOverride => text().nullable()();
  TextColumn get accountSyncIdOverride => text().nullable()();
  TextColumn get toAccountSyncIdOverride => text().nullable()();
  TextColumn get tagSyncIdsOverride => text().nullable()(); // JSON list

  /// 不计入收支:true 时从收支统计/图表/月年汇总剔除,但仍计入账户余额、净资产、
  /// 账单列表(.docs/transaction-flags/01 §二 D1)。
  BoolColumn get excludeFromStats =>
      boolean().withDefault(const Constant(false))();

  /// 不计入预算:true 时从预算用量剔除。与 excludeFromStats 完全独立(D2)。
  BoolColumn get excludeFromBudget =>
      boolean().withDefault(const Constant(false))();

  /// v30 交易级多币种(.docs/multi-currency-ledger):交易币种(ISO 大写)。
  /// 有账户 → 恒等于账户 currency(账户内不混币);无账户 → 用户所选(L12,
  /// 默认账本本位币)。显式存让交易自包含(同步/统计不必每次 join 账户)。
  TextColumn get currencyCode => text().nullable()();

  /// v30:折算到账本本位币的金额快照(按记账时汇率,保存即定,不随汇率重算)。
  /// 单币种/未折算 == amount(隐含汇率 1.0)。账本维度统计读本列(?? amount),
  /// 账户维度(余额等)仍读 amount。
  RealColumn get nativeAmount => real().nullable()();
}

/// v43 回收站 tombstone:删除的交易整行搬到这里(payloadJson = Transactions
/// 行序列化),主表读路径零改动;恢复 = payload 写回主表(新 int id)。30 天后
/// 由 [LocalRepository.cleanupDeletedTransactions] 物理清理(连附件文件)。
/// 远端 delete change 应用时也走同一路径(本地与服务端回收站各自独立)。
class DeletedTransactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get syncId => text()(); // 冗余列:恢复时反查/去重
  IntColumn get ledgerId => integer()();
  RealColumn get amount => real()();
  TextColumn get txType => text()();
  DateTimeColumn get happenedAt => dateTime()();
  TextColumn get payloadJson => text()(); // 整行 Transactions 序列化
  DateTimeColumn get deletedAt => dateTime().withDefault(currentDateAndTime)();
}

class RecurringTransactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ledgerId => integer()();
  TextColumn get type => text()(); // expense / income / transfer
  RealColumn get amount => real()();
  IntColumn get categoryId => integer().nullable()(); // 转账时为null
  IntColumn get accountId => integer().nullable()();
  IntColumn get toAccountId => integer().nullable()(); // 转账的目标账户
  TextColumn get note => text().nullable()();

  /// v32 周期账单币种(issue #444):模板币种(ISO 大写)。
  /// NULL = 账本本位币(存量语义);挂了账户时生成仍以账户币种为准(账户内不混币)。
  /// 汇率不锁在模板上 —— 每次生成按当日有效汇率折算 nativeAmount。
  TextColumn get currencyCode => text().nullable()();

  // 重复规则
  TextColumn get frequency => text()(); // daily / weekly / monthly / yearly
  IntColumn get interval =>
      integer().withDefault(const Constant(1))(); // 间隔（每1天、每2周等）
  IntColumn get dayOfMonth => integer().nullable()(); // 月的第几天（1-31）
  IntColumn get dayOfWeek => integer().nullable()(); // 周几（1=周一, 7=周日）
  IntColumn get monthOfYear => integer().nullable()(); // 哪个月（1-12，用于yearly）

  // 时间范围
  DateTimeColumn get startDate => dateTime()();
  DateTimeColumn get endDate => dateTime().nullable()(); // 为空表示永久
  DateTimeColumn get lastGeneratedDate =>
      dateTime().nullable()(); // 最后一次生成交易的日期

  // 状态
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// AI 对话表
class Conversations extends Table {
  IntColumn get id => integer().autoIncrement()();
  @Deprecated('对话已改为全局，不再与账本关联')
  IntColumn get ledgerId => integer().nullable()();
  TextColumn get title => text().withDefault(const Constant('AI对话'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// AI 消息表
class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get conversationId => integer()();
  TextColumn get role => text()(); // 'user' | 'assistant'
  TextColumn get content => text()();
  TextColumn get messageType => text()(); // 'text' | 'bill_card'
  TextColumn get metadata => text().nullable()(); // JSON (BillInfo 数据)
  IntColumn get transactionId => integer().nullable()(); // 关联的交易ID(撤销用)
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// 标签表
class Tags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()(); // 标签名称
  TextColumn get color => text().nullable()(); // 颜色值（如 #FF5722）
  IntColumn get sortOrder => integer().withDefault(const Constant(0))(); // 排序
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get syncId => text().nullable()(); // 跨设备同步唯一标识 (UUID)
}

// 本地变更追踪表（用于增量同步）
class LocalChanges extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entityType => text()(); // transaction/account/category/tag
  IntColumn get entityId => integer()(); // 本地实体ID
  TextColumn get entitySyncId => text()(); // 实体的 syncId (UUID)
  IntColumn get ledgerId => integer()(); // 关联账本ID
  TextColumn get action => text()(); // create/update/delete
  TextColumn get payloadJson => text().nullable()(); // 变更后的完整 JSON
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get pushedAt => dateTime().nullable()(); // 非null表示已推送
}

// 同步状态表
class SyncState extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get deviceId => text()(); // 设备唯一标识
  TextColumn get providerType => text().withDefault(
      const Constant('smartbook_cloud'))(); // 防止不同 provider 的 cursor 冲突
  IntColumn get serverCursor =>
      integer().withDefault(const Constant(0))(); // 服务端变更游标
  DateTimeColumn get lastPushAt => dateTime().nullable()();
  DateTimeColumn get lastPullAt => dateTime().nullable()();
}

// 交易-标签关联表
class TransactionTags extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get transactionId => integer()(); // 交易ID
  IntColumn get tagId => integer()(); // 标签ID
}

// v27: 共享账本 §7 — 交易标签 sync_id override
// Editor 在共享账本下记 tx 选 Owner 的 tag,Tag 主表没该行(SharedLedgerTags
// 才有),传统 transaction_tags.tag_id 没法存 (本地 int id 不存在)。这张
// override 表按 (transaction_id, tag_sync_id) 存,sync push 时 union 进 tagIds
// payload;tx 反查 / 编辑回显时 union 主表 transaction_tags + 本表。
class TransactionTagOverrides extends Table {
  TextColumn get transactionSyncId => text()(); // tx.syncId(全局唯一)
  TextColumn get tagSyncId => text()(); // Owner tag syncId
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {transactionSyncId, tagSyncId};
}

// v26: sync pull 时 server 端下发的 change 在本地 apply 抛错的持久化记录。
// 健康用户这张表是空的;只在出错时写入,供 UI 暴露 + 用户重试/跳过 + 开发者
// 远程诊断。详见 .docs/full-pull-refactor/04-data-model.md。
class SyncPullErrors extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get changeId => integer().unique()(); // server change_id,唯一
  TextColumn get ledgerExternalId =>
      text().nullable()(); // user-global change 可空
  TextColumn get entityType => text()();
  TextColumn get entitySyncId => text()();
  TextColumn get action => text()(); // upsert / delete
  TextColumn get rawChangeJson => text()(); // 完整 change JSON,供诊断 + 复制给用户
  TextColumn get errorClass => text().nullable()(); // Dart exception 类名
  TextColumn get errorMessage => text().nullable()(); // exception.toString() 首行
  TextColumn get stackTrace => text().nullable()(); // 截断到 ~2KB
  DateTimeColumn get firstSeenAt => dateTime()();
  DateTimeColumn get lastAttemptAt => dateTime()();
  IntColumn get attemptCount => integer().withDefault(const Constant(1))();
  TextColumn get userAction =>
      text().nullable()(); // null / 'skip' / 'retry_requested'
  DateTimeColumn get resolvedAt => dateTime().nullable()();
}

/// 自动记账入口事件的本地幂等/恢复表。
///
/// 这张表是客户端本地状态，不参与 SmartBook Cloud 同步。短信、通知、
/// 无障碍页面和截图都可能是同一笔交易的不同证据，不能把来源指纹写进
/// transactions.sync_id（sync_id 是云同步实体身份）；事件表只记录来源事件
/// 的生命周期和最终关联到的交易。
class AutoBookEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get eventKey => text().unique()();
  TextColumn get source =>
      text()(); // sms / notification / screen / image / deeplink ...
  TextColumn get captureIntent =>
      text().withDefault(const Constant('automatic'))();
  IntColumn get ledgerId => integer().nullable()();

  /// B2:捕获时冻结的自动目标快照。识别入账、确认与失败重放都用同一份,
  /// 后续改设置/切浏览账本不改已捕获事件的目标(B0 §3.3)。
  /// target_ref = `syncId:<v>` / `localId:<v>`;为空 = 尚未冻结。
  TextColumn get targetRef => text().nullable()();
  IntColumn get targetConfigVersion => integer().nullable()();
  TextColumn get targetState =>
      text().withDefault(const Constant('resolved'))();

  TextColumn get sourceChannel => text().nullable()();
  TextColumn get externalId => text().nullable()();
  TextColumn get contentHash => text().nullable()();
  TextColumn get state => text().withDefault(const Constant('captured'))();
  DateTimeColumn get capturedAt => dateTime()();
  DateTimeColumn get sourceOccurredAt => dateTime().nullable()();
  DateTimeColumn get expiresAt => dateTime().nullable()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextRetryAt => dateTime().nullable()();
  IntColumn get transactionId => integer().nullable()();
  IntColumn get duplicateOfTransactionId => integer().nullable()();
  TextColumn get billJson => text().nullable()();
  TextColumn get reason => text().nullable()();
  TextColumn get lastError => text().nullable()();

  /// 原始记账证据(短信/通知/详情页文本等)。是否写入由
  /// RawEvidencePolicyStore 控制；这些字段永不进入 transactions/sync_changes。
  TextColumn get rawTitle => text().nullable()();
  TextColumn get rawText => text().nullable()();
  TextColumn get rawActor => text().nullable()();
  TextColumn get rawMetadataJson => text().nullable()();

  /// Capture-time policy snapshot. It keeps a later preference change from
  /// unexpectedly deleting or uploading an already captured evidence item.
  BoolColumn get rawEvidenceLocalEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get rawEvidenceServerEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Separate windows let local cleanup and server retention evolve independently.
  /// [rawEvidenceRetentionUntil] is a compatibility/queue window (the later
  /// of the two) and is not a sync_changes field.
  DateTimeColumn get rawEvidenceLocalExpiresAt => dateTime().nullable()();
  DateTimeColumn get rawEvidenceServerExpiresAt => dateTime().nullable()();
  DateTimeColumn get rawEvidenceRetentionUntil => dateTime().nullable()();
  TextColumn get rawEvidenceUploadState =>
      text().withDefault(const Constant('not_requested'))();
  DateTimeColumn get rawEvidenceUploadedAt => dateTime().nullable()();
  IntColumn get rawEvidenceUploadAttempts =>
      integer().withDefault(const Constant(0))();
  TextColumn get rawEvidenceLastError => text().nullable()();
  DateTimeColumn get rawEvidenceNextRetryAt => dateTime().nullable()();

  /// 离线识别草稿(自动记账连不上服务端时保存的待重试输入)。
  ///
  /// 与 raw* 证据列相互独立:草稿是**待处理的临时输入**,识别成功/事件到终态
  /// 后立即清除,不参与隐私面板的证据统计,也永不进入 evidence 上传通道。
  /// JSON 结构见 AutoBookDraftPayload。
  TextColumn get draftPayloadJson => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// 一个自动入口事件解析出的账单子项。
///
/// 通过 (event_id, item_index) 做幂等，支持一张截图/一条文本包含多笔账单时
/// 部分成功后恢复，避免重试时重复创建已经落库的前几笔。
class AutoBookEventItems extends Table {
  IntColumn get eventId => integer()();
  IntColumn get itemIndex => integer()();
  TextColumn get semanticKey => text().nullable()();
  TextColumn get eventKind => text().nullable()();
  TextColumn get settlementStatus => text().nullable()();
  RealColumn get amount => real().nullable()();
  TextColumn get currency => text().nullable()();
  TextColumn get merchant => text().nullable()();
  IntColumn get transactionId => integer().nullable()();
  TextColumn get state => text().withDefault(const Constant('extracted'))();
  TextColumn get billJson => text().nullable()();
  TextColumn get reason => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {eventId, itemIndex};
}

// 交易附件表
class TransactionAttachments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get transactionId => integer()(); // 关联的交易ID
  TextColumn get fileName => text()(); // 文件名（不含路径）
  TextColumn get originalName => text().nullable()(); // 原始文件名
  IntColumn get fileSize => integer().nullable()(); // 文件大小（bytes）
  IntColumn get width => integer().nullable()(); // 图片宽度
  IntColumn get height => integer().nullable()(); // 图片高度
  IntColumn get sortOrder => integer().withDefault(const Constant(0))(); // 排序序号
  TextColumn get cloudFileId => text().nullable()(); // 云端文件ID
  TextColumn get cloudSha256 => text().nullable()(); // 云端文件SHA256
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// 预算表
class Budgets extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 跨设备同步 syncId(UUID)。v22 新增,migration 给老行补 UUID;之后每次 create
  /// 都必须填。server 端按此做 entity_sync_id,跨设备 LWW 合并。
  TextColumn get syncId => text().nullable()();

  /// 关联账本ID
  IntColumn get ledgerId => integer()();

  /// 预算类型：total-总预算, category-分类预算
  TextColumn get type => text().withDefault(const Constant('total'))();

  /// 关联分类ID（仅分类预算有值）
  IntColumn get categoryId => integer().nullable()();

  /// 预算金额
  RealColumn get amount => real()();

  /// 预算周期：monthly-月度, weekly-周度, yearly-年度
  TextColumn get period => text().withDefault(const Constant('monthly'))();

  /// 周期起始日（1-31，月度预算；1-7，周度预算）
  IntColumn get startDay => integer().withDefault(const Constant(1))();

  /// 是否启用
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// 创建时间
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 更新时间
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// 余额调整记录(v42,0028 对齐)。「调整余额」不再落一笔 exclude_from_stats
/// 交易,而是独立 ledger-scope 同步实体:**不进任何收支统计/预算/分类排行**,
/// 只参与账户余额与净资产口径(初始值 + Σ交易 + Σ调整)。
/// amount 带符号(正=调增,负=调减);balanceBefore/After 为审计快照。
class AccountAdjustments extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 跨设备同步 syncId(UUID),server 端 entity_sync_id。
  TextColumn get syncId => text().nullable()();

  /// 关联账本ID
  IntColumn get ledgerId => integer()();

  /// 目标账户(本地 int id;共享账本 Editor 场景用 accountSyncIdOverride)
  IntColumn get accountId => integer()();
  TextColumn get accountSyncIdOverride => text().nullable()();

  /// 带符号差额:正=调增,负=调减
  RealColumn get amount => real()();

  /// 调整前余额快照(审计展示用,统计不读)
  RealColumn get balanceBefore => real().nullable()();

  /// 调整后余额快照
  RealColumn get balanceAfter => real().nullable()();

  DateTimeColumn get happenedAt => dateTime().withDefault(currentDateAndTime)();

  /// 记录时间(server 首次落库盖章,pull payload.createdAt);本地新建为写入时刻
  DateTimeColumn get recordedAt => dateTime().nullable()();

  TextColumn get note => text().nullable()();

  /// 共享账本「谁调的」
  TextColumn get createdByUserId => text().nullable()();
  TextColumn get lastEditedByUserId => text().nullable()();

  /// 创建时间
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 更新时间
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// ============================================================================
// 共享账本(v24)
// ============================================================================

/// 账本成员镜像表。server `LedgerMember` 表的本地副本,用于"X 记的"显示 +
/// 离线渲染。`GET /api/v1/ledgers/{id}/members` 拉来后写入;`member_change`
/// WS 事件触发增量更新。
class LedgerMembers extends Table {
  TextColumn get ledgerSyncId => text()(); // ledger.syncId(全 user 唯一)
  TextColumn get userId => text()();
  TextColumn get email => text().nullable()();
  TextColumn get displayName => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get role => text()(); // owner / editor
  DateTimeColumn get joinedAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()(); // 本地更新时间,用于 cache 失效

  @override
  Set<Column> get primaryKey => {ledgerSyncId, userId};
}

/// 共享账本里 Owner 的 user-global 分类镜像。Editor 在共享账本下打开"选分类"
/// 弹窗读这表(而非自己的 Categories)。`GET /api/v1/ledgers/{id}/shared-resources`
/// 拉来落库;`shared_resource_change` WS 事件增量更新。
class SharedLedgerCategories extends Table {
  TextColumn get ledgerSyncId => text()();
  TextColumn get syncId => text()(); // Owner 的 user-global category sync_id
  TextColumn get name => text()();
  TextColumn get kind => text()(); // expense / income
  TextColumn get icon => text().nullable()();
  TextColumn get iconType => text().withDefault(const Constant('material'))();
  TextColumn get iconCloudFileId =>
      text().nullable()(); // 自定义图标:attachment UUID
  TextColumn get iconCloudSha256 =>
      text().nullable()(); // 自定义图标:sha256(本地 cache 去重)
  TextColumn get color => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get level => integer().withDefault(const Constant(1))();
  TextColumn get parentName => text().nullable()();
  // v25 共享账本二级分类:parent 的 syncId,用于 picker 建稳定父子链
  // (parent_name 兜底/显示,parent_sync_id 主)。
  TextColumn get parentSyncId => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {ledgerSyncId, syncId};
}

/// 共享账本里 Owner 的 user-global 账户镜像。
class SharedLedgerAccounts extends Table {
  TextColumn get ledgerSyncId => text()();
  TextColumn get syncId => text()();
  TextColumn get name => text()();
  TextColumn get accountType => text().withDefault(const Constant('cash'))();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  TextColumn get note => text().nullable()();
  RealColumn get initialBalance => real().nullable()();
  RealColumn get creditLimit => real().nullable()();
  IntColumn get billingDay => integer().nullable()();
  IntColumn get paymentDueDay => integer().nullable()();
  TextColumn get bankName => text().nullable()();
  TextColumn get cardLastFour => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {ledgerSyncId, syncId};
}

/// 共享账本里 Owner 的 user-global 标签镜像。
class SharedLedgerTags extends Table {
  TextColumn get ledgerSyncId => text()();
  TextColumn get syncId => text()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {ledgerSyncId, syncId};
}

/// 一条重复 (ledger_id, syncId) 组的 v45 去重计划。
///
/// 生成于任何 DML 之前(见 [BeeDatabase._v45BuildMergePlans]),写进
/// `pre-v45-<ts>.json` 快照的 `dedupePlans`,再驱动执行(见
/// [BeeDatabase._v45DeduplicateTransactionSyncIds])—— 去重不可逆,没有这份
/// 记录就只能靠猜。
///
/// 字段语义:
///  - [keeperId]:保留的行(合并目标);[loserIds] 是被删除的副本。
///  - [keeperCompleteness]:keeper 在可空业务列上的非 NULL 计数(选择依据)。
///  - [mergedValues]:从 loser 填进 keeper 的 **NULL** 列(列名 → 值)。
///  - [discardedByLoser]:随 loser 行删除而丢失、未被采信的列值
///    (loserId → {列名 → 值})。
///  - [refusedByInvariant]:**因结构不变量被拒绝**的候选填充
///    (`{loserId, column, value, rule}` 列表)。与 [discardedByLoser] 分开
///    记录:这些值不是「keeper 已有同列值所以不用」,而是「填进去会造出
///    自相矛盾的行」—— 见 [BeeDatabase._v45MergeableTransactionColumns]
///    的 I1/I2/I3 规则。留着便于事后诊断(如统计错值溯源)。
class _V45MergePlan {
  const _V45MergePlan({
    required this.ledgerId,
    required this.syncId,
    required this.keeperId,
    required this.loserIds,
    required this.keeperCompleteness,
    required this.mergedValues,
    required this.discardedByLoser,
    this.refusedByInvariant = const [],
  });

  final int ledgerId;
  final String syncId;
  final int keeperId;
  final List<int> loserIds;
  final int keeperCompleteness;
  final Map<String, Object?> mergedValues;
  final Map<int, Map<String, Object?>> discardedByLoser;
  final List<Map<String, Object?>> refusedByInvariant;

  Map<String, dynamic> toJson() => {
        'ledgerId': ledgerId,
        'syncId': syncId,
        'keeperId': keeperId,
        'keeperCompleteness': keeperCompleteness,
        'deletedRowIds': loserIds,
        'mergedIntoKeeper': mergedValues,
        'refusedByInvariant': refusedByInvariant,
        'discardedByLoser': {
          for (final e in discardedByLoser.entries) '${e.key}': e.value,
        },
      };
}

@DriftDatabase(tables: [
  Ledgers,
  Accounts,
  Categories,
  Transactions,
  RecurringTransactions,
  Conversations,
  Messages,
  Tags,
  TransactionTags,
  Budgets,
  TransactionAttachments,
  LocalChanges,
  SyncState,
  LedgerMembers,
  SharedLedgerCategories,
  SharedLedgerAccounts,
  SharedLedgerTags,
  TransactionTagOverrides,
  SyncPullErrors,
  ExchangeRates,
  ExchangeRateOverrides,
  AutoBookEvents,
  AutoBookEventItems,
  AccountAdjustments,
  DeletedTransactions,
])
class BeeDatabase extends _$BeeDatabase {
  BeeDatabase() : super(_openConnection());

  /// 测试专用:直接注入 [QueryExecutor](通常是 NativeDatabase.memory()),
  /// 跳过 [_openConnection] 的文件系统 / 平台副作用。test/ 下的 unit test
  /// 用这个。
  BeeDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 45; // v45: syncId 唯一索引(去重)/transaction_tags 唯一;v44: 自动目标快照

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            // 添加 sortOrder 字段（使用原始 SQL，因为此时代码还未生成）
            //
            // C3/建议-10:与 v24 同款幂等保护。SQLite DDL 隐式 commit 且不可
            // 回滚 —— 半迁移库(ALTER 已提交但 user_version 未更新)重跑时
            // 裸 ALTER 会 "duplicate column name" 把启动卡死。
            await _addColumnIfMissing('categories', 'sort_order',
                'ALTER TABLE categories ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;');

            // 为现有分类设置默认的 sortOrder（按 id 顺序）
            await customStatement('''
          UPDATE categories
          SET sort_order = (
            SELECT COUNT(*)
            FROM categories AS c2
            WHERE c2.id <= categories.id
          ) - 1;
        ''');
          }
          if (from < 3) {
            // 创建重复交易表
            await _createTableIfMissing(
                migrator, 'recurring_transactions', recurringTransactions);

            // 为 transactions 表添加 recurring_id 字段
            await _addColumnIfMissing('transactions', 'recurring_id',
                'ALTER TABLE transactions ADD COLUMN recurring_id INTEGER;');
          }
          if (from < 4) {
            // 为 accounts 表添加 initial_balance 字段
            await _addColumnIfMissing('accounts', 'initial_balance',
                'ALTER TABLE accounts ADD COLUMN initial_balance REAL NOT NULL DEFAULT 0.0;');
          }
          if (from < 5) {
            // v5: 账户独立改造
            // 注意：数据迁移逻辑在 MigrationService 中统一处理
            // 这里只添加必要的字段

            // 检查字段是否已存在，避免重复添加
            final tableInfo =
                await customSelect('PRAGMA table_info(accounts)').get();
            final hasCurrency =
                tableInfo.any((row) => row.data['name'] == 'currency');
            final hasCreatedAt =
                tableInfo.any((row) => row.data['name'] == 'created_at');
            final hasUpdatedAt =
                tableInfo.any((row) => row.data['name'] == 'updated_at');

            if (!hasCurrency) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN currency TEXT NOT NULL DEFAULT \'CNY\';');
            }

            if (!hasCreatedAt) {
              // SQLite 不支持非常量默认值，先添加可空字段，然后更新
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN created_at INTEGER;');
              await customStatement(
                  'UPDATE accounts SET created_at = strftime(\'%s\', \'now\') WHERE created_at IS NULL;');
            }

            if (!hasUpdatedAt) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN updated_at INTEGER;');
            }

            // 注意：不在onUpgrade中更新currency数据
            // 数据迁移统一由 MigrationService 处理，避免重复逻辑
          }
          if (from < 6) {
            // v6: 二级分类支持
            // 检查字段是否已存在，避免重复添加
            final tableInfo =
                await customSelect('PRAGMA table_info(categories)').get();
            final hasParentId =
                tableInfo.any((row) => row.data['name'] == 'parent_id');
            final hasLevel =
                tableInfo.any((row) => row.data['name'] == 'level');

            if (!hasParentId) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN parent_id INTEGER;');
            }

            if (!hasLevel) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN level INTEGER NOT NULL DEFAULT 1;');
            }

            // 确保所有现有分类的 level 都为 1（一级分类）
            await customStatement(
                'UPDATE categories SET level = 1 WHERE level IS NULL OR level = 0;');
          }
          if (from < 7) {
            print('[DB Migration] 开始迁移到 v7: 周期账单支持转账');
            // v7: 周期账单支持转账
            // 需要将 category_id 改为可空，并添加 to_account_id 字段
            // SQLite 不支持修改列约束，所以需要重建表
            //
            // C3/建议-10:重建表是**最危险**的迁移形态(SQLite DDL 隐式 commit
            // 且不可回滚):历史版在 DROP 与 RENAME 之间被杀,库会停在「旧表已删、
            // 新表未改名」的半迁移态,重跑时 INSERT ... SELECT FROM
            // recurring_transactions 直接 no such table 永久打不开。
            // 三步全部加存在性守卫,让任意中间态都能续跑到终态。
            final v7Cols =
                await customSelect('PRAGMA table_info(recurring_transactions)')
                    .get();
            final hasToAccountId =
                v7Cols.any((row) => row.data['name'] == 'to_account_id');
            if (hasToAccountId) {
              print('[DB Migration] v7 迁移跳过: to_account_id 已存在');
            } else {
              // 1. 创建新表
              print('[DB Migration] 步骤1: 创建新表');
              await customStatement('''
              CREATE TABLE IF NOT EXISTS recurring_transactions_new (
                id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                ledger_id INTEGER NOT NULL,
                type TEXT NOT NULL,
                amount REAL NOT NULL,
                category_id INTEGER,
                account_id INTEGER,
                to_account_id INTEGER,
                note TEXT,
                frequency TEXT NOT NULL,
                interval INTEGER NOT NULL DEFAULT 1,
                day_of_month INTEGER,
                day_of_week INTEGER,
                month_of_year INTEGER,
                start_date INTEGER NOT NULL,
                end_date INTEGER,
                last_generated_date INTEGER,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
              );
            ''');

              // 2. 复制数据(前一次已复制过就不再复制 —— 否则 id 主键冲突)
              print('[DB Migration] 步骤2: 复制数据');
              final newCnt = await customSelect(
                      'SELECT COUNT(*) AS c FROM recurring_transactions_new')
                  .getSingle();
              final newCount = (newCnt.data['c'] as num?)?.toInt() ?? 0;
              final oldTableRow = await customSelect(
                      "SELECT name FROM sqlite_master WHERE type='table' AND name='recurring_transactions'")
                  .getSingleOrNull();
              if (oldTableRow != null && newCount == 0) {
                await customStatement('''
              INSERT INTO recurring_transactions_new
              (id, ledger_id, type, amount, category_id, account_id, to_account_id, note,
               frequency, interval, day_of_month, day_of_week, month_of_year,
               start_date, end_date, last_generated_date, enabled, created_at, updated_at)
              SELECT id, ledger_id, type, amount, category_id, account_id,
                     NULL as to_account_id, note,
                     frequency, interval, day_of_month, day_of_week, month_of_year,
                     start_date, end_date, last_generated_date, enabled, created_at, updated_at
              FROM recurring_transactions;
            ''');
              }

              // 3. 删除旧表
              print('[DB Migration] 步骤3: 删除旧表');
              await customStatement('DROP TABLE IF EXISTS recurring_transactions;');

              // 4. 重命名新表
              print('[DB Migration] 步骤4: 重命名新表');
              await customStatement(
                  'ALTER TABLE recurring_transactions_new RENAME TO recurring_transactions;');
            }
            print('[DB Migration] v7 迁移完成');
          }
          if (from < 8) {
            // v8: AI 对话助手
            print('[DB Migration] 开始迁移到 v8: AI 对话助手');
            await migrator.createTable(conversations);
            await migrator.createTable(messages);
            logger.info('DB', 'v8 迁移完成: AI Chat tables created');
            print('[DB Migration] v8 迁移完成');
          }
          if (from < 9) {
            // v9: 为 ledgers 表添加 type 字段（支持家庭账本）
            print('[DB Migration] 开始迁移到 v9: 添加 ledgers.type 字段');

            // 检查字段是否已存在，避免重复添加
            final tableInfo =
                await customSelect('PRAGMA table_info(ledgers)').get();
            final hasType = tableInfo.any((row) => row.data['name'] == 'type');

            if (!hasType) {
              await customStatement(
                  'ALTER TABLE ledgers ADD COLUMN type TEXT NOT NULL DEFAULT \'personal\';');
              logger.info('DB', 'v9 迁移完成: ledgers.type 字段已添加');
            } else {
              logger.info('DB', 'v9 迁移跳过: ledgers.type 字段已存在');
            }

            print('[DB Migration] v9 迁移完成');
          }
          if (from < 10) {
            // v10: 添加标签功能
            print('[DB Migration] 开始迁移到 v10: 添加标签功能');

            // 创建 tags 表
            await migrator.createTable(tags);
            logger.info('DB', 'v10: tags 表已创建');

            // 创建 transaction_tags 关联表
            await migrator.createTable(transactionTags);
            logger.info('DB', 'v10: transaction_tags 表已创建');

            // 创建索引以提高查询性能
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_transaction_tags_transaction ON transaction_tags(transaction_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_transaction_tags_tag ON transaction_tags(tag_id)');
            logger.info('DB', 'v10: 索引已创建');

            print('[DB Migration] v10 迁移完成');
          }
          if (from < 11) {
            // v11: 添加预算功能
            print('[DB Migration] 开始迁移到 v11: 添加预算功能');

            // 创建 budgets 表
            await migrator.createTable(budgets);
            logger.info('DB', 'v11: budgets 表已创建');

            // 创建索引以提高查询性能
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_budgets_ledger ON budgets(ledger_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_budgets_category ON budgets(category_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_budgets_ledger_type ON budgets(ledger_id, type)');
            logger.info('DB', 'v11: 预算索引已创建');

            print('[DB Migration] v11 迁移完成');
          }
          if (from < 12) {
            // v12: 添加交易附件功能
            print('[DB Migration] 开始迁移到 v12: 添加交易附件功能');

            // 创建 transaction_attachments 表
            await migrator.createTable(transactionAttachments);
            logger.info('DB', 'v12: transaction_attachments 表已创建');

            // 创建索引以提高查询性能
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_attachments_transaction ON transaction_attachments(transaction_id)');
            logger.info('DB', 'v12: 附件索引已创建');

            print('[DB Migration] v12 迁移完成');
          }
          if (from < 13) {
            // v13: 分类自定义图标支持
            print('[DB Migration] 开始迁移到 v13: 分类自定义图标支持');

            // 检查字段是否已存在，避免重复添加
            final tableInfo =
                await customSelect('PRAGMA table_info(categories)').get();
            final hasIconType =
                tableInfo.any((row) => row.data['name'] == 'icon_type');
            final hasCustomIconPath =
                tableInfo.any((row) => row.data['name'] == 'custom_icon_path');
            final hasCommunityIconId =
                tableInfo.any((row) => row.data['name'] == 'community_icon_id');

            if (!hasIconType) {
              await customStatement(
                  "ALTER TABLE categories ADD COLUMN icon_type TEXT NOT NULL DEFAULT 'material';");
              logger.info('DB', 'v13: icon_type 字段已添加');
            }

            if (!hasCustomIconPath) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN custom_icon_path TEXT;');
              logger.info('DB', 'v13: custom_icon_path 字段已添加');
            }

            if (!hasCommunityIconId) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN community_icon_id TEXT;');
              logger.info('DB', 'v13: community_icon_id 字段已添加');
            }

            print('[DB Migration] v13 迁移完成');
          }
          if (from < 14) {
            // v14: 迁移转账记录到虚拟转账分类
            print('[DB Migration] 开始迁移到 v14: 迁移转账记录到虚拟转账分类');
            await SeedService.migrateTransferTransactions(this);
            logger.info('DB', 'v14 迁移完成: 转账记录已关联到虚拟转账分类');
            print('[DB Migration] v14 迁移完成');
          }
          if (from < 15) {
            // v15: 交易添加 syncId 用于云同步
            print('[DB Migration] 开始迁移到 v15: 添加 syncId 字段');

            // 1. 添加 sync_id 列 —— C3/建议-10:走 _addColumnIfMissing 幂等,
            // 半迁移库重跑不再 duplicate column。
            await _addColumnIfMissing('transactions', 'sync_id',
                'ALTER TABLE transactions ADD COLUMN sync_id TEXT;');
            logger.info('DB', 'v15: sync_id 字段已添加');

            // 2. 为所有已有交易生成 UUID v4
            // 使用 SQLite 内置函数生成简易唯一ID（hex + random）
            // 格式: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
            await customStatement('''
              UPDATE transactions SET sync_id =
                lower(hex(randomblob(4))) || '-' ||
                lower(hex(randomblob(2))) || '-4' ||
                substr(lower(hex(randomblob(2))),2) || '-' ||
                substr('89ab', abs(random()) % 4 + 1, 1) ||
                substr(lower(hex(randomblob(2))),2) || '-' ||
                lower(hex(randomblob(6)))
              WHERE sync_id IS NULL;
            ''');
            logger.info('DB', 'v15: 已为现有交易回填 syncId');

            // 3. 创建索引
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_transactions_sync_id ON transactions(sync_id);');
            logger.info('DB', 'v15: syncId 索引已创建');

            print('[DB Migration] v15 迁移完成');
          }
          if (from < 16) {
            // v16: 账户添加 sortOrder 排序字段
            print('[DB Migration] 开始迁移到 v16: 账户排序');

            await _addColumnIfMissing('accounts', 'sort_order',
                'ALTER TABLE accounts ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;');
            logger.info('DB', 'v16: sort_order 字段已添加');

            // 回填：按 type 分组，组内按 created_at 排序赋值 sortOrder
            await customStatement('''
              UPDATE accounts SET sort_order = (
                SELECT COUNT(*)
                FROM accounts AS a2
                WHERE a2.type = accounts.type
                  AND (a2.created_at < accounts.created_at
                       OR (a2.created_at = accounts.created_at AND a2.id < accounts.id)
                       OR (a2.created_at IS NULL AND accounts.created_at IS NOT NULL)
                       OR (a2.created_at IS NULL AND accounts.created_at IS NULL AND a2.id < accounts.id))
              );
            ''');
            logger.info('DB', 'v16: 已为现有账户回填 sortOrder');

            print('[DB Migration] v16 迁移完成');
          }
          if (from < 17) {
            // v17: 账户添加信用卡字段
            print('[DB Migration] 开始迁移到 v17: 信用卡字段');

            final tableInfo =
                await customSelect('PRAGMA table_info(accounts)').get();
            final hasCreditLimit =
                tableInfo.any((row) => row.data['name'] == 'credit_limit');
            final hasBillingDay =
                tableInfo.any((row) => row.data['name'] == 'billing_day');
            final hasPaymentDueDay =
                tableInfo.any((row) => row.data['name'] == 'payment_due_day');

            if (!hasCreditLimit) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN credit_limit REAL;');
              logger.info('DB', 'v17: credit_limit 字段已添加');
            }

            if (!hasBillingDay) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN billing_day INTEGER;');
              logger.info('DB', 'v17: billing_day 字段已添加');
            }

            if (!hasPaymentDueDay) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN payment_due_day INTEGER;');
              logger.info('DB', 'v17: payment_due_day 字段已添加');
            }

            print('[DB Migration] v17 迁移完成');
          }
          if (from < 18) {
            // v18: 账户添加元信息字段
            print('[DB Migration] 开始迁移到 v18: 账户元信息');

            final tableInfo =
                await customSelect('PRAGMA table_info(accounts)').get();
            final hasBankName =
                tableInfo.any((row) => row.data['name'] == 'bank_name');
            final hasCardLastFour =
                tableInfo.any((row) => row.data['name'] == 'card_last_four');
            final hasNote = tableInfo.any((row) => row.data['name'] == 'note');

            if (!hasBankName) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN bank_name TEXT;');
              logger.info('DB', 'v18: bank_name 字段已添加');
            }

            if (!hasCardLastFour) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN card_last_four TEXT;');
              logger.info('DB', 'v18: card_last_four 字段已添加');
            }

            if (!hasNote) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN note TEXT;');
              logger.info('DB', 'v18: note 字段已添加');
            }

            print('[DB Migration] v18 迁移完成');
          }
          if (from < 19) {
            // v19: 同步基础设施
            print('[DB Migration] 开始迁移到 v19: 同步基础设施');

            // 1. 为 accounts 添加 sync_id
            final accountInfo =
                await customSelect('PRAGMA table_info(accounts)').get();
            if (!accountInfo.any((row) => row.data['name'] == 'sync_id')) {
              await customStatement(
                  'ALTER TABLE accounts ADD COLUMN sync_id TEXT;');
              // 回填 UUID
              await customStatement('''
                UPDATE accounts SET sync_id =
                  lower(hex(randomblob(4))) || '-' ||
                  lower(hex(randomblob(2))) || '-4' ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  substr('89ab', abs(random()) % 4 + 1, 1) ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  lower(hex(randomblob(6)))
                WHERE sync_id IS NULL;
              ''');
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_accounts_sync_id ON accounts(sync_id);');
              logger.info('DB', 'v19: accounts.sync_id 已添加并回填');
            }

            // 2. 为 categories 添加 sync_id
            final categoryInfo =
                await customSelect('PRAGMA table_info(categories)').get();
            if (!categoryInfo.any((row) => row.data['name'] == 'sync_id')) {
              await customStatement(
                  'ALTER TABLE categories ADD COLUMN sync_id TEXT;');
              await customStatement('''
                UPDATE categories SET sync_id =
                  lower(hex(randomblob(4))) || '-' ||
                  lower(hex(randomblob(2))) || '-4' ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  substr('89ab', abs(random()) % 4 + 1, 1) ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  lower(hex(randomblob(6)))
                WHERE sync_id IS NULL;
              ''');
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_categories_sync_id ON categories(sync_id);');
              logger.info('DB', 'v19: categories.sync_id 已添加并回填');
            }

            // 3. 为 tags 添加 sync_id
            final tagInfo = await customSelect('PRAGMA table_info(tags)').get();
            if (!tagInfo.any((row) => row.data['name'] == 'sync_id')) {
              await customStatement(
                  'ALTER TABLE tags ADD COLUMN sync_id TEXT;');
              await customStatement('''
                UPDATE tags SET sync_id =
                  lower(hex(randomblob(4))) || '-' ||
                  lower(hex(randomblob(2))) || '-4' ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  substr('89ab', abs(random()) % 4 + 1, 1) ||
                  substr(lower(hex(randomblob(2))),2) || '-' ||
                  lower(hex(randomblob(6)))
                WHERE sync_id IS NULL;
              ''');
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS idx_tags_sync_id ON tags(sync_id);');
              logger.info('DB', 'v19: tags.sync_id 已添加并回填');
            }

            // 4. 创建 local_changes 表
            await migrator.createTable(localChanges);
            logger.info('DB', 'v19: local_changes 表已创建');

            // 5. 创建 sync_state 表
            await migrator.createTable(syncState);
            logger.info('DB', 'v19: sync_state 表已创建');

            print('[DB Migration] v19 迁移完成');
          }
          if (from < 20) {
            // v20: 附件云端同步字段
            print('[DB Migration] 开始迁移到 v20: 附件云端同步字段');

            final tableInfo =
                await customSelect('PRAGMA table_info(transaction_attachments)')
                    .get();
            final hasCloudFileId =
                tableInfo.any((row) => row.data['name'] == 'cloud_file_id');
            final hasCloudSha256 =
                tableInfo.any((row) => row.data['name'] == 'cloud_sha256');

            if (!hasCloudFileId) {
              await customStatement(
                  'ALTER TABLE transaction_attachments ADD COLUMN cloud_file_id TEXT;');
              logger.info('DB', 'v20: cloud_file_id 字段已添加');
            }

            if (!hasCloudSha256) {
              await customStatement(
                  'ALTER TABLE transaction_attachments ADD COLUMN cloud_sha256 TEXT;');
              logger.info('DB', 'v20: cloud_sha256 字段已添加');
            }

            print('[DB Migration] v20 迁移完成');
          }
          if (from < 21) {
            // v21: ledgers 加 syncId（跨设备同步 ledger 匹配）
            // C3/建议-10:原为裸 ALTER + 存在性判断的组合(部分幂等),统一走
            // helper 并把回填与索引也纳入守卫,半迁移库可安全重跑。
            print('[DB Migration] 开始迁移到 v21: ledgers.sync_id');

            final ledgerInfo =
                await customSelect('PRAGMA table_info(ledgers)').get();
            final hadSyncId =
                ledgerInfo.any((row) => row.data['name'] == 'sync_id');
            await _addColumnIfMissing('ledgers', 'sync_id',
                'ALTER TABLE ledgers ADD COLUMN sync_id TEXT;');
            // 把现有 ledger.id 回填成 syncId（转字符串）。这样旧 A 设备已推
            // 到 server 的 external_id（= 当时的 id.toString()）对得上新列，
            // 后续 push/pull 都走 syncId，无脑兼容。WHERE sync_id IS NULL
            // 保证回填可重跑(不覆盖已同步下来的 UUID)。
            await customStatement(
                "UPDATE ledgers SET sync_id = CAST(id AS TEXT) WHERE sync_id IS NULL;");
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_ledgers_sync_id ON ledgers(sync_id);');
            logger.info('DB',
                'v21: ledgers.sync_id ${hadSyncId ? "已存在" : "已添加"}并回填');

            print('[DB Migration] v21 迁移完成');
          }
          if (from < 22) {
            // v22: budgets 加 syncId(跨设备同步 budget 匹配)
            // C3/建议-10:同 v21,统一幂等。
            print('[DB Migration] 开始迁移到 v22: budgets.sync_id');

            final budgetInfo =
                await customSelect('PRAGMA table_info(budgets)').get();
            final hadSyncId =
                budgetInfo.any((row) => row.data['name'] == 'sync_id');
            await _addColumnIfMissing('budgets', 'sync_id',
                'ALTER TABLE budgets ADD COLUMN sync_id TEXT;');
            // SQLite 没有原生 UUID。用 lower(hex(randomblob(16))) 造 32 位
            // 随机 hex,足够当 server entity_sync_id 用。格式跟 UUID 不是
            // 标准 36 位,但 server 侧校验只要求非空字符串。
            await customStatement(
                "UPDATE budgets SET sync_id = lower(hex(randomblob(16))) WHERE sync_id IS NULL;");
            await customStatement(
                'CREATE INDEX IF NOT EXISTS idx_budgets_sync_id ON budgets(sync_id);');
            logger.info('DB',
                'v22: budgets.sync_id ${hadSyncId ? "已存在" : "已添加"}并回填');

            print('[DB Migration] v22 迁移完成');
          }
          if (from < 23) {
            // v23: 清理"分类图标靠 getCategoryIconByName 运行时推导"的毒瘤代码。
            // 历史上 `category.icon` 允许为 null/空,渲染时走 `getCategoryIconByName`
            // 按中文关键字模糊匹配回退推导图标。这个方案:
            //   - 改名就换图标(用户会懵)
            //   - 只认中文,英语/繁中走不到
            //   - web/server 必须复刻同一套 40 条正则,维护两份
            // v23 一次性把 icon IS NULL/'' 的分类按 byName 推算出结果写回 DB,
            // 之后渲染层 getCategoryIconData 只认 icon 字段、不再 byName 推导。
            // 结合服务端 alembic 0002 的同名 backfill,两端同步"迁 read-time 到
            // write-time"。
            print(
                '[DB Migration] 开始迁移到 v23: backfill category icons via byName');

            // 取所有 icon 空的分类,按 name 推导图标字符串回填
            final rows = await customSelect(
              "SELECT id, name FROM categories WHERE icon IS NULL OR icon = ''",
            ).get();
            var updated = 0;
            for (final row in rows) {
              final id = row.data['id'] as int;
              final name = row.data['name'] as String? ?? '';
              // 用 CategoryService.resolveIconNameByName(类似原 getCategoryIconByName
              // 但返回字符串名)一次性固化到 DB。此后渲染不再 byName。
              final iconName = CategoryService.resolveIconNameByName(name);
              await customStatement(
                'UPDATE categories SET icon = ? WHERE id = ?',
                [iconName, id],
              );
              updated++;
            }
            logger.info('DB', 'v23: backfilled $updated categories');
            print('[DB Migration] v23 迁移完成: 回填 $updated 条分类');
          }
          if (from < 24) {
            // v24: 共享账本完整 schema(合并自 v24/v25/v26/v27 的迭代,测试阶段
            // 一次落地最终态)。
            //
            // 重要:所有 ALTER / createTable 都包"存在则跳过"防御 — 用户从
            // 3.1.3 升级到带 bug 的 3.2.0 时 v25 ALTER 失败,但 v24 的 DDL
            // 已经隐式 commit(SQLite DDL 不可回滚),user_version 仍 23。
            // 装新版本再跑 onUpgrade(from=23) 时 v24 第一句又会 duplicate column
            // 卡死。每条都要幂等。
            print('[DB Migration] 开始迁移到 v24: 共享账本完整 schema');

            await _addColumnIfMissing('ledgers', 'my_role',
                "ALTER TABLE ledgers ADD COLUMN my_role TEXT NOT NULL DEFAULT 'owner';");
            await _addColumnIfMissing('ledgers', 'member_count',
                "ALTER TABLE ledgers ADD COLUMN member_count INTEGER NOT NULL DEFAULT 1;");
            await _addColumnIfMissing('ledgers', 'is_shared',
                "ALTER TABLE ledgers ADD COLUMN is_shared INTEGER NOT NULL DEFAULT 0;");
            await _addColumnIfMissing('ledgers', 'owner_user_id',
                "ALTER TABLE ledgers ADD COLUMN owner_user_id TEXT;");

            await _addColumnIfMissing('transactions', 'created_by_user_id',
                "ALTER TABLE transactions ADD COLUMN created_by_user_id TEXT;");
            await _addColumnIfMissing('transactions', 'last_edited_by_user_id',
                "ALTER TABLE transactions ADD COLUMN last_edited_by_user_id TEXT;");
            await _addColumnIfMissing(
                'transactions',
                'category_sync_id_override',
                'ALTER TABLE transactions ADD COLUMN category_sync_id_override TEXT;');
            await _addColumnIfMissing(
                'transactions',
                'account_sync_id_override',
                'ALTER TABLE transactions ADD COLUMN account_sync_id_override TEXT;');
            await _addColumnIfMissing(
                'transactions',
                'to_account_sync_id_override',
                'ALTER TABLE transactions ADD COLUMN to_account_sync_id_override TEXT;');
            await _addColumnIfMissing('transactions', 'tag_sync_ids_override',
                'ALTER TABLE transactions ADD COLUMN tag_sync_ids_override TEXT;');

            await _createTableIfMissing(
                migrator, 'ledger_members', ledgerMembers);
            await _createTableIfMissing(
                migrator, 'shared_ledger_categories', sharedLedgerCategories);
            await _createTableIfMissing(
                migrator, 'shared_ledger_accounts', sharedLedgerAccounts);
            await _createTableIfMissing(
                migrator, 'shared_ledger_tags', sharedLedgerTags);
            await _createTableIfMissing(
                migrator, 'transaction_tag_overrides', transactionTagOverrides);

            // 重置 server_cursor — 强制下次启动全量重拉,确保 sync_engine_apply
            // 用最新的 override 写入逻辑填回 *SyncIdOverride 字段。
            await customStatement('UPDATE sync_state SET server_cursor = 0');

            print('[DB Migration] v24 迁移完成');
          }
          if (from < 25) {
            // v25: SharedLedgerCategories 加 parent_sync_id 列。
            // 注:v24 `createTable(sharedLedgerCategories)` 用**当前 schema**
            // 建表,已经带 parent_sync_id 列 — 干净 from=23 升级时这里 ALTER
            // 会 duplicate。用 helper PRAGMA 检查后再 ALTER。
            logger.info('DBMigration',
                '开始迁移到 v25: SharedLedgerCategories.parent_sync_id');
            await _addColumnIfMissing(
                'shared_ledger_categories',
                'parent_sync_id',
                'ALTER TABLE shared_ledger_categories ADD COLUMN parent_sync_id TEXT;');
            // 数据回填:对每个 level=2 行,在同 ledger_sync_id + kind 内按
            // parent_name 反查 level=1 行的 syncId 填进 parent_sync_id。
            // 用 IS NULL/'' 守护让 UPDATE 可幂等重跑。
            await customStatement('''
              UPDATE shared_ledger_categories AS child
              SET parent_sync_id = (
                SELECT parent.sync_id
                FROM shared_ledger_categories AS parent
                WHERE parent.ledger_sync_id = child.ledger_sync_id
                  AND parent.name = child.parent_name
                  AND parent.kind = child.kind
                  AND COALESCE(parent.level, 1) = 1
                LIMIT 1
              )
              WHERE COALESCE(child.level, 1) >= 2
                AND child.parent_name IS NOT NULL
                AND (child.parent_sync_id IS NULL OR child.parent_sync_id = '')
            ''');
            // reset server_cursor 让后续 pull 重拉 user-global category change。
            await customStatement('UPDATE sync_state SET server_cursor = 0');
            logger.info('DBMigration', 'v25 迁移完成');
          }
          if (from < 26) {
            // v26: 新增 sync_pull_errors 表。健康用户为空,只在 pull apply
            // 抛错时写入,UI 据此显示"同步异常"banner + 重试/跳过操作。
            // 详见 .docs/full-pull-refactor/04-data-model.md
            logger.info('DBMigration', '开始迁移到 v26: sync_pull_errors');
            await _createTableIfMissing(
                migrator, 'sync_pull_errors', syncPullErrors);
            logger.info('DBMigration', 'v26 迁移完成');
          }
          if (from < 27) {
            logger.info('DBMigration', '开始迁移到 v27: ledgers.month_start_day');
            // v27: 账本自定义每月起始日(1-28),默认 1=自然月
            // C3/建议-10:裸 ALTER → 幂等 helper。
            await _addColumnIfMissing('ledgers', 'month_start_day',
                'ALTER TABLE ledgers ADD COLUMN month_start_day INTEGER NOT NULL DEFAULT 1;');
            logger.info('DBMigration', 'v27 迁移完成');
          }
          if (from < 28) {
            logger.info('DBMigration',
                '开始迁移到 v28: 多币种 MVP(exchange_rates / exchange_rate_overrides)');
            await _createTableIfMissing(
                migrator, 'exchange_rates', exchangeRates);
            await _createTableIfMissing(
                migrator, 'exchange_rate_overrides', exchangeRateOverrides);
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_override_pair '
                'ON exchange_rate_overrides (base_currency, quote_currency);');
            logger.info('DBMigration', 'v28 迁移完成');
          }
          if (from < 29) {
            logger.info('DBMigration', '开始迁移到 v29: 账单标记(不计入收支/不计入预算)');
            await _addColumnIfMissing('transactions', 'exclude_from_stats',
                'ALTER TABLE transactions ADD COLUMN exclude_from_stats INTEGER NOT NULL DEFAULT 0;');
            await _addColumnIfMissing('transactions', 'exclude_from_budget',
                'ALTER TABLE transactions ADD COLUMN exclude_from_budget INTEGER NOT NULL DEFAULT 0;');
            logger.info('DBMigration', 'v29 迁移完成');
          }
          if (from < 30) {
            logger.info('DBMigration',
                '开始迁移到 v30: 交易级多币种(currency_code + native_amount)');
            await _addColumnIfMissing('transactions', 'currency_code',
                'ALTER TABLE transactions ADD COLUMN currency_code TEXT;');
            await _addColumnIfMissing('transactions', 'native_amount',
                'ALTER TABLE transactions ADD COLUMN native_amount REAL;');
            // 回填:currency_code = 账户币种(无账户 → 账本本位币);
            // native_amount = amount(隐含汇率 1.0)→ 单币种账本统计结果不变。
            // ⚠️ SQL 与 test/data/migration_v30_test.dart 的常量保持一字不差。
            await customStatement('''
    UPDATE transactions SET currency_code = COALESCE(
      (SELECT a.currency FROM accounts a WHERE a.id = transactions.account_id),
      (SELECT l.currency FROM ledgers l WHERE l.id = transactions.ledger_id),
      'CNY')
    WHERE currency_code IS NULL;''');
            await customStatement(
                'UPDATE transactions SET native_amount = amount WHERE native_amount IS NULL;');
            logger.info('DBMigration', 'v30 迁移完成');
          }
          if (from < 31) {
            logger.info('DBMigration', '开始迁移到 v31: 账户隐藏(hidden)');
            await _addColumnIfMissing('accounts', 'hidden',
                'ALTER TABLE accounts ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;');
            logger.info('DBMigration', 'v31 迁移完成');
          }
          if (from < 32) {
            logger.info('DBMigration', '开始迁移到 v32: 周期账单币种(currency_code)');
            // 不回填:NULL = 账本本位币/跟随账户,与迁移前生成行为一字不差。
            await _addColumnIfMissing('recurring_transactions', 'currency_code',
                'ALTER TABLE recurring_transactions ADD COLUMN currency_code TEXT;');
            logger.info('DBMigration', 'v32 迁移完成');
          }
          if (from < 33) {
            logger.info('DBMigration', '开始迁移到 v33: 自动记账入口事件表');
            await _createTableIfMissing(
                migrator, 'auto_book_events', autoBookEvents);
            await _createTableIfMissing(
                migrator, 'auto_book_event_items', autoBookEventItems);
            logger.info('DBMigration', 'v33 迁移完成');
          }
          if (from < 34) {
            logger.info('DBMigration', '开始迁移到 v34: 自动记账原始证据字段');
            await _addColumnIfMissing('auto_book_events', 'raw_title',
                'ALTER TABLE auto_book_events ADD COLUMN raw_title TEXT;');
            await _addColumnIfMissing('auto_book_events', 'raw_text',
                'ALTER TABLE auto_book_events ADD COLUMN raw_text TEXT;');
            await _addColumnIfMissing('auto_book_events', 'raw_actor',
                'ALTER TABLE auto_book_events ADD COLUMN raw_actor TEXT;');
            await _addColumnIfMissing('auto_book_events', 'raw_metadata_json',
                'ALTER TABLE auto_book_events ADD COLUMN raw_metadata_json TEXT;');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_uploaded_at',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_uploaded_at INTEGER;');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_upload_attempts',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_upload_attempts INTEGER NOT NULL DEFAULT 0;');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_last_error',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_last_error TEXT;');
            logger.info('DBMigration', 'v34 迁移完成');
          }
          if (from < 35) {
            logger.info('DBMigration', '开始迁移到 v35: 原始证据策略与上传状态');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_local_enabled',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_local_enabled INTEGER NOT NULL DEFAULT 0;');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_server_enabled',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_server_enabled INTEGER NOT NULL DEFAULT 0;');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_retention_until',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_retention_until INTEGER;');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_upload_state',
                "ALTER TABLE auto_book_events ADD COLUMN raw_evidence_upload_state TEXT NOT NULL DEFAULT 'not_requested';");
            logger.info('DBMigration', 'v35 迁移完成');
          }
          if (from < 36) {
            logger.info('DBMigration', '开始迁移到 v36: 原始证据独立保留窗口');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_local_expires_at',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_local_expires_at INTEGER;');
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_server_expires_at',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_server_expires_at INTEGER;');
            await customStatement(
                'UPDATE auto_book_events SET raw_evidence_local_expires_at = raw_evidence_retention_until '
                'WHERE raw_evidence_local_enabled = 1 AND raw_evidence_local_expires_at IS NULL;');
            await customStatement(
                'UPDATE auto_book_events SET raw_evidence_server_expires_at = raw_evidence_retention_until '
                'WHERE raw_evidence_server_enabled = 1 AND raw_evidence_server_expires_at IS NULL;');
            logger.info('DBMigration', 'v36 迁移完成');
          }
          if (from < 37) {
            await _addColumnIfMissing(
                'auto_book_events',
                'raw_evidence_next_retry_at',
                'ALTER TABLE auto_book_events ADD COLUMN raw_evidence_next_retry_at INTEGER;');
          }
          if (from < 38) {
            // 自动记账离线识别草稿:瞬态失败(连不上服务端)时保存输入,
            // 手动/联网恢复后重试;终态清除。
            await _addColumnIfMissing('auto_book_events', 'draft_payload_json',
                'ALTER TABLE auto_book_events ADD COLUMN draft_payload_json TEXT;');
          }
          if (from < 40) {
            // v40 交易记录时间(server 首次落库盖章,pull 时下发)。不回填:
            // NULL = 老数据,UI 显示 "-"。
            await _addColumnIfMissing('transactions', 'recorded_at',
                'ALTER TABLE transactions ADD COLUMN recorded_at INTEGER;');
          }
          if (from < 42) {
            // v42 余额调整记录表:调整余额不再落一笔 exclude_from_stats 交易,
            // 独立实体只参与余额口径。存量调整交易不迁移(exclude 标记继续生效)。
            await migrator.createTable(accountAdjustments);
          }
          if (from < 43) {
            // v43 回收站 tombstone 表:删除的交易整行暂存,30 天内可恢复。
            await migrator.createTable(deletedTransactions);
          }
          if (from < 44) {
            // v44 自动目标快照:只有目标稳定标识/配置版本无法由既有字段安全
            // 表达时才加列(B0 §5.2)。存量行保持 NULL + resolved,不回填、
            // 不重写历史目标(计划 §5.4:历史数据不批量改账本)。
            await _addColumnIfMissing('auto_book_events', 'target_ref',
                'ALTER TABLE auto_book_events ADD COLUMN target_ref TEXT;');
            await _addColumnIfMissing(
                'auto_book_events',
                'target_config_version',
                'ALTER TABLE auto_book_events '
                'ADD COLUMN target_config_version INTEGER;');
            await _addColumnIfMissing(
                'auto_book_events',
                'target_state',
                "ALTER TABLE auto_book_events "
                "ADD COLUMN target_state TEXT DEFAULT 'resolved';");
          }
          if (from < 45) {
            // ──────────────────────────────────────────────────────────────
            // v45 syncId 身份族 + 关联表唯一约束(批次 C3)
            //
            // 【待确认产品决策 · 已按「更宽松/更安全」默认执行,待人工批准】
            //   唯一索引维度 = UNIQUE(ledger_id, sync_id)(**带账本维度**),
            //   而不是 UNIQUE(sync_id)。理由:syncId 的同步契约是「同一账本
            //   内的实体同一性」,跨账本同 syncId 是否合法属产品未决项(计划
            //   §九.2)。UNIQUE(ledger_id, sync_id) 保留跨账本同 id 的合法性,
            //   不会因一次迁移把跨账本数据判为冲突而删行;若后续产品拍板
            //   「全局唯一」,只需重建索引为 UNIQUE(sync_id)。
            //   空串 syncId 不纳入唯一域(历史 HARDENING:空串是 caller 契约
            //   外的输入,当前行为是一次写改多行),避免把存量空串行判为重复。
            //
            // 【回滚说明(阻塞-7a)】本迁移**不是**纯索引变更:
            //   ① 合并重复 syncId 行(删除副本)与 ② 关联表去重都是**不可逆**
            //      的数据删除。回滚只能依赖本迁移自动导出的快照
            //      `pre-v45-<ts>.json`(还原脚本需按该文件重放,不提供自动
            //      downgrade)。仅索引部分可回滚:
            //      [v45RollbackDropIndexesSql] 里的 DROP INDEX 语句。
            //   ③ 非有限金额(NaN/±Infinity)存量行被归零,同样不可逆,快照里
            //      以 `amountUnrepresentable: true` 标记原值不可表示。
            //
            // 【安全设计(阻塞-7b)】
            //   - 备份导出前先**过滤非有限值**:buildBackupJson 无法
            //     jsonEncode Infinity → 若先备份后清洗,历史脏行会让备份抛
            //     JsonUnsupportedObjectError;在 onUpgrade 内抛错 = 库永远打不开。
            //   - 整个 v45 是**逐步骤 best-effort**:每步独立 try/catch + 告警,
            //     绝不把异常抛出 onUpgrade。所有 DDL 都是 IF NOT EXISTS、所有
            //     DML 都是幂等形态 → 任意半迁移态下次启动都能续跑到终态。
            //   - 备份文件写失败只告警不中止(库仍可开,迁移照做)。
            // ──────────────────────────────────────────────────────────────
            await _v45SyncIdIdentityMigration();
          }
          // v39(M3-1):索引统一到 _ensureIndexes(),无条件跑一遍。
          await _ensureIndexes();
        },
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
              'CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_override_pair '
              'ON exchange_rate_overrides (base_currency, quote_currency);');
          await _ensureIndexes();
        },
        // C3/缺陷 D:v45 唯一索引的「下次启动重试」承诺必须落在 beforeOpen。
        // `onUpgrade` 只在 versionBefore < versionNow 时执行 —— user_version
        // 一旦已是 45,残余重复行 + 缺失唯一索引的库永远不会再进迁移分支
        // (实测连续打开 3 次仍 uniqueIndex=0 dupRows=2)。
        // beforeOpen 每次打开都跑(drift db_base.dart:137),先做常数级检查
        // (两个索引是否都在),缺失才进入修复路径 → 正常打开零额外开销。
        beforeOpen: (details) async => _v45RepairUniqueIndexesIfNeeded(),
      );

  /// 建全部二级索引(M3-1)。onCreate / onUpgrade 结束时都调用。
  ///
  /// 拆出来的原因:历史上索引散落在各个 `if (from < N)` 分支里,而 onCreate 只
  /// 有 createAll + 汇率唯一索引 —— **全新安装拿不到任何一条**,只有升级上来的
  /// 老用户才跑在索引上。同一份 SQL 走两条路径才能保证行为一致。
  ///
  /// 全部 `CREATE INDEX IF NOT EXISTS`,可重复执行;以后加索引只在这里加一行 +
  /// bump schemaVersion,不必再写 migration 分支。
  ///
  /// 按表分组 + 建前查 sqlite_master,并且**单条失败不致命**:onUpgrade 尾部是
  /// 无条件执行的,半迁移库/只建了部分表的库里,一条 "no such table/column" 绝不
  /// 能把启动卡死 —— 少一条索引只是慢一点,起不来是灾难。
  Future<void> _ensureIndexes() async {
    const byTable = <String, List<String>>{
      'transactions': [
        // 账本流水按时间倒序翻页(首页/明细/统计的主查询)。
        'CREATE INDEX IF NOT EXISTS idx_transactions_ledger_time '
            'ON transactions (ledger_id, happened_at DESC);',
        // M5-4 keyset 分页:稳定双键 (happened_at DESC, id DESC)。在
        // idx_transactions_ledger_time 基础上补 id,使同时间戳多笔交易跨页
        // 不重复/不漏;新装与升级都建,暂保留旧索引一个版本(见计划 v41)。
        'CREATE INDEX IF NOT EXISTS idx_transactions_ledger_time_id '
            'ON transactions (ledger_id, happened_at DESC, id DESC);',
        // 自动记账判重、收支分类统计:先按账本 + 类型收窄再按时间。
        'CREATE INDEX IF NOT EXISTS idx_transactions_ledger_type_time '
            'ON transactions (ledger_id, type, happened_at DESC);',
        'CREATE INDEX IF NOT EXISTS idx_transactions_sync_id '
            'ON transactions (sync_id);',
        // v45(C3/F-01..F-04):syncId 身份唯一性。带账本维度 —— 跨账本同
        // syncId 是否合法属产品未决项(计划 §九.2),取更宽松的
        // UNIQUE(ledger_id, sync_id) 保留跨账本合法性。部分索引:空串
        // syncId 不纳入唯一域(HARDENING:空串是契约外输入)。只建普通
        // 索引时同 syncId 可重复插入,导致 getTransactionBySyncId
        // (getSingleOrNull)抛 Bad state、删除永远推不出去。
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_transactions_ledger_sync_id '
            "ON transactions (ledger_id, sync_id) "
            "WHERE sync_id IS NOT NULL AND sync_id <> '';",
        // PERF-P0-04 账户维度余额/统计聚合:按 account_id 范围扫描,替代
        // 逐账户全表扫描;时间列附带加速账户流水按日聚合。
        'CREATE INDEX IF NOT EXISTS idx_transactions_account_time '
            'ON transactions (account_id, happened_at DESC);',
        // 转入侧(转账 to_account)点查;稀疏列,部分索引体积很小。
        'CREATE INDEX IF NOT EXISTS idx_transactions_to_account '
            'ON transactions (to_account_id) WHERE to_account_id IS NOT NULL;',
        // PERF-P1-22 分类维度聚合/分类明细 watch。
        'CREATE INDEX IF NOT EXISTS idx_transactions_category_time '
            'ON transactions (category_id, happened_at DESC);',
        // 共享账本编辑器按 categorySyncIdOverride 反查;稀疏列部分索引。
        'CREATE INDEX IF NOT EXISTS idx_transactions_category_sync_override '
            'ON transactions (category_sync_id_override) '
            'WHERE category_sync_id_override IS NOT NULL;',
      ],
      'account_adjustments': [
        // 余额聚合按账户扫调整记录;列表按时间倒序。
        'CREATE INDEX IF NOT EXISTS idx_account_adjustments_account_time '
            'ON account_adjustments (account_id, happened_at DESC);',
        'CREATE INDEX IF NOT EXISTS idx_account_adjustments_ledger_time '
            'ON account_adjustments (ledger_id, happened_at DESC);',
        'CREATE INDEX IF NOT EXISTS idx_account_adjustments_sync_id '
            'ON account_adjustments (sync_id);',
      ],
      'local_changes': [
        // PERF-P1-12:push 前未推送变更按 (账本, pushed_at, id) 范围扫描;
        // recordPulledFromServer 幂等查重按 (entity_type, entity_sync_id)。
        'CREATE INDEX IF NOT EXISTS idx_local_changes_ledger_pushed '
            'ON local_changes (ledger_id, pushed_at, id);',
        'CREATE INDEX IF NOT EXISTS idx_local_changes_entity '
            'ON local_changes (entity_type, entity_sync_id);',
      ],
      'transaction_tags': [
        'CREATE INDEX IF NOT EXISTS idx_transaction_tags_transaction '
            'ON transaction_tags (transaction_id);',
        'CREATE INDEX IF NOT EXISTS idx_transaction_tags_tag '
            'ON transaction_tags (tag_id);',
        // v45(C3/F-29):同交易同标签只允许一行(批量路径曾不去重 →
        // getTagStats 的 INNER JOIN 把同一笔金额算成两倍)。
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_transaction_tags_pair '
            'ON transaction_tags (transaction_id, tag_id);',
      ],
      // C3/F-33:此前 byTable 里没有这张表 —— idx_rate_override_pair 是
      // 全库唯一真 UNIQUE 约束,却只在 onCreate/v28 分支建,丢失后不会自愈。
      'exchange_rate_overrides': [
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_override_pair '
            'ON exchange_rate_overrides (base_currency, quote_currency);',
      ],
      'transaction_attachments': [
        'CREATE INDEX IF NOT EXISTS idx_attachments_transaction '
            'ON transaction_attachments (transaction_id);',
        // PERF-P1-18:删除交易时按 file_name 反查待清理附件。
        'CREATE INDEX IF NOT EXISTS idx_attachments_file_name '
            'ON transaction_attachments (file_name);',
      ],
      'auto_book_events': [
        // 到期草稿 / 待重试事件扫描:where state = ? and next_retry_at <= ?。
        'CREATE INDEX IF NOT EXISTS idx_auto_book_state_retry '
            'ON auto_book_events (state, next_retry_at);',
        // PERF-P1-11 判重:external_id 点查(注意列可空,非唯一)。
        'CREATE INDEX IF NOT EXISTS idx_auto_book_external_id '
            'ON auto_book_events (external_id);',
        // 待确认队列按账本 + 状态过滤。
        'CREATE INDEX IF NOT EXISTS idx_auto_book_ledger_state '
            'ON auto_book_events (ledger_id, state);',
      ],
      'auto_book_event_items': [
        // 语义去重按 semanticKey 反查历史 item。
        'CREATE INDEX IF NOT EXISTS idx_auto_book_items_semantic '
            'ON auto_book_event_items (semantic_key);',
        // PERF-P1-11:按已入账 transaction 反查事件(判重豁免/撤销)。
        'CREATE INDEX IF NOT EXISTS idx_auto_book_items_transaction '
            'ON auto_book_event_items (transaction_id);',
      ],
      // 以下几张表的索引老版本只在 onUpgrade 分支里建过,新装缺失,一并收敛。
      'accounts': [
        'CREATE INDEX IF NOT EXISTS idx_accounts_sync_id '
            'ON accounts (sync_id);',
      ],
      'categories': [
        'CREATE INDEX IF NOT EXISTS idx_categories_sync_id '
            'ON categories (sync_id);',
        // PERF-P1-22:分类树按 parent_id 取子级。
        'CREATE INDEX IF NOT EXISTS idx_categories_parent '
            'ON categories (parent_id);',
      ],
      'tags': [
        'CREATE INDEX IF NOT EXISTS idx_tags_sync_id ON tags (sync_id);',
      ],
      'ledgers': [
        'CREATE INDEX IF NOT EXISTS idx_ledgers_sync_id ON ledgers (sync_id);',
      ],
      'budgets': [
        'CREATE INDEX IF NOT EXISTS idx_budgets_sync_id ON budgets (sync_id);',
        'CREATE INDEX IF NOT EXISTS idx_budgets_ledger ON budgets (ledger_id);',
        'CREATE INDEX IF NOT EXISTS idx_budgets_category '
            'ON budgets (category_id);',
        'CREATE INDEX IF NOT EXISTS idx_budgets_ledger_type '
            'ON budgets (ledger_id, type);',
      ],
      'messages': [
        // AI 会话内消息按会话 + 时间读取。
        'CREATE INDEX IF NOT EXISTS idx_messages_conversation_time '
            'ON messages (conversation_id, created_at);',
      ],
      'conversations': [
        'CREATE INDEX IF NOT EXISTS idx_conversations_updated '
            'ON conversations (updated_at);',
      ],
    };
    final rows =
        await customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get();
    final existing = rows.map((r) => r.read<String>('name')).toSet();
    final failed = <String>[];
    for (final entry in byTable.entries) {
      if (!existing.contains(entry.key)) continue;
      for (final sql in entry.value) {
        try {
          await customStatement(sql);
        } catch (e) {
          // 列缺失(历史半迁移库)等情况:跳过这一条,不影响其它索引和启动。
          failed.add('${entry.key}: $e');
        }
      }
    }
    // 只在有失败时打日志:_ensureIndexes 每次升级都会跑,成功是常态。
    if (failed.isNotEmpty) {
      logger.warning(
          'DBMigration', '部分索引未建立(不影响功能,仅影响查询速度)', failed.join('; '));
    }
    // 零风险快修:让优化器基于当前库的统计刷新执行计划(无统计时等价一次
    // 轻量 ANALYZE,只会分析近期变动的表),减少大账本下选错索引。
    try {
      await customStatement('PRAGMA optimize;');
    } catch (_) {
      // 纯调优语句,失败不致命。
    }
  }

  /// Migration helper: 列不存在再 ALTER ADD,避免 partial state 重跑时
  /// "duplicate column" 把启动卡死。
  ///
  /// SQLite DDL 隐式 commit 且不可回滚;上次 onUpgrade 跑到一半失败时,前面
  /// 已成功的 ALTER 已写入文件但 user_version 没更新,下次启动同一段重跑就
  /// 报 duplicate。每条 ALTER 都通过这里走 PRAGMA 检查可幂等。
  Future<void> _addColumnIfMissing(
      String table, String column, String ddl) async {
    final cols = await customSelect("PRAGMA table_info($table)").get();
    final exists = cols.any((r) => r.read<String>('name') == column);
    if (exists) {
      logger.info('DBMigration', '$table.$column 已存在,跳过 ALTER');
      return;
    }
    await customStatement(ddl);
  }

  /// Migration helper: 表不存在再 createTable,避免 partial state 重跑时
  /// "table already exists"。
  Future<void> _createTableIfMissing(
      Migrator m, String tableName, dynamic table) async {
    final row = await customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      variables: [Variable<String>(tableName)],
    ).getSingleOrNull();
    if (row != null) {
      logger.info('DBMigration', '$tableName 表已存在,跳过 createTable');
      return;
    }
    await m.createTable(table);
  }

  // ══════════════════════════════════════════════════════════════════════
  // v45 syncId 身份族迁移(批次 C3 / F-01..F-04、F-29、F-34)
  //
  // 设计要点(见 onUpgrade 内 v45 注释):
  //  1. fail-safe:每步独立 try/catch,绝不向 onUpgrade/beforeOpen 抛错;
  //  2. 幂等:全部 DDL 用 IF NOT EXISTS / DML 用「已处理则无操作」形态;
  //  3. 备份:`pre-v45-<ts>.json`,序列化前清洗非有限值,**内嵌去重计划**;
  //  4. 存量 Infinity/NaN 行清理(阻塞-7c);
  //  5. 唯一索引带 ledger 维度 UNIQUE(ledger_id, sync_id)(待确认产品决策);
  //  6. keeper 规则「最完整 → recorded_at 最新 → 引用最多 → id 最小」+ 字段级
  //     merge(只填空不覆盖)+ **全部交易引用表**改指 + local_changes.payload_json
  //     重写(缺陷 A/B/C,实现见 _v45BuildMergePlans / _v45DeduplicateTransactionSyncIds);
  //  7. 唯一索引自愈放 beforeOpen(缺陷 D):user_version 已是 45 后 onUpgrade
  //     永不再跑,「下次启动重试」只有每次打开都执行的钩子能兑现。
  // ══════════════════════════════════════════════════════════════════════

  /// 仅索引部分可回滚的 DROP 语句(数据去重部分不可回滚,见类注释)。
  /// 备份恢复:用 `pre-v45-<ts>.json` 快照重放(无自动 downgrade)。
  static const List<String> v45RollbackDropIndexesSql = [
    'DROP INDEX IF EXISTS idx_transactions_ledger_sync_id',
    'DROP INDEX IF EXISTS idx_transaction_tags_pair',
  ];

  /// v45 要保证存在的两条唯一索引(唯一且全部)。beforeOpen 自愈按此清单检查。
  static const List<String> _v45UniqueIndexNames = [
    'idx_transactions_ledger_sync_id',
    'idx_transaction_tags_pair',
  ];

  /// 测试用:覆盖 pre-v45 快照的输出目录(测试环境无 path_provider 插件)。
  /// 生产恒为 null → 走 `getApplicationDocumentsDirectory()/backups`。
  @visibleForTesting
  static String? v45BackupDirectoryOverrideForTesting;

  /// 去重时可从 loser 填进 keeper 的**可空业务列**(缺陷 B)。
  ///
  /// 只列可空列:NOT NULL 列(type / amount / happened_at / ledger_id / sync_id)
  /// 无法用「填空」语义表达,「保留哪一份」由 keeper 选择规则决定,不做字段级
  /// 覆盖(amount=0.0 之类的非空值不会被 loser 的非零值顶掉 —— 宁可保守)。
  /// 顺序即 merge 优先级:同一列多个 loser 都有值时取排在前面的 loser 的值
  /// (loser 之间按 keeper 规则同序,最早/最完整者优先)。
  ///
  /// **列级规则不是「有值就填」**(跨审缺陷 1a/1b):merge 只填空不覆盖,但
  /// 「空」不等于「任何 loser 的值都能放」。三个结构不变量在
  /// [_v45BuildMergePlans] 内按列判定,拒绝会造出结构上自相矛盾的行:
  ///
  ///  I1 **原子三元组 `(amount, currency_code, native_amount)`**:
  ///     账本维度统计一律读 `COALESCE(native_amount, amount)`
  ///     (local_statistics_repository.dart:42/78/167/272、
  ///     local_ledger_repository.dart:114),故 native 必须与 amount 同源。
  ///     `currency_code` / `native_amount` 只从 **amount 与 keeper 相等**的
  ///     loser 成对采纳;keeper 已有其一时,只接受与该值自洽的另一半。
  ///     反例(跨审探针):keeper(999,无币种,无折算)+ loser(10,USD,72) 旧实现
  ///     产出 (999,USD,72) → `SUM(COALESCE(native,amount))` = 72 而非 999。
  ///  I2 **自转账**:`account_id` 与 `to_account_id` 不得相等(UI 侧有守卫
  ///     transfer_form.dart:524,仓库层无)。且 `to_account_id` 只属于
  ///     `type='transfer'` 行 —— 非 transfer 行带上它会让两个余额 API 口径
  ///     分歧(getAccountBalance 的 `type='transfer'` 过滤 vs
  ///     getAccountBalanceInLedger 的裸 `to_account_id = ?` 命中)。
  ///     反例(跨审探针):keeper(transfer,account_id=5,to=NULL)+ loser(to=5)
  ///     → 合并行 account_id == to_account_id,两个余额 API 永久分歧。
  ///  I3 **本地 id 与 syncId override 互斥**:同一引用只有一种表示
  ///     (category/account/to_account 三对)。两者并存时同步侧读 override
  ///     (sync_engine_serialization.dart:191 等)、本地统计侧读 id
  ///     (local_statistics_repository 的 override 过滤) → 同一行两个口径。
  ///
  /// 被拒绝的 loser 值不算静默丢失:仍进 `discardedByLoser` 审计(快照可重放)。
  static const List<String> _v45MergeableTransactionColumns = [
    'recorded_at',
    'note',
    'category_id',
    'account_id',
    'to_account_id',
    'category_sync_id_override',
    'account_sync_id_override',
    'to_account_sync_id_override',
    'tag_sync_ids_override',
    'currency_code',
    'native_amount',
    'recurring_id',
    'created_by_user_id',
    'last_edited_by_user_id',
  ];

  /// 交易行的全部 int-id 引用列(缺陷 A)。枚举方法:遍历 db.dart 每个
  /// `Table` 类里的 IntColumn,凡语义为「本地 transactions 主键」者入下表
  /// (命名命中 `transactionId` / `duplicateOfTransactionId` / `transaction_id`
  /// / `duplicate_of_transaction_id`)。**共 6 列,分布在 4 张表**:
  /// transaction_tags / transaction_attachments / messages /
  /// auto_book_events(2 列)/ auto_book_event_items。
  ///
  /// JSON 内嵌的本地 int 引用(不在列清单里,由专用路径处理):
  ///   - `messages.metadata.txIds`(AI 卡片关联交易)和
  ///     `messages.metadata.undoneIds`(已撤销子集,`isUndone` 的判据)
  ///     → [_v45RewriteMessageTxIds];
  ///   - `local_changes.entity_id` + `local_changes.payload_json`
  ///     → 去重主体里的 entity_id 改指 + payload 按 keeper 终态重写。
  ///
  /// 未列入且**不需要**改指的引用(避免过度改写):
  ///   - `transaction_tag_overrides.transaction_sync_id`:存 syncId 字符串,
  ///     去重后 syncId 不变,无需改;
  ///   - `deleted_transactions.sync_id` / `payload_json`:存 syncId,同上;
  ///   - `auto_book_*.bill_json` 里的 `external_id`/`transaction_id` 键:那是
  ///     **来源侧**(短信/通知)的商户单号,不是本地 int 主键(见 bill_info.dart
  ///     的 externalId 解析),改指会破坏跨渠道判重。
  static const List<({String table, String column})>
      _v45TransactionIdReferenceColumns = [
    (table: 'transaction_tags', column: 'transaction_id'),
    (table: 'transaction_attachments', column: 'transaction_id'),
    (table: 'messages', column: 'transaction_id'),
    (table: 'auto_book_events', column: 'transaction_id'),
    (table: 'auto_book_events', column: 'duplicate_of_transaction_id'),
    (table: 'auto_book_event_items', column: 'transaction_id'),
  ];

  /// v45 主流程。每步独立 best-effort,绝不抛错。
  Future<void> _v45SyncIdIdentityMigration() async {
    logger.info('DBMigration', '开始 v45: syncId 唯一索引 / 关联表唯一 / 脏值清洗');

    // ── 步骤 1:先算去重计划(只读) ──
    // 备份必须记录「keeper 是谁、合并了什么、丢弃了什么」(缺陷 B 要求不静默
    // 丢失),所以计划先于备份生成,备份内嵌同一份计划,执行阶段按它落地。
    final plans = await _v45BuildMergePlans();

    // ── 步骤 2:备份(导出前清洗非有限值,失败只告警不中止) ──
    await _v45ExportBackupBestEffort(plans);

    // ── 步骤 3:存量非有限金额清洗(阻塞-7c) ──
    // NaN/±Infinity 会让所有聚合入口返回 Infinity/NaN(整账本统计不可用),
    // 且会让 JSON 备份序列化失败。归零 + 记录数量(不删行,保住账目)。
    await _v45SanitizeNonFiniteAmounts();

    // ── 步骤 4:重复 syncId 去重(按计划执行) ──
    await _v45DeduplicateTransactionSyncIds(plans: plans);

    // ── 步骤 5:transaction_tags 去重 + 唯一索引 ──
    await _v45AddTransactionTagsUnique();

    // ── 步骤 6:唯一索引(带账本维度) ──
    await _v45AddTransactionSyncIdUnique();

    logger.info('DBMigration', 'v45 迁移完成');
  }

  /// v45 唯一索引自愈(缺陷 D)。**在 beforeOpen 里跑** —— onUpgrade 只在
  /// `versionBefore < versionNow` 时执行,`user_version` 一旦是 45(哪怕索引
  /// 因残余重复没建起来),`_v45AddTransactionSyncIdUnique` 里「下次启动重试」
  /// 的注释永远等不到下一次(onUpgrade 不再运行,实测连开 3 次仍
  /// uniqueIndex=0 / dupRows=2 / userVersion=45 → 重复行永久不解、
  /// `getTransactionBySyncId` 永久不可靠)。
  ///
  /// 开销:先做**常数级检查**(两条唯一索引是否都在 sqlite_master),都在就
  /// 直接返回 —— 正常打开零额外读写。只有缺失时才进修复路径(再备一次份 +
  /// 去重 + 建索引),整段 best-effort,绝不抛错(beforeOpen 抛错 = 库打不开)。
  Future<void> _v45RepairUniqueIndexesIfNeeded() async {
    try {
      final missing = <String>[];
      for (final name in _v45UniqueIndexNames) {
        final row = await customSelect(
          "SELECT name FROM sqlite_master WHERE type='index' AND name = ?",
          variables: [Variable<String>(name)],
        ).getSingleOrNull();
        if (row == null) missing.add(name);
      }
      if (missing.isEmpty) return; // 常态路径:两条索引都在,零额外工作

      // 表不存在(极老/损坏库)→ 直接返回;缺表时补索引只会抛错。
      final hasTx = await customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'transactions'",
      ).getSingleOrNull();
      if (hasTx == null) return;

      logger.warning('DBMigration',
          'v45 唯一索引缺失(${missing.join(", ")}),启动期自愈:去重 + 重建索引');
      final plans = await _v45BuildMergePlans();
      await _v45ExportBackupBestEffort(plans);
      await _v45SanitizeNonFiniteAmounts();
      await _v45DeduplicateTransactionSyncIds(plans: plans);
      await _v45AddTransactionTagsUnique();
      await _v45AddTransactionSyncIdUnique();
    } catch (e, st) {
      // 自愈失败只告警:下次打开还会再试(索引仍缺失 → 检查仍会命中)。
      logger.warning('DBMigration', 'v45 唯一索引自愈失败(不阻断启动): $e', st);
    }
  }

  /// 导出 `pre-v45-<ts>.json` 快照。**绝不抛错**(备份失败不能阻断迁移/启动)。
  ///
  /// 清洗口径:非有限金额写 null + `<col>Unrepresentable: true`,其余非有限
  /// 数值字段一并清洗,保证 jsonEncode 不会抛(阻塞-7b)。
  ///
  /// 快照同时内嵌 [plans]:每条重复的「keeper 是谁、delete 哪些行、从 loser
  /// 合并了哪些字段值、丢弃了 loser 的哪些字段值」—— 去重不可逆,没有这份
  /// 记录就只能靠猜(缺陷 B 的「不得静默丢失」)。
  Future<void> _v45ExportBackupBestEffort(List<_V45MergePlan> plans) async {
    try {
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final doc = <String, dynamic>{
        'format': 'smartbook-pre-migration-snapshot',
        'version': 2,
        'reason': 'v45 syncId-unique migration',
        'exportedAt': DateTime.now().toIso8601String(),
        // 回滚必须依赖本快照:去重/清洗是破坏性且不可逆的(阻塞-7a)。
        'rollbackNote': 'v45 合并重复 syncId 行与清洗非有限金额不可逆;'
            '回滚需按本快照重放。仅索引部分可用 DROP INDEX 回滚'
            '(见 BeeDatabase.v45RollbackDropIndexesSql)。',
        // 去重计划与执行结果分开:plans 是「将要做什么」,执行日志另见
        // logger;两者字段一致,便于把快照当重放脚本用。
        'dedupePlans': [for (final plan in plans) plan.toJson()],
        'ledgers': await _v45RowsToJson('SELECT * FROM ledgers'),
        'accounts': await _v45RowsToJson('SELECT * FROM accounts'),
        'categories': await _v45RowsToJson('SELECT * FROM categories'),
        'transactions': await _v45RowsToJson('SELECT * FROM transactions'),
        'transaction_tags':
            await _v45RowsToJson('SELECT * FROM transaction_tags'),
        'transaction_attachments':
            await _v45RowsToJson('SELECT * FROM transaction_attachments'),
        'budgets': await _v45RowsToJson('SELECT * FROM budgets'),
        'account_adjustments':
            await _v45RowsToJson('SELECT * FROM account_adjustments'),
        'deleted_transactions':
            await _v45RowsToJson('SELECT * FROM deleted_transactions'),
        // 交易引用表的完整快照(缺陷 A 涉及的表在恢复重放时都要一起还原)。
        'messages': await _v45RowsToJson('SELECT * FROM messages'),
        'auto_book_events':
            await _v45RowsToJson('SELECT * FROM auto_book_events'),
        'auto_book_event_items':
            await _v45RowsToJson('SELECT * FROM auto_book_event_items'),
        'local_changes': await _v45RowsToJson('SELECT * FROM local_changes'),
      };
      final raw = jsonEncode(doc);
      final overrideDir = v45BackupDirectoryOverrideForTesting;
      final outDir = overrideDir != null
          ? Directory(overrideDir)
          : Directory(
              p.join((await getApplicationDocumentsDirectory()).path, 'backups'));
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      final file = File(p.join(outDir.path, 'pre-v45-$ts.json'));
      await file.writeAsString(raw);
      logger.info('DBMigration', 'v45 备份已导出: ${file.path}');
    } catch (e, st) {
      // 关键:必须吞掉异常。onUpgrade 抛错 = user_version 不更新 + 库可能
      // 永久打不开(见 v24 段注释里的 3.2.0 事故)。
      logger.warning('DBMigration', 'v45 备份导出失败(不阻断迁移): $e', st);
    }
  }

  /// 读表并转 json-ready 结构;所有非有限数值 → null(+ 标记)。
  Future<List<Map<String, dynamic>>> _v45RowsToJson(String sql) async {
    try {
      final rows = await customSelect(sql).get();
      return rows.map((r) {
        final out = <String, dynamic>{};
        r.data.forEach((k, v) {
          if (v is double && !v.isFinite) {
            out[k] = null;
            out['${k}Unrepresentable'] = true;
          } else {
            out[k] = v;
          }
        });
        return out;
      }).toList();
    } catch (e) {
      logger.warning('DBMigration', 'v45 备份读取失败($sql): $e');
      return const [];
    }
  }

  /// 存量 NaN/±Infinity 金额归零(NOT NULL 列不能用 NULL;0.0 安全)。
  /// 同时覆盖 native_amount。幂等:第二次跑没有非有限值可改。
  Future<void> _v45SanitizeNonFiniteAmounts() async {
    try {
      final cols = await customSelect('PRAGMA table_info(transactions)').get();
      if (cols.isEmpty) return; // 表不存在(极老库),跳过
      // SQLite 里 NaN 存成 NULL(被 NOT NULL 拦下),Infinity 以 REAL 落库。
      // 用 `amount > maxFinite` 判定溢出即等价于 ±Infinity。
      const maxFinite = 1.7976931348623157e308;
      final rows = await customSelect(
        'SELECT id FROM transactions '
        'WHERE (amount IS NOT NULL AND (amount > $maxFinite OR amount < -$maxFinite))',
      ).get();
      var fixed = 0;
      for (final r in rows) {
        final id = r.read<int>('id');
        await customStatement(
            'UPDATE transactions SET amount = 0.0 WHERE id = ?', [id]);
        fixed++;
      }
      final hasNative =
          cols.any((row) => row.read<String>('name') == 'native_amount');
      if (hasNative) {
        final nRows = await customSelect(
          'SELECT id FROM transactions WHERE native_amount IS NOT NULL '
          'AND (native_amount > $maxFinite OR native_amount < -$maxFinite)',
        ).get();
        for (final r in nRows) {
          final id = r.read<int>('id');
          await customStatement(
            'UPDATE transactions SET native_amount = NULL WHERE id = ?', [id]);
          fixed++;
        }
      }
      if (fixed > 0) {
        logger.warning('DBMigration',
            'v45 清洗 $fixed 个非有限金额(NaN/Infinity → 0/null);原值已存 pre-v45 快照');
      }
    } catch (e, st) {
      logger.warning('DBMigration', 'v45 非有限金额清洗失败(跳过): $e', st);
    }
  }

  /// 只读扫描:找出全部重复 (ledger_id, sync_id) 组,选出 keeper,算出
  /// 字段级 merge 计划。**不改任何数据**(备份以它为依据)。
  ///
  /// 幂等性:同库同状态下重复调用返回同一计划(排序确定:
  /// completeness DESC, recorded_at DESC, refcount DESC, id ASC)。
  Future<List<_V45MergePlan>> _v45BuildMergePlans() async {
    final plans = <_V45MergePlan>[];
    try {
      final dupGroups = await customSelect(
        '''
        SELECT ledger_id, sync_id, COUNT(*) AS c
        FROM transactions
        WHERE sync_id IS NOT NULL AND sync_id <> ''
        GROUP BY ledger_id, sync_id
        HAVING c > 1
        ''',
      ).get();
      if (dupGroups.isEmpty) return plans;

      // 可空业务列:用于 completeness 打分 + 字段级 merge。
      final mergeCols = _v45MergeableTransactionColumns;
      final completenessExpr =
          mergeCols.map((c) => '($c IS NOT NULL)').join(' + ');

      for (final g in dupGroups) {
        final ledgerId = g.read<int>('ledger_id');
        final syncId = g.read<String>('sync_id');
        final rows = await customSelect(
          '''
          SELECT t.id,
                 t.recorded_at,
                 t.type,
                 t.amount,
                 t.happened_at,
                 $completenessExpr AS completeness,
                 ${mergeCols.join(", ")},
                 (SELECT COUNT(*) FROM transaction_tags tt WHERE tt.transaction_id = t.id)
               + (SELECT COUNT(*) FROM transaction_attachments ta WHERE ta.transaction_id = t.id)
                 AS refcount
          FROM transactions t
          WHERE t.ledger_id = ? AND t.sync_id = ?
          ORDER BY completeness DESC, t.recorded_at DESC, refcount DESC, t.id ASC
          ''',
          variables: [Variable<int>(ledgerId), Variable<String>(syncId)],
        ).get();
        if (rows.length < 2) continue;

        final keeper = rows.first;
        final keeperId = keeper.read<int>('id');
        final losers = rows.skip(1).toList(growable: false);
        final loserIds =
            losers.map((r) => r.read<int>('id')).toList(growable: false);

        // 字段级 merge 计划:keeper 为 NULL 且 loser 有非 NULL 的列 → 取第一个
        // 有值的 loser(loser 顺序 = keeper 同序 = 最完整者优先)。keeper 非 NULL
        // 的列永不被覆盖;无 loser 有值的列不进计划。
        //
        // 非有限值(NaN/±Infinity)不参与 merge:① 它是 F-13 的脏数据,
        // `_v45SanitizeNonFiniteAmounts` 会先把它归零/置 NULL,若在这里把它带进
        // keeper 的 NULL 列,等于在清洗之后又把 Infinity 写回库;② jsonEncode
        // 无法序列化 Infinity,会击穿备份(阻塞-7b)。
        //
        // **结构不变量闸门**(跨审缺陷 1a/1b):「填空」不是「有值就填」。
        // 三个不变量(规则全文见 [_v45MergeableTransactionColumns] 的 I1/I2/I3):
        //   I1 (amount, currency_code, native_amount) 原子三元组 —— 币种/折算
        //      只从 amount 与 keeper 相等的 loser 采纳,且两者同源同一 loser;
        //   I2 自转账禁止(account_id == to_account_id),to_account_* 仅属
        //      transfer 行;
        //   I3 本地 id 与 syncId override 互斥(同一引用只能有一种表示)。
        // 被闸门拒绝的候选值不算静默丢失:仍进 refusedByInvariant +
        // discardedByLoser 审计(快照可读、可重放)。
        final mergedValues = <String, Object?>{};
        final refusedByInvariant = <Map<String, Object?>>[];

        // 非有限值不参与 merge(清洗后也不回写)。
        bool acceptable(Object? v) => !(v is double && !v.isFinite);

        // 第一个「有该列非 NULL 有限值」的 loser(loser 顺序 = 最完整者优先)。
        ({int loserId, Object value})? firstLoser(String col) {
          for (final loser in losers) {
            final v = loser.data[col];
            if (v == null || !acceptable(v)) continue;
            return (loserId: loser.read<int>('id'), value: v);
          }
          return null;
        }

        void refuse(int loserId, String col, Object? value, String rule) {
          refusedByInvariant.add({
            'loserId': loserId,
            'column': col,
            'value': _v45JsonSafeValue(value),
            'rule': rule,
          });
        }

        // ── I1:(amount, currency_code, native_amount) 原子三元组 ──
        // amount 是 NOT NULL 列,keeper 规则决定保留哪一份,**永不从 loser 取**,
        // 故三元组的唯一合法来源是「amount == keeper.amount」的 loser:金额不同
        // 的 loser 的币种/折算属于另一个金额,填进来会造出 (999, USD, 72) ——
        // 账本统计 `SUM(COALESCE(native_amount, amount))` 静默返回 72 而非 999。
        // 为避免「币种来自 A、折算来自 B」的缝合,两者取**同一个** loser。
        final keeperAmount = (keeper.data['amount'] as num).toDouble();
        ({int loserId, String? currency, double? native})? tripleSrc;
        for (final loser in losers) {
          final la = loser.data['amount'];
          if (la is! num || la.toDouble() != keeperAmount) {
            // 金额不同的 loser:其币种/折算永不采纳(记录原因,便于诊断统计错值来源)。
            for (final col in const ['currency_code', 'native_amount']) {
              final v = loser.data[col];
              if (v != null && acceptable(v)) {
                refuse(loser.read<int>('id'), col, v, 'I1-amount-mismatch');
              }
            }
            continue;
          }
          final cur = loser.data['currency_code'];
          final nat = loser.data['native_amount'];
          final hasCur = cur is String && cur.isNotEmpty && acceptable(cur);
          final hasNat = nat is num && acceptable(nat);
          if (!hasCur && !hasNat) continue;
          tripleSrc = (
            loserId: loser.read<int>('id'),
            currency: hasCur ? cur : null,
            native: hasNat ? nat.toDouble() : null,
          );
          break; // 只认第一个同金额来源,不跨 loser 缝合
        }
        if (tripleSrc != null) {
          final keeperCurrency = keeper.data['currency_code'];
          final keeperNative = keeper.data['native_amount'];
          if (keeperCurrency == null && tripleSrc.currency != null) {
            mergedValues['currency_code'] = tripleSrc.currency;
          }
          if (keeperNative == null && tripleSrc.native != null) {
            mergedValues['native_amount'] = tripleSrc.native;
          }
        }

        // ── I3:引用对(本地 id ↔ syncId override)互斥 ──
        // 同一引用只能有一种表示:同步侧读 override
        // (sync_engine_serialization.dart:191 等),本地统计/余额侧读 id
        // (local_statistics_repository 的 override 过滤)—— 两者并存时同一行
        // 有两个口径。冲突取舍(确定性):keeper 自有值优先;两侧都来自 loser
        // 时保留本地 id(主表示),override 记入 refusedByInvariant。
        //
        // 返回该对的最终值(含 keeper 自有 + loser 填充)+ 值来源 loser id
        // (0 = 来自 keeper 自有值),供 I2 的账户/转入账户交叉判定使用。
        ({
          int? id,
          String? override,
          int? idFromLoser,
          int? overrideFromLoser,
        }) mergeReferencePair({
          required String idCol,
          required String overrideCol,
        }) {
          final keeperIdVal = keeper.data[idCol] as int?;
          final keeperOvVal = keeper.data[overrideCol] as String?;
          final idPick = keeperIdVal == null ? firstLoser(idCol) : null;
          final ovPick = keeperOvVal == null ? firstLoser(overrideCol) : null;
          int? finalId = keeperIdVal;
          String? finalOv = keeperOvVal;
          if (finalId != null) {
            // 已有本地 id → override 只能被拒(双表示)。
            if (ovPick != null) {
              refuse(ovPick.loserId, overrideCol, ovPick.value,
                  'I3-dual-representation');
            }
          } else if (finalOv != null) {
            // 已有 override → 不再填 id(会造出双表示)。
            if (idPick != null) {
              refuse(idPick.loserId, idCol, idPick.value,
                  'I3-dual-representation');
            }
          } else if (idPick != null) {
            // 两者都空:优先本地 id(主表示),override 让位。
            finalId = idPick.value as int;
            if (ovPick != null) {
              refuse(ovPick.loserId, overrideCol, ovPick.value,
                  'I3-dual-representation');
            }
          } else if (ovPick != null) {
            finalOv = ovPick.value as String;
          }
          if (finalId != null && keeperIdVal == null) {
            mergedValues[idCol] = finalId;
          }
          if (finalOv != null && keeperOvVal == null) {
            mergedValues[overrideCol] = finalOv;
          }
          return (
            id: finalId,
            override: finalOv,
            idFromLoser: keeperIdVal == null && finalId != null
                ? (idPick?.loserId ?? 0)
                : null,
            overrideFromLoser: keeperOvVal == null && finalOv != null
                ? (ovPick?.loserId ?? 0)
                : null,
          );
        }

        mergeReferencePair(
            idCol: 'category_id', overrideCol: 'category_sync_id_override');

        // ── I2 + I3:账户引用对(account_id ↔ account_sync_id_override) ──
        final accountPair = mergeReferencePair(
            idCol: 'account_id', overrideCol: 'account_sync_id_override');

        // ── I2 + I3:转入账户引用对(to_account_id ↔ to_account_sync_id_override) ──
        // I2 附加闸门:
        //  ① `to_account_*` 只属于 transfer 行 —— 非 transfer 行带转入引用会让
        //     两个余额 API 永久分歧(getAccountBalance 过滤 `type='transfer'`,
        //     getAccountBalanceInLedger 是裸 `to_account_id = ?` 命中);
        //  ② 填入后不得与最终 account_id / account_sync_id_override 指向**同一
        //     账户**(自转账)。比较按账户身份,不按表示:id↔id、override↔override
        //     以及 id↔override(反查 accounts.sync_id)都算同一账户。UI 侧有守卫
        //     (transfer_form.dart:524),仓库层此前没有 —— 跨审探针
        //     keeper(transfer, account_id=5, to=NULL)+ loser(to=5) 会合并出
        //     account_id == to_account_id,getAccountBalance 与
        //     getAccountBalanceInLedger 从此永久分歧。
        {
          final isTransfer = keeper.data['type'] == 'transfer';
          final finalAccountId = accountPair.id;
          final finalAccountOv = accountPair.override;
          var finalToId = keeper.data['to_account_id'];
          var finalToOv = keeper.data['to_account_sync_id_override'];
          final toIdPick =
              finalToId == null ? firstLoser('to_account_id') : null;
          final toOvPick = finalToOv == null
              ? firstLoser('to_account_sync_id_override')
              : null;

          // 账户身份:id → syncId 反查,用于跨表示比较(缓存,每计划最多 2 次)。
          // best-effort:极老/半迁移库没有 accounts 表时返回 null(退化为
          // 「无法跨表示判定」),不让一次查表失败把整批合并计划清空。
          final syncIdById = <int, String?>{};
          Future<String?> syncIdOf(int? id) async {
            if (id == null) return null;
            if (syncIdById.containsKey(id)) return syncIdById[id];
            String? s;
            try {
              final row = await customSelect(
                'SELECT sync_id FROM accounts WHERE id = ?',
                variables: [Variable<int>(id)],
              ).getSingleOrNull();
              s = row?.readNullable<String>('sync_id');
            } catch (_) {
              s = null;
            }
            return syncIdById[id] = (s == null || s.isEmpty) ? null : s;
          }

          /// 两个引用是否指向同一账户(id 相等 / syncId 相等 / 交叉解析相等)。
          Future<bool> sameAccount(
              int? aId, String? aOv, int? bId, String? bOv) async {
            if (aId != null && bId != null && aId == bId) return true;
            if (aOv != null && bOv != null && aOv == bOv) return true;
            if (aId != null && bOv != null && await syncIdOf(aId) == bOv) {
              return true;
            }
            if (bId != null && aOv != null && await syncIdOf(bId) == aOv) {
              return true;
            }
            return false;
          }

          if (!isTransfer) {
            // 非 transfer:拒绝全部转入引用填充(记录原因,值仍进 discarded)。
            if (toIdPick != null) {
              refuse(toIdPick.loserId, 'to_account_id', toIdPick.value,
                  'I2-non-transfer');
            }
            if (toOvPick != null) {
              refuse(toOvPick.loserId, 'to_account_sync_id_override',
                  toOvPick.value, 'I2-non-transfer');
            }
          } else if (finalToId != null || finalToOv != null) {
            // keeper 已有转入表示:另一种表示一律拒绝(I3 双表示)。
            if (toIdPick != null) {
              refuse(toIdPick.loserId, 'to_account_id', toIdPick.value,
                  'I3-dual-representation');
            }
            if (toOvPick != null) {
              refuse(toOvPick.loserId, 'to_account_sync_id_override',
                  toOvPick.value, 'I3-dual-representation');
            }
          } else if (toIdPick != null) {
            // 两者都空:优先本地 id(主表示)。
            if (await sameAccount(
                finalAccountId, finalAccountOv, toIdPick.value as int?, null)) {
              refuse(toIdPick.loserId, 'to_account_id', toIdPick.value,
                  'I2-self-transfer');
              // id 被拒后才考虑 override(仍是同一账户则一并拒)。
              if (toOvPick != null) {
                if (await sameAccount(finalAccountId, finalAccountOv, null,
                    toOvPick.value as String?)) {
                  refuse(toOvPick.loserId, 'to_account_sync_id_override',
                      toOvPick.value, 'I2-self-transfer');
                } else {
                  finalToOv = toOvPick.value;
                }
              }
            } else {
              finalToId = toIdPick.value;
              if (toOvPick != null) {
                refuse(toOvPick.loserId, 'to_account_sync_id_override',
                    toOvPick.value, 'I3-dual-representation');
              }
            }
          } else if (toOvPick != null) {
            if (await sameAccount(finalAccountId, finalAccountOv, null,
                toOvPick.value as String?)) {
              refuse(toOvPick.loserId, 'to_account_sync_id_override',
                  toOvPick.value, 'I2-self-transfer');
            } else {
              finalToOv = toOvPick.value;
            }
          }

          if (finalToId != null && keeper.data['to_account_id'] == null) {
            mergedValues['to_account_id'] = finalToId;
          }
          if (finalToOv != null &&
              keeper.data['to_account_sync_id_override'] == null) {
            mergedValues['to_account_sync_id_override'] = finalToOv;
          }

          // ── I2 反向交叉检查 ──
          // 上面的闸门只覆盖「转入引用被填入」的方向。反向同样会造出自转账:
          // keeper 自带 to_account_id=5,而**账户侧**从 loser 填进 account_id=5
          // (或 account_sync_id_override 指向 ACC-5)。此时转出/转入同一账户,
          // 两个余额 API 分歧。检测到即撤回账户侧的 loser 填充。
          if (isTransfer &&
              finalToId != null &&
              (accountPair.idFromLoser != null ||
                  accountPair.overrideFromLoser != null) &&
              await sameAccount(
                  accountPair.id, accountPair.override, finalToId, finalToOv)) {
            if (accountPair.idFromLoser != null && accountPair.id != null) {
              mergedValues.remove('account_id');
              refuse(accountPair.idFromLoser!, 'account_id', accountPair.id,
                  'I2-self-transfer');
            }
            if (accountPair.overrideFromLoser != null &&
                accountPair.override != null) {
              mergedValues.remove('account_sync_id_override');
              refuse(accountPair.overrideFromLoser!, 'account_sync_id_override',
                  accountPair.override, 'I2-self-transfer');
            }
          }
        }

        // ── 其余可空列:无结构耦合,原「填空」语义照旧 ──
        const invariantManaged = <String>{
          'currency_code',
          'native_amount',
          'category_id',
          'category_sync_id_override',
          'account_id',
          'account_sync_id_override',
          'to_account_id',
          'to_account_sync_id_override',
        };
        for (final col in mergeCols) {
          if (invariantManaged.contains(col)) continue;
          if (keeper.data[col] != null) continue; // 不覆盖 keeper 的非空值
          final pick = firstLoser(col);
          if (pick != null) mergedValues[col] = pick.value;
        }

        // 丢弃审计:随 loser 行删除而消失、且**没有**被 merge 采纳的值。
        // 结构:{loserId: {column: value}} —— 快照可读、可重放。
        final discarded = <int, Map<String, Object?>>{};
        for (final loser in losers) {
          final loserId = loser.read<int>('id');
          final perRow = <String, Object?>{};
          for (final col in mergeCols) {
            final lv = loser.data[col];
            if (lv == null) continue;
            final kv = keeper.data[col];
            if (kv == lv) continue; // 值相同,无损失
            if (kv == null && mergedValues[col] == lv) continue; // 已被采纳
            perRow[col] = _v45JsonSafeValue(lv);
          }
          // NOT NULL 业务列:与 keeper 不同即被丢弃(不做字段级 merge,
          // 避免「金额来自 A、备注来自 B」的缝合行)。
          for (final col in const ['type', 'amount', 'happened_at', 'ledger_id']) {
            final lv = loser.data[col];
            final kv = keeper.data[col];
            if (lv == null) continue;
            if (kv == lv) continue;
            perRow[col] = _v45JsonSafeValue(lv);
          }
          if (perRow.isNotEmpty) discarded[loserId] = perRow;
        }

        plans.add(_V45MergePlan(
          ledgerId: ledgerId,
          syncId: syncId,
          keeperId: keeperId,
          loserIds: loserIds,
          keeperCompleteness: keeper.read<int>('completeness'),
          mergedValues: mergedValues,
          discardedByLoser: discarded,
          refusedByInvariant: refusedByInvariant,
        ));
      }
    } catch (e, st) {
      // 计划失败 → 空计划(去重跳过);唯一索引失败后由 beforeOpen 自愈重试。
      logger.warning('DBMigration', 'v45 去重计划生成失败(跳过去重): $e', st);
      return const [];
    }
    return plans;
  }

  /// 重复 (ledger_id, sync_id) 去重(缺陷 A/B/C 的修复主体)。
  ///
  /// **keeper 选择规则**(缺陷 B,「最完整 → 最新 → 引用最多 → 最早」):
  ///  1. 业务字段非 NULL 数**多**者为 keeper(空行不该赢过有数据的行);
  ///  2. 平手比 `recorded_at`(server 首次落库时刻)**新**者;
  ///  3. 再平手比引用数(transaction_tags + transaction_attachments)多者
  ///     (保留引用多的行,减少改指面);
  ///  4. 再平手取 `id` **小**者(最早,确定性收尾)。
  ///
  /// **字段级 merge**(只填空、不覆盖):
  ///  - loser 的非 NULL 值填进 keeper 的 NULL 列,列清单见
  ///    [_v45MergeableTransactionColumns];keeper 已有非 NULL 值永不被覆盖;
  ///  - NOT NULL 列(type/amount/happened_at/ledger_id/sync_id)不做字段级
  ///    merge —— 由 keeper 选择规则决定保留哪一份,避免「金额一半来自 A、
  ///    一半来自 B」的缝合行(记录在快照 discarded 里)。
  ///
  /// **引用改指**(缺陷 A):[_v45TransactionIdReferenceColumns] 里**全部**表/
  /// 列改指 keeper(先按 keeper 已有的业务键去重,避免改指后撞唯一约束)。
  /// 旧实现只处理 transaction_tags / transaction_attachments,让
  /// messages.transactionId / auto_book_events.transactionId /
  /// auto_book_events.duplicateOfTransactionId /
  /// auto_book_event_items.transactionId 指向被删行 —— 且这四张表**不在**
  /// OrphanScanner 的 16 条规则里,损坏永久不可见。
  ///
  /// **local_changes.payload_json 重写**(缺陷 C):entity_id 改指 keeper 后,
  /// payload 里嵌的旧快照仍带 loser 的值/`id`,使同一行自相矛盾
  /// (`entity_id=1` + `payload_json={"id":2,...}`);ChangeTracker 已预留
  /// payload 参数,是潜在的错值推送源。这里按 keeper 合并后的最终行重写。
  ///
  /// 幂等:第二次跑没有重复对可合并;所有 DML 都以「已处理则无操作」形态写。
  Future<void> _v45DeduplicateTransactionSyncIds({
    required List<_V45MergePlan> plans,
  }) async {
    if (plans.isEmpty) {
      logger.info('DBMigration', 'v45 无重复 syncId,跳过去重');
      return;
    }
    try {
      var mergedRows = 0;
      // 引用表存在性(半迁移库/极老库可能还没建 messages/auto_book_* 表)。
      // 缺表时跳过该表的改指,而不是让一条 "no such table" 中止整组去重
      // (中止会留下「部分计划已执行」的中间态;虽然 beforeOpen 会自愈重试,
      // 少一次来回更好)。
      final existingTables = await _v45ExistingTables([
        ..._v45TransactionIdReferenceColumns.map((r) => r.table),
        'messages',
      ]);
      for (final plan in plans) {
        final keeperId = plan.keeperId;
        final dupIds = plan.loserIds;
        if (dupIds.isEmpty) continue;
        // 幂等守卫:keeper 已被之前的运行删掉(不可能,防御)→ 跳过该计划。
        final keeperAlive = await customSelect(
          'SELECT id FROM transactions WHERE id = ?',
          variables: [Variable<int>(keeperId)],
        ).getSingleOrNull();
        if (keeperAlive == null) continue;

        // ① 字段级 merge:只填 keeper 的 NULL 列,不覆盖非 NULL。
        //
        // 注意 `customStatement` 的第二参是**裸值**列表(不是 drift 的
        // Variable 表达式;传 Variable 会被 sqlite3 驱动拒绝:
        // "Allowed parameters must either be null or bool, int, num, String")。
        if (plan.mergedValues.isNotEmpty) {
          final sets = <String>[];
          final args = <Object?>[];
          plan.mergedValues.forEach((column, value) {
            sets.add('$column = ?');
            args.add(value);
          });
          await customStatement(
            'UPDATE transactions SET ${sets.join(", ")} '
            'WHERE id = ? AND ${plan.mergedValues.keys.map((c) => "$c IS NULL").join(" AND ")}',
            [...args, keeperId],
          );
        }

        for (final dupId in dupIds) {
          // ② 全部引用表改指 keeper。先删「改指后会重键」的副本行:
          //    - transaction_tags / transaction_attachments:keeper 已有同业务键
          //      → 删 loser 行(改指会造成重复关联/重复附件);
          //    - 其余引用列(messages/auto_book_*):同一行只指向一笔交易,
          //      改指即可,没有重键问题。
          for (final ref in _v45TransactionIdReferenceColumns) {
            if (!existingTables.contains(ref.table)) continue;
            if (ref.table == 'transaction_tags') {
              await customStatement(
                'DELETE FROM transaction_tags WHERE ${ref.column} = ? '
                'AND tag_id IN (SELECT tag_id FROM transaction_tags '
                'WHERE ${ref.column} = ?)',
                [dupId, keeperId],
              );
            } else if (ref.table == 'transaction_attachments') {
              await customStatement(
                'DELETE FROM transaction_attachments WHERE ${ref.column} = ? '
                'AND file_name IN (SELECT file_name FROM transaction_attachments '
                'WHERE ${ref.column} = ?)',
                [dupId, keeperId],
              );
            }
            await customStatement(
              'UPDATE ${ref.table} SET ${ref.column} = ? WHERE ${ref.column} = ?',
              [keeperId, dupId],
            );
          }

          mergedRows++;
        }

        // ③ local_changes:整组 entity_id 改指 keeper,payload_json 重写为 keeper
        //    合并后的最终行(缺陷 C)。payload 是「变更后的完整 JSON」,保持与
        //    entity_id 自洽;旧实现只改 entity_id,payload 里还嵌着 loser 的
        //    `{"id":<loser>,...}` 快照。
        //
        //    作用域带 ledger_id:唯一索引是 UNIQUE(ledger_id, sync_id),跨账本
        //    同 syncId 合法 —— 不加账本过滤会误改另一个账本的同名 change。
        await customStatement(
          'UPDATE local_changes SET entity_id = ?, payload_json = ? '
          "WHERE entity_type = 'transaction' AND entity_sync_id = ? "
          'AND ledger_id = ?',
          [
            keeperId,
            jsonEncode(await _v45KeeperPayloadJson(keeperId)),
            plan.syncId,
            plan.ledgerId,
          ],
        );

        // ④ messages.metadata 内嵌的 "txIds" / "undoneIds" 数组(缺陷 A 的
        //    JSON 内嵌引用)。AI 账单卡片的撤销/编辑/改账本按钮全部读它
        //    (`ai_chat_page.dart` 的 `_parseBillMetadata`),只改
        //    `messages.transaction_id` 会让卡片按钮仍指向被删行 —— 点撤销删不到
        //    东西;`undoneIds` 是 txIds 的子集、决定卡片是否已置灰
        //    (`isUndone`),漏改会让已撤销的卡片复活成「可撤销」。
        //    两个数组都替换 loser id → keeper id,并去重。
        if (existingTables.contains('messages')) {
          await _v45RewriteMessageTxIds(
              dupIds: dupIds, keeperId: keeperId);
        }

        await customStatement(
          'DELETE FROM transactions WHERE id IN (${dupIds.join(",")})',
        );
        logger.warning('DBMigration',
            'v45 合并重复 syncId=${plan.syncId}(ledger=${plan.ledgerId}): '
            'keeper=$keeperId, 删 ${dupIds.length} 行, '
            '合并字段=${plan.mergedValues.keys.join(",")}, '
            '丢弃字段=${plan.discardedByLoser.values.expand((m) => m.keys).toSet().join(",")}');
      }
      if (mergedRows > 0) {
        logger.warning('DBMigration',
            'v45 共合并 $mergedRows 行重复交易(不可逆;合并/丢弃明细见 pre-v45 快照的 dedupePlans)');
      }
    } catch (e, st) {
      // 去重失败不阻断:唯一索引步骤会因残余重复而失败并被捕获;beforeOpen
      // 自愈会在下次打开时重试(缺陷 D),故这里不再依赖「下次 onUpgrade」。
      logger.warning('DBMigration', 'v45 syncId 去重失败(跳过): $e', st);
    }
  }

  /// 这批表里哪些确实存在(半迁移库/极老库可能还没建)。恒返回去重集合。
  Future<Set<String>> _v45ExistingTables(List<String> names) async {
    final wanted = names.toSet();
    if (wanted.isEmpty) return const {};
    final placeholders = List.filled(wanted.length, '?').join(',');
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN ($placeholders)",
      variables: wanted.map((n) => Variable<String>(n)).toList(),
    ).get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  /// 重写 `messages.metadata` 里 `txIds` / `undoneIds` 数组中的 loser id →
  /// keeper id(缺陷 A 的 JSON 内嵌引用;AI 账单卡片的撤销/编辑/改账本按钮读
  /// 这一列)。
  ///
  /// **两个数组都是本地 int 交易主键列表**:`txIds` 是卡片关联的交易,
  /// `undoneIds` 是其中已被「撤销」的子集(契约见
  /// `ai_chat_page.dart:1816` "undoneIds 是 txIds 的子集";消费侧
  /// `ai_chat_page.dart:1888` 用 `undoneIds.contains(txId)` 决定卡片是否置灰)。
  /// 只改 `txIds` 会让同一张卡片自相矛盾:txIds 指向 keeper(未撤销),
  /// undoneIds 还留着被删的 loser id → 去重前已撤销的卡片复活成可撤销。
  ///
  /// **不碰** `bills` 里业务字段:那是 AI 识别的账单内容,不是本地主键引用。
  /// 老格式(`{billInfo, isUndone}`)无需处理:它读 `messages.transaction_id`
  /// 列(同一批已改指)+ 布尔标志,不含 id 列表。
  /// JSON 解析失败的行原样保留(损坏数据不该被迁移二次破坏)。
  /// 幂等:替换后不存在 loser id,重跑无改动。
  Future<void> _v45RewriteMessageTxIds({
    required List<int> dupIds,
    required int keeperId,
  }) async {
    if (dupIds.isEmpty) return;
    // 只扫描真正引用了 loser 的行,避免全表 decode。
    final placeholders = List.filled(dupIds.length, '?').join(',');
    final rows = await customSelect(
      'SELECT id, transaction_id, metadata FROM messages '
      "WHERE metadata LIKE '%txIds%' OR metadata LIKE '%undoneIds%' "
      "OR transaction_id IN ($placeholders)",
      variables: dupIds.map((i) => Variable<int>(i)).toList(),
    ).get();
    final dupSet = dupIds.toSet();
    for (final row in rows) {
      final metadata = row.readNullable<String>('metadata');
      if (metadata == null || metadata.isEmpty) continue;
      dynamic decoded;
      try {
        decoded = jsonDecode(metadata);
      } catch (_) {
        continue; // 损坏 JSON:保持原样
      }
      if (decoded is! Map) continue;
      var changed = false;
      // txIds / undoneIds 同为本地 int 交易主键列表,同一映射规则 + 去重
      // (两个 loser id 都指同一笔时不留重复项;undoneIds 与 txIds 各自去重,
      // 保持「undo 集合 ⊆ tx 集合」)。
      for (final key in const ['txIds', 'undoneIds']) {
        final rawIds = decoded[key];
        if (rawIds is! List) continue;
        final rewritten = <dynamic>[];
        for (final id in rawIds) {
          final mapped = (id is int && dupSet.contains(id)) ? keeperId : id;
          if (!rewritten.contains(mapped)) rewritten.add(mapped);
        }
        // 元素变了(id 改指)或长度变了(去重)才算改动;纯遍历不动。
        final same = rewritten.length == rawIds.length &&
            rewritten.asMap().entries.every((e) => e.value == rawIds[e.key]);
        if (same) continue;
        decoded[key] = rewritten;
        changed = true;
      }
      if (!changed) continue;
      await customStatement(
        'UPDATE messages SET metadata = ? WHERE id = ?',
        [jsonEncode(decoded), row.read<int>('id')],
      );
    }
  }

  /// 快照/日志用:`double` 非有限值 → 标记字符串,避免 jsonEncode 抛
  /// (阻塞-7b;`_V45MergePlan.toJson` 会被写进 pre-v45 快照)。
  static Object? _v45JsonSafeValue(Object? value) {
    if (value is double && !value.isFinite) return '<non-finite>';
    return value;
  }

  /// keeper 合并后的最终行 → 与 EntitySerializer/`_archiveToTrash` 同口径的
  /// JSON(供 local_changes.payload_json 重写,缺陷 C)。
  ///
  /// 字段集对齐 `_archiveToTrash` 的 payload:同步侧读的是 entity_sync_id +
  /// int id,这里把整行关键字段序列化,杜绝 `{"id":<loser>}` 这类陈旧值。
  /// 非有限 double 走 `_v45JsonSafeValue`(jsonEncode 会直接抛,而这一步在
  /// DML 里抛出会让整个去重计划半途而废)。
  Future<Map<String, dynamic>> _v45KeeperPayloadJson(int keeperId) async {
    final row = await customSelect(
      'SELECT * FROM transactions WHERE id = ?',
      variables: [Variable<int>(keeperId)],
    ).getSingleOrNull();
    if (row == null) return const {};
    final data = <String, dynamic>{
      for (final e in row.data.entries) e.key: _v45JsonSafeValue(e.value),
    };
    data['id'] = keeperId; // 自洽:payload.id == local_changes.entity_id
    return data;
  }

  /// transaction_tags 去重 + UNIQUE(transaction_id, tag_id)。
  Future<void> _v45AddTransactionTagsUnique() async {
    try {
      final dupes = await customSelect(
        '''
        SELECT transaction_id, tag_id, COUNT(*) AS c
        FROM transaction_tags
        GROUP BY transaction_id, tag_id
        HAVING c > 1
        ''',
      ).get();
      for (final d in dupes) {
        final txId = d.read<int>('transaction_id');
        final tagId = d.read<int>('tag_id');
        // 保留最小 id 行,删其余
        await customStatement(
          'DELETE FROM transaction_tags WHERE transaction_id = ? AND tag_id = ? '
          'AND id NOT IN (SELECT MIN(id) FROM transaction_tags '
          'WHERE transaction_id = ? AND tag_id = ?)',
          [txId, tagId, txId, tagId],
        );
      }
      if (dupes.isNotEmpty) {
        logger.warning('DBMigration',
            'v45 transaction_tags 去重 ${dupes.length} 组(不可逆;原值见 pre-v45 快照)');
      }
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_transaction_tags_pair '
        'ON transaction_tags (transaction_id, tag_id);');
    } catch (e, st) {
      logger.warning('DBMigration', 'v45 transaction_tags 唯一索引失败(跳过): $e', st);
    }
  }

  /// UNIQUE(ledger_id, sync_id) 部分索引(仅非空、非空串 sync_id)。
  Future<void> _v45AddTransactionSyncIdUnique() async {
    try {
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_transactions_ledger_sync_id '
        "ON transactions (ledger_id, sync_id) "
        "WHERE sync_id IS NOT NULL AND sync_id <> '';");
      logger.info('DBMigration', 'v45 idx_transactions_ledger_sync_id 已建立');
    } catch (e, st) {
      logger.warning('DBMigration',
          'v45 syncId 唯一索引未建立(残余重复未清干净,下次启动重试): $e', st);
    }
  }

  // Seed minimal data
  /// [l10n] 国际化对象，如果为null则使用英文作为默认语言
  /// [currency] 货币代码
  /// [useHierarchicalCategories] 是否使用二级分类
  ///
  /// 注意：此方法只应在真正的首次初始化时调用（欢迎页完成时）
  Future<void> ensureSeed({
    AppLocalizations? l10n,
    String currency = 'CNY',
    bool useHierarchicalCategories = false,
    bool skipCategories = false,
    bool createDefaultLedger = true,
  }) async {
    logger.info('db', 'ensureSeed 被调用');
    logger.info('db', 'l10n 是否提供: ${l10n != null}');
    logger.info('db', '货币: $currency');
    logger.info('db', '使用二级分类: $useHierarchicalCategories');
    logger.info('db', '跳过分类创建: $skipCategories');
    logger.info('db', '创建默认账本: $createDefaultLedger');

    // 如果没有提供l10n，使用Lookup创建默认的中文版本(2026-09-18 国际化
    // 收敛后生成类仅支持 zh,传入其它 locale 会在 lookup 断言处崩溃)
    final effectiveL10n = l10n ?? lookupAppLocalizations(const Locale('zh'));
    logger.info('db', '使用的语言环境: ${l10n != null ? "提供的l10n" : "默认中文"}');

    await SeedService.seedDatabase(
      this,
      effectiveL10n,
      currency: currency,
      useHierarchicalCategories: useHierarchicalCategories,
      skipCategories: skipCategories,
      createDefaultLedger: createDefaultLedger,
    );
    logger.info('db', '数据库初始化完成');
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    // 品牌更名前数据库文件名是 beecount.sqlite(2026-09)。首次以新文件名
    // 打开时把旧文件(-shm/-wal 一起)移过去,避免存量用户数据"丢失"。
    final file = File(p.join(dir.path, 'smartbook.sqlite'));
    final legacy = File(p.join(dir.path, 'beecount.sqlite'));
    if (!file.existsSync() && legacy.existsSync()) {
      await legacy.rename(p.join(dir.path, 'smartbook.sqlite'));
      for (final suffix in ['-shm', '-wal']) {
        final f = File('${legacy.path}$suffix');
        if (f.existsSync()) {
          await f.rename(p.join(dir.path, 'smartbook.sqlite$suffix'));
        }
      }
      logger.info('db', '已迁移数据文件 beecount.sqlite → smartbook.sqlite');
    }

    // 开发环境：如果检测到锁文件，尝试删除（仅用于调试）
    try {
      final shmFile = File(p.join(dir.path, 'smartbook.sqlite-shm'));
      final walFile = File(p.join(dir.path, 'smartbook.sqlite-wal'));

      if (shmFile.existsSync() || walFile.existsSync()) {
        logger.warning('db', '检测到 SQLite 临时文件，可能存在锁定');
        // 注意：只在开发环境中记录，不自动删除，因为可能正在使用
      }
    } catch (e) {
      logger.debug('db', '检查锁文件时出错: $e');
    }

    return NativeDatabase.createInBackground(
      file,
      // WAL 读连接池(PERF-P0-03):主连接负责写,另开 4 条只读连接,写期间
      // UI 查询不再排队(仅 WAL 模式下生效,见下方 setup)。
      readPool: 4,
      setup: (db) {
        // WAL:读写不再互斥,单条写从「双 fsync + 删 journal」降为一次追加;
        // synchronous=NORMAL 在 WAL 下进程崩溃不丢数据,仅掉电可能丢最近
        // 若干事务(要零丢失可退回 FULL,收益约降到 3×)。
        db.execute('PRAGMA journal_mode = WAL;');
        db.execute('PRAGMA synchronous = NORMAL;');
        // 页缓存 8MB(默认 2MB):大账本热页常驻内存,减少回盘。
        db.execute('PRAGMA cache_size = -8000;');
        db.execute('PRAGMA temp_store = MEMORY;');
      },
    );
  });
}

/// 开发工具：清除数据库锁文件（仅在应用完全关闭后使用）
Future<void> clearDatabaseLockFiles() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(dir.path, 'smartbook.sqlite'));
    final shmFile = File(p.join(dir.path, 'smartbook.sqlite-shm'));
    final walFile = File(p.join(dir.path, 'smartbook.sqlite-wal'));

    // WAL 模式(PERF-P0-03)下 -wal 里可能残留未 checkpoint 的已提交事务,
    // 直接删文件会丢数据:先 checkpoint(TRUNCATE) 写回主库并截断,失败则
    // 保留文件不动(宁可留锁也不丢账)。
    if (walFile.existsSync()) {
      try {
        final raw = sq.sqlite3.open(dbFile.path);
        try {
          raw.execute('PRAGMA wal_checkpoint(TRUNCATE);');
        } finally {
          raw.dispose();
        }
      } catch (e) {
        logger.error('db', 'WAL checkpoint 失败,保留 -wal/-shm 不删除', e);
        return;
      }
    }

    if (shmFile.existsSync()) {
      await shmFile.delete();
      logger.info('db', '已删除 .sqlite-shm 文件');
    }

    if (walFile.existsSync()) {
      await walFile.delete();
      logger.info('db', '已删除 .sqlite-wal 文件');
    }

    logger.info('db', '数据库锁文件清理完成');
  } catch (e) {
    logger.error('db', '清理锁文件失败', e);
  }
}
