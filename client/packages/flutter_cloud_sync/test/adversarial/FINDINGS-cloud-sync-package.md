# 对抗性测试报告 — flutter_cloud_sync

- **日期**: 2026-10-11(第二轮:上一轮限频中断,本轮盘点 → 运行 → 补漏 → 出报告)
- **范围**: `client/packages/flutter_cloud_sync`(仅测 `test/adversarial/` 下 4 个文件;未跑全量)
- **环境**: Flutter 3.27.3 / Dart 3.6.1;HTTP 用 MockClient、实时用 127.0.0.1 回环、时间用 fakeAsync,无外网依赖
- **约束**: 未改 `lib/**`,未改 3 个既有基线测试;仅编辑 4 个 adversarial 文件 + 本报告;删除了同目录 `_probe*.dart` 临时文件

## 1. 基线

```
flutter test test/cloud_sync_manager_test.dart test/utils/ --reporter compact
→ 00:16 +59: All tests passed!   (59/59,两轮运行结果一致)
```

`git status` 确认工作区仅新增 `test/adversarial/`(untracked),`lib/**` 与基线测试零改动。

## 2. 运行结果总览

| 测试文件 | 测试数 | 绿(HARDENING/保留) | 红(ADVERSE 确证) | 处置 |
|---|---|---|---|---|
| `path_and_retry_adversarial_test.dart` | 33 | 25 | **8** | 5 处断言判错已修正(翻绿),新增 2 测试 |
| `serializer_exceptions_adversarial_test.dart` | 28 | 24 | **4** | 3 处断言判错已修正,合并 1 组,新增 2 测试 |
| `auth_realtime_adversarial_test.dart` | 49 | 32 | **17** | 2 处断言判错已修正,新增 1 测试 |
| `store_manager_adversarial_test.dart` | 44 | 34 | **10** | 1 处编译错修复,6 处断言判错已修正,1 处重标,1 处改造 |
| **合计** | **154** | **115** | **39** | |

初轮运行(修正前):path 13 红 / serializer 7 红 / auth 19 红 / store 16 红(含 1 个编译失败),共 55 红。经"断言 vs 产品缺陷"逐条裁决,16 处翻绿、39 处确证保留红。

复现(单文件):

```bash
export PATH="$HOME/devtools/flutter-3.27.3-sdk/bin:$PATH"
cd /d/github/smartbook/client/packages/flutter_cloud_sync
flutter test test/adversarial/<file>_adversarial_test.dart --reporter compact
# 单条红项: ... --plain-name "<测试名>"
```

## 3. 断言修正记录(原红 → 翻绿,附理由)

