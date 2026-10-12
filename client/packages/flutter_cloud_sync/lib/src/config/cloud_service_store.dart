import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_service_config.dart';

/// 云服务配置持久化存储
/// 支持类型: 本地存储、SmartBook Cloud、自定义 Supabase、自定义 WebDAV、iCloud、S3
class CloudServiceStore {
  static const _kActiveType =
      'cloud_active_type'; // local | smartbook_cloud | supabase | webdav | icloud | s3
  static const _kSmartBookCloudCfg = 'cloud_smartbook_cloud_cfg';
  // 品牌更名前的旧前缀(2026-09, BeeCount → SmartBook)。读旧写新做一次性迁移,
  // 避免存量用户升级后云服务配置丢失。
  static const _kLegacySmartBookCloudCfg = 'cloud_beecount_cloud_cfg';
  static const _kLegacyActiveBeecount = 'beecount_cloud';

  /// 读新 key,缺失时回退旧 key 并迁移到新 key。
  ///
  /// 读取后会尝试就地重写配置体:品牌更名时只迁移了 key 前缀与 activeType 值,
  /// 配置 JSON 内的 `type` 枚举名与展示名仍是旧品牌,靠 [decodeCloudConfig]
  /// 的旧名映射兼容。这里在读到旧值时把整份配置重新编码写回新形态,
  /// 与 key/activeType 迁移同口径(迁移失败不影响本次返回)。
  Future<String?> _readSmartBookCloudCfg(SharedPreferences sp) async {
    var raw = sp.getString(_kSmartBookCloudCfg);
    if (raw != null) return raw;
    raw = sp.getString(_kLegacySmartBookCloudCfg);
    if (raw != null) {
      final migrated = _migrateConfigBody(raw);
      await sp.setString(_kSmartBookCloudCfg, migrated);
      await sp.remove(_kLegacySmartBookCloudCfg);
    }
    return raw;
  }

  /// 把配置体里可识别的旧枚举名/旧展示名重写为当前值。
  ///
  /// 解析失败(损坏 JSON)时原样返回,由调用方的 catch 处理回退。
  static String _migrateConfigBody(String raw) {
    try {
      final cfg = decodeCloudConfig(raw);
      final reEncoded = encodeCloudConfig(cfg);
      return reEncoded;
    } catch (_) {
      return raw;
    }
  }
  static const _kSupabaseCfg = 'cloud_supabase_cfg';
  static const _kWebdavCfg = 'cloud_webdav_cfg';
  static const _kS3Cfg = 'cloud_s3_cfg';

  /// 加载当前激活的云服务配置
  Future<CloudServiceConfig> loadActive() async {
    final sp = await SharedPreferences.getInstance();
    var activeType = sp.getString(_kActiveType) ?? 'local';
    // 品牌更名前激活类型存的是 'beecount_cloud',升级后迁移成新值。
    if (activeType == _kLegacyActiveBeecount) {
      activeType = 'smartbook_cloud';
      await sp.setString(_kActiveType, activeType);
    }

    switch (activeType) {
      case 'local':
        return CloudServiceConfig.localStorage();

      case 'smartbook_cloud':
        final raw = await _readSmartBookCloudCfg(sp);
        if (raw != null) {
          try {
            return decodeCloudConfig(raw);
          } catch (e) {
            // 解析失败，静默回退到本地存储
          }
        }
        return CloudServiceConfig.localStorage();

      case 'supabase':
        final raw = sp.getString(_kSupabaseCfg);
        if (raw != null) {
          try {
            return decodeCloudConfig(raw);
          } catch (e) {
            // 解析失败，静默回退到本地存储
          }
        }
        // 回退到本地存储
        return CloudServiceConfig.localStorage();

      case 'webdav':
        final raw = sp.getString(_kWebdavCfg);
        if (raw != null) {
          try {
            return decodeCloudConfig(raw);
          } catch (e) {
            // 解析失败，静默回退到本地存储
          }
        }
        // 回退到本地存储
        return CloudServiceConfig.localStorage();

      case 'icloud':
        // iCloud 无需额外配置，返回 iCloud 类型的配置
        return const CloudServiceConfig(
          type: CloudBackendType.icloud,
          name: 'iCloud',
        );

      case 's3':
        final raw = sp.getString(_kS3Cfg);
        if (raw != null) {
          try {
            return decodeCloudConfig(raw);
          } catch (e) {
            // 解析失败，静默回退到本地存储
          }
        }
        // 回退到本地存储
        return CloudServiceConfig.localStorage();

      default:
        return CloudServiceConfig.localStorage();
    }
  }

  /// 加载 SmartBook Cloud 配置(不管是否激活)
  Future<CloudServiceConfig?> loadSmartBookCloud() async {
    final sp = await SharedPreferences.getInstance();
    final raw = await _readSmartBookCloudCfg(sp);
    if (raw == null) return null;
    try {
      return decodeCloudConfig(raw);
    } catch (e) {
      return null;
    }
  }

