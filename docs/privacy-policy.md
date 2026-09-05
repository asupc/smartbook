# SmartBook 原始记账证据隐私说明

更新日期：2026-09-05。适用于本仓库的原始证据通道及其 Web / 客户端查看功能。

## 默认关闭，由用户配置

- 原始短信、支付通知、账单详情页文本是否保存，由客户端「数据 → 隐私面板」控制。本机保存、SmartBook Cloud 服务端保存默认均关闭，两个开关互相独立。
- 支持默认策略及短信、通知、屏幕文本、截图、分享图片、链接文本的来源覆盖。本机与服务端分别配置保留天数。
- 策略按采集事件保存快照；修改只影响之后采集的新事件，不追溯收集之前未保存的正文，也不会自动修改旧证据的保留期限。需要立即清除既有内容或取消待上传内容时，请使用本机清理；已上传内容请另外使用服务端删除/清理。

## 保存内容与用途

可能保存事件标识、来源、采集/发生时间、发送者或应用包名、标题、原始文本及来源元数据。短信和支付详情可能包含金额、商户及账号片段，请只在信任的自托管实例上开启。

本证据通道保存文本及元数据，不提供截图原图上传/预览。图片附件及既有 AI 调用记录是独立功能，不能把这里的文本证据列表当作全部图片或 AI 历史的管理入口。

本机证据保存在自动记账事件表；服务端证据保存在独立表中，按登录用户隔离。共享账本成员不会仅因账本共享而看到你的原始证据。原始证据不写入普通交易的备注，也不进入 local_changes / sync_changes 交易同步事件流。

## 独立保留与上传恢复

- 仅本机保存：原文不经本证据通道上传。
- 仅服务端保存：本机仍会临时保存上传队列；上传成功即清除临时原文。离线、未登录或请求失败时保留到上传成功或服务端队列期限届满。
- 两端都保存：本机与服务端各自到期，服务端较短的保留期不会提前结束本机保留。
- 上传失败按持久化退避重试；启动、登录就绪、网络恢复、回到前台及应用存活期间的周期检查都可恢复处理。系统强制停止应用期间不会承诺后台持续运行；重新打开后恢复。
- 服务端到期证据不会通过列表或详情再次返回。服务进程启动及每 15 分钟清理到期存储；应用本机清理在启动、运行期间检查和打开隐私面板时执行。关闭中的设备无法执行本机物理清理。

## 查看与删除

Web「设置 → 原始记账证据」和客户端隐私面板的「服务端」数据源只读取当前账号自己的证据，提供来源/日期筛选（Web）、分页、详情、删除和清理。查看、刷新与删除不会再次提交原始文本给 AI，也不会触发自动记账。

- 本机清理不等于服务端清理，两端需分别操作。进行中的上传可能已被服务器接收；完全清理时请再检查服务端列表。
- 服务端单条删除和按来源/时间清理不可恢复，不删除已生成的交易，也不删除另一端独立保存的副本。
- Web 批量清理按确认框标明的来源和截止时间处理，覆盖所有分页，不受列表日期筛选影响。
- 导出的备份、服务商或自托管管理员管理的备份，不会被在线删除操作自动追溯擦除；如需清除备份，请另行管理备份保留策略。

## 与 AI 授权及既有功能的边界

证据留存设置不替代 AI 隐私授权或 AI 服务配置。是否调用 AI、向何处发送识别内容，以及既有 AI 调用记录/交易附件的保留，属于各自的独立功能。关闭这里的证据留存，不等于停用 AI，也不等于清除既有 AI 历史或图片附件；需要时请分别关闭或清理。

本说明是 SmartBook 二开的本地补充说明。应用内仍引用的上游官网隐私页不是本仓库可更新的文件，如其描述与本功能不同，以本说明列明的实际配置和功能边界为准。

---

# Raw evidence privacy summary (English)

Updated September 5, 2026. Local and server raw-evidence retention are separately opt-in and disabled by default. Per-source policies and retention windows are captured on each new event. Changing a policy does not collect previously discarded text or retroactively change existing records; clear the corresponding storage to remove existing evidence.

Server-only retention requires a temporary local upload queue. Successful uploads clear that temporary content; failed or offline uploads retry with persisted backoff until expiry. Server expiry never shortens a longer local retention window. Expired server records are hidden from readers and removed at startup and every 15 minutes. Local cleanup runs while the app is active, including when the privacy panel opens.

Evidence is private to the uploading account, including in shared ledgers. It stays out of transaction notes and normal transaction synchronization. The viewer supports text and metadata, not original screenshot images. Viewing, refreshing and deleting evidence never invokes AI or creates transactions.

Local and server deletion are independent and keep existing transactions. Server cleanup spans all pages and uses the source and cutoff stated in its confirmation, not the list date filter. An in-flight upload may already have reached the server; verify the server list when clearing both copies. Online deletion does not erase separately managed backups.

AI requests, existing AI call history, and image attachments have separate controls and retention. Disabling this evidence channel does not disable AI or erase those other records. This local supplement describes the SmartBook fork; it does not update the upstream website.