| # | 测试(所在文件) | 原断言 | 判决理由 |
|---|---|---|---|
| 1 | `HARDENING: 反斜杠不当分隔符…`(path) | 期望 basename(`C:\x\y.json`)==`y.json` | 云对象键 POSIX 语义,'\' 非分隔符可辩护;风险降级为"整串透传"文档化 |
| 2 | `HARDENING: 反斜杠段整体透传…`(path) | 期望 `users\u\..\..\x`→`users/x` | 与 #1 前提一致:'\' 不是分隔符则其内 `..` 只是普通字符,无穿越语义 |
| 3 | `HARDENING: maxAttempts=0…`(path) | 期望操作执行 1 次 | `maxAttempts`=尝试次数,0 次执行与参数名自洽;改为固化"0 次 + 兜底 CloudSyncException 含混文案" |
| 4 | `HARDENING: maxAttempts<0…`(path) | 期望 ArgumentError | 非法配置抛基类异常是分类学欠缺而非崩溃,不构成确证缺陷 |
| 5 | `HARDENING: onRetry 回调抛错…`(path) | 期望回调异常被吞、重试 3 次 | 回调是调用方代码,快速失败可辩护;改为固化"回调异常顶掉原始异常"事实 |
| 6 | `HARDENING: JSON 超范围数字 1e999…`(serializer) | 期望 jsonDecode 抛 FormatException | 打错靶子:断言的是 dart:convert SDK 行为,包无法改;改为固化不对称性 + 包内防御 |
| 7 | `HARDENING: 不可编码数据(Infinity)…upload`(serializer,新增) | (原"往返断裂"红项) | upload 的 catch(e) 无类型过滤,已验证包成 CloudStorageException,不裸抛 → 改为绿 |
| 8 | `HARDENING: getStatus 的 catch 无类型过滤…`(serializer) | 期望 Error 向上冒泡 | "查询状态接口永不抛"是可辩护契约,调用方拿得到 SyncState.error;固化降级行为 |
| 9 | `HARDENING: expires_in≤30s 每次读取都 refresh`(auth) | 期望 0 次 refresh | token 确已"将过期",刷新是唯一正确动作,无缓存可复用;固化"读取频率=刷新频率" |
| 10 | `HARDENING: signOut 清凭证,device_id 残留`(auth) | 期望 device_id 一并清空 | 凭证(session:access+refresh)已验证清除;device_id 属设备身份非凭证,保留可辩护,只文档化残留 |
| 11 | `HARDENING: encodeCloudConfig 输入恒为标量…`(store) | 期望包内抛 CloudConfigurationException | 前提崩塌:循环引用在**参数求值阶段**就抛,进不了包代码;toJson 只输出标量,场景不可达 → 打错靶子 |
| 12 | `HARDENING: 未知 active_type 静默回退 local`(store) | 期望 `isNot(local)` | 未知后端没有可猜测的加载路径,回退 local 是唯一合理实现,断言不可实现;改为固化"与未配置同形、UI 无提示" |
| 13 | `HARDENING: 方向退化 unknown(信息不足)`(store) | 期望 direction≠unknown | 该用例双侧确实无可比信息(未传 localUpdatedAt、云端无 count/exportedAt),unknown 是诚实值 → 翻绿,并把真实缺口(uploadedAt 未作兜底)记为提示 |
| 14 | `HARDENING: TTL 窗口内云端变化不反映`(store) | 期望立即 outOfSync | TTL 缓存的既定语义(默认 30s,forceRefresh 可绕);翻绿并补 forceRefresh 绕过断言 |
| 15 | `HARDENING: 版本跳跃(≥+2)后 LWW 静默选本地`(store,原 ADVERSE) | 期望云端 999 胜出 | LWW-by-version 语义本地 9>5 本就该本地胜;真正的缺陷在另一分支(见红 R-30),此条翻绿固化"冲突静默" |
| 16 | `HARDENING: 缺 id 抛基类;双侧缺 version 本地优先`(store,原 ADVERSE) | 期望拒绝/保云端 | 与源码明示的 "Cannot determine, prefer local"(database_sync_manager:625-626)同口径,是设计选择 → 翻绿固化 |

其他修复:
- **编译错**:`store_manager:451` `await manager.clearCache()`(clearCache 返回 void)→ 去掉 await。
- **改造**:`saveAndActivate 不校验`红项改用 `baseUrl=null`(确定 invalid)配置,与"纯空白 valid=true"红项解耦,保证独立成立。
- **重标**:原 HARDENING「本地版本落后于云端」经实测(local 3 < cloud 5 时本地胜出)确认为产品缺陷,重标为 ADVERSE 红项(见 R-30)。
- **合并**:serializer 原 S1/S2 两条打 dart:convert 靶子的红项合并为一条 HARDENING。

## 4. 确证缺陷(红,39 条)

严重级:高=数据丢失/语义失效;中=契约违背/静默降级/覆盖风险;低=边界配置/可诊断性。

### 4.1 path_and_retry_adversarial_test.dart(8 红)

**R-1. `../` 段不被解析,穿越路径原样存活** — 中
- 证据:`lib/src/utils/path_helper.dart:14-27`(normalize 只收敛斜杠);下游消费 `packages/flutter_cloud_sync_webdav/lib/src/webdav_storage_service.dart:162`(`PathHelper.join([_remotePath, path])` 直接进 WebDAV URL,`..` 段会由服务端/URI 归一化逃出配置的 remotePath 根)、`flutter_cloud_sync_supabase/lib/src/supabase_storage_service.dart:241`
- 期望:`normalize('users/../../etc/passwd')=='etc/passwd'`(解析或拒绝,任选其一) | 实际:原样返回 `users/../../etc/passwd`
- 复现:`ADVERSE: ../ 段不被解析,穿越路径原样存活`

**R-2. userPath 允许 userId 逃出 users/ 命名空间** — 中
- 证据:`path_helper.dart:38-41`(join)、`:108-110`(userPath)
- 期望:`userPath('../..', ['x.json'])` 解析/净化后仍落在 `users/` 下 | 实际:`users/../../x.json`(解析后为 `x.json`)
- 复现:`ADVERSE: userPath 允许 userId 逃出 users/ 命名空间`