  /// 加载Supabase配置(不管是否激活)
  Future<CloudServiceConfig?> loadSupabase() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kSupabaseCfg);
    if (raw == null) return null;
    try {
      return decodeCloudConfig(raw);
    } catch (e) {
      return null;
    }
  }

  /// 加载WebDAV配置(不管是否激活)
  Future<CloudServiceConfig?> loadWebdav() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kWebdavCfg);
    if (raw == null) return null;
    try {
      return decodeCloudConfig(raw);
    } catch (e) {
      return null;
    }
  }

  /// 加载S3配置(不管是否激活)
  Future<CloudServiceConfig?> loadS3() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kS3Cfg);
    if (raw == null) return null;
    try {
      return decodeCloudConfig(raw);
    } catch (e) {
      return null;
    }
  }

  /// 保存并激活配置
  ///
  /// 非法配置(`cfg.valid == false`)会被拒绝:不写 key、不改 activeType,
  /// 并返回 false。此前该入口不校验,激活一个 valid=false 的配置后
  /// `loadActive` 会返回它、provider 初始化才失败,用户看到的是
  /// "切换云服务失败"而不是"请输入地址";与 [activate] 的校验口径也不一致。
  Future<bool> saveAndActivate(CloudServiceConfig cfg) async {
    // local / iCloud 无需外部配置,始终可激活(与 activate() 同口径)。
    final requiresValidation = cfg.type != CloudBackendType.local &&
        cfg.type != CloudBackendType.icloud;
    if (requiresValidation && !cfg.valid) {
      return false;
    }

    final sp = await SharedPreferences.getInstance();

    switch (cfg.type) {
      case CloudBackendType.local:
        await sp.setString(_kActiveType, 'local');
        // Provider 会在下次使用时自动初始化
        break;

      case CloudBackendType.smartbookCloud:
        await sp.setString(_kSmartBookCloudCfg, encodeCloudConfig(cfg));
        await sp.setString(_kActiveType, 'smartbook_cloud');
        break;

      case CloudBackendType.supabase:
        await sp.setString(_kSupabaseCfg, encodeCloudConfig(cfg));
        await sp.setString(_kActiveType, 'supabase');
        // Provider 会在下次使用时自动初始化
        break;

      case CloudBackendType.webdav:
        await sp.setString(_kWebdavCfg, encodeCloudConfig(cfg));
        await sp.setString(_kActiveType, 'webdav');
        // Provider 会在下次使用时自动初始化
        break;

      case CloudBackendType.icloud:
        await sp.setString(_kActiveType, 'icloud');
        // iCloud 无需额外配置，Provider 会在下次使用时自动初始化
        break;

      case CloudBackendType.s3:
        await sp.setString(_kS3Cfg, encodeCloudConfig(cfg));
        await sp.setString(_kActiveType, 's3');
        // Provider 会在下次使用时自动初始化
        break;
    }
    return true;
  }

  /// 仅保存配置,不激活
  Future<void> saveOnly(CloudServiceConfig cfg) async {
    final sp = await SharedPreferences.getInstance();

    switch (cfg.type) {
      case CloudBackendType.local:
        // 本地存储无需保存
        break;

      case CloudBackendType.smartbookCloud:
        await sp.setString(_kSmartBookCloudCfg, encodeCloudConfig(cfg));
        break;

      case CloudBackendType.supabase:
        await sp.setString(_kSupabaseCfg, encodeCloudConfig(cfg));
        break;

      case CloudBackendType.webdav:
        await sp.setString(_kWebdavCfg, encodeCloudConfig(cfg));
        break;

      case CloudBackendType.icloud:
        // iCloud 无需保存额外配置
        break;

      case CloudBackendType.s3:
        await sp.setString(_kS3Cfg, encodeCloudConfig(cfg));
        break;
    }
  }

  /// 激活指定类型的配置
  Future<bool> activate(CloudBackendType type) async {
    final sp = await SharedPreferences.getInstance();

    switch (type) {
      case CloudBackendType.local:
        await sp.setString(_kActiveType, 'local');
        return true;

      case CloudBackendType.smartbookCloud:
        final raw = await _readSmartBookCloudCfg(sp);
        if (raw == null) return false;
        try {
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 'smartbook_cloud');
          return true;
        } catch (e) {
          return false;
        }

      case CloudBackendType.supabase:
        final raw = sp.getString(_kSupabaseCfg);
        if (raw == null) return false;
        try {
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 'supabase');
          return true;
        } catch (e) {
          return false;
        }

      case CloudBackendType.webdav:
        final raw = sp.getString(_kWebdavCfg);
        if (raw == null) return false;
        try {
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 'webdav');
          return true;
        } catch (e) {
          return false;
        }

      case CloudBackendType.icloud:
        // iCloud 无需配置，直接激活
        await sp.setString(_kActiveType, 'icloud');
        return true;

      case CloudBackendType.s3:
        final raw = sp.getString(_kS3Cfg);
        if (raw == null) return false;
        try {
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 's3');
          return true;
        } catch (e) {
          return false;
        }
    }
  }
}
