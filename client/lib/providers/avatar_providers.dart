import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ui/avatar_service.dart';

/// 头像刷新触发器
final avatarRefreshProvider = StateProvider<int>((ref) => 0);

/// 用户头像路径
final avatarPathProvider = FutureProvider<String?>((ref) async {
  ref.watch(avatarRefreshProvider);
  return AvatarService.getAvatarPath();
});