**R-3. `.` 与 `..` 被当作普通文件名字段** — 低
- 证据:`path_helper.dart:14-27, 71-79`
- 期望:`normalize('a/./b')=='a/b'`、`basename('a/.')=='a'` | 实际:原样 `a/./b`;`basename('a/.')=='.'`
- 复现:`ADVERSE: . 与 .. 被当作普通文件名字段`

**R-4. initialDelay 不受 maxDelay 约束(30s 首等 vs 100ms 上限)** — 低
- 证据:`lib/src/utils/retry_helper.dart:84, 109, 112-116`(首等直接用 initialDelay,maxDelay 只 clamp 后续计算值);`RetryConfig.maxDelay` 文档为 "Maximum delay between retries"(`:11`)
- 期望:任何单次等待 ≤ maxDelay → 500ms 内完成 | 实际:睡满 30s,fakeAsync 500ms 后未完成
- 复现:`ADVERSE: initialDelay 不受 maxDelay 约束(30s 首等 vs 100ms 上限)`

**R-5. 巨大 initialDelay(2^40 ms ≈ 34.8 年)原样睡下去** — 低
- 证据:`retry_helper.dart:109-116`(退避参数无上界校验)
- 期望:maxDelay=1s 截断 → 1 小时 fake 时间内完成 | 实际:未完成
- 复现:`ADVERSE: 巨大 initialDelay(2^40 ms)原样睡下去`

**R-6. backoffMultiplier=infinity 用 UnsupportedError 掩盖真实失败** — 低
- 证据:`retry_helper.dart:112-116`(`(x * infinity).round()` 抛 `Unsupported operation: Infinity or NaN toInt`)
- 期望:最终抛原始 `CloudStorageException`(重试 3 次) | 实际:首败后抛 `UnsupportedError`,原错误丢失
- 复现:`ADVERSE: backoffMultiplier=infinity 用 UnsupportedError 掩盖真实失败`

**R-7. backoffMultiplier=0 退化为零延迟重试风暴** — 低
- 证据:`retry_helper.dart:112-116`(×0 → clamp(0)=0,系数无校验)
- 期望:系数被校验(≥1)或每次重试至少间隔 initialDelay → 时间点 [0,5000,10000,15000] | 实际:[0,5000,5000,5000]
- 复现:`ADVERSE: backoffMultiplier=0 退化为零延迟重试风暴`

**R-8. HTTP 4xx(终态)仍被重试 3 次** — 中
- 证据:`retry_helper.dart:203-205`(默认对一切 CloudStorageException 重试);`lib/src/core/exceptions.dart:30-33`(异常不携带 statusCode,无法区分 4xx/5xx —— 关联 R-18)
- 期望:4xx 只尝试 1 次 | 实际:3 次(生产=无效请求重复提交)
- 复现:`ADVERSE: HTTP 4xx(终态校验失败)仍被重试 3 次`

### 4.2 serializer_exceptions_adversarial_test.dart(4 红)

**R-9. 云端内容损坏时 FormatException 摘录把云端字段带进异常文本** — 中
- 证据:`lib/src/manager/cloud_sync_manager.dart:181-187`(catch 后 `CloudStorageException('Download failed', e)`);dart `FormatException.toString()` 附输入前 ~78 字符摘录;App 侧 `client/lib/pages/cloud/cloud_sync_page.dart:187-188` 把 message 显示到界面
- 期望:异常/日志不含云端原始内容(备注/卡号) | 实际:测试实测异常文本含 `4242-4242-4242-4242`
- 复现:`ADVERSE: 云端内容损坏时,FormatException 摘录把云端字段带进异常文本`

**R-10. getStatus 兜底把原始异常文本塞进 SyncStatus.message** — 低
- 证据:`cloud_sync_manager.dart:387-394`(`message: 'Failed to get sync status: $e'`)
- 期望:message 为结构化错误分类、不含底层摘录 | 实际:`'Failed to get sync status: FormatException: boom-secret-fragment'`
- 复现:`ADVERSE: getStatus 兜底把原始异常文本塞进 SyncStatus.message`

