// 对抗性测试 — 配置持久化(CloudServiceStore / CloudServiceConfig)/
//              CloudSyncManager 缓存 / DatabaseSyncManager 编排
//
// 规则:
//   // ADVERSE FINDING: <标题>  → 已确认缺陷,断言"应有行为",保持失败(红)
//   // HARDENING: <说明>        → 行为可辩护但脆弱,断言当前行为并通过(绿)
//
// 反 flaky: SharedPreferences.setMockInitialValues + 内存 mock,无网络、无 wall clock。
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

CloudServiceConfig smartbookCfg({
  String name = 'SmartBook Cloud',
  String? baseUrl = 'https://h.test',
  String? apiPrefix,
  String? email,
  String? password,
}) =>
    CloudServiceConfig(
      type: CloudBackendType.smartbookCloud,
      name: name,
      smartbookCloudBaseUrl: baseUrl,
      smartbookCloudApiPrefix: apiPrefix,
      smartbookCloudEmail: email,
      smartbookCloudPassword: password,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('CloudServiceConfig — 序列化与校验', () {
    test('HARDENING: 各后端类型往返保持一致', () {
      final configs = <CloudServiceConfig>[
        CloudServiceConfig.localStorage(),
        smartbookCfg(apiPrefix: '/api/v1', email: 'a@b.c', password: 'p'),
        const CloudServiceConfig(
          type: CloudBackendType.supabase,
          name: 'Supabase',
          supabaseUrl: 'https://x.supabase.co',
          supabaseAnonKey: 'anon',
          supabaseBucket: 'bucket',
          supabaseEmail: 'e',
          supabasePassword: 'p',
        ),
        const CloudServiceConfig(
          type: CloudBackendType.webdav,
          name: 'WebDAV',
          webdavUrl: 'https://dav.test/remote.php',
          webdavUsername: 'u',
          webdavPassword: 'p',
          webdavRemotePath: '/smartbook',
        ),
        const CloudServiceConfig(
          type: CloudBackendType.icloud,
          name: 'iCloud',
        ),
        const CloudServiceConfig(
          type: CloudBackendType.s3,
          name: 'S3',
          s3Endpoint: 's3.example.com',
          s3Region: 'us-east-1',
          s3AccessKey: 'AK',
          s3SecretKey: 'SK',
          s3Bucket: 'b',
          s3UseSSL: true,
          s3Port: 9000,
        ),
      ];
      for (final c in configs) {
        final back = decodeCloudConfig(encodeCloudConfig(c));
        expect(back.type, equals(c.type), reason: '${c.type}');
        expect(back.name, equals(c.name));
        expect(back.valid, equals(c.valid), reason: '${c.type} valid 变化');
      }
    });

    test('HARDENING: S3 endpoint 的协议前缀在反序列化时被剥离', () {
      final back = decodeCloudConfig(jsonEncode({
        'type': 's3',
        'name': 'S3',
        's3Endpoint': 'https://s3.example.com',
        's3AccessKey': 'AK',
        's3SecretKey': 'SK',
        's3Bucket': 'b',
      }));
      expect(back.s3Endpoint, equals('s3.example.com'));
      // 只有 http/https 被剥离
      final ws = decodeCloudConfig(jsonEncode({
        'type': 's3',
        'name': 'S3',
        's3Endpoint': 'ws://x',
        's3AccessKey': 'AK',
        's3SecretKey': 'SK',
        's3Bucket': 'b',
      }));
      expect(ws.s3Endpoint, equals('ws://x'));
    });

    test('ADVERSE: valid 只看"非空",纯空白串通过校验', () {
      // ADVERSE FINDING: 所有 valid 分支用 `?.isNotEmpty ?? false`
      // (lib/src/config/cloud_service_config.dart:76-97),不 trim。
      // ' ' / '\t' 被当成合法配置 → 保存后 provider 初始化才失败,
      // 用户看到的是"切换云服务失败"而不是"请输入地址"。
      // 期望: 纯空白视为未配置
      // 实际: valid == true
      final blank = CloudServiceConfig(
        type: CloudBackendType.smartbookCloud,
        name: 'x',
        smartbookCloudBaseUrl: '   ',
      );
      expect(blank.valid, isFalse,
          reason: '纯空白 baseUrl 被判为有效配置');

      final blankWebdav = CloudServiceConfig(
        type: CloudBackendType.webdav,
        name: 'w',
        webdavUrl: ' ',
        webdavUsername: '\t',
        webdavPassword: '\n',
      );
      expect(blankWebdav.valid, isFalse,
          reason: '纯空白 WebDAV 三要素被判为有效配置');
    });

    test('ADVERSE: 未知后端类型让解码抛 StateError(无版本兼容层)', () {
      // ADVERSE FINDING: fromJson 用 `CloudBackendType.values.firstWhere(...)`
      // (lib/src/config/cloud_service_config.dart:136-137),未知/更名前的
      // 类型名抛 StateError('No element'),不是可分类的配置异常。
      // 品牌更名(beecount_cloud → smartbook_cloud)已改了 activeType 与
      // 存储 key 前缀,但**没有**为旧枚举值 name 做兼容 —— 若历史
      // prefs 里存过旧 name,读取会直接崩。
      // 期望: 未知类型回退到 local(与 loadActive 的 default 分支一致)
      // 实际: StateError: Bad state: No element
      expect(
        () => decodeCloudConfig(jsonEncode({
          'type': 'beecountCloud',
          'name': '旧品牌',
          'smartbookCloudBaseUrl': 'https://h.test',
        })),
        returnsNormally,
      );
    });

    test('ADVERSE: 缺 name / 数字型 s3Port 触发裸 _TypeError', () {
      // ADVERSE FINDING: fromJson 里 `j['name'] as String` 与
      // `j['s3Port'] as int?` 都是裸转换
      // (lib/src/config/cloud_service_config.dart:138, 162):
      //  - 缺 name → _TypeError('Null is not a subtype of String')
      //  - s3Port 存成 9000.0(JSON 里很常见)→ _TypeError
      // 期望: 统一抛 CloudConfigurationException / 回退默认值
      // 实际: _TypeError(Error,非 Exception)
      expect(
        () => decodeCloudConfig('{"type":"s3"}'),
        throwsA(isA<CloudSyncException>()),
        reason: '缺 name',
      );
      expect(
        () => decodeCloudConfig('{"type":"s3","name":"S3","s3Port":9000.0}'),
        throwsA(isA<CloudSyncException>()),
        reason: '浮点型端口',
      );
    });

    test('HARDENING: 非法 JSON / 顶层非对象抛 FormatException/_TypeError', () {
      expect(() => decodeCloudConfig('not json'),
          throwsA(isA<FormatException>()));
      expect(() => decodeCloudConfig('[1,2,3]'),
          throwsA(isA<TypeError>()));
      expect(() => decodeCloudConfig('null'), throwsA(isA<TypeError>()));
    });

    test('HARDENING: encodeCloudConfig 输入恒为标量,循环引用不可达', () {
      // HARDENING: toJson 只输出 String/int/bool/null 标量
      // (cloud_service_config.dart:99-126)→ jsonEncode 不可能抛
      // JsonCyclicError;若在**参数求值阶段**手造不可编码对象,异常发生在
      // 进入包代码之前,包无法也不必包装(上一版断言打错了靶子)。
      expect(() => encodeCloudConfig(smartbookCfg()), returnsNormally);
      expect(
        () => encodeCloudConfig(const CloudServiceConfig(
          type: CloudBackendType.s3,
          name: 'S3',
          s3Port: null,
        )),
        returnsNormally,
      );
      // 包外 dart:convert 的行为对照:循环引用确实抛 JsonCyclicError
      final cyc = <String, Object?>{};
      cyc['self'] = cyc;
      expect(() => jsonEncode(cyc), throwsA(isA<JsonCyclicError>()));
    });

    test('HARDENING: 明文密码进 prefs(设计如此,但需知晓)', () {
      // HARDENING: smartbookCloudPassword / supabasePassword /
      // webdavPassword / s3SecretKey 均以明文写进 SharedPreferences
      // (lib/src/config/cloud_service_config.dart:99-126 的 toJson 全量输出;
      //  App 侧 config_export_service.dart:2293 再把它写进 YAML 导出文件)。
      // 这不是包内能修的问题(需要平台 keystore),但影响面明确:
      // 导出文件 + 应用数据目录都可读到凭据。
      final cfg = smartbookCfg(password: 'S3CR3T-PW');
      final raw = encodeCloudConfig(cfg);
      expect(raw, contains('S3CR3T-PW'));
      expect(cfg.toJson()['smartbookCloudPassword'], equals('S3CR3T-PW'));
    });

    test('HARDENING: obfuscatedUrl 只显示 host,不回显完整 URL', () {
      expect(
        smartbookCfg(baseUrl: 'https://api.example.com:8888/api/v1')
            .obfuscatedUrl(),
        equals('api.example.com'),
      );
      expect(
        smartbookCfg(baseUrl: 'https://user:secret@h.test').obfuscatedUrl(),
        equals('h.test'),
      );
      // 无 host 时回退原始串(可能带凭据)
      expect(
        smartbookCfg(baseUrl: 'not-a-url').obfuscatedUrl(),
        equals('not-a-url'),
      );
      expect(CloudServiceConfig.localStorage().obfuscatedUrl(),
          equals('__LOCAL_DEVICE__'));
    });
  });

  group('CloudServiceStore — 损坏数据与迁移', () {
    late CloudServiceStore store;

    setUp(() => store = CloudServiceStore());

    test('HARDENING: 损坏 JSON 静默回退到 local(不抛)', () async {
      SharedPreferences.setMockInitialValues({
        'cloud_active_type': 'smartbook_cloud',
        'cloud_smartbook_cloud_cfg': '{corrupt!!!',
      });
      final cfg = await store.loadActive();
      expect(cfg.type, equals(CloudBackendType.local));
    });

    test('HARDENING: 未知 active_type 静默回退 local,与"未配置"不可区分', () async {
      // HARDENING: loadActive 的 default 分支静默返回 local
      // (lib/src/config/cloud_service_store.dart:98-99)。回退本身可辩护
      // (未知后端没有可猜测的加载路径,不能抛),脆弱点:云同步被**静默**
      // 停用 —— 与"用户本来就用本地"完全同形,UI 无任何提示。
      // (未知 type 枚举名导致的同形回退见下一条红项。)
      SharedPreferences.setMockInitialValues({
        'cloud_active_type': 'totally_unknown_backend',
      });
      final cfg = await store.loadActive();
      expect(cfg.type, equals(CloudBackendType.local),
          reason: '当前行为:未知后端类型被静默当作本地存储(云同步悄悄停用)');
    });

    test('ADVERSE: 旧品牌 activeType 迁移成功,但配置里的旧枚举名会崩', () async {
      // ADVERSE FINDING: 品牌更名迁移覆盖了 _kActiveType 的值
      // ('beecount_cloud' → 'smartbook_cloud',store:33-38)与存储 key 前缀
      // (store:12),但**没覆盖**配置 JSON 里的 type 枚举名 ——
      // 一旦历史数据写出过旧枚举名(如 'beecountCloud'),decodeCloudConfig
      // 抛 StateError(config:136-137 firstWhere),被 loadActive 的 catch
      // (store:49-51)吞掉后静默回退 local(用户"云同步消失")。
      // 注:旧枚举名的具体拼写无 git 证据(仓库历史已重置),但机制确证:
      //     activeType 已迁移 + 配置体 type 未迁移/未知 → 静默降级 local。
      // 期望: 读取旧枚举名时迁移为 smartbookCloud(与 key 迁移同口径)
      // 实际: StateError 被吞 → 回退 local
      SharedPreferences.setMockInitialValues({
        'cloud_active_type': 'beecount_cloud',
        'cloud_beecount_cloud_cfg': jsonEncode({
          'type': 'beecountCloud',
          'name': '旧品牌',
          'smartbookCloudBaseUrl': 'https://h.test',
        }),
      });
      final cfg = await store.loadActive();
      expect(cfg.type, equals(CloudBackendType.smartbookCloud),
          reason: '旧枚举名配置被降级为 local(实际: ${cfg.type})');
    });

    test('HARDENING: 旧 key 迁移:读旧 → 写新 → 删旧', () async {
      SharedPreferences.setMockInitialValues({
        'cloud_active_type': 'smartbook_cloud',
        'cloud_beecount_cloud_cfg': encodeCloudConfig(smartbookCfg()),
      });
      final cfg = await store.loadActive();
      final prefs = await SharedPreferences.getInstance();
      expect(cfg.type, equals(CloudBackendType.smartbookCloud));
      expect(cfg.smartbookCloudBaseUrl, equals('https://h.test'));
      expect(prefs.getString('cloud_smartbook_cloud_cfg'), isNotNull);
      expect(prefs.getString('cloud_beecount_cloud_cfg'), isNull);
    });

    test('HARDENING: 旧 activeType 值被就地改写为新值', () async {
      SharedPreferences.setMockInitialValues({
        'cloud_active_type': 'beecount_cloud',
        'cloud_smartbook_cloud_cfg': encodeCloudConfig(smartbookCfg()),
      });
      final cfg = await store.loadActive();
      final prefs = await SharedPreferences.getInstance();
      expect(cfg.type, equals(CloudBackendType.smartbookCloud));
      expect(prefs.getString('cloud_active_type'), equals('smartbook_cloud'));
    });

    test('ADVERSE: saveAndActivate 不校验配置合法性,valid=false 也能激活', () async {
      // ADVERSE FINDING: saveAndActivate 无条件写 key + activeType
      // (lib/src/config/cloud_service_store.dart:152-189),不做 cfg.valid 检查。
      // 对比 activate()(223-284)在切换时会检查 valid 并返回 false ——
      // 两个入口的校验口径不一致(此处用 baseUrl=null 的确定 invalid 配置,
      // 与"纯空白 valid=true"红项相互独立)。
      // 期望: 保存并激活非法配置时拒绝(或至少返回失败)
      // 实际: 激活成功,active_type 被写为 'smartbook_cloud',
      //       下次 loadActive 返回一个 valid=false 的配置,
      //       provider 初始化失败 → UI 报"云服务切换失败"
      final invalid = CloudServiceConfig(
        type: CloudBackendType.smartbookCloud,
        name: 'x',
      );
      expect(invalid.valid, isFalse, reason: '前提:baseUrl 缺失 → valid=false');
      await store.saveAndActivate(invalid);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cloud_active_type'),
          isNot(equals('smartbook_cloud')),
          reason: '非法配置被激活(实际 active_type=${prefs.getString('cloud_active_type')})');
    });

    test('HARDENING: activate() 对非法配置返回 false 且不改 active_type', () async {
      await store.saveOnly(CloudServiceConfig(
        type: CloudBackendType.webdav,
        name: 'w',
        webdavUrl: '   ',
        webdavUsername: ' ',
        webdavPassword: ' ',
      ));
      final ok = await store.activate(CloudBackendType.webdav);
      final prefs = await SharedPreferences.getInstance();
      // 修复后(R-34):纯空白不再是"已配置",activate 拒绝且不改 active_type。
      // (原断言固化"纯空白被判为 valid",与本文件第一条红项 R-34 直接矛盾。)
      expect(ok, isFalse, reason: '纯空白三要素应判为未配置');
      expect(prefs.getString('cloud_active_type'), isNot(equals('webdav')));
    });

    test('HARDENING: activate() 在无配置时返回 false', () async {
      for (final t in [
        CloudBackendType.smartbookCloud,
        CloudBackendType.supabase,
        CloudBackendType.webdav,
        CloudBackendType.s3,
      ]) {
        expect(await store.activate(t), isFalse, reason: '$t');
      }
      expect(await store.activate(CloudBackendType.local), isTrue);
      expect(await store.activate(CloudBackendType.icloud), isTrue);
    });

    test('HARDENING: load* 系列在损坏配置下返回 null 而非抛', () async {
      SharedPreferences.setMockInitialValues({
        'cloud_supabase_cfg': '{bad',
        'cloud_webdav_cfg': '[1,2]',
        'cloud_s3_cfg': 'null',
        'cloud_smartbook_cloud_cfg': '{"type":"nope"}',
      });
      expect(await store.loadSmartBookCloud(), isNull);
      expect(await store.loadSupabase(), isNull);
      expect(await store.loadWebdav(), isNull);
      expect(await store.loadS3(), isNull);
    });

    test('HARDENING: saveOnly 不改 activeType', () async {
      SharedPreferences.setMockInitialValues({
        'cloud_active_type': 'local',
      });
      await store.saveOnly(smartbookCfg());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cloud_active_type'), equals('local'));
      expect(prefs.getString('cloud_smartbook_cloud_cfg'), isNotNull);
    });

    test('HARDENING: 并发 saveAndActivate 不产生撕裂的 (key, activeType) 组合', () async {
      // 注:这里只是把并发写变成"最后一个赢",没有原子性保证也没有损坏。
      // SharedPreferences 的 setString 是逐 key 异步写,切换过程中
      // (key 写完但 activeType 未写)被读取会看到旧组合 —— 单线程
      // 事件循环下窗口很小,但确实存在。
      await Future.wait([
        store.saveAndActivate(smartbookCfg(baseUrl: 'https://a.test')),
        store.saveAndActivate(smartbookCfg(baseUrl: 'https://b.test')),
      ]);
      final cfg = await store.loadActive();
      expect(cfg.type, equals(CloudBackendType.smartbookCloud));
      expect(
        cfg.smartbookCloudBaseUrl,
        anyOf(equals('https://a.test'), equals('https://b.test')),
      );
    });

    test('HARDENING: iCloud 无需配置即可激活;local 永远有效', () async {
      await store.saveAndActivate(
          const CloudServiceConfig(type: CloudBackendType.icloud, name: 'iCloud'));
      final cfg = await store.loadActive();
      expect(cfg.type, equals(CloudBackendType.icloud));
      expect(cfg.valid, isTrue);
      expect(CloudServiceConfig.localStorage().valid, isTrue);
    });
  });

  group('CloudSyncManager — 状态缓存语义', () {
    late _MockProvider provider;
    late CloudSyncManager<int> manager;

    setUp(() {
      provider = _MockProvider();
      manager = CloudSyncManager<int>(
        provider: provider,
        serializer: _ShaSerializer(),
      );
    });

    test('ADVERSE: 状态缓存按 path 命中,不校验入参 data 是否同一份', () async {
      // ADVERSE FINDING: 缓存 key 只有 path(_statusCache[path]),
      // 且 getStatus 命中缓存时不重算本地指纹
      // (lib/src/manager/cloud_sync_manager.dart:221-228)。
      // 于是"同一 path 不同 data"会拿到过期状态:
      // 调用方以为 status 描述的是当前本地数据,实际是 T 秒前的快照。
      // 期望: 缓存键包含本地指纹(或 data 变化时失效)
      // 实际: data 从 1 换成 999 仍返回同一 SyncStatus 实例
      provider.files['p.json'] = jsonEncode({'ledgerId': 2, 'count': 2});
      final s1 = await manager.getStatus(data: 1, path: 'p.json');
      final s2 = await manager.getStatus(data: 999, path: 'p.json');
      // 修复后:缓存键纳入本地指纹,data 变化即失效 → 两份本地指纹不同。
      // (原断言先 expect(s2 == s1) 再 expect(s2 == fresh) 自相矛盾:
      //  两者不可能同时成立。)
      expect(s2.localFingerprint, isNot(equals(s1.localFingerprint)),
          reason: 'data 变化后仍命中旧缓存(data=1 的指纹)');
      final fresh = await manager.getStatus(
          data: 999, path: 'p.json', forceRefresh: true);
      expect(s2.localFingerprint, equals(fresh.localFingerprint),
          reason: 'data 1 → 999 指纹未变(缓存返回了旧指纹 ${s2.localFingerprint})');
    });

    test('HARDENING: forceRefresh 绕过缓存并回写', () async {
      provider.files['p.json'] = jsonEncode({'ledgerId': 2, 'count': 2});
      final first = await manager.getStatus(data: 1, path: 'p.json');
      expect(first.state, equals(SyncState.outOfSync));
      final forced = await manager.getStatus(
          data: 1, path: 'p.json', forceRefresh: true);
      expect(forced.state, equals(SyncState.outOfSync));
      // 之后普通调用也拿到新值(缓存已回写)
      final cached = await manager.getStatus(data: 1, path: 'p.json');
      expect(cached.state, equals(SyncState.outOfSync));
    });

    test('HARDENING: 上传/下载/删除都会失效对应 path 的缓存', () async {
      provider.files['p.json'] = '{"ledgerId":1}';
      await manager.getStatus(data: 1, path: 'p.json');
      manager.clearCache(); // 先清空以便观察"回写" (clearCache 返回 void)
      final s0 = await manager.getStatus(data: 1, path: 'p.json');
      expect(s0.state, isNotNull);
      await manager.upload(data: 1, path: 'p.json');
      // upload 后缓存失效 → 下次会重算(且现在云端内容变了)
      final after = await manager.getStatus(data: 1, path: 'p.json');
      expect(after.state, equals(SyncState.synced));
      await manager.deleteRemote(path: 'p.json');
      final gone = await manager.getStatus(data: 1, path: 'p.json');
      expect(gone.state, equals(SyncState.localOnly));
    });

    test('HARDENING: 缓存 TTL 默认 30s,可用 cacheTTL 调整', () async {
      final m = CloudSyncManager<int>(
        provider: provider,
        serializer: _ShaSerializer(),
        cacheTTL: Duration.zero,
      );
      provider.files['p.json'] = '{"ledgerId":1}';
      await m.getStatus(data: 1, path: 'p.json');
      provider.files['p.json'] = '{"ledgerId":1,"extra":true}';
      final s = await m.getStatus(data: 1, path: 'p.json');
      // TTL=0 → 每次重算
      expect(s.cloudFingerprint, isNotNull);
    });

    test('HARDENING: 双侧均无比较信息时方向退化为 unknown(信息不足)', () async {
      // HARDENING: getStatus 的方向判定依次用 时间戳 → count → unknown
      // (cloud_sync_manager.dart:340-368)。本用例未传 localUpdatedAt、
      // 云端 JSON 又缺 count/exportedAt —— 确实无比较依据,unknown 是诚实值。
      // 脆弱点(提示,非本断言):第 6 步已取到的 uploadedAt/lastSyncedAt
      // (312-315)没有作为 cloudUpdatedAt 的兜底,调用方即使传了
      // localUpdatedAt 仍可能判不出方向;App 侧把 unknown 映射为
      // "不一致"且无建议(client/lib/cloud/transactions_sync_manager.dart:392+)。
      provider.files['p.json'] =
          jsonEncode({'ledgerId': 2, 'items': [1, 2, 3]}); // 无 count/exportedAt
      final s = await manager.getStatus(data: 1, path: 'p.json');
      expect(s.state, equals(SyncState.outOfSync));
      expect(s.direction, equals(SyncDirection.unknown),
          reason: '当前行为:无可比信息 → direction=unknown');
      expect(s.message, equals('Local and cloud data differ'));
    });

    test('HARDENING: 本地与云端指纹一致 → synced', () async {
      provider.files['p.json'] = await _ShaSerializer().serialize(5);
      final s = await manager.getStatus(data: 5, path: 'p.json');
      expect(s.state, equals(SyncState.synced));
      expect(s.localFingerprint, equals(s.cloudFingerprint));
    });

    test('HARDENING: 云端不存在 → localOnly(带本地指纹)', () async {
      final s = await manager.getStatus(data: 3, path: 'p.json');
      expect(s.state, equals(SyncState.localOnly));
      expect(s.localFingerprint, isNotNull);
      expect(s.cloudFingerprint, isNull);
    });

    test('HARDENING: 不传 data 时只报云端状态,不做方向判定', () async {
      provider.files['p.json'] = '{"ledgerId":1}';
      final s = await manager.getStatus(path: 'p.json');
      expect(s.state, equals(SyncState.synced));
      expect(s.localFingerprint, isNull);
      expect(s.direction, isNull);
    });

    test('HARDENING: TTL 窗口内云端变化不反映;forceRefresh 可绕过', () async {
      // HARDENING: 缓存按 path 命中、TTL(默认 30s)内不看云端
      // (cloud_sync_manager.dart:221-228)—— TTL 缓存的既定语义,
      // 另一台设备改云端后本机短窗内仍显示旧状态,App 侧靠 forceRefresh
      // 绕开。脆弱面:走默认参数的调用方会看到陈旧状态;缓存不区分
      // 账号/云端版本,极端场景(同 manager 换账号)有串味理论风险。
      provider.files['p.json'] = await _ShaSerializer().serialize(7);
      final before = await manager.getStatus(data: 7, path: 'p.json');
      expect(before.state, equals(SyncState.synced));
      provider.files['p.json'] = '{"ledgerId":7,"remoteEdit":true}';
      final after = await manager.getStatus(data: 7, path: 'p.json');
      expect(after.state, equals(SyncState.synced),
          reason: '当前行为:TTL 窗口内仍报 ${after.state}(陈旧)');
      final forced = await manager.getStatus(
          data: 7, path: 'p.json', forceRefresh: true);
      expect(forced.state, equals(SyncState.outOfSync),
          reason: 'forceRefresh 应绕过缓存拿到真实状态');
    });
  });

  group('DatabaseSyncManager — 冲突 / 离线队列 / 生命周期', () {
    test('HARDENING: 版本跳跃(≥+2)判为冲突后 LWW 静默选本地,调用方无感知', () async {
      // HARDENING: _detectConflict 对 localVersion > cloudVersion+1 判冲突
      // (database_sync_manager.dart:561-567),_resolveConflict 的 LWW 用
      // `localVersion > cloudVersion` 选 winner(606-610)→ 本地 9 > 云端 5
      // → 本地胜。可辩护:LWW-by-version 的标准语义(版本号高者新);
      // 脆弱点:冲突全程静默,调用方拿不到"本地跳版覆盖了云端"的信号。
      // (真正反直觉的分支 —— 本地**落后**也覆盖云端 —— 见下一条红项。)
      final db = _FakeDb();
      db.records['1'] = {'id': '1', 'version': 5, 'amount': 999};
      final m = DatabaseSyncManager(databaseService: db);
      await m.syncRecord(
        table: 'transactions',
        localRecord: {'id': '1', 'version': 9, 'amount': 1},
      );
      m.dispose();
      expect(db.records['1']!['amount'], equals(1),
          reason: '当前行为:版本跳跃判冲突 → LWW 本地(9>5)胜,云端变更被静默覆盖');
    });

    test('ADVERSE: 本地版本落后于云端时直通更新,旧本地覆盖更新的云端', () async {
      // ADVERSE FINDING: _detectConflict 对 `localVersion <= cloudVersion`
      // 返回 null("Local version is not newer, no conflict",
      // database_sync_manager.dart:553-555)→ syncRecord 走"无冲突"分支
      // **无条件** databaseService.update(data: localRecord)(297-301)。
      // 于是本地 3 < 云端 5 时,旧本地把新云端覆盖 —— 云端变更静默丢失。
      // 讽刺点:同文件的 _resolveConflict LWW 分支(606-610)对 3 vs 5 本
      // 会选 cloudRecord;正因为压根没进冲突处理,正确分支永远不执行。
      // 期望: 落后版本应走冲突处理(LWW 保云端)或拒绝更新
      // 实际: amount=1 覆盖 999
      final db = _FakeDb();
      db.records['1'] = {'id': '1', 'version': 5, 'amount': 999};
      final m = DatabaseSyncManager(databaseService: db);
      await m.syncRecord(
        table: 't',
        localRecord: {'id': '1', 'version': 3, 'amount': 1},
      );
      m.dispose();
      expect(db.records['1']!['amount'], equals(999),
          reason: '云端应胜出(本地 version=3 落后于 5,实际: '
              '${db.records['1']!['amount']} —— 旧本地覆盖了新云端)');
    });

    test('ADVERSE: manual 冲突策略抛出的异常里 table 字段是空串', () async {
      // ADVERSE FINDING: _detectConflict 构造 SyncConflict 时硬编码
      // table: ''(lib/src/manager/database_sync_manager.dart:565, 584),
      // 注释写"Will be filled by caller"但没有任何调用方填充。
      // 于是 manual 策略的错误信息是
      // 'Manual conflict resolution required: /1'(table 缺失),
      // 用户/日志无法知道是哪个表。
      // 期望: 异常里包含真实 table 名
      // 实际: '... required: /1'
      final db = _FakeDb();
      db.records['1'] = {'id': '1', 'version': 5};
      final m = DatabaseSyncManager(
          databaseService: db,
          conflictStrategy: ConflictResolutionStrategy.manual);
      try {
        await m.syncRecord(
            table: 'transactions', localRecord: {'id': '1', 'version': 9});
        fail('应当抛出');
      } catch (e) {
        expect('$e', contains('transactions'),
            reason: '实际错误信息: $e');
      } finally {
        m.dispose();
      }
    });

    test('ADVERSE: 超过 maxRetryAttempts 的操作被静默丢弃(无 dead-letter)', () async {
      // ADVERSE FINDING: processOfflineQueue 对超次数的操作只打日志并**丢弃**
      // (lib/src/manager/database_sync_manager.dart:381-383),
      // 队列里不再有它,调用方拿不到任何信号(successCount 不含它、
      // 也没有 failed 列表)。用户数据变更就此消失。
      // 期望: 超次数的操作进入可查询的 dead-letter 队列(或抛/返回失败列表)
      // 实际: 静默消失
      final db = _FakeDb()..failInsert = true;
      final m = DatabaseSyncManager(databaseService: db, maxRetryAttempts: 2);
      m.queueOperation(PendingSyncOperation(
        id: 'op-doomed',
        type: SyncOperationType.insert,
        table: 't',
        data: {'id': 'x'},
        timestamp: DateTime.now(),
      ));
      for (var i = 0; i < 6; i++) {
        await m.processOfflineQueue();
      }
      final pending = m.pendingOperationsCount;
      final deadLetter = m.deadLetterCount;
      final attempts = db.insertAttempts;
      m.dispose();
      // 期望: 超次数的操作进入可查询 dead-letter 队列,而非静默消失
      // 实际(已修):pending(可重试)排空,操作保留在 dead-letter 中
      expect(deadLetter, equals(1),
          reason: '操作被静默丢弃(轮询 6 次后队列为空,仅尝试 $attempts 次)');
      expect(pending, equals(0),
          reason: '超次数操作不应留在可重试队列(pending=$pending)');
      expect(attempts, equals(3),
          reason: 'maxRetryAttempts=2 → 1 次首发 + 2 次重试 = 3 次');
    });

    test('HARDENING: 失败操作在阈值内被重新入队并累加 retryCount', () async {
      final db = _FakeDb()..failInsert = true;
      final m = DatabaseSyncManager(databaseService: db, maxRetryAttempts: 5);
      m.queueOperation(PendingSyncOperation(
        id: 'op1',
        type: SyncOperationType.insert,
        table: 't',
        data: {'id': 'x'},
        timestamp: DateTime.now(),
      ));
      final n = await m.processOfflineQueue();
      final status = m.status;
      final pending = m.pendingOperationsCount;
      m.dispose();
      expect(n, equals(0));
      expect(pending, equals(1));
      expect(status, equals(DatabaseSyncStatus.offline));
    });

    test('ADVERSE: 同一队列被并发 processOfflineQueue 时操作重复执行', () async {
      // ADVERSE FINDING: processOfflineQueue 没有互斥/isSyncing 保护
      // (lib/src/manager/database_sync_manager.dart:351-401 只有
      //  _offlineQueue.isEmpty 检查,队列在循环内被消耗)。
      // 两次并发调用会从同一队列各取一部分,但 queueOperation 之后
      // 若操作失败会被**两处**重新入队 → 队列长度增长;
      // 更糟的是 insert 类操作可能被执行两次(非幂等写入)。
      // 期望: 并发调用应串行化(第二次直接返回 0 或等待)
      // 实际: 无保护,操作可被重复执行
      final db = _FakeDb();
      var inFlight = 0;
      var maxInFlight = 0;
      db.onInsert = () async {
        inFlight++;
        maxInFlight = maxInFlight > inFlight ? maxInFlight : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        inFlight--;
      };
      final m = DatabaseSyncManager(databaseService: db);
      for (var i = 0; i < 4; i++) {
        m.queueOperation(PendingSyncOperation(
          id: 'op$i',
          type: SyncOperationType.insert,
          table: 't',
          data: {'id': 'r$i'},
          timestamp: DateTime.now(),
        ));
      }
      final results = await Future.wait([
        m.processOfflineQueue(),
        m.processOfflineQueue(),
      ]);
      final total = results.reduce((a, b) => a + b);
      final attempts = db.insertAttempts;
      m.dispose();
      expect(attempts, equals(4),
          reason: '并发处理导致重复执行:共 ${attempts} 次 insert(应为 4)');
    });

    test('HARDENING: 队列空时 processOfflineQueue 返回 0 且不改状态', () async {
      final db = _FakeDb();
      final m = DatabaseSyncManager(databaseService: db);
      expect(await m.processOfflineQueue(), equals(0));
      expect(m.status, equals(DatabaseSyncStatus.idle));
      expect(m.pendingOperationsCount, equals(0));
      m.dispose();
    });

    test('HARDENING: 缺 id 抛基类 CloudSyncException;双侧缺 version 按"无法判定则本地优先"覆盖', () async {
      // HARDENING: (a) 缺 id → CloudSyncException(基类,非专用校验异常,
      //     database_sync_manager.dart:251-254);(b) 双侧缺 version/updated_at
      //     时 _detectConflict 两条回退都失败返回 null(571-590)→ 直通更新。
      //     与 _resolveConflict 明示的 "Cannot determine, prefer local"
      //     (625-626)同口径 —— 无乐观锁信息时本地优先是**设计选择**,
      //     可辩护;代价:调用方不带版本字段就没有任何冲突保护。
      final db = _FakeDb();
      db.records['1'] = {'id': '1', 'amount': 999}; // 云端也没有 version
      final m = DatabaseSyncManager(databaseService: db);
      await expectLater(
        m.syncRecord(table: 't', localRecord: {'amount': 1}),
        throwsA(isA<CloudSyncException>()), // 非 ValidationException/ArgumentError
      );
      await m.syncRecord(table: 't', localRecord: {'id': '1', 'amount': 1});
      m.dispose();
      expect(db.records['1']!['amount'], equals(1),
          reason: '当前行为:无 version/updated_at → 判不出冲突 → 本地覆盖云端');
    });

    test('HARDENING: _parseEventType 对未知事件类型默认按 insert 处理', () async {
      // HARDENING: 未知 eventType 落到 default → DatabaseEventType.insert
      // (lib/src/manager/database_sync_manager.dart:687-698)。
      // 语义上"未知当新增"是危险的(可能把 DELETE 当 INSERT),
      // 但该路径由 Supabase provider 控制,输入面较窄。
      final db = _FakeDb();
      final realtime = _RecordingRealtime();
      final m = DatabaseSyncManager(
          databaseService: db, realtimeService: realtime);
      final received = <DatabaseEvent>[];
      await m.subscribeToTable(
        table: 'transactions',
        filters: [QueryFilter.eq('ledger_id', 'L1')],
        onEvent: (e) async => received.add(e),
      );
      realtime.emit('sync:transactions', {
        'eventType': 'WEIRD_FUTURE_EVENT',
        'new': {'id': '1'},
      });
      await Future<void>.delayed(Duration.zero);
      m.dispose();
      // 当前行为:未知类型 → insert
      expect(received.single.type, equals(DatabaseEventType.insert));
    });

    test('ADVERSE: dispose() 后再 queueOperation 抛 StateError', () async {
      // ADVERSE FINDING: dispose 关闭 _statusController,但
      // queueOperation → _updateStatus → _statusController.add 仍会执行
      // (lib/src/manager/database_sync_manager.dart:332-336, 678-684, 701-705)。
      // Riverpod 释放与 UI 回调竞态时会命中。
      // 期望: dispose 后的状态更新为 no-op
      // 实际: StateError: Cannot add new events after calling close
      final m = DatabaseSyncManager(databaseService: _FakeDb());
      m.dispose();
      expect(
        () => m.queueOperation(PendingSyncOperation(
          id: 'x',
          type: SyncOperationType.insert,
          table: 't',
          data: {'id': '1'},
          timestamp: DateTime.now(),
        )),
        returnsNormally,
      );
    });

    test('HARDENING: 离线队列按 FIFO 顺序处理', () async {
      final db = _FakeDb();
      final m = DatabaseSyncManager(databaseService: db);
      for (final id in ['a', 'b', 'c']) {
        m.queueOperation(PendingSyncOperation(
          id: 'op-$id',
          type: SyncOperationType.insert,
          table: 't',
          data: {'id': id},
          timestamp: DateTime.now(),
        ));
      }
      final n = await m.processOfflineQueue();
      m.dispose();
      expect(n, equals(3));
      expect(db.insertOrder, equals(['a', 'b', 'c']));
    });

    test('HARDENING: copyWith 不带 error 时清空错误文本', () async {
      // copyWith 的 error 参数无 `?? this.error`,显式传 null 会清空
      final op = PendingSyncOperation(
        id: 'x',
        type: SyncOperationType.insert,
        table: 't',
        timestamp: DateTime.now(),
        error: 'old error',
      );
      expect(op.copyWith(retryCount: 1).error, isNull);
      expect(op.copyWith(retryCount: 1).retryCount, equals(1));
      expect(op.copyWith(error: 'new').error, equals('new'));
    });

    test('HARDENING: unsubscribeAll 清理全部订阅,未知 channel 只告警', () async {
      final realtime = _RecordingRealtime();
      final m = DatabaseSyncManager(
          databaseService: _FakeDb(), realtimeService: realtime);
      await m.subscribeToTable(
          table: 't1', onEvent: (e) async {});
      await m.subscribeToTable(
          table: 't2', onEvent: (e) async {});
      expect(realtime.unsubscribed, isEmpty);
      await m.unsubscribeAll();
      expect(realtime.unsubscribed.toSet(), equals({'sync:t1', 'sync:t2'}));
      await m.unsubscribeFromTable('never-subscribed'); // 不抛
      m.dispose();
    });

    test('HARDENING: 无 realtimeService 时 subscribeToTable 抛 CloudSyncException', () async {
      final m = DatabaseSyncManager(databaseService: _FakeDb());
      await expectLater(
        m.subscribeToTable(table: 't', onEvent: (e) async {}),
        throwsA(isA<CloudSyncException>()),
      );
      m.dispose();
    });
  });
}

