// Repository 基类和接口
export 'base_repository.dart';
export 'ledger_repository.dart';
export 'transaction_repository.dart';
export 'category_repository.dart';
export 'account_repository.dart';
export 'statistics_repository.dart';
export 'recurring_transaction_repository.dart';
export 'ai_repository.dart';
export 'tag_repository.dart';

// Local 实现
//
// 历史上还有 Cloud* 系列(数据完全存 Supabase)。SmartBook Cloud 上线后,
// 同步范式统一到「LocalRepository + ChangeTracker 推 SmartBook Cloud」,
// Cloud* 仓库整组已删,这里不再 export。
export 'local/local_repository.dart';
export 'local/local_ledger_repository.dart';
export 'local/local_transaction_repository.dart';
export 'local/local_category_repository.dart';
export 'local/local_account_repository.dart';
export 'local/local_statistics_repository.dart';
export 'local/local_tag_repository.dart';