**R-11. CloudStorageException 不携带 statusCode,无法区分 4xx/5xx** — 中
- 证据:`lib/src/core/exceptions.dart:2-33`(仅 message + dynamic originalError);`smartbook_cloud_provider.dart` 40+ 构造点只传 message,个别点(:2080/:2109)把 statusCode 塞进 originalError —— 口径不一致;直接后果即 R-8
- 期望:异常暴露可编程字段(如 `int? statusCode`) | 实际:dynamic 探测为 null,调用方只能解析 message 字符串
- 复现:`ADVERSE: CloudStorageException 不携带 statusCode,无法区分 4xx/5xx`

**R-12. 异常 toString 无条件展开 originalError,敏感内容整包进日志** — 中
- 证据:`lib/src/core/exceptions.dart:8-14`;`cloud_sync_manager.dart:129,388` 以 `$e` 直接落 logger;上游把响应/明细作为 originalError 传入
- 期望:记录时对 originalError 脱敏或截断 | 实际:`$e` 含 `token=eyJ...(SECRET)`
- 复现:`ADVERSE: 异常 toString 无条件展开 originalError,敏感响应整包进日志`
- 附:包内**未发现**把 access/refresh token 直接拼进 throw 文本(源码扫描 + 新增绿项 `HARDENING: 请求失败路径的异常文本不回显 access/refresh token`)—— 泄漏面是"响应内容/摘录",不是凭证本身

### 4.3 auth_realtime_adversarial_test.dart(17 红)

**R-13. 空字符串 access/refresh token 被全盘接受** — 低
- 证据:`smartbook_cloud_provider.dart:3580-3610`(`fromAuthResponse` 只做 `is String` 类型校验)
- 期望:空 token 视为非法响应,signIn 抛 CloudAuthException | 实际:登录"成功",后续 `Bearer ` 空凭证 401 循环
- 复现:`ADVERSE: 空字符串 access/refresh token 被全盘接受`

**R-14. 超长 token(1MB)无长度校验,直进请求头/存储** — 低
- 证据:同上(:3580-3610 无长度上限);`_saveSession`:1705-1711 直写 SharedPreferences
- 期望:明显超长 token 被拒(<8KB) | 实际:接受 1048576 字节并持久化
- 复现:`ADVERSE: 超长 token(1MB)无长度校验,直接进请求头/存储`

**R-15. expires_in 极大(1e19)→ 会话永久处于"已过期"态** — 低
- 证据:`smartbook_cloud_provider.dart:3596-3607`(`expiresIn.toInt()` 饱和 int64 → `Duration(seconds:)` 微秒乘法溢出为负 → 过期时间落在过去)、`:1753-1757`(30s 提前量判定)
- 期望:刚登录的会话 `isAccessTokenExpired==false` | 实际:true(每次读取都 refresh,rotating token 下=持续轮换)
- 复现:`ADVERSE: expires_in 极大(1e19)→ 会话永久处于"已过期"态`

**R-16. expires_in 为 Infinity(JSON 1e999)直接崩在 round,穿透登录路径** — 低
- 证据:`smartbook_cloud_provider.dart:3596-3607`(`num` 类型校验放行 Infinity → `.toInt()` 抛 UnsupportedError)
- 期望:非法 expires_in → CloudAuthException | 实际:`UnsupportedError: Infinity or NaN toInt`(非包异常类型)
- 复现:`ADVERSE: expires_in 为 Infinity(JSON 1e999)直接崩在 round`

**R-17. signOut 后恢复凭证会把用户"自动登回去"(登出语义失效)** — 高
- 证据:`smartbook_cloud_provider.dart:1178-1195`(setRecoveryCredentials 存邮密)、`:1297-1298`(currentUser 静默重登)、`:1623-1642`(signOut 不清恢复凭证);App 注入点 `client/lib/providers/sync_providers.dart:634-638`
- 期望:signOut 后 currentUser 保持 null 直至主动登录 | 实际:返回原用户(测试实测共 2 次 login)
- 复现:`ADVERSE: signOut 后恢复凭证会把用户"自动登回去"`

**R-18. dispose() 后再 signOut 抛 StateError(流已关闭)** — 低
- 证据:`smartbook_cloud_provider.dart:1655-1658`(dispose 关闭 `_authStateController`)、`:1726-1731`(`_clearSession` 仍 `add(null)`)
- 期望:dispose 后内部回调为 no-op | 实际:`StateError: Cannot add new events after calling close`
- 复现:`ADVERSE: dispose() 后再 signOut 抛 StateError(流已关闭)`