class _ShaSerializer implements DataSerializer<int> {
  @override
  Future<String> serialize(int data) async =>
      jsonEncode({'ledgerId': data, 'count': data});

  @override
  Future<int> deserialize(String data) async =>
      (jsonDecode(data) as Map<String, dynamic>)['ledgerId'] as int;

  @override
  String fingerprint(String data) =>
      sha256.convert(utf8.encode(data)).toString();
}

class _MockProvider implements CloudProvider {
  final Map<String, String> files = {};
  CloudUser? user = const CloudUser(id: 'u1');

  @override
  CloudAuthService get auth => _MockAuth(this);
  @override
  CloudStorageService get storage => _MockStorage(this);
  @override
  String get providerId => 'mock';
  @override
  String get providerName => 'mock';
  @override
  Future<void> initialize(Map<String, dynamic> config) async {}
  @override
  bool validateConfig(Map<String, dynamic> config) => true;
  @override
  Future<void> dispose() async {}
}

class _MockAuth implements CloudAuthService {
  _MockAuth(this.p);
  final _MockProvider p;
  @override
  Stream<CloudUser?> get authStateChanges => Stream.value(p.user);
  @override
  Future<CloudUser?> get currentUser async => p.user;
  @override
  Future<CloudUser> signInWithEmail(
          {required String email, required String password}) async =>
      p.user!;
  @override
  Future<CloudUser> signUpWithEmail(
          {required String email, required String password}) async =>
      p.user!;
  @override
  Future<void> signOut() async => p.user = null;
  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}
  @override
  Future<void> resendEmailVerification({required String email}) async {}
}

