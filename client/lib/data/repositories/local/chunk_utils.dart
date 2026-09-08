/// SQLite bind 参数分块工具（M6-2A）。
///
/// Drift / SQLite 的 `IN (...)` 参数列表有绑定上限（常见 999，但不同 Android
/// SQLite 编译版本上限不一）。为不依赖设备编译上限，统一以 [sqliteBindChunkSize]
/// 切分，单次查询最多 400 个 ID，并给 ledgerId、时间边界等其它参数留足余量。
///
/// 通用 Repository 仍需支持更大列表（如导入/统计），调用方通过 [chunkIds]
/// 分块执行，再合并结果。
library;

/// 单次 SQLite `IN (...)` 允许的最大 ID 数。
/// 低于常见 999 上限，且给其它参数留空间。
const int sqliteBindChunkSize = 400;

/// 把 [ids] 按 [size] 切成若干块。空列表返回空。
List<List<T>> chunkIds<T>(List<T> ids, {int size = sqliteBindChunkSize}) {
  if (ids.isEmpty) return const [];
  final out = <List<T>>[];
  for (var i = 0; i < ids.length; i += size) {
    final end = i + size;
    out.add(ids.sublist(i, end > ids.length ? ids.length : end));
  }
  return out;
}