**R-19. 2xx 但响应体非 JSON 时抛 FormatException,绕过 CloudStorageException** — 中
- 证据:`smartbook_cloud_provider.dart:4595-4601`(_decodeJsonObject 直接 jsonDecode);代表点 `:2014`(list)
- 期望:抛 CloudStorageException(包异常契约,可被 RetryHelper 分类) | 实际:裸 `FormatException`(反代 HTML 错误页 200 时即触发),调用方与重试策略都识别不了
- 复现:`ADVERSE: 2xx 但响应体不是 JSON 时抛 FormatException,绕过 CloudStorageException`

**R-20. /sync/ledgers 返回对象而非数组时静默视作"无云端账本"** — 中
- 证据:`smartbook_cloud_provider.dart:2014-2017`(非 List → `const []`);消费方 `client/lib/app.dart:308`、`sync_engine.dart:452`、`transactions_sync_manager.dart:601` 用 `list('')` 判定远端存在性
- 期望:形态不符抛 CloudStorageException | 实际:静默 `[]`(可能被当成"云端为空"走向上传/新建,覆盖风险)
- 复现:`ADVERSE: /sync/ledgers 返回对象而非数组时静默视作"无云端账本"`

**R-21. 404 与 2xx-损坏快照 不可区分(均返回 null)** — 中
- 证据:`smartbook_cloud_provider.dart:1917-1926`(snapshot/payload/content 形态不符也返回 null)
- 期望:损坏抛 CloudStorageException,与 404 区分 | 实际:两者同为 null,坏数据被当成"没有备份"
- 复现:`ADVERSE: 404 与 2xx-空快照 不可区分,坏数据被当成"没有备份"`

**R-22. change_id 为字符串时整个 pull 抛 TypeError → 同步永久卡死** — 高
- 证据:`smartbook_cloud_provider.dart:2193`(`(row['change_id'] as num?)` 裸转换在校验/`continue`(2198-2204)之**前**)
- 期望:畸形行跳过,余下 1 条照常返回 | 实际:`_TypeError` 贯穿整页 pullChanges;客户端拿到 0 条、服务端 cursor 未推进 → 下次同批 → 卡死
- 复现:`ADVERSE: change_id 为字符串时整个 pull 抛 TypeError(设计意图是跳过该行)`

**R-23. 缺字段的 change 被静默跳过,但 cursor 照常推进(变更永久丢失)** — 高
- 证据:`smartbook_cloud_provider.dart:2188-2204`(continue 丢行)与 `:2221-2223`(`if (persistCursor) _saveCursor(nextCursor)` 无条件落盘)
- 期望:有 change 被丢弃时不推进 cursor(或抛错重试) | 实际:3 条进 1 条出、cursor 落到 42(测试实测 prefs 含 42),被丢弃变更永久拉不回 —— 与 `server/docs/SYNC_ARCHITECTURE.md` "cursor 已推进但 apply 未完成"同类
- 复现:`ADVERSE: 缺字段的 change 被静默跳过,但 cursor 照常推进(变更永久丢失)`

**R-24. refresh 失败路径丢弃服务端 401 原因** — 低
- 证据:`smartbook_cloud_provider.dart:3442-3448`(固定文案 `'Session expired, please login again.'`,originalError=null)
- 期望:异常或 originalError 保留服务端 detail(device revoked 等) | 实际:`'$e | ${e.originalError}'` 不含 `revoked`
- 复现:`ADVERSE: refresh 失败路径丢弃服务端 401 原因,异常链中不可见`

**R-25. serverCursor 为非数字字符串时整帧被静默丢弃** — 中
- 证据:`smartbook_cloud_provider.dart:4513`(`as num?` 对 String 抛 TypeError)与 `:4527`(`catch (_) {}` 吞掉整帧)
- 期望:仅降级 serverCursor=null,事件照常投递 | 实际:事件消失(实测只收到 `connected`);App `client/lib/cloud/sync/sync_engine_realtime.dart:17` 依赖该事件触发 pull
- 复现:`ADVERSE: serverCursor 为非数字字符串时整帧被静默丢弃`

**R-26. dispose() 后再 start() 陷入无限重连循环** — 中
- 证据:`smartbook_cloud_provider.dart:4418-4424`(start 只查 `_running`)、`:4438-4440`(dispose 关 `_events`)、`:4471,4525`(StateError 被 catch → scheduleReconnect)
- 期望:dispose 后 start() no-op/抛错,不建连 | 实际:8 秒内建 2 条连接并按退避持续重连(每次新建 TCP)
- 复现:`ADVERSE: dispose() 后再 start() 会陷入无限重连循环`