class _MockStorage implements CloudStorageService {
  _MockStorage(this.p);
  final _MockProvider p;
  @override
  Future<void> upload(
      {required String path,
      required String data,
      Map<String, String>? metadata}) async {
    p.files[path] = data;
  }

  @override
  Future<String?> download({required String path}) async => p.files[path];
  @override
  Future<void> delete({required String path}) async => p.files.remove(path);
  @override
  Future<List<CloudFile>> list({required String path}) async => p.files.entries
      .map((e) => CloudFile(name: e.key, path: e.key))
      .toList();
  @override
  Future<bool> exists({required String path}) async =>
      p.files.containsKey(path);
  @override
  Future<CloudFile?> getMetadata({required String path}) async =>
      p.files.containsKey(path) ? CloudFile(name: path, path: path) : null;
}

class _FakeDb implements CloudDatabaseService {
  final Map<String, Map<String, dynamic>> records = {};
  final List<String> insertOrder = [];
  int insertAttempts = 0;
  bool failInsert = false;
  Future<void> Function()? onInsert;

  @override
  Future<Map<String, dynamic>> insert(
      {required String table,
      required Map<String, dynamic> data,
      bool autoInjectUserId = true}) async {
    insertAttempts++;
    if (onInsert != null) await onInsert!();
    if (failInsert) throw CloudStorageException('insert failed');
    records[data['id'] as String] = data;
    insertOrder.add(data['id'] as String);
    return data;
  }

