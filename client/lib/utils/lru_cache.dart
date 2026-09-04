import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// 简单的 LRU (Least Recently Used) 缓存管理工具
/// 用于记录和排序最近使用的项目（如账户ID）
class LRUCache {
  final String _key;
  final int _maxSize;

  LRUCache({required String key, int maxSize = 20})
      : _key = key,
        _maxSize = maxSize;

  /// 获取排序后的ID列表（最近使用的在前）
  Future<List<int>> getOrderedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr == null || jsonStr.isEmpty) {
      return [];
    }
    try {
      final List<dynamic> list = json.decode(jsonStr);
      return list.cast<int>();
    } catch (e) {
      return [];
    }
  }

  /// 记录使用某个ID（将其移到最前面）
  Future<void> recordUsage(int id) async {
    final prefs = await SharedPreferences.getInstance();
    List<int> ids = await getOrderedIds();

    // 移除已存在的ID
    ids.remove(id);

    // 将ID添加到最前面
    ids.insert(0, id);

    // 限制列表大小
    if (ids.length > _maxSize) {
      ids = ids.sublist(0, _maxSize);
    }

    // 保存到 SharedPreferences
    await prefs.setString(_key, json.encode(ids));
  }

  /// 清空缓存
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// 移除指定ID
  Future<void> remove(int id) async {
    final prefs = await SharedPreferences.getInstance();
    List<int> ids = await getOrderedIds();
    ids.remove(id);
    await prefs.setString(_key, json.encode(ids));
  }
}