**R-27. WS 握手被拒(401)时抛未捕获异步异常,事件流无错误信号** — 中
- 证据:`smartbook_cloud_provider.dart:4449-4476`(`WebSocketChannel.connect` 的 future 未被 await,不在 try/catch 内);App 侧 `client/lib/cloud/sync/sync_engine_realtime.dart:12-14` 的 `.catchError(...)` 捕获不到
- 期望:握手失败表现为 start() 抛错或 events 流 onError | 实际:异常逃逸到 Zone(测试进程被判失败),流上 errs 为空
- 复现:`ADVERSE: WS 握手被拒(401)时抛未捕获的异步异常`

**R-28. baseUrl 允许携带 userinfo(凭据进 URL/日志)** — 低
- 证据:`smartbook_cloud_provider.dart:1132-1136`(validateConfig 只查 scheme+host)
- 期望:`https://user:secret@h.test` 被拒 | 实际:validateConfig==true
- 复现:`ADVERSE: baseUrl 允许携带 userinfo(凭据进 URL/日志)`

**R-29. apiPrefix 允许路径穿越,请求被改写到 prefix 之外** — 低
- 证据:`smartbook_cloud_provider.dart:4581-4593`(_normalizeApiPrefix 只补/删斜杠,不拒 `..`);Uri 构造按 RFC 归一化
- 期望:非法 prefix 被拒,请求留在 `/api/v1` 下 | 实际:`/api/v1/../../etc` + `/auth/login` → 实际打到 `/etc/auth/login`
- 复现:`ADVERSE: apiPrefix 允许路径穿越,请求被改写到别的路径`

### 4.4 store_manager_adversarial_test.dart(10 红)

**R-30. 本地版本落后于云端时直通更新,旧本地覆盖更新的云端(数据丢失)** — 高
- 证据:`lib/src/manager/database_sync_manager.dart:553-555`(`localVersion <= cloudVersion` → "no conflict" 返回 null)→ `:296-301`(无冲突直通 `update(data: localRecord)`);讽刺点:`_resolveConflict` LWW 分支(`:606-610`)对 3 vs 5 本会选 cloudRecord,但该分支永远不执行
- 期望:local 3 < cloud 5 → 走冲突处理保云端(或拒绝) | 实际:`amount=1` 覆盖 `999`,云端变更静默丢失
- 复现:`ADVERSE: 本地版本落后于云端时直通更新,旧本地覆盖更新的云端`

**R-31. 超过 maxRetryAttempts 的操作被静默丢弃(无 dead-letter)** — 中
- 证据:`database_sync_manager.dart:374-383`(超次数只 `logger.error` 后不回队、不入失败列表,successCount 不含之)
- 期望:进入可查询 dead-letter(或返回失败列表/抛出) | 实际:轮询 6 次后队列为空(pending 0),仅尝试 3 次,操作消失
- 复现:`ADVERSE: 超过 maxRetryAttempts 的操作被静默丢弃(无 dead-letter)`

**R-32. 状态缓存按 path 命中,不校验入参 data 是否同一份** — 中
- 证据:`lib/src/manager/cloud_sync_manager.dart:221-228`(缓存键只有 path,命中时不重算本地指纹)
- 期望:data 1→999 后 `getStatus(data:999)` 的 localFingerprint 应等于 forceRefresh 结果 | 实际:返回 data=1 的旧指纹与旧状态(TTL 内"同一入参同一 path 不同 data"拿到过期答案)
- 复现:`ADVERSE: 状态缓存按 path 命中,不校验入参 data 是否同一份`

**R-33. 旧品牌 activeType 迁移成功,但配置里的旧枚举名会崩 → 静默回退 local** — 中
- 证据:`config/cloud_service_store.dart:33-38`(activeType 值迁移)+ `:12`(key 迁移)vs `:47-53`(decode 抛错被吞 → local);根因 `config/cloud_service_config.dart:136-137`(`values.firstWhere` 未知名 → StateError)
- 期望:旧枚举名迁移为 smartbookCloud(与 key 迁移同口径) | 实际:StateError 被吞 → `CloudBackendType.local`(云同步"消失")
- 复现:`ADVERSE: 旧品牌 activeType 迁移成功,但配置里的旧枚举名会崩`
- 注:旧枚举名具体拼写无 git 证据(仓库历史已重置),机制(activeType 迁移 + 配置体不迁移 → 静默降级)已实测确证