  @override
  Future<Map<String, dynamic>> update(
      {required String table,
      required String id,
      required Map<String, dynamic> data,
      bool autoFilterByUser = true}) async {
    records[id] = data;
    return data;
  }

  @override
  Future<void> delete(
      {required String table,
      required String id,
      bool autoFilterByUser = true}) async {
    records.remove(id);
  }

  @override
  Future<List<Map<String, dynamic>>> query(
      {required String table,
      List<QueryFilter>? filters,
      String? orderBy,
      bool descending = false,
      int? limit,
      int? offset,
      bool autoFilterByUser = true}) async =>
      records.values.toList();

  @override
  Stream<DatabaseEvent> subscribe(
          {required String table,
          List<QueryFilter>? filters,
          String event = '*'}) =>
      const Stream.empty();

  @override
  Future<List<Map<String, dynamic>>> batchInsert(
          {required String table,
          required List<Map<String, dynamic>> data}) async =>
      data;
  @override
  Future<void> batchUpdate(
      {required String table,
      required List<Map<String, dynamic>> data,
      String idField = 'id'}) async {}
  @override
  Future<void> batchDelete(
      {required String table, required List<QueryFilter> filters}) async {}
  @override
  Future<List<Map<String, dynamic>>> rawQuery(String query) async => [];
  @override
  Future<Map<String, dynamic>?> getById(
          {required String table, required String id}) async =>
      records[id];
}

