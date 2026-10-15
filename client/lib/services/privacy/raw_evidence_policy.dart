/// 原始证据一律永久保存:本地恒启用、服务端恒上传、无过期。
///
/// 历史上这里是一套可配置策略(RawEvidenceSourcePolicy / RawEvidencePolicy /
/// RawEvidencePolicyStore + planFor/shouldStore/retentionUntil + SharedPreferences
/// 持久化),已随隐私策略调整删除。只保留上传状态常量供事件行与上传队列使用。
library;

/// Upload states are deliberately separate from AutoBookEvent.state.
abstract final class RawEvidenceUploadState {
  static const notRequested = 'not_requested';
  static const pending = 'pending';
  static const uploading = 'uploading';
  static const uploaded = 'uploaded';
  static const retry = 'retry';
  static const rejected = 'rejected';
  static const cleared = 'cleared';
  static const expired = 'expired';
}