**R-34. valid 只看"非空",纯空白串通过校验** — 低
- 证据:`config/cloud_service_config.dart:76-97`(全分支 `?.isNotEmpty ?? false`,不 trim)
- 期望:`'   '` baseUrl / WebDAV 三要素判为无效 | 实际:`valid==true`(provider 初始化才失败,报"切换云服务失败"而非"请输入地址")
- 复现:`ADVERSE: valid 只看"非空",纯空白串通过校验`

**R-35. 未知后端类型让解码抛 StateError(无版本兼容层)** — 低
- 证据:`config/cloud_service_config.dart:136-137`(firstWhere 无默认;StateError 是 Error 家族,输入错误用了 Error 类型)
- 期望:未知类型回退 local 或抛 CloudConfigurationException(可分类) | 实际:`StateError: Bad state: No element`
- 复现:`ADVERSE: 未知后端类型让解码抛 StateError(无版本兼容层)`

**R-36. 缺 name / 数字型 s3Port 触发裸 _TypeError** — 低
- 证据:`config/cloud_service_config.dart:138`(`j['name'] as String`)、`:162`(`j['s3Port'] as int?`,9000.0 即崩)
- 期望:统一 CloudSyncException 或回退默认 | 实际:`_TypeError`(Error 家族)
- 复现:`ADVERSE: 缺 name / 数字型 s3Port 触发裸 _TypeError`

**R-37. saveAndActivate 不校验配置合法性,valid=false 也能激活** — 低
- 证据:`config/cloud_service_store.dart:152-189`(无条件写 key+activeType)vs `activate()`:223-284(检查 valid 返回 false)—— 两入口口径不一致
- 期望:拒绝(或返回失败) | 实际:`cloud_active_type='smartbook_cloud'` 被写入,下次 loadActive 得到 invalid 配置 → provider 初始化失败
- 复现:`ADVERSE: saveAndActivate 不校验配置合法性,valid=false 也能激活`

**R-38. manual 冲突策略异常里 table 字段是空串** — 低
- 证据:`database_sync_manager.dart:565, 584`(`table: ''` 注释 "Will be filled by caller" 但无调用方填充)→ `:635-637`
- 期望:异常含真实表名 | 实际:`Manual conflict resolution required: /1`
- 复现:`ADVERSE: manual 冲突策略抛出的异常里 table 字段是空串`

**R-39. dispose() 后再 queueOperation 抛 StateError** — 低
- 证据:`database_sync_manager.dart:678-684`(`_updateStatus` → `_statusController.add`)、`:701-705`(dispose 关闭 controller,无 isClosed 守卫)
- 期望:dispose 后状态更新 no-op | 实际:`StateError: Cannot add new events after calling close`(Riverpod 释放与 UI 回调竞态可命中)
- 复现:`ADVERSE: dispose() 后再 queueOperation 抛 StateError`

## 5. HARDENING 固化项(绿,115 条中的风险提示)

以下行为"可辩护但脆弱",已断言当前行为并通过,修复时会变红提示:

- **明文密码进 prefs**:smartbookCloud/supabase/webdav 密码与 S3 secret 以明文写 SharedPreferences(`cloud_service_config.dart:99-126`),App 导出 YAML 同样带出(`config_export_service.dart:2293`)—— 需平台 keystore,包内无法自修。
- **WS token 在 URL query**(`smartbook_cloud_provider.dart:4479-4494`):会落反代 access log(服务端 ws.py 已有首帧 auth 新流程,mobile 仍 query)。
- **重试无总预算/无 per-attempt 超时/无取消**:卡死操作永久挂起;极大 maxAttempts 事实上无界重试(新增测试固化 10s ≈ 10^4 次)。
- **重试不含幂等键**:副作用按次数叠加(包内未代为注入 Idempotency-Key)。
- **onRetry 回调异常顶掉原始异常**(见修正 #5)。
- **expires_in≤30s → 读取频率=refresh 频率**(rotating token 持续轮换,见修正 #9)。
- **TTL 窗口陈旧/缓存不区分云端版本与账号**(forceRefresh 可绕,见修正 #14)。
- **getStatus catch-all 吞 Error**(见修正 #8);`download/upload/delete` 同样 catch-all 包装(反而更安全)。
- **存储解析失败与"无数据"同形**:非 JSON → FormatException(R-19)之外,list `[]`、download null 等都缺结构化错误信号(R-20/21 红项的另一面)。
- **1MB WS 帧无上限**进内存;**大帧不崩**。
- **list prefix 是 startsWith**(`ledger_1` 命中 `ledger_10/100`);**空 path 在 list/exists 意为"全部"**,仅 upload/download 校验。
- **CRLF token 使请求构造失败**(http 包拦截,无头注入,但损坏 token 常驻无自愈)。
- **单段穿越/反斜杠/盘符/大小写/%00/Unicode 均原样透传**(见修正 #1 #2 及纯 `.` 用例)。
- **缺 version 时"无法判定则本地优先"**(见修正 #16)。

## 6. 攻击清单覆盖对照

| 清单项 | 覆盖 |
|---|---|
| 路径:`..` 穿越 / 空段 / 反斜杠 / 超长(400 字符>300) / Unicode+emoji / `%00` / 纯 `.` / 前导 `/` / 盘符 `:` / 大小写 | ✅ 全覆盖(R-1~3 + HARDENING) |
| 重试:0/负/极大 maxAttempts / 退避溢出(infinity、1e300、2^40) / 4xx 不重试 / 取消与超时 / 重试叠副作用 | ✅ 全覆盖(R-4~8 + HARDENING;极大 maxAttempts 本轮新增) |
| 序列化:int/double 精度、bool、null、嵌套 / 日期往返 / Unicode+控制字符 / 1MB 字符串 / 100 层嵌套(含 10000 层 StackOverflow) / 非法 JSON 异常类型 | ✅ 全覆盖 |
| 异常分类:未知异常兜底 / **message 不泄漏 token**(运行时断言 + 源码扫描,本轮新增) | ✅ |
| 认证:token null(畸形响应)/ 空 / 超长 / 非法字符(CRLF) / 登出残留(凭证已清+device_id 残留) / 并发 refresh 去重 | ✅ 全覆盖 |
| 实时:畸形 JSON 帧 / 未知 event type / 超大 1MB 帧 / 空消息 → 不关流;握手失败不得抛未捕获异常 | ✅ 全覆盖 |
| 配置存储:损坏 JSON / 缺字段 / 版本不匹配(未知 type、旧枚举名) / 并发写(撕裂组合) | ✅ 全覆盖 |

## 7. 未能验证 / 已知边界

1. **旧枚举名历史拼写**(`beecountCloud`):仓库 git 历史已重置(仅 `init` 提交),R-33 的机制实测确证,但"历史数据确实写过该名"无法从仓库内证明。
2. **跨包穿越的实际服务端效应**:R-1/R-2 只在 PathHelper 与 WebDAV/Supabase 的 join 代码层面证实;`flutter_cloud_sync_webdav`/`_s3` 等兄弟包未跑其测试,真实 WebDAV 服务器对 `..` 的解析行为未实测。
3. **服务端行为**(`server/`):ledger_id auto-create、ghost-ledger guard、cursor 推进语义等仅按源码/测试注释引用,未在本轮起服务验证。
4. **App 侧展示/调用面**:`cloud_sync_page`、`sync_engine(_realtime)`、`transactions_sync_manager` 等仅做静态引用,未做 UI 级复现。
5. **按任务要求未跑全量 `flutter test`**,主工程(client/)未回归;红项修复后需重跑 4 文件 + 基线。
6. **真实网络/真实 rotating refresh 服务器**行为以 MockClient 与回环模拟;wall-clock 断言已用 fakeAsync/超时豁免规避,但 R-26/R-27 类实时用例含固定等待(8s/400ms),慢机上裕度较大但非零。
7. `getStatus` 对 `localUpdatedAt` 存在时的方向判定路径(含 uploadedAt 兜底缺口)仅记为提示,未展开成红项。

## 8. 红项速览(修复优先级建议)

- **高(4)**: R-17(登出自动重登)、R-22(pull TypeError 卡死)、R-23(cursor 推进丢变更)、R-30(落后版本覆盖云端)
- **中(15)**: R-1, R-2, R-8, R-9, R-11, R-12, R-19, R-20, R-21, R-25, R-26, R-27, R-31, R-32, R-33
- **低(20)**: R-3~R-7, R-10, R-13~R-16, R-18, R-24, R-28, R-29, R-34~R-39