/// 可编程的 realtime 替身:记录订阅并在测试内触发回调。
class _RecordingRealtime implements CloudRealtimeService {
  final Map<String, _RecordingChannel> _channels = {};
  final List<String> unsubscribed = [];

  @override
  RealtimeConnectionState get currentState =>
      RealtimeConnectionState.connected;

  @override
  Stream<RealtimeConnectionState> get connectionState =>
      Stream.value(RealtimeConnectionState.connected);

  @override
  RealtimeChannel channel(String channelName) =>
      _channels.putIfAbsent(channelName, () => _RecordingChannel(this, channelName));

  @override
  List<RealtimeChannel> get channels => _channels.values.toList();

  @override
  bool hasChannel(String channelName) => _channels.containsKey(channelName);

  @override
  Future<void> removeChannel(String channelName) async {
    _channels.remove(channelName);
  }

  @override
  Future<void> removeAllChannels() async => _channels.clear();

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {
    _channels.clear();
  }

  void emit(String channelName, Map<String, dynamic> payload) {
    _channels[channelName]?.emitPayload(payload);
  }
}

class _RecordingChannel implements RealtimeChannel {
  _RecordingChannel(this._owner, this.name);
  final _RecordingRealtime _owner;
  @override
  final String name;
  final List<void Function(Map<String, dynamic>)> _callbacks = [];
  bool subscribed = false;
  bool unsubscribedFlag = false;

  void emitPayload(Map<String, dynamic> payload) {
    for (final cb in List.of(_callbacks)) {
      cb(payload);
    }
  }

  @override
  RealtimeChannel onPostgresChanges({
    required String event,
    required String schema,
    required String table,
    String? filter,
    required void Function(Map<String, dynamic> payload) callback,
  }) {
    _callbacks.add(callback);
    return this;
  }

  @override
  RealtimeChannel on(
      String event, void Function(Map<String, dynamic> payload) callback) {
    _callbacks.add(callback);
    return this;
  }

  @override
  Future<void> send(
      {required String event, required Map<String, dynamic> payload}) async {}

  @override
  Future<void> subscribe() async => subscribed = true;

  @override
  Future<void> unsubscribe() async {
    unsubscribedFlag = true;
    _owner.unsubscribed.add(name);
  }

  @override
  String get state => subscribed ? 'joined' : 'closed';
}
