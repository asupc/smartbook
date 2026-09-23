import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get aiConsentTitle => '开启 AI 功能前,请知悉';

  @override
  String get aiConsentBody => 'AI 功能需将相关数据发送给你所配置的第三方 AI 服务商进行处理:\n\n• 发送给谁:默认「智谱 GLM」(open.bigmodel.cn,由智谱华章运营);若你自行配置了其它第三方 AI 服务商,则发送给你填写的服务商。\n• 发送什么:你主动用于识别/对话的内容 —— 账单图片、语音录音、你输入的文字,以及为完成识别/分析所需的分类名称、账户名称和相关交易记录。\n• 用途:仅用于账单识别、记账与你发起的对话分析;智记自身不收集、不存储这些数据。\n\n数据由该第三方服务商按其隐私政策处理。开启即表示你同意上述数据共享。';

  @override
  String get aiConsentAgree => '同意并开启';

  @override
  String get aboutPrivacyPolicy => '隐私政策';

  @override
  String get aboutChangelog => '更新日志';

  @override
  String get appTitle => '智记';

  @override
  String get tabHome => '明细';

  @override
  String get tabInsights => '洞察';

  @override
  String get tabAssets => '资产';

  @override
  String get tabRecord => '记账';

  @override
  String get tabAiAssistant => 'AI 助手';

  @override
  String get tabMine => '我的';

  @override
  String get commonCancel => '取消';

  @override
  String get commonConfirm => '确定';

  @override
  String get commonSave => '保存';

  @override
  String get commonDelete => '删除';

  @override
  String get commonAdd => '添加';

  @override
  String get commonEdit => '编辑';

  @override
  String get commonMore => '更多';

  @override
  String get commonOk => '确定';

  @override
  String get commonKnow => '知道了';

  @override
  String get commonNo => '否';

  @override
  String get commonEmpty => '暂无数据';

  @override
  String get commonError => '错误';

  @override
  String get commonSuccess => '成功';

  @override
  String get commonFailed => '失败';

  @override
  String get commonBack => '返回';

  @override
  String get commonNext => '下一步';

  @override
  String get fabActionCamera => '拍照';

  @override
  String get fabActionGallery => '相册';

  @override
  String get fabActionVoice => '语音';

  @override
  String get fabActionVoiceDisabled => '需要启用AI并配置API Key';

  @override
  String get fabActionManual => '记一笔';

  @override
  String get voiceRecordingTitle => '语音记账';

  @override
  String get voiceRecordingPreparing => '准备录音...';

  @override
  String get voiceRecordingInProgress => '正在录音...';

  @override
  String get voiceRecordingProcessing => '正在识别...';

  @override
  String voiceRecordingDuration(int duration) {
    return '录音时长: $duration秒';
  }

  @override
  String get voiceRecordingSuccess => '语音记账成功';

  @override
  String get voiceRecordingNoLedger => '未找到当前账本';

  @override
  String get voiceRecordingNoInfo => '未识别到记账信息';

  @override
  String get voiceRecordingPermissionDenied => '需要麦克风权限才能录音';

  @override
  String get voiceRecordingPermissionDeniedTitle => '需要麦克风权限';

  @override
  String get voiceRecordingPermissionDeniedMessage => '语音记账功能需要使用麦克风权限。请在系统设置中允许智记访问麦克风。';

  @override
  String voiceRecordingStartFailed(String error) {
    return '启动录音失败: $error';
  }

  @override
  String voiceRecordingFailed(String error) {
    return '录音失败: $error';
  }

  @override
  String voiceRecordingRecognizeFailed(String error) {
    return '识别失败: $error';
  }

  @override
  String voiceRecordingNoInfoDetected(String text) {
    return '未能识别账单信息: $text';
  }

  @override
  String get voiceRecordingNoSpeech => '未检测到语音输入';

  @override
  String get voiceRecordingHoldToTalk => '按住 说话';

  @override
  String get voiceRecordingReleaseToFinish => '松手结束录音';

  @override
  String get voiceRecordingTooShort => '录音时间过短';

  @override
  String get voiceRecordingResultLabel => '识别结果：';

  @override
  String get voiceRecordingAutoHintSpoken => '说完后停顿即可自动识别';

  @override
  String get voiceRecordingAutoHintWaiting => '请开始说话...';

  @override
  String get smartBillingVoiceTrigger => '语音触发方式';

  @override
  String get voiceTriggerModeAuto => '自动检测停顿';

  @override
  String get voiceTriggerModeAutoDesc => '录音后自动判断说完，适合短句快速记账';

  @override
  String get voiceTriggerModeHold => '按住说话';

  @override
  String get voiceTriggerModeHoldDesc => '长按录音、松开结束，适合一次说较多内容';

  @override
  String get smartBillingVoiceSilenceTimeout => '停顿结束时长';

  @override
  String smartBillingVoiceSilenceTimeoutValue(String seconds) {
    return '停顿 $seconds 秒后自动结束识别';
  }

  @override
  String get commonPrevious => '上一步';

  @override
  String get commonFinish => '完成';

  @override
  String get commonClose => '关闭';

  @override
  String get commonOther => '其他';

  @override
  String get commonYesterday => '昨天';

  @override
  String get commonSearch => '搜索';

  @override
  String get commonNoteHint => '备注…';

  @override
  String get commonSettings => '设置';

  @override
  String get commonGoSettings => '前往设置';

  @override
  String get commonLanguage => '语言';

  @override
  String get commonWeekdayMonday => '星期一';

  @override
  String get commonWeekdayTuesday => '星期二';

  @override
  String get commonWeekdayWednesday => '星期三';

  @override
  String get commonWeekdayThursday => '星期四';

  @override
  String get commonWeekdayFriday => '星期五';

  @override
  String get commonWeekdaySaturday => '星期六';

  @override
  String get commonWeekdaySunday => '星期日';

  @override
  String get commonCurrent => '当前';

  @override
  String get commonTutorial => '教程';

  @override
  String get commonConfigure => '配置';

  @override
  String get commonPressAgainToExit => '再按一次退出应用';

  @override
  String get homeIncome => '收入';

  @override
  String get homeExpense => '支出';

  @override
  String get homeBalance => '结余';

  @override
  String get homeNoRecords => '还没有记账';

  @override
  String get homeSelectDate => '选择日期';

  @override
  String get homeAppTitle => '智记';

  @override
  String get homeSearch => '搜索';

  @override
  String homeYear(Object year) {
    return '$year年';
  }

  @override
  String homeMonth(Object month) {
    return '$month月';
  }

  @override
  String get homeNoRecordsSubtext => '点击下方「AI 助手」记账，长按可手动记一笔';

  @override
  String homeNewRecordsCount(int count) {
    return '有 $count 条新记录';
  }

  @override
  String get homeViewNewRecords => '查看';

  @override
  String get homeLastMonthReportSubtitle => '查看上月消费报告并分享';

  @override
  String get homeLastMonthReportView => '查看';

  @override
  String homeAnnualReportReminder(int year) {
    return '$year年度账单已生成，回顾你的财务足迹';
  }

  @override
  String get homeAnnualReportView => '查看';

  @override
  String get widgetTodayExpense => '今日支出';

  @override
  String get widgetTodayIncome => '今日收入';

  @override
  String get widgetMonthExpense => '本月支出';

  @override
  String get widgetMonthIncome => '本月收入';

  @override
  String get widgetMonthSuffix => '月';

  @override
  String get widgetToday => '今日';

  @override
  String get widgetQuickAddLabel => '记一笔';

  @override
  String get widgetBudgetTotal => '总额';

  @override
  String get widgetBudgetRemaining => '剩';

  @override
  String get widgetNoBudget => '未设预算';

  @override
  String get widgetNoTransactions => '暂无交易';

  @override
  String get widgetRecentTransactions => '最近交易';

  @override
  String get widgetNoAccounts => '暂无账户';

  @override
  String get searchTitle => '搜索';

  @override
  String get searchHint => '搜索备注、分类或金额...';

  @override
  String get searchCategoryHint => '搜索分类名称...';

  @override
  String get searchCategoryFilter => '分类筛选';

  @override
  String get searchMinAmount => '最小金额';

  @override
  String get searchMaxAmount => '最大金额';

  @override
  String get searchNoInput => '输入关键词开始搜索';

  @override
  String get searchNoResults => '未找到匹配的结果';

  @override
  String get searchBatchMode => '批量操作';

  @override
  String searchBatchModeWithCount(int selected, int total) {
    return '批量操作 ($selected/$total)';
  }

  @override
  String get searchExitBatchMode => '退出批量操作';

  @override
  String get searchSelectAll => '全选';

  @override
  String get searchDeselectAll => '取消全选';

  @override
  String searchSelectedCount(int count) {
    return '已选择 $count 项';
  }

  @override
  String get searchBatchSetNote => '设置备注';

  @override
  String get searchBatchChangeCategory => '调整分类';

  @override
  String get searchBatchDeleteConfirmTitle => '确认删除';

  @override
  String searchBatchDeleteConfirmMessage(int count) {
    return '确定要删除选中的 $count 笔记账吗?\n此操作无法撤销。';
  }

  @override
  String get searchBatchSetNoteTitle => '批量设置备注';

  @override
  String searchBatchSetNoteMessage(int count) {
    return '将为选中的 $count 笔记账设置相同的备注';
  }

  @override
  String get searchBatchSetNoteHint => '输入备注内容 (留空则清空备注)';

  @override
  String searchBatchDeleteSuccess(int count) {
    return '成功删除 $count 笔记账';
  }

  @override
  String searchBatchDeleteFailed(String error) {
    return '删除失败: $error';
  }

  @override
  String searchBatchSetNoteSuccess(int count) {
    return '成功为 $count 笔记账设置备注';
  }

  @override
  String searchBatchSetNoteFailed(String error) {
    return '设置备注失败: $error';
  }

  @override
  String searchBatchChangeCategorySuccess(int count) {
    return '成功为 $count 笔记账调整分类';
  }

  @override
  String searchBatchChangeCategoryFailed(String error) {
    return '调整分类失败: $error';
  }

  @override
  String searchResultsCount(int count) {
    return '共 $count 条结果';
  }

  @override
  String get searchSummaryIncome => '收入';

  @override
  String get searchSummaryExpense => '支出';

  @override
  String get searchFilterTitle => '筛选';

  @override
  String get searchAmountFilter => '金额筛选';

  @override
  String get searchDateFilter => '时间筛选';

  @override
  String get searchStartDate => '开始日期';

  @override
  String get searchEndDate => '结束日期';

  @override
  String get searchNotSet => '未设置';

  @override
  String get searchClearFilter => '清空筛选';

  @override
  String get searchBatchCategoryTransferError => '选中的交易包含转账，无法修改分类';

  @override
  String get searchBatchCategoryTypeError => '选中的交易类型不一致，请选择全部为收入或全部为支出的交易';

  @override
  String get searchDateStart => '开始';

  @override
  String get searchDateEnd => '结束';

  @override
  String get analyticsMonth => '月';

  @override
  String get analyticsYear => '年';

  @override
  String get analyticsAll => '全部';

  @override
  String get analyticsCustom => '自定义';

  @override
  String get analyticsCompareLastMonth => '较上月';

  @override
  String get analyticsCompareSameMonthLastYear => '较去年同月';

  @override
  String get analyticsCompareLastYear => '较去年';

  @override
  String get analyticsComparePrevPrevYear => '较前年';

  @override
  String get analyticsAccountBreakdown => '账户分布';

  @override
  String get analyticsTopMerchants => '商户 Top';

  @override
  String get analyticsNoAccount => '未指定账户';

  @override
  String get analyticsCategoryRanking => '分类排行';

  @override
  String get analyticsTotalAmount => '总计';

  @override
  String get analyticsNoDataSubtext => '可左右滑动切换周期，或点击按钮切换收入/支出';

  @override
  String get analyticsSwipeHint => '左右滑动切换周期';

  @override
  String analyticsSwitchTo(Object type) {
    return '切换到$type';
  }

  @override
  String get analyticsTipHeader => '提示：顶部胶囊可切换 月/年/全部';

  @override
  String get analyticsSwipeToSwitch => '横滑切换';

  @override
  String get analyticsAllYears => '全部年份';

  @override
  String get analyticsToday => '今天';

  @override
  String get splashAppName => '智记';

  @override
  String get splashSlogan => '一笔一蜜';

  @override
  String get splashSecurityTitle => '开源数据安全';

  @override
  String get splashSecurityFeature1 => '• 数据本地存储，隐私完全自控';

  @override
  String get splashSecurityFeature2 => '• 开源代码透明，安全值得信赖';

  @override
  String get splashSecurityFeature3 => '• 可选云端同步，多设备数据一致';

  @override
  String get splashInitializing => '正在初始化数据...';

  @override
  String get ledgersTitle => '账本管理';

  @override
  String get ledgersNew => '新建账本';

  @override
  String get ledgersClear => '清空账本';

  @override
  String ledgersClearMessage(String name) {
    return '确定要清空账本\"$name\"的所有账单吗？此操作不可恢复。\\n账本本身会保留，仅删除账单数据。';
  }

  @override
  String get ledgerDefaultName => '默认账本';

  @override
  String get ledgersEdit => '编辑账本';

  @override
  String get ledgersDelete => '删除账本';

  @override
  String get ledgersDeleteConfirm => '删除账本';

  @override
  String get ledgersDeleteMessage => '确定要删除该账本及其全部记录吗？此操作不可恢复。\\n若云端存在备份，也会一并删除。';

  @override
  String get ledgersDeleted => '已删除';

  @override
  String get ledgersDeleteFailed => '删除失败';

  @override
  String get ledgersClearTitle => '清空账本';

  @override
  String get ledgersClearSuccess => '账本已清空';

  @override
  String get ledgersDeleteLocal => '仅删除本地账本';

  @override
  String get ledgersDeleteLocalTitle => '删除本地账本';

  @override
  String ledgersDeleteLocalMessage(String name) {
    return '确定要删除本地账本\"$name\"吗？\\n云端备份会保留，您可以随时恢复。';
  }

  @override
  String get ledgersDeleteLocalSuccess => '本地账本已删除';

  @override
  String get ledgersName => '名称';

  @override
  String get ledgersDefaultLedgerName => '默认账本';

  @override
  String get ledgersCurrency => '币种';

  @override
  String get ledgersMonthStartDay => '每月起始日';

  @override
  String get ledgersMonthStartDayHint => '统计与预算按该日作为每月周期起点（1-28）';

  @override
  String get ledgersMonthStartDayNatural => '1日（自然月）';

  @override
  String ledgersMonthStartDayValue(Object day) {
    return '每月$day日';
  }

  @override
  String get ledgersSelectCurrency => '选择币种';

  @override
  String get ledgersSearchCurrency => '搜索：中文或代码';

  @override
  String get ledgersCreate => '创建';

  @override
  String get ledgersActions => '操作';

  @override
  String ledgersRecords(Object count) {
    return '笔数：$count';
  }

  @override
  String ledgersBalance(Object balance) {
    return '余额：$balance';
  }

  @override
  String get ledgerCardDownloadCloud => '下载云账本';

  @override
  String get categoryTitle => '分类管理';

  @override
  String get categoryNew => '新建分类';

  @override
  String get categoryExpense => '支出';

  @override
  String get categoryIncome => '收入';

  @override
  String get categoryEmpty => '暂无分类';

  @override
  String get categoryDefault => '默认分类';

  @override
  String get categoryReorderTip => '长按分类可拖拽调整顺序';

  @override
  String categoryLoadFailed(Object error) {
    return '加载失败: $error';
  }

  @override
  String get iconPickerTitle => '选择图标';

  @override
  String get iconCategoryTransport => '交通';

  @override
  String get iconCategoryShopping => '购物';

  @override
  String get iconCategoryEntertainment => '娱乐';

  @override
  String get iconCategoryLife => '生活';

  @override
  String get iconCategoryHealth => '健康';

  @override
  String get iconCategoryEducation => '学习';

  @override
  String get iconCategoryWork => '工作';

  @override
  String get iconCategoryFinance => '理财';

  @override
  String get iconCategoryReward => '奖励';

  @override
  String get iconCategoryOther => '其他';

  @override
  String get importTitle => '导入账单';

  @override
  String get importBillType => '账单类型';

  @override
  String get importBillTypeGeneric => '通用CSV';

  @override
  String get importBillTypeAlipay => '支付宝';

  @override
  String get importBillTypeWechat => '微信';

  @override
  String get importChooseFile => '选择文件';

  @override
  String get importNoFileSelected => '未选择文件';

  @override
  String get importHint => '提示：请选择一个文件开始导入（支持 CSV/TSV/XLSX）';

  @override
  String get importReading => '读取文件中…';

  @override
  String get importPreparing => '准备中…';

  @override
  String importFileOpenError(String error) {
    return '无法打开文件选择器：$error';
  }

  @override
  String get mineTitle => '我的';

  @override
  String get mineReminder => '提醒设置';

  @override
  String get mineImport => '导入数据';

  @override
  String get mineExport => '导出数据';

  @override
  String get mineCloud => '云服务';

  @override
  String get mineUpdate => '检查更新';

  @override
  String get mineLanguageSettings => '语言';

  @override
  String get languageTitle => '语言设置';

  @override
  String get languageChinese => '中文';

  @override
  String get languageSystemDefault => '跟随系统';

  @override
  String get deleteConfirmTitle => '删除确认';

  @override
  String get deleteConfirmMessage => '确定要删除这条记账吗？';

  @override
  String get mineSlogan => '智记，智能自动';

  @override
  String get mineDisplayNameEditTitle => '设置昵称';

  @override
  String get mineDisplayNameHint => '输入昵称';

  @override
  String get mineDisplayNameSaved => '昵称已更新';

  @override
  String get mineGreetingMorning => '早上好';

  @override
  String get mineGreetingNoon => '中午好';

  @override
  String get mineGreetingAfternoon => '下午好';

  @override
  String get mineGreetingEvening => '晚上好';

  @override
  String get mineGreetingNight => '夜深了';

  @override
  String mineGreetingNamed(Object greeting, Object name) {
    return '$greeting，$name';
  }

  @override
  String get mineProfileEditTitle => '编辑资料';

  @override
  String get headerSkinTitle => '皮肤';

  @override
  String get headerSkinSubtitle => '跟随主题色,叠在头部之上';

  @override
  String get headerSkinGroupBasic => '基础';

  @override
  String get headerSkinGroupAnniversary => '周年纪念';

  @override
  String get headerSkinGroupGradient => '渐变';

  @override
  String get headerSkinGroupScene => '场景';

  @override
  String get headerSkinGroupPattern => '图案';

  @override
  String get headerSkinGroupGeometric => '几何艺术';

  @override
  String get headerSkinNone => '纯色';

  @override
  String get headerSkinAnniversary => '一岁星座';

  @override
  String get headerSkinAnnivCake => '周年蛋糕';

  @override
  String get headerSkinTabAll => '全部';

  @override
  String get headerSkinTabAnimated => '动态';

  @override
  String get headerSkinTabStatic => '静态';

  @override
  String get headerSkinAnimatedBadge => '动';

  @override
  String get headerSkinFixedPalette => '自带配色';

  @override
  String personalizeLockedBySkin(String skin) {
    return '当前皮肤「$skin」自带配色,主题色已随皮肤设定,暂不可更改。换回其它皮肤即可恢复你原来的颜色。';
  }

  @override
  String get personalizeFixedSkinAction => '换皮肤';

  @override
  String get headerSkinAurora => '极光';

  @override
  String get headerSkinMountains => '山峦';

  @override
  String get headerSkinBokeh => '光斑';

  @override
  String get headerSkinWaves => '波浪';

  @override
  String get headerSkinSunset => '日落';

  @override
  String get headerSkinClouds => '云朵';

  @override
  String get headerSkinExample => '示例';

  @override
  String get headerSkinHoneycomb => '蜂巢';

  @override
  String get headerSkinStarry => '星河';

  @override
  String get headerSkinStripes => '斜纹';

  @override
  String get headerSkinSkyline => '城市';

  @override
  String get headerSkinSakura => '樱花';

  @override
  String get headerSkinMeteor => '流星';

  @override
  String get headerSkinMemphis => '孟菲斯';

  @override
  String get headerSkinSilk => '丝带';

  @override
  String get headerSkinBubbles => '气泡';

  @override
  String get headerSkinGalaxy => '星系';

  @override
  String get headerSkinLowPoly => '低多边形';

  @override
  String get headerSkinPrism => '棱镜';

  @override
  String get headerSkinTerrazzo => '水磨石';

  @override
  String get mineAvatarTitle => '头像设置';

  @override
  String get mineAvatarFromGallery => '从相册选择';

  @override
  String get mineAvatarFromCamera => '拍照';

  @override
  String get mineAvatarDelete => '删除头像';

  @override
  String get annualReportTitle => '年度账单';

  @override
  String annualReportSubtitle(int year) {
    return '回顾你的$year年财务足迹';
  }

  @override
  String get annualReportEntrySubtitle => '生成专属年度报告，分享你的记账故事';

  @override
  String annualReportNoData(int year) {
    return '暂无$year年数据';
  }

  @override
  String get annualReportPage1Title => '年度总览';

  @override
  String annualReportPage1Subtitle(int year) {
    return '$year年记账之旅';
  }

  @override
  String get annualReportTotalDays => '记账天数';

  @override
  String get annualReportTotalRecords => '记账笔数';

  @override
  String get annualReportTotalIncome => '总收入';

  @override
  String get annualReportTotalExpense => '总支出';

  @override
  String get annualReportNetSavings => '年度结余';

  @override
  String get annualReportPage2Title => '支出分析';

  @override
  String get annualReportPage2Subtitle => '你的钱花在哪了';

  @override
  String get annualReportPage3Title => '月度趋势';

  @override
  String get annualReportPage3Subtitle => '12个月的收支变化';

  @override
  String get annualReportHighestMonth => '支出最高月份';

  @override
  String get annualReportLowestMonth => '支出最低月份';

  @override
  String get annualReportPage4Title => '特别时刻';

  @override
  String get annualReportPage4Subtitle => '那些值得铭记的账单';

  @override
  String get annualReportLargestExpense => '年度最大支出';

  @override
  String get annualReportLargestIncome => '年度最大收入';

  @override
  String get annualReportFirstRecord => '第一笔记录';

  @override
  String get annualReportPage5Title => '年度成就';

  @override
  String get annualReportPage5Subtitle => '你的记账成就徽章';

  @override
  String get annualReportAchievementConsistent => '持之以恒';

  @override
  String annualReportAchievementConsistentDesc(int days) {
    return '连续记账超过$days天';
  }

  @override
  String get annualReportAchievementSaver => '精打细算';

  @override
  String get annualReportAchievementSaverDesc => '年度结余为正';

  @override
  String get annualReportAchievementDetail => '明察秋毫';

  @override
  String annualReportAchievementDetailDesc(int count) {
    return '记账笔数超过$count笔';
  }

  @override
  String get annualReportShareButton => '生成分享海报';

  @override
  String get annualReportGenerating => '正在生成年度报告...';

  @override
  String get annualReportSaveSuccess => '年度报告海报已保存';

  @override
  String get mineShareApp => '分享应用';

  @override
  String get mineShareWithFriends => '和好友分享智记';

  @override
  String get mineCopyPromoText => '复制推广文案';

  @override
  String get mineCopyPromoSubtitle => '一键复制分享给好友';

  @override
  String get mineShareGenerating => '正在生成分享海报...';

  @override
  String get sharePosterAppName => '智记';

  @override
  String get sharePosterSlogan => '一笔一蜜，记录美好生活';

  @override
  String get sharePosterFeature1 => '数据安全·你做主';

  @override
  String get sharePosterFeature2 => '完全开源·可审计';

  @override
  String get sharePosterFeature3 => 'AI智能记账·图片语音';

  @override
  String get sharePosterFeature4 => '拍照记账·自动识别';

  @override
  String get sharePosterFeature5 => '多账本·暗黑模式';

  @override
  String get sharePosterFeature6 => '自建云同步·永久免费';

  @override
  String get sharePosterScanText => '扫码访问开源项目';

  @override
  String get appPromoTagOpenSource => '开源';

  @override
  String get appPromoTagFree => '免费';

  @override
  String get appPromoFooterText => '让每一笔都有迹可循';

  @override
  String userProfileJourneyYears(int years) {
    return '记账达人 $years 年';
  }

  @override
  String get userProfileJourneyOneYear => '记账满一年';

  @override
  String get userProfileJourneyHalfYear => '坚持记账半年';

  @override
  String get userProfileJourneyThreeMonths => '记账三个月';

  @override
  String get userProfileJourneyOneMonth => '记账满一个月';

  @override
  String get userProfileJourneyOneWeek => '记账一周';

  @override
  String get userProfileJourneyStart => '开始记账之旅';

  @override
  String get userProfileDailyAverage => '日均记账';

  @override
  String get sharePosterSave => '保存到相册';

  @override
  String get sharePosterShare => '分享';

  @override
  String get sharePosterHideIncome => '隐藏收入';

  @override
  String get sharePosterShowIncome => '显示收入';

  @override
  String get sharePosterSaveSuccess => '已保存到相册';

  @override
  String get shareGuidanceCopyText => '用智记记录生活，开源免费无广告！🐝 下载地址：https://github.com/TNT-Likely/BeeCount';

  @override
  String get shareGuidanceCopied => '文案已复制';

  @override
  String get sharePosterSaveFailed => '保存失败';

  @override
  String get sharePosterPermissionDenied => '相册权限被拒绝，请在设置中开启';

  @override
  String get sharePosterGenerating => '生成中...';

  @override
  String get sharePosterGenerateFailed => '生成海报失败，请重试';

  @override
  String get sharePosterNoLedger => '请先选择一个账本';

  @override
  String get sharePosterYearTitle => '我的记账年度报告';

  @override
  String get sharePosterYearSubtitle => '用数据记录生活 用理性规划未来';

  @override
  String get sharePosterMonthTitle => '月度账单报告';

  @override
  String get sharePosterMonthSubtitle => '精打细算 理性消费';

  @override
  String get sharePosterLedgerTitle => '账本统计报告';

  @override
  String get sharePosterRecordDays => '记账天数';

  @override
  String get sharePosterRecordCount => '记账笔数';

  @override
  String get sharePosterTotalExpense => '总支出';

  @override
  String get sharePosterTotalIncome => '总收入';

  @override
  String get sharePosterYearBalance => '年度结余';

  @override
  String get sharePosterYearDeficit => '年度赤字';

  @override
  String get sharePosterMonthBalance => '月度结余';

  @override
  String get sharePosterBalance => '总结余';

  @override
  String get sharePosterAvgMonthlyExpense => '月均支出';

  @override
  String get sharePosterAvgMonthlyIncome => '月均收入';

  @override
  String get sharePosterAvgDailyExpense => '日均支出';

  @override
  String get sharePosterMaxExpenseMonth => '支出最高月份';

  @override
  String get sharePosterTopExpense => 'TOP 3 支出';

  @override
  String get sharePosterCompareLastMonth => '环比上月';

  @override
  String get sharePosterIncreaseRate => '较上月增长';

  @override
  String get sharePosterDecreaseRate => '较上月减少';

  @override
  String get sharePosterSavedMoneyTitle => '恭喜！本月比上月省了';

  @override
  String get sharePosterLedgerName => '账本名称';

  @override
  String get sharePosterUnitDay => '天';

  @override
  String get sharePosterUnitCount => '笔';

  @override
  String get sharePosterUnitYuan => '元';

  @override
  String userProfilePosterStartDate(String date) {
    return '记账始于 $date';
  }

  @override
  String get userProfilePosterRecordDays => '记账天数';

  @override
  String get userProfilePosterDaysUnit => '天';

  @override
  String get userProfilePosterRecordCount => '记账笔数';

  @override
  String get userProfilePosterCountUnit => '笔';

  @override
  String get userProfilePosterLedgerCount => '账本数量';

  @override
  String get userProfilePosterLedgerUnit => '本';

  @override
  String get mineDaysCount => '记账天数';

  @override
  String get mineTotalRecords => '总笔数';

  @override
  String get mineCurrentBalance => '账本结余';

  @override
  String get mineCloudService => '云服务';

  @override
  String get mineCloudServiceLoading => '加载中…';

  @override
  String get mineCloudServiceOffline => '默认模式 (离线)';

  @override
  String get mineCloudServiceCustom => '自定义 Supabase';

  @override
  String get mineCloudServiceWebDAV => '自定义云服务 (WebDAV)';

  @override
  String get mineSyncTitle => '同步';

  @override
  String get mineSyncNotLoggedIn => '未登录';

  @override
  String get mineSyncNotConfigured => '未配置云端';

  @override
  String get mineSyncNoRemote => '云端暂无数据';

  @override
  String mineSyncInSync(Object count) {
    return '已同步 (本地$count条)';
  }

  @override
  String get mineSyncInSyncSimple => '已同步';

  @override
  String mineSyncLocalNewer(Object count) {
    return '本地有更新 (本地$count条, 建议上传)';
  }

  @override
  String get mineSyncLocalNewerSimple => '本地有更新';

  @override
  String get mineSyncCloudNewer => '云端有更新 (建议下载同步)';

  @override
  String get mineSyncCloudNewerSimple => '云端有更新';

  @override
  String get mineSyncDifferent => '本地与云端有差异，建议下载对比';

  @override
  String get mineSyncError => '状态获取失败';

  @override
  String get mineSyncDetailTitle => '同步状态详情';

  @override
  String mineSyncLocalRecords(Object count) {
    return '本地记录数: $count';
  }

  @override
  String mineSyncCloudRecords(Object count) {
    return '云端记录数: $count';
  }

  @override
  String mineSyncCloudLatest(Object time) {
    return '云端最新记账时间: $time';
  }

  @override
  String mineSyncLocalFingerprint(Object fingerprint) {
    return '本地指纹: $fingerprint';
  }

  @override
  String mineSyncCloudFingerprint(Object fingerprint) {
    return '云端指纹: $fingerprint';
  }

  @override
  String mineSyncMessage(Object message) {
    return '说明: $message';
  }

  @override
  String get mineUploadTitle => '上传';

  @override
  String get mineUploadNeedLogin => '需登录';

  @override
  String get mineUploadNeedCloudService => '仅限云服务模式可用';

  @override
  String get mineUploadInProgress => '正在上传中…';

  @override
  String get mineUploadRefreshing => '刷新中…';

  @override
  String get mineUploadSynced => '已同步';

  @override
  String get mineUploadSuccess => '已上传';

  @override
  String get mineUploadSuccessMessage => '当前账本已同步到云端';

  @override
  String get mineDownloadTitle => '下载同步';

  @override
  String get mineDownloadNeedCloudService => '仅限云服务模式可用';

  @override
  String get mineDownloadComplete => '同步完成';

  @override
  String mineDownloadResult(Object inserted) {
    return '导入：$inserted 条';
  }

  @override
  String get mineLoginTitle => '登录';

  @override
  String get mineLoginSubtitle => '仅在同步时需要';

  @override
  String get cloudReloginTitle => '重新登录';

  @override
  String get cloudReloginSuccess => '已重新登录';

  @override
  String get cloudReloginFailed => '重新登录失败';

  @override
  String get mineLoggedInEmail => '已登录';

  @override
  String get mineLogoutSubtitle => '点击可退出登录';

  @override
  String get mineLogoutConfirmTitle => '退出登录';

  @override
  String get mineLogoutConfirmMessage => '确定要退出当前账号登录吗？\n退出后将无法使用云同步功能。';

  @override
  String get mineLogoutButton => '退出';

  @override
  String get mineAutoSyncTitle => '自动同步账本';

  @override
  String get mineAutoSyncSubtitle => '记账后自动上传到云端';

  @override
  String get mineAutoSyncNeedLogin => '需登录后可开启';

  @override
  String get mineImportProgressTitle => '后台导入中…';

  @override
  String mineImportProgressSubtitle(Object done, Object fail, Object ok, Object total) {
    return '进度：$done/$total，成功 $ok，失败 $fail';
  }

  @override
  String get mineImportCompleteTitle => '导入完成';

  @override
  String get mineCategoryManagement => '分类管理';

  @override
  String get mineCategoryManagementSubtitle => '编辑自定义分类';

  @override
  String get mineCategoryMigration => '分类迁移';

  @override
  String get mineCategoryMigrationSubtitle => '将分类数据迁移到其他分类';

  @override
  String get mineRecurringTransactions => '周期账单';

  @override
  String get mineRecurringTransactionsSubtitle => '管理周期性账单';

  @override
  String get mineReminderSettings => '记账提醒';

  @override
  String get mineReminderSettingsSubtitle => '设置每日记账提醒';

  @override
  String get minePersonalize => '个性装扮';

  @override
  String get mineDisplayScale => '显示缩放';

  @override
  String get mineDisplayScaleSubtitle => '调整文字和界面元素大小';

  @override
  String get mineCheckUpdate => '检测更新';

  @override
  String get mineCheckUpdateSubtitle => '正在检查最新版本';

  @override
  String get mineUpdateDownload => '下载更新';

  @override
  String get mineFeedback => '问题反馈';

  @override
  String get mineFeedbackSubtitle => '提交问题或建议';

  @override
  String get mineHelp => '使用帮助';

  @override
  String get helpCenterOpenInBrowser => '在浏览器中打开';

  @override
  String get helpCenterLoadFailed => '加载失败，请检查网络';

  @override
  String get helpCenterRetry => '重试';

  @override
  String get mineHelpSubtitle => '查看使用文档和常见问题';

  @override
  String get mineSupportAuthor => '给项目 Star ⭐️';

  @override
  String mineSupportAuthorSubtitle(String count) {
    return '开源免费，已有 $count 人 Star';
  }

  @override
  String get githubStarGuideTitle => '如何给项目 Star';

  @override
  String get githubStarGuideContent => '点击下方按钮打开 GitHub 页面后，点击图中标注的位置即可完成 Star';

  @override
  String get githubStarGuideButton => '前往 GitHub';

  @override
  String get categoryEditTitle => '编辑分类';

  @override
  String get categoryNewTitle => '新建分类';

  @override
  String get categoryDetailTooltip => '分类详情';

  @override
  String get categoryMigrationTooltip => '分类迁移';

  @override
  String get categoryMigrationTitle => '分类迁移';

  @override
  String get categoryMigrationDescription => '分类迁移说明';

  @override
  String get categoryMigrationDescriptionContent => '• 将指定分类的所有交易记录迁移到另一个分类\n• 迁移后，原分类的交易数据将全部转移到目标分类\n• 此操作不可撤销，请谨慎选择';

  @override
  String get categoryMigrationTypeLabel => '选择类型';

  @override
  String get categoryMigrationFromLabel => '迁出分类';

  @override
  String get categoryMigrationFromHint => '选择要迁出的分类';

  @override
  String get categoryMigrationToLabel => '迁入分类';

  @override
  String get categoryMigrationToHint => '选择迁入的分类';

  @override
  String get categoryMigrationToHintFirst => '请先选择迁出分类';

  @override
  String get categoryMigrationStartButton => '开始迁移';

  @override
  String get categoryMigrationCannotTitle => '无法迁移';

  @override
  String get categoryMigrationCannotMessage => '选择的分类无法进行迁移，请检查分类状态。';

  @override
  String get categoryExpenseType => '支出分类';

  @override
  String get categoryIncomeType => '收入分类';

  @override
  String get categoryDefaultTitle => '默认分类';

  @override
  String get categoryNameLabel => '分类名称';

  @override
  String get categoryNameHint => '请输入分类名称';

  @override
  String get categoryNameRequired => '请输入分类名称';

  @override
  String get categoryNameTooLong => '分类名称不能超过4个字';

  @override
  String get categoryNameDuplicate => '分类名称已存在';

  @override
  String get categoryIconLabel => '分类图标';

  @override
  String get categoryCustomIconTitle => '自定义图标';

  @override
  String get categoryCustomIconTapToSelect => '点击选择图片';

  @override
  String get categoryCustomIconTapToChange => '点击更换图片';

  @override
  String get categoryCustomIconError => '选择图片时出错';

  @override
  String get categoryCustomIconRequired => '请选择自定义图标图片';

  @override
  String get categoryCustomIconCrop => '裁剪图标';

  @override
  String get categoryDangerousOperations => '危险操作';

  @override
  String get categoryDeleteTitle => '删除分类';

  @override
  String get categoryDeleteSubtitle => '删除后无法恢复';

  @override
  String get categorySaveError => '保存失败';

  @override
  String categoryUpdated(Object name) {
    return '分类\"$name\"已更新';
  }

  @override
  String categoryCreated(Object name) {
    return '分类\"$name\"已创建';
  }

  @override
  String get categoryCannotDelete => '无法删除';

  @override
  String categoryCannotDeleteMessage(Object count) {
    return '该分类下还有 $count 笔交易记录，请先处理这些记录。';
  }

  @override
  String get categoryShare => '分享分类';

  @override
  String get categoryImport => '导入分类';

  @override
  String get categoryClearUnused => '清空未使用分类';

  @override
  String get categoryClearUnusedTitle => '清空未使用分类';

  @override
  String categoryClearUnusedMessage(int count) {
    return '确定要删除 $count 个未使用的分类吗？此操作无法撤销。';
  }

  @override
  String get categoryClearUnusedListTitle => '将被删除的分类：';

  @override
  String get categoryClearUnusedEmpty => '没有未使用的分类';

  @override
  String categoryClearUnusedSuccess(int count) {
    return '已删除 $count 个分类';
  }

  @override
  String get categoryClearUnusedFailed => '清空失败';

  @override
  String get categoryShareScopeTitle => '选择分享范围';

  @override
  String get categoryShareScopeExpense => '仅支出分类';

  @override
  String get categoryShareScopeIncome => '仅收入分类';

  @override
  String get categoryShareScopeAll => '全部分类';

  @override
  String categoryShareSuccess(String path) {
    return '已保存到 $path';
  }

  @override
  String get categoryShareSubject => '智记 分类配置';

  @override
  String get categoryShareFailed => '分享失败';

  @override
  String get categoryImportInvalidFile => '请选择分类包文件（.zip）';

  @override
  String get categoryImportModeTitle => '选择导入模式';

  @override
  String get categoryImportModeMerge => '合并';

  @override
  String get categoryImportModeMergeDesc => '保留现有分类，新增不存在的';

  @override
  String get categoryImportModeOverwrite => '覆盖';

  @override
  String get categoryImportModeOverwriteDesc => '清空未使用分类后导入';

  @override
  String get categoryImportSuccess => '导入成功';

  @override
  String categoryImportSuccessDetail(int imported, int skipped, int icons) {
    return '已导入 $imported 个分类，跳过 $skipped 个，导入 $icons 个图标';
  }

  @override
  String get categoryImportFailed => '导入失败';

  @override
  String get categoryDeleteConfirmTitle => '删除分类';

  @override
  String categoryDeleteConfirmMessage(Object name) {
    return '确定要删除分类\"$name\"吗？此操作无法撤销。';
  }

  @override
  String get categoryDeleteError => '删除失败';

  @override
  String categoryDeleted(Object name) {
    return '分类\"$name\"已删除';
  }

  @override
  String get categorySubCategoryTitle => '二级分类';

  @override
  String get categorySubCategoryDescriptionEnabled => '此分类属于某个一级分类';

  @override
  String get categorySubCategoryDescriptionDisabled => '此分类为独立的一级分类';

  @override
  String get categoryParentCategoryTitle => '父分类';

  @override
  String get categoryParentCategoryHint => '请选择父分类';

  @override
  String get categorySelectParentTitle => '选择父分类';

  @override
  String categorySubCategoryCreated(Object name) {
    return '已添加二级分类：$name';
  }

  @override
  String get categoryParentRequired => '请选择父分类';

  @override
  String get categoryParentRequiredTitle => '错误';

  @override
  String get categoryExpenseList => '餐饮-交通-购物-娱乐-居家-家庭-通讯-水电-住房-医疗-教育-宠物-运动-数码-旅行-烟酒-母婴-美容-维修-社交-学习-汽车-打车-地铁-外卖-物业-停车-捐赠-送礼-纳税-饮料-服装-零食-发红包-水果-游戏-书-爱人-装修-日用品-彩票-股票-社保-快递-工作';

  @override
  String get categoryIncomeList => '工资-理财-收红包-奖金-报销-兼职-收礼-利息-退款-投资收益-二手转卖-社会保障-退税退费-公积金';

  @override
  String get categoryExpenseDining => '餐饮-早餐-午餐-晚餐-美团外卖-饿了么外卖-京东外卖-餐厅-美食';

  @override
  String get categoryExpenseSnacks => '零食-饼干-薯片-糖果-巧克力-坚果';

  @override
  String get categoryExpenseFruit => '水果-苹果-香蕉-橙子-葡萄-西瓜-其他水果';

  @override
  String get categoryExpenseBeverage => '饮品-奶茶-咖啡-果汁-汽水-矿泉水';

  @override
  String get categoryExpensePastry => '糕点-蛋糕-面包-甜点-曲奇';

  @override
  String get categoryExpenseCooking => '做饭食材-蔬菜-肉类-水产-调料-粮油';

  @override
  String get categoryExpenseShopping => '购物-服装-鞋帽-包包-配饰-日用百货';

  @override
  String get categoryExpensePets => '宠物-宠物食品-宠物用品-宠物医疗-宠物美容';

  @override
  String get categoryExpenseTransport => '交通-地铁-公交-出租车-网约车-停车费-加油';

  @override
  String get categoryExpenseCar => '汽车-汽车保养-汽车维修-汽车保险-洗车-违章罚款';

  @override
  String get categoryExpenseClothing => '服饰-上衣-裤子-裙子-鞋子-服饰配件';

  @override
  String get categoryExpenseDailyGoods => '日用品-洗护用品-纸品-清洁用品-厨房用品';

  @override
  String get categoryExpenseEducation => '教育-学费-培训费-书籍-文具-办公用品';

  @override
  String get categoryExpenseInvestLoss => '投资亏损-股票亏损-基金亏损-其他投资亏损';

  @override
  String get categoryExpenseEntertainment => '娱乐-电影-KTV-游乐场-酒吧-其他娱乐';

  @override
  String get categoryExpenseGame => '游戏-游戏充值-游戏装备-游戏会员';

  @override
  String get categoryExpenseHealthProducts => '保健品-维生素-保健食品-营养品';

  @override
  String get categoryExpenseSubscription => '订阅服务-视频会员-音乐会员-云存储-其他订阅';

  @override
  String get categoryExpenseSports => '运动-健身房-运动装备-运动课程-户外活动';

  @override
  String get categoryExpenseHousing => '住房-房租-物业费-房贷-装修';

  @override
  String get categoryExpenseHome => '居家-家具-家电-装饰品-床上用品';

  @override
  String get categoryExpenseBeauty => '美容-护肤品-化妆品-美容美发-美甲';

  @override
  String get categoryIncomeSalary => '工资-基本工资-绩效奖金-年终奖-加班费';

  @override
  String get categoryIncomeInvestment => '理财-基金收益-股票分红-理财产品-其他理财';

  @override
  String get categoryIncomeRedPacket => '红包-节日红包-生日红包-随礼回礼';

  @override
  String get categoryIncomeBonus => '奖金-年度奖金-季度奖-项目奖金-其他奖金';

  @override
  String get categoryIncomeReimbursement => '报销-差旅报销-餐费报销-其他报销';

  @override
  String get categoryIncomePartTime => '兼职-兼职收入-外快';

  @override
  String get categoryIncomeGift => '礼金-结婚礼金-生日礼金-其他礼金';

  @override
  String get categoryIncomeInterest => '利息-银行利息-其他利息';

  @override
  String get categoryIncomeRefund => '退款-购物退款-服务退款-其他退款';

  @override
  String get categoryIncomeInvestIncome => '投资收益-股票收益-基金投资-其他投资收益';

  @override
  String get categoryIncomeSecondHand => '二手交易-闲置物品-二手商品';

  @override
  String get categoryIncomeSocialBenefit => '社会福利-失业保险-生育津贴-其他补贴';

  @override
  String get categoryIncomeTaxRefund => '退税-个税退税-其他退费';

  @override
  String get categoryIncomeProvidentFund => '公积金-公积金提取-公积金利息';

  @override
  String get personalizeTitle => '主题色';

  @override
  String get personalizeSubtitle => '选择或自定义应用主题色';

  @override
  String get personalizeCustomColor => '选择自定义颜色';

  @override
  String get personalizeCustomTitle => '自定义';

  @override
  String personalizeHue(Object value) {
    return '色相 ($value°)';
  }

  @override
  String personalizeSaturation(Object value) {
    return '饱和度 ($value%)';
  }

  @override
  String personalizeBrightness(Object value) {
    return '亮度 ($value%)';
  }

  @override
  String get personalizeSelectColor => '选择此颜色';

  @override
  String get appearanceThemeMode => '外观模式';

  @override
  String get appearanceThemeModeSystem => '跟随系统';

  @override
  String get appearanceThemeModeLight => '亮色模式';

  @override
  String get appearanceThemeModeDark => '暗黑模式';

  @override
  String get appearanceDarkModePattern => '暗黑模式头部图案';

  @override
  String get appearancePatternNone => '无';

  @override
  String get appearancePatternIcons => '图标平铺';

  @override
  String get appearancePatternParticles => '粒子星星';

  @override
  String get appearancePatternHoneycomb => '蜂巢六边形';

  @override
  String get appearanceAmountFormat => '余额显示格式';

  @override
  String get appearanceAmountFormatFull => '完整金额';

  @override
  String get appearanceAmountFormatFullDesc => '显示完整金额，如 123,456.78';

  @override
  String get appearanceAmountFormatCompact => '简洁显示';

  @override
  String get appearanceAmountFormatCompactDesc => '大金额缩写，如 12.3万（仅对账户余额生效）';

  @override
  String get appearanceSkinAnimation => '皮肤动效';

  @override
  String get appearanceSkinAnimationDesc => '关闭后动态皮肤停在静止画面，更省电';

  @override
  String get appearanceShowTransactionTime => '显示交易时间';

  @override
  String get appearanceShowTransactionTimeDesc => '在账单列表显示时分，编辑时可选择时间';

  @override
  String get appearanceNoteDisplay => '备注显示方式';

  @override
  String get appearanceNoteDisplayCategory => '分类优先';

  @override
  String get appearanceNoteDisplayCategoryDesc => '显示分类名,备注以括号附在后面';

  @override
  String get appearanceNoteDisplayNote => '备注优先';

  @override
  String get appearanceNoteDisplayNoteDesc => '有备注时显示备注,无备注时显示分类名';

  @override
  String get appearanceNoteHistory => '历史备注';

  @override
  String get appearanceNoteHistoryScope => '展示范围';

  @override
  String get appearanceNoteHistoryScopeAllCategories => '全部分类';

  @override
  String get appearanceNoteHistoryScopeCurrentCategory => '当前分类';

  @override
  String get appearanceNoteHistorySort => '排序方式';

  @override
  String get appearanceNoteHistorySortFrequency => '使用频次';

  @override
  String get appearanceNoteHistorySortRecent => '最近使用';

  @override
  String get appearanceNoteHistoryLimit => '显示数量';

  @override
  String get appearanceNoteHistoryLimitHint => '可设置 1 至 100 条';

  @override
  String get appearanceNoteHistoryLimitInvalid => '请输入 1 至 100 的整数';

  @override
  String get appearanceColorScheme => '收支颜色方案';

  @override
  String get appearanceColorSchemeOn => '红色收入 · 绿色支出';

  @override
  String get appearanceColorSchemeOff => '红色支出 · 绿色收入';

  @override
  String get appearanceColorSchemeOnDesc => '红色表示收入，绿色表示支出';

  @override
  String get appearanceColorSchemeOffDesc => '红色表示支出，绿色表示收入';

  @override
  String fontSettingsCurrentScale(Object scale) {
    return '当前缩放：x$scale';
  }

  @override
  String get fontSettingsPreview => '实时预览';

  @override
  String get fontSettingsPreviewText => '今天吃饭花了 23.50 元，记一笔；\n本月已记账 45 天，共 320 条记录；\n坚持就是胜利！';

  @override
  String fontSettingsCurrentLevel(Object level, Object scale) {
    return '当前档位：$level  (倍率 x$scale)';
  }

  @override
  String get fontSettingsQuickLevel => '快速档位';

  @override
  String get fontSettingsCustomAdjust => '自定义调整';

  @override
  String get fontSettingsDescription => '说明：此设置确保所有设备在1.0倍时显示效果一致，设备差异已自动补偿；调整数值可在一致基础上进行个性化缩放。';

  @override
  String get fontSettingsExtraSmall => '极小';

  @override
  String get fontSettingsVerySmall => '很小';

  @override
  String get fontSettingsSmall => '较小';

  @override
  String get fontSettingsStandard => '标准';

  @override
  String get fontSettingsLarge => '较大';

  @override
  String get fontSettingsBig => '大';

  @override
  String get fontSettingsVeryBig => '很大';

  @override
  String get fontSettingsExtraBig => '极大';

  @override
  String get fontSettingsMoreStyles => '更多风格';

  @override
  String get fontSettingsPageTitle => '页面标题';

  @override
  String get fontSettingsBlockTitle => '区块标题';

  @override
  String get fontSettingsBodyExample => '正文示例';

  @override
  String get fontSettingsLabelExample => '标签说明';

  @override
  String get fontSettingsStrongNumber => '强调数字';

  @override
  String get fontSettingsListTitle => '列表项标题';

  @override
  String get fontSettingsListSubtitle => '辅助说明文本';

  @override
  String get fontSettingsScreenInfo => '屏幕适配信息';

  @override
  String get fontSettingsScreenDensity => '屏幕密度';

  @override
  String get fontSettingsScreenWidth => '屏幕宽度';

  @override
  String get fontSettingsDeviceScale => '设备缩放';

  @override
  String get fontSettingsUserScale => '用户缩放';

  @override
  String get fontSettingsFinalScale => '最终缩放';

  @override
  String get fontSettingsBaseDevice => '基准设备';

  @override
  String get fontSettingsRecommendedScale => '推荐缩放';

  @override
  String get fontSettingsYes => '是';

  @override
  String get fontSettingsNo => '否';

  @override
  String get fontSettingsScaleExample => '此方框和间距会根据设备自动缩放';

  @override
  String get fontSettingsPreciseAdjust => '精确调整';

  @override
  String get fontSettingsResetTo1x => '重置到1.0x';

  @override
  String get fontSettingsAdaptBase => '适配基准';

  @override
  String get reminderTitle => '记账提醒';

  @override
  String get reminderSubtitle => '设置每日记账提醒时间';

  @override
  String get reminderDailyTitle => '每日记账提醒';

  @override
  String get reminderDailySubtitle => '开启后将在指定时间提醒您记账';

  @override
  String get reminderTimeTitle => '提醒时间';

  @override
  String get commonSelectTime => '选择时间';

  @override
  String get reminderTestNotification => '发送测试通知';

  @override
  String get reminderTestSent => '测试通知已发送';

  @override
  String get reminderTestTitle => '测试通知';

  @override
  String get reminderTestBody => '这是一条测试通知，点击查看效果';

  @override
  String get reminderCheckBattery => '检查电池优化状态';

  @override
  String get reminderBatteryStatus => '电池优化状态';

  @override
  String reminderManufacturer(Object value) {
    return '设备制造商: $value';
  }

  @override
  String reminderModel(Object value) {
    return '设备型号: $value';
  }

  @override
  String reminderAndroidVersion(Object value) {
    return 'Android版本: $value';
  }

  @override
  String get reminderBatteryIgnored => '电池优化状态: 已忽略 ✅';

  @override
  String get reminderBatteryNotIgnored => '电池优化状态: 未忽略 ⚠️';

  @override
  String get reminderBatteryAdvice => '建议关闭电池优化以确保通知正常工作';

  @override
  String get reminderCheckChannel => '检查通知渠道设置';

  @override
  String get reminderChannelStatus => '通知渠道状态';

  @override
  String get reminderChannelEnabled => '渠道启用: 是 ✅';

  @override
  String get reminderChannelDisabled => '渠道启用: 否 ❌';

  @override
  String reminderChannelImportance(Object value) {
    return '重要性: $value';
  }

  @override
  String get reminderChannelSoundOn => '声音: 开启 🔊';

  @override
  String get reminderChannelSoundOff => '声音: 关闭 🔇';

  @override
  String get reminderChannelVibrationOn => '震动: 开启 📳';

  @override
  String get reminderChannelVibrationOff => '震动: 关闭';

  @override
  String get reminderChannelDndBypass => '勿扰模式: 可绕过';

  @override
  String get reminderChannelDndNoBypass => '勿扰模式: 不可绕过';

  @override
  String get reminderChannelAdvice => '⚠️ 建议设置：';

  @override
  String get reminderChannelAdviceImportance => '• 重要性：紧急或高';

  @override
  String get reminderChannelAdviceSound => '• 开启声音和震动';

  @override
  String get reminderChannelAdviceBanner => '• 允许横幅通知';

  @override
  String get reminderChannelAdviceXiaomi => '• 小米手机需单独设置每个渠道';

  @override
  String get reminderChannelGood => '✅ 通知渠道配置良好';

  @override
  String get reminderOpenAppSettings => '打开应用设置';

  @override
  String get reminderAppSettingsMessage => '请在设置中允许通知、关闭电池优化';

  @override
  String get reminderDescription => '提示：开启记账提醒后，系统会在每天指定时间发送通知提醒您记录收支。';

  @override
  String get reminderIOSInstructions => '🍎 iOS通知设置：\n• 设置 > 通知 > 智记\n• 开启\"允许通知\"\n• 设置通知样式：横幅或提醒\n• 开启声音和震动\n\n⚠️ 重要提示：\n• iOS本地通知依赖应用进程\n• 请勿在任务管理器中划掉应用\n• 应用在后台或前台时通知正常\n• 完全关闭应用会导致通知失效\n\n💡 使用建议：\n• 日常使用后直接按Home键退出\n• iOS会自动管理后台应用\n• 保持应用在后台即可收到提醒';

  @override
  String get reminderAndroidInstructions => '如果通知无法正常工作，请检查：\n• 已允许应用发送通知\n• 关闭应用的电池优化/省电模式\n• 允许应用在后台运行和自启动\n• Android 12+需要精确闹钟权限\n\n📱 小米手机特殊设置：\n• 设置 > 应用管理 > 智记 > 通知管理\n• 点击\"记账提醒\"渠道\n• 设置重要性为\"紧急\"或\"高\"\n• 开启\"横幅通知\"、\"声音\"、\"震动\"\n• 安全中心 > 应用管理 > 权限 > 自启动\n\n🔒 锁定后台方法：\n• 最近任务中找到智记\n• 向下拉动应用卡片显示锁定图标\n• 点击锁定图标防止被清理';

  @override
  String get categoryDetailLoadFailed => '加载失败';

  @override
  String get categoryDetailSummaryTitle => '分类汇总';

  @override
  String get categoryDetailTotalCount => '总笔数';

  @override
  String get categoryDetailTotalAmount => '总金额';

  @override
  String get categoryDetailAverageAmount => '平均金额';

  @override
  String get categoryDetailSortTitle => '排序';

  @override
  String get categoryDetailSortTimeDesc => '时间↓';

  @override
  String get categoryDetailSortTimeAsc => '时间↑';

  @override
  String get categoryDetailSortAmountDesc => '金额↓';

  @override
  String get categoryDetailSortAmountAsc => '金额↑';

  @override
  String get categoryDetailNoTransactions => '暂无交易记录';

  @override
  String get categoryDetailNoTransactionsSubtext => '该分类下还没有任何交易记录';

  @override
  String get categoryDetailDeleteFailed => '删除失败';

  @override
  String get categoryMigrationConfirmTitle => '确认迁移';

  @override
  String categoryMigrationConfirmMessage(Object count, Object fromName, Object toName) {
    return '确定要将「$fromName」的 $count 笔交易迁移到「$toName」吗？\n\n此操作不可撤销！';
  }

  @override
  String get categoryMigrationConfirmOk => '确认迁移';

  @override
  String get categoryMigrationCompleteTitle => '迁移完成';

  @override
  String categoryMigrationCompleteMessage(Object count, Object fromName, Object toName) {
    return '成功将 $count 笔交易从「$fromName」迁移到「$toName」。';
  }

  @override
  String get categoryMigrationFailedTitle => '迁移失败';

  @override
  String categoryMigrationFailedMessage(Object error) {
    return '迁移过程中发生错误：$error';
  }

  @override
  String categoryMigrationTransactionLabel(Object count) {
    return '$count笔';
  }

  @override
  String importColumnNumber(Object number) {
    return '第 $number 列';
  }

  @override
  String get importConfirmMapping => '确认映射';

  @override
  String get importCategoryMapping => '分类映射';

  @override
  String get importNoDataParsed => '未解析到任何数据，请返回上一页检查 CSV 内容或分隔符。';

  @override
  String get importFieldDate => '日期';

  @override
  String get importFieldType => '类型';

  @override
  String get importFieldAmount => '金额';

  @override
  String get importFieldCategory => '分类';

  @override
  String get importFieldAccount => '账户';

  @override
  String get importFieldNote => '备注';

  @override
  String get importPreview => '预览：';

  @override
  String importPreviewLimit(Object shown, Object total) {
    return '仅预览前 $shown 行，共 $total 行';
  }

  @override
  String get importCategoryNotSelected => '未选择\"分类\"列，请点击\"上一步\"返回并设置\"分类\"的列，再继续。';

  @override
  String get importCategoryMappingDescription => '请将左侧\"源分类名\"映射到系统内已有分类（或保持原名自动创建/合并）';

  @override
  String get importKeepOriginalName => '保持原名（自动创建/合并）';

  @override
  String importProgress(Object fail, Object ok) {
    return '导入中… 成功 $ok，失败 $fail';
  }

  @override
  String get importCancelImport => '取消导入';

  @override
  String get importCompleteTitle => '导入完成';

  @override
  String get importSelectCategoryFirst => '请先选择\"分类\"列再继续';

  @override
  String get importNextStep => '下一步';

  @override
  String get importPreviousStep => '上一步';

  @override
  String get importStartImport => '开始导入';

  @override
  String get importAutoDetect => '自动';

  @override
  String get importInProgress => '正在导入…';

  @override
  String importProgressDetail(Object done, Object fail, Object ok, Object total) {
    return '已完成：$done/$total，成功 $ok，失败 $fail';
  }

  @override
  String get importBackgroundImport => '后台导入';

  @override
  String get importCancelled => '（已取消）';

  @override
  String importCompleted(Object cancelled, Object fail, Object ok) {
    return '导入完成$cancelled：成功 $ok 条，失败 $fail 条';
  }

  @override
  String importSkippedNonTransactionTypes(Object count) {
    return '跳过 $count 条非收支记录（债务等）';
  }

  @override
  String importTransactionFailed(Object error) {
    return '导入失败，已回滚所有更改：$error';
  }

  @override
  String get mineImportCompleteAllSuccess => '全部成功';

  @override
  String get mineCheckUpdateDetecting => '检测更新中...';

  @override
  String get mineCheckUpdateSubtitleDetecting => '正在检查最新版本';

  @override
  String get mineUpdateDownloadTitle => '下载更新';

  @override
  String get cloudTest => '测试';

  @override
  String get cloudSwitched => '已切换';

  @override
  String get cloudSwitchFailed => '切换失败';

  @override
  String get cloudSupabaseUrlLabel => 'Supabase URL';

  @override
  String get cloudSupabaseUrlHint => 'https://xxx.supabase.co';

  @override
  String get cloudAnonKeyLabel => 'Anon Key';

  @override
  String get cloudSelectServiceType => '选择云服务类型';

  @override
  String get cloudMultiDeviceWarningTitle => '多设备使用提醒';

  @override
  String get cloudMultiDeviceWarningMessage => '换设备前记得先上传，到新设备后先下载再记账。不要同时在两台设备上记同一个账本。点击查看详情 →';

  @override
  String get cloudWebdavUrlLabel => 'WebDAV 服务器地址';

  @override
  String get cloudWebdavUrlHint => 'https://dav.jianguoyun.com/dav/';

  @override
  String get cloudWebdavUsernameLabel => '用户名';

  @override
  String get cloudWebdavPasswordLabel => '密码';

  @override
  String get cloudWebdavPathHint => '/SmartBook 智记';

  @override
  String get cloudS3EndpointLabel => '端点地址';

  @override
  String get cloudS3EndpointHint => 's3.amazonaws.com 或自定义端点';

  @override
  String get cloudS3RegionLabel => '区域';

  @override
  String get cloudS3RegionHint => 'us-east-1（留空自动）';

  @override
  String get cloudS3AccessKeyLabel => 'Access Key';

  @override
  String get cloudS3AccessKeyHint => '您的 Access Key ID';

  @override
  String get cloudS3SecretKeyLabel => 'Secret Key';

  @override
  String get cloudS3SecretKeyHint => '您的 Secret Access Key';

  @override
  String get cloudS3BucketLabel => '存储桶名称';

  @override
  String get cloudS3BucketHint => 'smartbook-data';

  @override
  String get cloudS3UseSSLLabel => '使用 HTTPS';

  @override
  String get cloudS3PortLabel => '端口（可选）';

  @override
  String get cloudS3PortHint => '留空使用默认端口';

  @override
  String get cloudSupabaseBucketLabel => 'Storage Bucket 名称';

  @override
  String get cloudSupabaseBucketHint => '留空使用默认值 beecount-backups';

  @override
  String get authRememberAccount => '记住账号密码';

  @override
  String get authRememberAccountHint => '下次登录时自动填充（仅Supabase）';

  @override
  String get cloudConfigSaved => '配置已保存';

  @override
  String get cloudTestSuccess => '连接测试成功！';

  @override
  String get cloudTestFailed => '连接测试失败，请检查配置是否正确。';

  @override
  String get cloudTestError => '测试失败';

  @override
  String get cloudLocalStorageTitle => '本地存储';

  @override
  String get cloudLocalStorageSubtitle => '数据仅保存在本地设备';

  @override
  String get cloudCustomSupabaseTitle => '自定义 Supabase';

  @override
  String get cloudCustomWebdavTitle => '自定义 WebDAV';

  @override
  String get cloudSwitchConfirmTitle => '切换云服务';

  @override
  String get cloudSwitchConfirmMessage => '切换云服务将登出当前账号,确认切换?';

  @override
  String get cloudSwitchFailedTitle => '切换失败';

  @override
  String get cloudSwitchFailedConfigMissing => '请先配置该云服务';

  @override
  String get cloudConfigInvalidTitle => '配置无效';

  @override
  String get cloudConfigInvalidMessage => '请填写完整信息';

  @override
  String get cloudSaveFailed => '保存失败';

  @override
  String cloudSwitchedTo(String type) {
    return '已切换到$type';
  }

  @override
  String get cloudConfigureSupabaseTitle => '配置 Supabase';

  @override
  String get cloudConfigureWebdavTitle => '配置 WebDAV';

  @override
  String get cloudConfigureS3Title => '配置 S3';

  @override
  String get cloudWebdavRemotePathHelp => '数据存储的远程目录路径';

  @override
  String get authLogin => '登录';

  @override
  String get authEmail => '邮箱';

  @override
  String get authPassword => '密码';

  @override
  String get authInvalidEmail => '请输入有效的邮箱地址';

  @override
  String get authNoAccountYet => '还没有账号？';

  @override
  String get authViewRegisterGuide => '查看注册指引';

  @override
  String get authErrorInvalidCredentials => '邮箱或密码不正确。';

  @override
  String get authErrorEmailNotConfirmed => '邮箱未验证，请先到邮箱完成验证再登录。';

  @override
  String get authErrorRateLimit => '操作过于频繁，请稍后再试。';

  @override
  String get authErrorNetworkIssue => '网络异常，请检查网络后重试。';

  @override
  String get authErrorLoginFailed => '登录失败，请稍后再试。';

  @override
  String get authErrorEmailInvalid => '邮箱地址无效，请检查是否拼写有误。';

  @override
  String get authErrorWeakPassword => '密码过于简单，请包含字母和数字，长度至少 6 位。';

  @override
  String get importSelectCsvFile => '请选择文件进行导入（支持 CSV/TSV/XLSX 格式）';

  @override
  String get exportTitle => '导出';

  @override
  String get exportDescription => '支持导出的数据类型：\n• 交易记录（收入/支出/转账）\n• 分类信息\n• 账户信息\n\n点击下方按钮选择保存位置，开始导出当前账本为 CSV 文件。';

  @override
  String get exportButtonIOS => '导出并分享';

  @override
  String get exportButtonAndroid => '导出数据';

  @override
  String get exportJsonButton => 'JSON 结构化导出(备份)';

  @override
  String get privacyPanelTitle => '隐私面板';

  @override
  String get privacyPanelDesc => '原文数据保留策略与一键清理';

  @override
  String get privacyStatsAttachments => '截图/图片原文';

  @override
  String privacyStatsAttachmentsDesc(Object count, Object size) {
    return '$count 个文件,占用 $size';
  }

  @override
  String privacyStatsPending(Object count) {
    return '待确认候选:$count 项';
  }

  @override
  String get privacyNoOriginalForSmsNotifyTitle => '短信/通知原文不落盘';

  @override
  String get privacyNoOriginalForSmsNotifyDesc => '短信与支付通知原文在 AI 解析后即丢弃,不持久化(设计保证);仅保留解析出的结构化交易。';

  @override
  String get privacyClearAttachments => '一键清除截图/图片原文';

  @override
  String get privacyClearAttachmentsConfirmTitle => '确认清除原文?';

  @override
  String privacyClearAttachmentsConfirmBody(Object count) {
    return '将删除 $count 个截图/图片原文文件,不影响交易记录与统计。建议先导出备份。';
  }

  @override
  String privacyCleared(Object count) {
    return '已清除 $count 个原文文件(交易数据保留)';
  }

  @override
  String exportSavedTo(String path) {
    return '已保存到：$path';
  }

  @override
  String get exportCsvHeaderType => '类型';

  @override
  String get exportCsvHeaderCategory => '分类';

  @override
  String get exportCsvHeaderSubCategory => '二级分类';

  @override
  String get exportCsvHeaderAmount => '金额';

  @override
  String get exportCsvHeaderAccount => '账户';

  @override
  String get exportCsvHeaderFromAccount => '转出账户';

  @override
  String get exportCsvHeaderToAccount => '转入账户';

  @override
  String get exportCsvHeaderNote => '备注';

  @override
  String get exportCsvHeaderTime => '时间';

  @override
  String get exportCsvHeaderTags => '标签';

  @override
  String get exportCsvHeaderAttachments => '附件';

  @override
  String get exportShareText => '智记 导出文件';

  @override
  String get exportSuccessTitle => '导出成功';

  @override
  String exportSuccessMessageIOS(String path) {
    return '已保存并可在分享历史中找到：\n$path';
  }

  @override
  String exportSuccessMessageAndroid(String path) {
    return '已保存到：\n$path';
  }

  @override
  String get exportFailedTitle => '导出失败';

  @override
  String get exportTypeIncome => '收入';

  @override
  String get exportTypeExpense => '支出';

  @override
  String get exportTypeTransfer => '转账';

  @override
  String get personalizeThemeHoney => '蜜蜂黄';

  @override
  String get personalizeThemeOrange => '火焰橙';

  @override
  String get personalizeThemeGreen => '琉璃绿';

  @override
  String get personalizeThemePurple => '青莲紫';

  @override
  String get personalizeThemePink => '樱绯红';

  @override
  String get personalizeThemeBlue => '晴空蓝';

  @override
  String get personalizeThemeMint => '林间月';

  @override
  String get personalizeThemeSand => '黄昏沙丘';

  @override
  String get personalizeThemeLavender => '雪与松';

  @override
  String get personalizeThemeSky => '迷雾仙境';

  @override
  String get personalizeThemeWarmOrange => '暖阳橘';

  @override
  String get personalizeThemeMintGreen => '薄荷青';

  @override
  String get personalizeThemeRoseGold => '玫瑰金';

  @override
  String get personalizeThemeDeepBlue => '深海蓝';

  @override
  String get personalizeThemeMapleRed => '枫叶红';

  @override
  String get personalizeThemeEmerald => '翡翠绿';

  @override
  String get personalizeThemeLavenderPurple => '薰衣草';

  @override
  String get personalizeThemeAmber => '琥珀黄';

  @override
  String get personalizeThemeRouge => '胭脂红';

  @override
  String get personalizeThemeIndigo => '靛青蓝';

  @override
  String get personalizeThemeOlive => '橄榄绿';

  @override
  String get personalizeThemeCoral => '珊瑚粉';

  @override
  String get personalizeThemeDarkGreen => '墨绿色';

  @override
  String get personalizeThemeViolet => '紫罗兰';

  @override
  String get personalizeThemeSunset => '日落橙';

  @override
  String get personalizeThemePeacock => '孔雀蓝';

  @override
  String get personalizeThemeLime => '柠檬绿';

  @override
  String get analyticsMonthlyAvg => '月均';

  @override
  String get analyticsDailyAvg => '日均';

  @override
  String get analyticsOverallAvg => '平均值';

  @override
  String get analyticsTotalIncome => '总收入： ';

  @override
  String get analyticsTotalExpense => '总支出： ';

  @override
  String get analyticsBalance => '结余： ';

  @override
  String analyticsAvgIncome(Object avgLabel) {
    return '$avgLabel收入： ';
  }

  @override
  String analyticsAvgExpense(Object avgLabel) {
    return '$avgLabel支出： ';
  }

  @override
  String get analyticsExpense => '支出';

  @override
  String get analyticsIncome => '收入';

  @override
  String analyticsTotal(Object type) {
    return '总$type： ';
  }

  @override
  String analyticsAverage(Object avgLabel) {
    return '$avgLabel： ';
  }

  @override
  String get updateCheckTitle => '检查更新';

  @override
  String updateNewVersionTitle(Object version) {
    return '发现新版本 $version';
  }

  @override
  String get updateNoApkFound => '未找到APK下载链接';

  @override
  String get updateAlreadyLatest => '当前已是最新版本';

  @override
  String get updateCheckFailed => '检查更新失败';

  @override
  String get updatePermissionDenied => '权限被拒绝';

  @override
  String get updateUserCancelled => '用户取消';

  @override
  String get updateDownloadTitle => '下载更新';

  @override
  String updateDownloading(Object percent) {
    return '下载中: $percent%';
  }

  @override
  String get updateDownloadBackgroundHint => '可以将应用切换到后台，下载会继续进行';

  @override
  String get updateCancelButton => '取消';

  @override
  String get updateBackgroundDownload => '后台下载';

  @override
  String get updateLaterButton => '稍后';

  @override
  String get updateDownloadButton => '下载';

  @override
  String get updateInstallingCachedApk => '正在安装缓存的APK';

  @override
  String get updateDownloadComplete => '下载完成';

  @override
  String get updateInstallStarted => '下载完成，安装程序已启动';

  @override
  String get updateInstallFailed => '安装失败';

  @override
  String get updateDownloadFailed => '下载失败';

  @override
  String get updateInstallNow => '立即安装';

  @override
  String get updateNotificationPermissionTitle => '通知权限被拒绝';

  @override
  String get updateCheckFailedTitle => '检测更新失败';

  @override
  String get updateDownloadFailedTitle => '下载失败';

  @override
  String get updateGoToGitHub => '前往GitHub';

  @override
  String get updateCannotOpenLink => '无法打开链接';

  @override
  String get updateManualVisit => '请手动在浏览器中访问：\\nhttps://github.com/TNT-Likely/BeeCount/releases';

  @override
  String get updateNoLocalApkTitle => '未找到更新包';

  @override
  String get updateInstallPackageTitle => '安装更新包';

  @override
  String get updateMultiplePackagesTitle => '找到多个更新包';

  @override
  String get updateSearchFailedTitle => '查找失败';

  @override
  String get updateFoundCachedPackageTitle => '发现已下载的更新包';

  @override
  String get updateIgnoreButton => '忽略';

  @override
  String get updateInstallFailedTitle => '安装失败';

  @override
  String get updateInstallFailedMessage => '无法启动APK安装程序，请检查文件权限。';

  @override
  String get updateErrorTitle => '错误';

  @override
  String get updateCheckingPermissions => '检查权限...';

  @override
  String get updateCheckingCache => '检查本地缓存...';

  @override
  String get updatePreparingDownload => '准备下载...';

  @override
  String get updateUserCancelledDownload => '用户取消下载';

  @override
  String get updateStartingInstaller => '正在启动安装...';

  @override
  String get updateInstallerStarted => '安装程序已启动';

  @override
  String get updateInstallationFailed => '安装失败';

  @override
  String get updateDownloadCompleted => '下载完成';

  @override
  String get updateDownloadCompletedManual => '下载完成，可以手动安装';

  @override
  String get updateDownloadCompletedDialog => '下载完成，请手动安装（弹窗异常）';

  @override
  String get updateDownloadCompletedContext => '下载完成，请手动安装';

  @override
  String get updateDownloadFailedGeneric => '下载失败';

  @override
  String get updateCheckingUpdate => '正在检查更新...';

  @override
  String get updateCurrentLatestVersion => '当前已是最新版本';

  @override
  String get updateCheckFailedGeneric => '检查更新失败';

  @override
  String updateDownloadProgress(Object percent) {
    return '下载中: $percent%';
  }

  @override
  String updateCheckingUpdateError(Object error) {
    return '检查更新失败: $error';
  }

  @override
  String get updateNoLocalApkFoundMessage => '没有找到已下载的更新包文件。\n\n请先通过\"检查更新\"下载新版本。';

  @override
  String updateInstallPackageFoundMessage(Object fileName, Object fileSize, Object time) {
    return '找到更新包：\n\n文件名：$fileName\n大小：${fileSize}MB\n下载时间：$time\n\n是否立即安装？';
  }

  @override
  String updateMultiplePackagesFoundMessage(Object count, Object path) {
    return '找到 $count 个更新包文件。\n\n建议使用最新下载的版本，或手动到文件管理器中安装。\n\n文件位置：$path';
  }

  @override
  String updateSearchLocalApkError(Object error) {
    return '查找本地更新包时发生错误：$error';
  }

  @override
  String updateCachedPackageFoundMessage(Object fileName, Object fileSize) {
    return '检测到之前下载的更新包：\n\n文件名：$fileName\n大小：${fileSize}MB\n\n是否立即安装？';
  }

  @override
  String updateReadCachedPackageError(Object error) {
    return '读取缓存更新包失败：$error';
  }

  @override
  String get iconCategoryDining => '餐饮';

  @override
  String get updateOk => '知道了';

  @override
  String get updateCannotOpenLinkTitle => '无法打开链接';

  @override
  String get updateNotificationPermissionGuideText => '下载进度通知被关闭，但不影响下载功能。如需查看进度：';

  @override
  String get updateNotificationGuideStep1 => '进入系统设置 > 应用管理';

  @override
  String get updateNotificationGuideStep2 => '找到\\\"智记\\\"应用';

  @override
  String get updateNotificationGuideStep3 => '开启通知权限';

  @override
  String get updateNotificationGuideInfo => '即使不开启通知，下载也会在后台正常进行';

  @override
  String get updateCachedVersionTitle => '发现已下载版本';

  @override
  String get updateCachedVersionMessage => '已找到之前下载的安装包...点击\\\"确定\\\"立即安装，点击\\\"取消\\\"关闭...';

  @override
  String get updateCorruptedFileTitle => '安装包已损坏';

  @override
  String get updateCorruptedFileMessage => '检测到之前下载的安装包不完整或已损坏，是否删除并重新下载？';

  @override
  String get updateConfirmDownload => '立即下载并安装';

  @override
  String get updateDownloadCompleteTitle => '下载完成';

  @override
  String get updateInstallConfirmMessage => '新版本已下载完成，是否立即安装？';

  @override
  String get updateMirrorSelectTitle => '选择下载加速器';

  @override
  String get updateMirrorSelectHint => '如果下载缓慢，可以选择一个加速镜像。点击「测速」检测各镜像延迟。';

  @override
  String get updateMirrorTestButton => '测速';

  @override
  String updateMirrorTesting(int completed, int total) {
    return '正在测试 $completed/$total...';
  }

  @override
  String get updateMirrorDirectHint => '适合网络通畅的用户';

  @override
  String updateDownloadMirror(String mirror) {
    return '下载源: $mirror';
  }

  @override
  String get updateMirrorSettingTitle => '下载加速器';

  @override
  String get currencyCNY => '人民币';

  @override
  String get currencyUSD => '美元';

  @override
  String get currencyEUR => '欧元';

  @override
  String get currencyJPY => '日元';

  @override
  String get currencyHKD => '港币';

  @override
  String get currencyTWD => '新台币';

  @override
  String get currencyGBP => '英镑';

  @override
  String get currencyAUD => '澳元';

  @override
  String get currencyCAD => '加元';

  @override
  String get currencyKRW => '韩元';

  @override
  String get currencySGD => '新加坡元';

  @override
  String get currencyMYR => '马来西亚林吉特';

  @override
  String get currencyTHB => '泰铢';

  @override
  String get currencyIDR => '印尼卢比';

  @override
  String get currencyPHP => '菲律宾比索';

  @override
  String get currencyVND => '越南盾';

  @override
  String get currencyINR => '印度卢比';

  @override
  String get currencyRUB => '俄罗斯卢布';

  @override
  String get currencyBYN => '白俄罗斯卢布';

  @override
  String get currencyNZD => '新西兰元';

  @override
  String get currencyCHF => '瑞士法郎';

  @override
  String get currencySEK => '瑞典克朗';

  @override
  String get currencyNOK => '挪威克朗';

  @override
  String get currencyDKK => '丹麦克朗';

  @override
  String get currencyBRL => '巴西雷亚尔';

  @override
  String get currencyMXN => '墨西哥比索';

  @override
  String get currencyTRY => '土耳其里拉';

  @override
  String get currencyZAR => '南非兰特';

  @override
  String get currencyAED => '阿联酋迪拉姆';

  @override
  String get currencySAR => '沙特里亚尔';

  @override
  String get currencyPLN => '波兰兹罗提';

  @override
  String get currencyCZK => '捷克克朗';

  @override
  String get currencyHUF => '匈牙利福林';

  @override
  String get currencyARS => '阿根廷比索';

  @override
  String get currencyCLP => '智利比索';

  @override
  String get currencyCOP => '哥伦比亚比索';

  @override
  String get currencyPEN => '秘鲁索尔';

  @override
  String get currencyEGP => '埃及镑';

  @override
  String get currencyNGN => '尼日利亚奈拉';

  @override
  String get currencyKZT => '哈萨克斯坦坚戈';

  @override
  String get currencyUAH => '乌克兰格里夫纳';

  @override
  String get currencyILS => '以色列新谢克尔';

  @override
  String get currencyPKR => '巴基斯坦卢比';

  @override
  String get currencyBDT => '孟加拉塔卡';

  @override
  String get currencyLKR => '斯里兰卡卢比';

  @override
  String get currencyMMK => '缅甸元';

  @override
  String get webdavConfiguredTitle => 'WebDAV 云服务已配置';

  @override
  String get webdavConfiguredMessage => 'WebDAV 云服务使用配置时提供的凭据，无需额外登录。';

  @override
  String get recurringTransactionTitle => '周期账单';

  @override
  String get recurringTransactionAdd => '添加周期账单';

  @override
  String get recurringTransactionEdit => '编辑周期账单';

  @override
  String get recurringTransactionFrequency => '周期频率';

  @override
  String get recurringTransactionDaily => '每天';

  @override
  String get recurringTransactionWeekly => '每周';

  @override
  String get recurringTransactionMonthly => '每月';

  @override
  String get recurringTransactionYearly => '每年';

  @override
  String get recurringTransactionInterval => '间隔';

  @override
  String get recurringTransactionDayOfMonth => '每月第几天';

  @override
  String get recurringTransactionStartDate => '开始日期';

  @override
  String get recurringTransactionEndDate => '结束日期';

  @override
  String get recurringTransactionNoEndDate => '永久周期';

  @override
  String get recurringTransactionDeleteConfirm => '确定要删除这个周期账单吗？';

  @override
  String get recurringTransactionEmpty => '暂无周期账单';

  @override
  String get recurringTransactionEmptyHint => '点击右上角 + 按钮添加';

  @override
  String recurringTransactionEveryNDays(int n) {
    return '每 $n 天';
  }

  @override
  String recurringTransactionEveryNWeeks(int n) {
    return '每 $n 周';
  }

  @override
  String recurringTransactionEveryNMonths(int n) {
    return '每 $n 个月';
  }

  @override
  String recurringTransactionEveryNYears(int n) {
    return '每 $n 年';
  }

  @override
  String get recurringTransactionUsageTitle => '使用说明';

  @override
  String get recurringTransactionUsageContent => '周期记账会在每次冷启动进入App时自动扫描并生成账单。设置日期后，系统会在该日期之后的冷启动时创建对应账单。例如：设置11月27日，则会在11月27日之后的首次启动时自动记账。';

  @override
  String get ledgerSelectTitle => '选择账本';

  @override
  String get ledgerSelect => '选择账本';

  @override
  String get syncNotConfiguredMessage => '未配置云端';

  @override
  String get syncNotLoggedInMessage => '未登录';

  @override
  String get syncCloudBackupCorruptedMessage => '云端备份内容无法解析，可能是早期版本编码问题造成的损坏。请点击\\\"上传当前账本到云端\\\"覆盖修复。';

  @override
  String get syncNoCloudBackupMessage => '云端暂无备份';

  @override
  String get syncAccessDeniedMessage => '403 拒绝访问（检查 storage RLS 策略与路径）';

  @override
  String get cloudTestConnection => '测试连接';

  @override
  String get cloudCustomSupabaseSubtitle => '点击配置自建Supabase服务';

  @override
  String get cloudCustomWebdavSubtitle => '点击配置坚果云/Nextcloud等';

  @override
  String get cloudCustomS3Title => 'S3 协议存储';

  @override
  String get cloudCustomS3Subtitle => 'AWS S3 / Cloudflare R2 / MinIO';

  @override
  String get cloudSmartBookCloudTitle => '智记';

  @override
  String get cloudSmartBookCloudSubtitle => '自建云服务 · 增量同步 · 多设备协同';

  @override
  String get cloudConfigureSmartBookCloudTitle => '配置智记';

  @override
  String get cloudSmartBookCloudUrlLabel => '服务器地址';

  @override
  String get cloudSmartBookCloudUrlHint => 'https://your-server.com';

  @override
  String get cloudSmartBookCloudApiPrefixLabel => 'API 前缀';

  @override
  String get cloudSmartBookCloudApiPrefixHint => '/api/v1';

  @override
  String get cloudSmartBookCloudEmailLabel => '邮箱';

  @override
  String get cloudSmartBookCloudEmailHint => 'your@email.com';

  @override
  String get cloudSmartBookCloudPasswordLabel => '密码';

  @override
  String get cloudSmartBookCloudPasswordHint => '输入密码';

  @override
  String get cloudSmartBookCloudLoginSuccess => '登录成功';

  @override
  String get cloudSmartBookCloudLoginFailed => '登录失败';

  @override
  String get cloudSmartBookCloudSyncSubtitle => '增量同步 · 多设备协同';

  @override
  String get cloudSmartBookCloudConnected => '已连接';

  @override
  String get cloudSmartBookCloudNotConnected => '未连接';

  @override
  String get cloudSmartBookCloudNotConnectedHint => '请先在云服务设置中配置并登录';

  @override
  String get cloudSmartBookCloudAutoSync => '增量同步';

  @override
  String get cloudSmartBookCloudAutoSyncHint => '数据变更自动同步到云端，无需手动操作';

  @override
  String get cloudSmartBookCloudMultiDevice => '多设备协同';

  @override
  String get cloudSmartBookCloudMultiDeviceHint => '多台设备间自动保持数据一致';

  @override
  String get cloudSmartBookCloudAttachment => '附件同步';

  @override
  String get cloudSmartBookCloudAttachmentHint => '账单图片等附件自动云端备份';

  @override
  String get cloudTabOffline => '离线模式';

  @override
  String get cloudTabBackup => '备份同步';

  @override
  String get cloudTabCloudSync => '云端协同';

  @override
  String get cloudIcloudSubtitle => '使用 Apple ID 自动同步';

  @override
  String get cloudIcloudNotAvailableTitle => 'iCloud 不可用';

  @override
  String get cloudIcloudNotAvailableMessage => '请在系统设置中登录 iCloud 账户后再试';

  @override
  String get cloudIcloudHelpTitle => 'iCloud 使用说明';

  @override
  String get cloudIcloudHelpPrerequisites => '前提条件';

  @override
  String get cloudIcloudHelpPrereq1 => '1. 设备已登录 Apple ID';

  @override
  String get cloudIcloudHelpPrereq2 => '2. 已开启 iCloud Drive';

  @override
  String get cloudIcloudHelpPrereq3 => '3. 设备已联网';

  @override
  String get cloudIcloudHelpCheckTitle => '如何检查 iCloud Drive';

  @override
  String get cloudIcloudHelpCheck1 => '1. 打开「设置」';

  @override
  String get cloudIcloudHelpCheck2 => '2. 点击顶部的 Apple ID';

  @override
  String get cloudIcloudHelpCheck3 => '3. 点击「iCloud」';

  @override
  String get cloudIcloudHelpCheck4 => '4. 确保「iCloud 云盘」已开启';

  @override
  String get cloudIcloudHelpFaqTitle => '常见问题';

  @override
  String get cloudIcloudHelpFaq1 => '如果提示不可用，请检查 iCloud Drive 是否开启';

  @override
  String get cloudIcloudHelpFaq2 => '首次使用可能需要等待几秒钟初始化';

  @override
  String get cloudIcloudHelpFaq3 => '数据存储在您的私人 iCloud 空间中';

  @override
  String get cloudIcloudHelpFaq4 => '同一 Apple ID 的设备可自动同步';

  @override
  String get cloudIcloudHelpNote => 'iCloud 同步使用您的 Apple ID，无需额外配置';

  @override
  String get cloudSupabaseHelpTitle => 'Supabase 配置说明';

  @override
  String get cloudSupabaseHelpIntro => '什么是 Supabase';

  @override
  String get cloudSupabaseHelpIntro1 => 'Supabase 是一个开源的后端即服务平台';

  @override
  String get cloudSupabaseHelpIntro2 => '提供免费套餐，足够个人使用';

  @override
  String get cloudSupabaseHelpIntro3 => '数据完全由您掌控';

  @override
  String get cloudSupabaseHelpSteps => '配置步骤';

  @override
  String get cloudSupabaseHelpStep1 => '1. 访问 supabase.com 注册账号';

  @override
  String get cloudSupabaseHelpStep2 => '2. 创建新项目（选择免费套餐）';

  @override
  String get cloudSupabaseHelpStep3 => '3. 进入项目设置 > API';

  @override
  String get cloudSupabaseHelpStep4 => '4. 复制 Project URL 和 anon key';

  @override
  String get cloudSupabaseHelpStep5 => '5. 粘贴到应用的配置中';

  @override
  String get cloudSupabaseHelpFaq => '常见问题';

  @override
  String get cloudSupabaseHelpFaq1 => '免费套餐有 500MB 存储空间';

  @override
  String get cloudSupabaseHelpFaq2 => '数据加密存储，安全可靠';

  @override
  String get cloudSupabaseHelpFaq3 => '支持多设备同步';

  @override
  String get cloudSupabaseHelpNote => '配置完成后需要注册/登录账号才能使用同步功能';

  @override
  String get cloudDetailedTutorial => '详细教程';

  @override
  String get cloudWebdavHelpTitle => 'WebDAV 配置说明';

  @override
  String get cloudWebdavHelpIntro => '什么是 WebDAV';

  @override
  String get cloudWebdavHelpIntro1 => 'WebDAV 是一种网络文件协议';

  @override
  String get cloudWebdavHelpIntro2 => '支持多种云盘和NAS设备';

  @override
  String get cloudWebdavHelpIntro3 => '数据存储在您自己的服务器上';

  @override
  String get cloudWebdavHelpProviders => '支持的服务商';

  @override
  String get cloudWebdavHelpProvider1 => '• 坚果云（推荐国内用户）';

  @override
  String get cloudWebdavHelpProvider2 => '• Nextcloud / ownCloud';

  @override
  String get cloudWebdavHelpProvider3 => '• 群晖 / 威联通 NAS';

  @override
  String get cloudWebdavHelpProvider4 => '• 其他支持 WebDAV 的服务';

  @override
  String get cloudWebdavHelpSteps => '配置步骤（以坚果云为例）';

  @override
  String get cloudWebdavHelpStep1 => '1. 登录坚果云网页版';

  @override
  String get cloudWebdavHelpStep2 => '2. 点击右上角账户名 > 账户信息';

  @override
  String get cloudWebdavHelpStep3 => '3. 选择「安全选项」标签';

  @override
  String get cloudWebdavHelpStep4 => '4. 添加应用密码（用于第三方应用）';

  @override
  String get cloudWebdavHelpStep5 => '5. 复制服务器地址、账号、应用密码';

  @override
  String get cloudWebdavHelpNote => '建议使用应用专用密码，而非账号密码';

  @override
  String get cloudS3HelpTitle => 'S3 存储配置说明';

  @override
  String get cloudS3HelpIntro => '什么是 S3';

  @override
  String get cloudS3HelpIntro1 => 'S3 是一种标准的对象存储协议';

  @override
  String get cloudS3HelpIntro2 => '支持多家云服务商';

  @override
  String get cloudS3HelpIntro3 => '数据存储在您选择的云服务中';

  @override
  String get cloudS3HelpProviders => '支持的服务商';

  @override
  String get cloudS3HelpProvider1 => '• AWS S3（Amazon Web Services）';

  @override
  String get cloudS3HelpProvider2 => '• Cloudflare R2（免费 10GB/月）';

  @override
  String get cloudS3HelpProvider3 => '• Backblaze B2（免费 10GB）';

  @override
  String get cloudS3HelpProvider4 => '• MinIO（自建服务）';

  @override
  String get cloudS3HelpProvider5 => '• 阿里云 OSS';

  @override
  String get cloudS3HelpProvider6 => '• 腾讯云 COS';

  @override
  String get cloudS3HelpProvider7 => '• 七牛云 Kodo';

  @override
  String get cloudS3HelpSteps => '配置步骤（以 Cloudflare R2 为例）';

  @override
  String get cloudS3HelpStep1 => '1. 登录 Cloudflare 控制台';

  @override
  String get cloudS3HelpStep2 => '2. 进入 R2 > 创建存储桶';

  @override
  String get cloudS3HelpStep3 => '3. 进入 R2 > 管理 R2 API 令牌';

  @override
  String get cloudS3HelpStep4 => '4. 创建 API 令牌并复制凭据';

  @override
  String get cloudS3HelpStep5 => '5. 粘贴端点、访问密钥、私密密钥和存储桶名称';

  @override
  String get cloudS3HelpNote => '推荐使用 Cloudflare R2，提供 10GB 免费存储且无流量费';

  @override
  String get cloudStatusNotTested => '未测试';

  @override
  String get cloudStatusNormal => '连接正常';

  @override
  String get cloudStatusFailed => '连接失败';

  @override
  String get cloudCannotOpenLink => '无法打开链接';

  @override
  String get cloudErrorAuthFailed => '认证失败: API Key 无效';

  @override
  String cloudErrorServerStatus(String code) {
    return '服务器返回状态码 $code';
  }

  @override
  String get cloudErrorWebdavNotSupported => '服务器不支持 WebDAV 协议';

  @override
  String get cloudErrorAuthFailedCredentials => '认证失败: 用户名或密码错误';

  @override
  String get cloudErrorAccessDenied => '访问被拒绝: 请检查权限';

  @override
  String cloudErrorPathNotFound(String path) {
    return '服务器路径不存在: $path';
  }

  @override
  String cloudErrorNetwork(String message) {
    return '网络错误: $message';
  }

  @override
  String get cloudTestSuccessTitle => '测试成功';

  @override
  String get cloudTestSuccessMessage => '连接正常,配置有效';

  @override
  String get cloudTestFailedTitle => '测试失败';

  @override
  String get cloudTestFailedMessage => '连接失败';

  @override
  String get cloudTestErrorTitle => '测试错误';

  @override
  String get cloudSupabaseAnonKeyHintLong => '粘贴完整的 anon key';

  @override
  String get cloudWebdavRemotePathLabel => '远程路径';

  @override
  String get cloudWebdavRemotePathHelperText => '数据存储的远程目录路径';

  @override
  String get accountsTitle => '资产管理';

  @override
  String get accountsEmptyMessage => '还没有账户，点击右上角添加';

  @override
  String get accountAddTooltip => '添加账户';

  @override
  String get accountAddButton => '添加账户';

  @override
  String get accountBalance => '余额';

  @override
  String get accountEditTitle => '编辑账户';

  @override
  String get accountNewTitle => '新建账户';

  @override
  String get accountNameLabel => '账户名称';

  @override
  String get accountNameHint => '例如：工商银行、支付宝等';

  @override
  String get accountNameRequired => '请输入账户名称';

  @override
  String get accountNameDuplicate => '账户名称已存在，请使用其他名称';

  @override
  String get accountTypeLabel => '账户类型';

  @override
  String get accountTypeCash => '现金';

  @override
  String get accountTypeBankCard => '银行卡';

  @override
  String get accountTypeCreditCard => '信用卡';

  @override
  String get accountTypeAlipay => '支付宝';

  @override
  String get accountTypeWechat => '微信';

  @override
  String get accountTypeOther => '其他';

  @override
  String get accountInitialBalance => '初始资金';

  @override
  String get accountInitialBalanceHint => '请输入初始资金（可选）';

  @override
  String get accountInitialBalanceLocked => '初始值创建后不可修改，如需调整请使用「调整余额」';

  @override
  String get accountAdjustBalanceLabel => '调整余额';

  @override
  String get accountAdjustBalanceHint => '输入调整后的当前余额（如与银行对账单核对）';

  @override
  String get accountAdjustBalanceNote => '余额调整';

  @override
  String get accountAdjustmentsTitle => '调整记录';

  @override
  String get accountAdjustmentsEmpty => '暂无余额调整记录';

  @override
  String get accountAdjustmentsViewAction => '调整记录';

  @override
  String get accountBalanceAdjustedToast => '已记录余额调整，入账同步中';

  @override
  String get accountAdjustBalanceSame => '余额与输入一致，无需调整';

  @override
  String get accountAdjustBalanceNewValue => '调整后余额';

  @override
  String get accountAdjustBalanceUpdate => '确认更新';

  @override
  String get accountAdjustBalanceInvalid => '请输入有效的金额';

  @override
  String get accountDeleteWarningTitle => '确认删除';

  @override
  String accountDeleteWarningMessage(int count) {
    return '该账户有 $count 笔关联交易，删除后交易记录中的账户信息将被清空。确认删除吗？';
  }

  @override
  String get accountDeleteConfirm => '确认删除该账户吗？';

  @override
  String get accountSelectTitle => '选择账户';

  @override
  String get accountNone => '不选择账户';

  @override
  String get accountsEnableFeature => '启用账户功能';

  @override
  String get accountHide => '隐藏账户';

  @override
  String get accountUnhide => '恢复账户';

  @override
  String get accountRestore => '恢复';

  @override
  String get accountHiddenTag => '已隐藏';

  @override
  String get accountHiddenSection => '已隐藏';

  @override
  String accountHiddenSectionSummary(Object count, Object total) {
    return '已隐藏 $count · 合计 $total';
  }

  @override
  String get accountHideConfirmTitle => '隐藏此账户？';

  @override
  String get accountHideConfirmBody => '隐藏后无法再记账到它，新增记账时也不再显示；历史交易与余额保留，可随时恢复。';

  @override
  String accountHideRecurringWarn(Object count) {
    return '有 $count 个周期账单在用此账户，隐藏后这些账单将跳过生成，建议先改到其他账户。';
  }

  @override
  String get accountHideClearedDefault => '已取消其默认账户设置';

  @override
  String get accountHiddenToast => '已隐藏';

  @override
  String get accountRestoredToast => '已恢复';

  @override
  String get privacyOpenSourceUrlError => '无法打开链接';

  @override
  String get welcomeTitle => '欢迎使用智记';

  @override
  String get welcomeDescription => '一个真正尊重您隐私的记账应用';

  @override
  String get welcomeCurrencyDescription => '选择您常用的货币，之后可以随时在设置中更改';

  @override
  String get welcomeCreateDefaultLedger => '创建默认账本';

  @override
  String get welcomePrivacyTitle => '开源透明 · 社群驱动';

  @override
  String get welcomePrivacyFeature1 => '100% 开源代码，接受社区监督';

  @override
  String get welcomePrivacyFeature2 => '无隐私顾虑，数据完全本地存储';

  @override
  String get welcomeOpenSourceFeature1 => '活跃的开发者社群，持续改进';

  @override
  String get welcomeViewGitHub => '访问 GitHub 仓库';

  @override
  String get welcomeCloudSyncTitle => '可选的云同步';

  @override
  String get welcomeCloudSyncDescription => '智记 支持多种同步方式，数据完全由你掌控';

  @override
  String get welcomeCloudSyncFeature1 => '完全离线使用，无需云服务';

  @override
  String get welcomeCloudSyncFeature2 => '智记 自建云（多设备实时协同 + Web 端）';

  @override
  String get welcomeCloudSyncFeature3 => 'iCloud / WebDAV / Supabase / S3 任选';

  @override
  String get widgetManagement => '桌面小组件';

  @override
  String get widgetManagementDesc => '在主屏幕快速查看收支情况';

  @override
  String get widgetPreview => '小组件预览';

  @override
  String get widgetPreviewDesc => '小组件会自动显示当前账本的实际数据，主题色跟随应用设置';

  @override
  String get widgetGalleryTitle => '组件库';

  @override
  String get widgetGalleryDesc => '以下为示例效果，实际将显示当前账本的真实数据，主题色跟随 App 设置';

  @override
  String get widgetGalleryGlanceTitle => '收支速览';

  @override
  String get widgetGalleryGlanceDesc => '今日和本月收支一目了然';

  @override
  String get widgetGalleryNetWorthDesc => '总资产、总负债与净值趋势';

  @override
  String get widgetGalleryQuickAddTitle => '快速记账';

  @override
  String get widgetGalleryQuickAddDesc => '常用分类一键速记';

  @override
  String get widgetGalleryBudgetDesc => '预算进度实时掌握';

  @override
  String get widgetGalleryRecentDesc => '快速查看最近几笔账单';

  @override
  String get widgetGalleryDashboardTitle => '综合仪表盘';

  @override
  String get widgetDashboardTitle => '本月概览';

  @override
  String get widgetGalleryDashboardDesc => '收支、趋势与最近交易一屏看尽';

  @override
  String get widgetSizeSmall => '小号';

  @override
  String get widgetSizeMedium => '中号';

  @override
  String get widgetSizeLarge => '大号';

  @override
  String get howToAddWidget => '如何添加小组件';

  @override
  String get iosWidgetStep1 => '长按主屏幕空白区域，进入编辑模式';

  @override
  String get iosWidgetStep2 => '点击左上角的\"+\"按钮';

  @override
  String get iosWidgetStep3 => '搜索并选择\"智记\"';

  @override
  String get iosWidgetStep4 => '选择中型小组件，添加到主屏幕';

  @override
  String get androidWidgetStep1 => '长按主屏幕空白区域';

  @override
  String get androidWidgetStep2 => '选择\"小组件\"或\"Widgets\"';

  @override
  String get androidWidgetStep3 => '找到并长按\"智记\"小组件';

  @override
  String get androidWidgetStep4 => '拖动到主屏幕合适位置';

  @override
  String get aboutWidget => '关于小组件';

  @override
  String get widgetDescription => '小组件会自动同步显示今日和本月的收支数据，每30分钟自动刷新一次。打开应用后会立即更新数据。';

  @override
  String get widgetQuickEntryTitle => '快捷记账';

  @override
  String get widgetQuickEntryDesc => '点击小组件左侧区域可快速新建支出，点击右侧区域可快速新建收入。也可通过快捷指令使用 smartbook://new?type=transfer 快速发起转账。';

  @override
  String get appName => '智记';

  @override
  String get monthSuffix => '月';

  @override
  String get todayExpense => '今日支出';

  @override
  String get todayIncome => '今日收入';

  @override
  String get monthExpense => '本月支出';

  @override
  String get monthIncome => '本月收入';

  @override
  String get autoScreenshotBilling => '截图自动记账';

  @override
  String get autoScreenshotBillingDesc => '截图后自动识别支付信息';

  @override
  String get autoScreenshotBillingTitle => '截图自动记账';

  @override
  String get featureDescription => '功能说明';

  @override
  String get featureDescriptionContent => '截图支付页面后，系统会自动识别金额和商家信息，并创建支出记录。\n\n⚡ 识别速度约 2-3 秒（部分设备可能更长）\n🤖 智能匹配分类\n📝 自动填写备注\n\n⚠️ 注意：\n• 不同设备截图入库速度不同，识别延迟可能 5-10 秒\n• 部分设备可能无法正常工作，取决于系统实现\n• 识别成功后会自动跳过已处理的截图\n• 受Android分区存储限制（Android 10+），应用无法删除系统截图，需手动清理相册';

  @override
  String get autoBilling => '自动记账';

  @override
  String get enabled => '已启用';

  @override
  String get disabled => '已禁用';

  @override
  String get photosPermissionRequired => '需要照片权限才能监听截图';

  @override
  String get photosPermissionLimitedHint => '截图自动记账需要「允许所有照片」权限,请在系统设置中把智记的照片权限改为「允许所有照片」';

  @override
  String get enableSuccess => '自动记账已启用';

  @override
  String get disableSuccess => '自动记账已禁用';

  @override
  String get autoBillingBatteryTitle => '保持后台运行';

  @override
  String get autoBillingBatteryGuideTitle => '电池优化设置';

  @override
  String get autoBillingBatteryDesc => '自动记账需要应用在后台保持运行。部分手机会在锁屏后自动清理后台应用，导致自动记账功能失效。建议关闭电池优化以确保功能正常工作。';

  @override
  String get autoBillingCheckBattery => '检查电池优化状态';

  @override
  String get autoBillingBatteryWarning => '⚠️ 未关闭电池优化，应用可能会被系统自动清理，导致自动记账失效。建议点击上方\"去设置\"按钮关闭电池优化。';

  @override
  String get enableFailed => '启用失败';

  @override
  String get disableFailed => '禁用失败';

  @override
  String get iosAutoFeatureDesc => '通过iOS\"快捷指令\"应用，实现截图后自动识别支付信息并记账。设置后，每次截图都会自动触发识别。';

  @override
  String get iosAutoShortcutConfigTitle => '配置步骤：';

  @override
  String get iosAutoShortcutStep1 => '打开\"快捷指令\"应用，点击右上角\"+\"创建新快捷指令';

  @override
  String get iosAutoShortcutStep2 => '添加\"截屏\"操作';

  @override
  String get iosAutoShortcutStep3 => '搜索并添加\"智记 - 截图自动记账\"操作';

  @override
  String get iosAutoShortcutStep4 => '将\"智记\"的截图参数设置为上一步的\"截屏\"';

  @override
  String get iosAutoShortcutStep5 => '（可选）在系统设置 > 辅助功能 > 触控 > 轻点背面中，绑定此快捷指令';

  @override
  String get iosAutoShortcutStep6 => '完成！支付时双击手机背部即可快速记账';

  @override
  String get iosAutoShortcutRecommendedTip => '✅ 推荐：在\"轻点背面\"中绑定快捷指令后，支付时双击手机背部即可自动截图并识别记账，无需手动截图。';

  @override
  String get iosAutoBackTapTitle => '💡 双击背部快速触发（推荐）';

  @override
  String get iosAutoBackTapDesc => '设置 > 辅助功能 > 触控 > 轻点背面\n• 选择\"轻点两下\"或\"轻点三下\"\n• 选择刚创建的快捷指令\n• 完成后，支付时双击手机背面即可自动记账，无需截图';

  @override
  String get iosAutoTutorialTitle => '视频教程';

  @override
  String get iosAutoTutorialDesc => '查看详细配置视频教程';

  @override
  String get iosAutoImportTitle => '一键获取快捷指令';

  @override
  String get iosAutoImportDesc => '点击下方按钮，自动导入已配置好的「截屏 → 自动记账」快捷指令，无需手动添加“截屏”操作和连接参数。导入后建议在「轻点背面」中绑定它。';

  @override
  String get iosAutoImportButton => '获取快捷指令';

  @override
  String get iosAutoImportFailed => '无法打开快捷指令链接，请检查网络后重试';

  @override
  String get iosAutoManualConfigTitle => '手动配置（高级）';

  @override
  String get iosAutoManualConfigDesc => '若一键导入不可用，可按以下步骤手动创建快捷指令。';

  @override
  String get aiSettingsTitle => 'AI小助手';

  @override
  String get aiSettingsSubtitle => '配置AI模型和识别策略';

  @override
  String get aiEnableTitle => '启用AI小助手';

  @override
  String get aiEnableSubtitle => '使用 AI 视觉识别账单截图,提取金额、商家、时间等信息,并支持自然语言对话';

  @override
  String get aiEnableToastOn => 'AI小助手已启用';

  @override
  String get aiEnableToastOff => 'AI小助手已关闭';

  @override
  String get aiStrategyTitle => '执行策略';

  @override
  String get aiStrategyLocalFirst => '本地优先（推荐）';

  @override
  String get aiStrategyCloudFirst => '云端优先';

  @override
  String get aiStrategyCloudFirstDesc => '优先使用云端API，失败后降级到本地';

  @override
  String get aiStrategyLocalOnly => '仅本地';

  @override
  String get aiStrategyCloudOnly => '仅云端';

  @override
  String get aiStrategyCloudOnlyDesc => '只使用云端API，不下载模型';

  @override
  String get aiStrategyUnavailable => '本地模型训练中，敬请期待';

  @override
  String aiStrategySwitched(String strategy) {
    return '已切换: $strategy';
  }

  @override
  String get aiCloudApiKeyHint => '输入智谱AI的API Key';

  @override
  String get aiCloudApiKeyHintCustom => '输入API Key';

  @override
  String get aiCloudApiKeyHelper => 'GLM-*-Flash模型完全免费';

  @override
  String get aiCloudApiGetKey => '获取API Key';

  @override
  String get aiCloudApiTutorial => '详细教程';

  @override
  String get aiCloudApiTestKey => '测试连接';

  @override
  String get aiChatConfigWarning => '未配置 AI 服务商，请先在设置中添加并绑定';

  @override
  String get aiChatGoToSettings => '去设置';

  @override
  String get aiOcrRecognizing => '正在识别账单...';

  @override
  String get aiOcrNoAmount => '未识别到有效金额，请手动记账';

  @override
  String get aiNotConfiguredHint => '未配置 AI 服务，请前往「我的 → AI 设置」配置';

  @override
  String get aiOcrCheckLog => '识别失败，请查看日志了解详情';

  @override
  String get aiOcrNoBill => '未识别到账单信息，请确认图片是账单后重试';

  @override
  String get aiNotConfiguredNotificationTitle => '❌ 无法识别截图';

  @override
  String get aiNotConfiguredNotificationBody => '未配置 AI 服务，点击前往设置';

  @override
  String get autoBillingNotifyDetectedTitle => '✅ 检测到截图';

  @override
  String get autoBillingNotifyWaitingFileBody => '正在等待文件写入...';

  @override
  String get autoBillingNotifyRecognizingScreenshotTitle => '正在识别截图...';

  @override
  String get autoBillingNotifyVisionAnalyzingBody => '正在调用 AI 视觉分析支付信息，请稍候';

  @override
  String get autoBillingNotifyRecognizingTextTitle => '⏳ 正在识别';

  @override
  String get autoBillingNotifyTextAnalyzingBody => '正在调用 AI 解析支付信息...';

  @override
  String get autoSmsBillingRecognizingTitle => '⏳ 正在识别短信';

  @override
  String get autoNotifyBillingRecognizingTitle => '⏳ 正在识别通知';

  @override
  String get autoNotifyBillingAnalyzingBody => '正在从通知中提取记账信息...';

  @override
  String get autoScreenBillingRecognizingTitle => '⏳ 正在识别账单页';

  @override
  String get autoScreenBillingAnalyzingBody => '正在从页面文本中提取记账信息...';

  @override
  String get autoSmsBillingAnalyzingBody => '正在从短信中提取记账信息...';

  @override
  String get autoSmsBillingTitle => '短信自动记账';

  @override
  String get autoSmsBillingDesc => '监听银行/支付短信,用 AI 自动记账';

  @override
  String get autoSmsBillingDescEnabled => '监听中,银行/支付短信将自动入账';

  @override
  String get smsPermissionRequired => '需要「短信」权限才能自动记账';

  @override
  String get autoBillingEntryTitle => '自动记账';

  @override
  String get autoBillingHealthy => '运行正常';

  @override
  String autoBillingPartial(Object count, Object issues) {
    return '有 $count 项未就绪:$issues';
  }

  @override
  String get autoBillingSmsPermissionMissing => '短信权限未授权,自动记账不完整';

  @override
  String get autoBillingNotifyPermissionMissing => '「通知使用权」未授权,通知自动记账不完整';

  @override
  String get autoBillingNotifyTitle => '通知自动记账';

  @override
  String get autoBillingNotifyDesc => '监听微信/支付宝/银行 App 支付通知自动记账';

  @override
  String get autoBillingNotifyDescEnabled => '监听中,支付通知将自动入账';

  @override
  String get autoBillingNotifyPermissionTitle => '开启「通知使用权」';

  @override
  String get autoBillingNotifyPermissionContent => '通知自动记账需要系统「通知使用权」授权。点击后跳转系统设置页,找到本应用并开启。';

  @override
  String get autoBillingScreenTextTitle => '详情页自动记账';

  @override
  String get autoBillingScreenTextDesc => '监听支付宝/抖音/京东/微信账单详情页,自动记账';

  @override
  String get autoBillingScreenTextDescEnabled => '监听中,打开账单详情页将自动入账';

  @override
  String get autoBillingScreenTextPermissionMissing => '「无障碍」未授权,详情页自动记账不生效';

  @override
  String get autoBillingScreenTextVivoHint => 'vivo/iQOO 用户注意:若开启后开关自动回弹关闭,请到「设置 → 快速与辅助 → 无障碍」找到本服务开启;仍被关闭时,需在「i 管家 → 隐私权限 → 受限设置」中允许本应用,并在「设置 → 电池 → 后台高耗电」中允许智记。';

  @override
  String get autoBillingScreenTextPermissionTitle => '开启「无障碍服务」';

  @override
  String get autoBillingScreenTextPermissionContent => '详情页自动记账需要系统「无障碍」授权。仅读取支付宝/抖音/京东/微信页面文字(含金额、商户),用于自动记账;文字不入日志、不存储,处理完即删。';

  @override
  String get autoBillingHealthIssueScreenshot => '截图监听';

  @override
  String get autoBillingHealthIssueSms => '短信监听';

  @override
  String get autoBillingHealthIssueSmsPermission => '短信权限';

  @override
  String get autoBillingHealthIssueNotify => '通知监听';

  @override
  String get autoBillingHealthIssueNotifyListener => '通知使用权';

  @override
  String get autoBillingHealthIssueAiText => 'AI 文本模型';

  @override
  String get autoBillingHealthIssueAiVision => 'AI 视觉模型';

  @override
  String get autoBillingHealthIssueBattery => '电池优化';

  @override
  String get autoStartTitle => '自启动与后台保活';

  @override
  String get autoStartDesc => 'vivo/OriginOS 等需手动允许自启动、关闭「后台高耗电」限制、最近任务锁定 App,否则被清理后收不到短信/通知';

  @override
  String get autoStartGo => '去设置';

  @override
  String get autoStartOpened => '已跳转系统设置,请找到本应用开启自启动';

  @override
  String get autoStartOpenFailed => '无法打开厂商设置,请手动在应用详情页开启自启动';

  @override
  String get channelMappingTitle => '渠道→账户映射';

  @override
  String get channelMappingDesc => '短信/通知来源(如 招商银行、支付宝)忽略 AI 账户识别,直接记到指定资产账户';

  @override
  String get channelMappingAdd => '添加映射';

  @override
  String get channelMappingChannelLabel => '渠道名称';

  @override
  String get channelMappingAccountLabel => '目标账户';

  @override
  String get channelMappingEmpty => '暂无映射规则,添加后自动记账将按来源渠道落账';

  @override
  String get channelMappingSaved => '映射已保存';

  @override
  String get channelMappingDeleted => '映射已删除';

  @override
  String get autoBillingMockTitle => '手动模拟测试';

  @override
  String get autoBillingMockDesc => '不依赖真实短信/通知,注入模拟数据验证 AI 记账链路是否正常';

  @override
  String get autoBillingMockSms => '模拟短信';

  @override
  String get autoBillingMockNotify => '模拟通知';

  @override
  String get autoBillingMockScreen => '模拟屏幕文本';

  @override
  String get autoBillingMockSubmitted => '已提交,处理结果见系统通知';

  @override
  String get autoBillingMockCustom => '自定义内容';

  @override
  String get autoBillingMockNotice => '模拟数据与真实消息走同一套 AI 解析流程';

  @override
  String get autoRecognitionRecordsTitle => '自动识别记录';

  @override
  String get autoRecognitionRecordsDesc => '自动记账的识别决策与入账结果';

  @override
  String get autoRecognitionRecordsEmpty => '暂无记录。去打开一笔账单/订单详情页，再回到此页点刷新：\n· 出现新记录 → 决策码说明被哪道闸拦截（或已正常入账）\n· 始终无记录 → 无障碍监听未生效，请检查系统无障碍开关';

  @override
  String get commonRefresh => '刷新';

  @override
  String get pendingConfirmationTitle => '待确认记账';

  @override
  String get pendingConfirmationDesc => '自动记账中低置信/大额/疑似重复的候选,人工审核';

  @override
  String get pendingConfirmationEmpty => '没有待确认的记账';

  @override
  String pendingConfirmationCountBadge(Object count) {
    return '有 $count 笔待确认,点击审核';
  }

  @override
  String get pendingConfirmationConfirm => '确认入账';

  @override
  String get pendingConfirmationEdit => '编辑后入账';

  @override
  String get pendingConfirmationReject => '拒绝';

  @override
  String get pendingConfirmationRejectAsk => '确定拒绝并删除这条待确认记账?';

  @override
  String get pendingConfirmationApproved => '已入账';

  @override
  String get pendingConfirmationRejected => '已拒绝';

  @override
  String get pendingConfirmationEditFailed => '金额无效';

  @override
  String get pendingConfirmationApproveFailed => '入账失败';

  @override
  String get pendingConfirmationAmount => '金额';

  @override
  String get pendingConfirmationNote => '备注';

  @override
  String get pendingConfirmationUncheckedReason => '待确认';

  @override
  String get pendingCandidateReasonDuplicate => '疑似重复:近期已有相似交易';

  @override
  String get pendingCandidateReasonLarge => '大额消费';

  @override
  String get pendingCandidateReasonLowConfidence => '低置信度,请核对';

  @override
  String get pendingCandidateReasonAnomaly => '异常消费:高于近期基线';

  @override
  String get pendingCandidateReasonAutoBookDisabled => '自动入账已关闭,需手动确认';

  @override
  String get pendingCandidatesArchivedHint => '部分较旧候选已归档,请尽快处理';

  @override
  String get autoBookDetailTitle => '自动记账详情';

  @override
  String get autoBookDetailState => '状态';

  @override
  String get autoBookDetailSource => '来源';

  @override
  String get autoBookDetailCapturedAt => '捕获时间';

  @override
  String get autoBookDetailUpdatedAt => '更新时间';

  @override
  String get autoBookDetailAttempts => '尝试次数';

  @override
  String get autoBookDetailError => '错误信息';

  @override
  String get autoBookDetailReason => '原因';

  @override
  String get autoBookDetailEvidence => '原始证据';

  @override
  String get autoBookDetailEvidenceCleared => '原始证据已按留存策略清理或未留存';

  @override
  String get autoBookDetailItems => '解析子项';

  @override
  String get autoBookDetailNoItems => '无子项记录';

  @override
  String get autoBookDetailRelatedTx => '关联交易';

  @override
  String autoBookDetailOpenTx(int id) {
    return '查看交易 #$id';
  }

  @override
  String get autoBookDetailRetry => '手动重试';

  @override
  String get autoBillingNotifyMergeTitle => '已合并到已有交易';

  @override
  String autoBillingNotifyMergeBody(int count, String date, String amount) {
    return '$count 笔与 $date 的 ¥$amount 判为同一笔，已合并，可在自动记账历史中撤销';
  }

  @override
  String get autoBookUndoMerge => '撤销合并（恢复为一笔）';

  @override
  String get autoBookUndoMergeDone => '已恢复到待确认，请处理';

  @override
  String get autoBookUndoMergeEmpty => '没有可恢复的记录';

  @override
  String get dedupExemptTitle => '判重豁免';

  @override
  String get dedupExemptDesc => '确认「仍记一笔」后，同商户同金额段不再被判重';

  @override
  String get dedupExemptEmpty => '暂无豁免规则';

  @override
  String get dedupExemptClear => '清空豁免';

  @override
  String get pendingBatchMode => '批量管理';

  @override
  String get pendingBatchSelectAll => '全选';

  @override
  String get pendingBatchApprove => '批量确认';

  @override
  String get pendingBatchReject => '批量拒绝';

  @override
  String pendingBatchApproved(int count, int failed) {
    return '成功确认 $count 条，失败 $failed 条（已保留）';
  }

  @override
  String pendingBatchRejected(Object count, Object failed) {
    return '成功拒绝 $count 条，失败 $failed 条（已保留）';
  }

  @override
  String pendingBatchRejectAsk(Object count) {
    return '确定拒绝选中的 $count 条候选吗？';
  }

  @override
  String get pendingConfirmationPickCategory => '选择分类';

  @override
  String get pendingConfirmationSimilarTransaction => '相似已有交易';

  @override
  String get pendingConfirmationCompare => '查看对比';

  @override
  String get pendingConfirmationCandidate => '待确认候选';

  @override
  String get pendingConfirmationExisting => '已有交易';

  @override
  String get pendingConfirmationRecordedAt => '记录时间';

  @override
  String get pendingConfirmationMatchedMissing => '这条已有交易已不存在或已删除';

  @override
  String get pendingConfirmationOpenMatched => '打开已有交易';

  @override
  String get pendingConfirmationMatchScoreLabel => '匹配度';

  @override
  String get autoDeleteScreenshotTitle => '记账成功自动删截图';

  @override
  String get autoDeleteScreenshotDesc => '截图被识别为账单并成功入账后,自动从相册删除;非账单、失败或进入「待确认」时保留';

  @override
  String get screenshotSourceFilterTitle => '仅消费类App截图记账';

  @override
  String get screenshotSourceFilterDesc => '仅在金融/电商类App(支付宝、微信、银行、淘宝、京东等)内截图才自动记账,其它App截图不触发识别';

  @override
  String get screenshotSourceFilterDescOff => '已关闭:所有截图都会尝试识别记账';

  @override
  String get screenshotSourceFilterPermissionMissing => '无法识别截图来源App:需开启无障碍服务或授权「使用情况访问」,否则截图不会自动记账';

  @override
  String get autoBookCheckTitle => '自动入账总闸';

  @override
  String get autoBookCheckDesc => '开启:低置信/疑似重复进待确认,其余自动入账';

  @override
  String get autoBookCheckDisabledDesc => '已关闭:所有识别结果需手动确认后入账';

  @override
  String get smartBillingChecking => '正在检查…';

  @override
  String get autoBillingNotifyRecognizeFailedTitle => '❌ 识别失败';

  @override
  String get autoBillingNotifyRecognizeFailedBody => '无法从截图提取账单信息，请检查 AI 配置或图片';

  @override
  String get autoBillingNotifyNoBillTitle => '未识别到账单';

  @override
  String get autoBillingNotifyNoBillBody => '这张截图未识别到账单信息，可能不是账单';

  @override
  String get autoScreenBillingNoBillTitle => '该页面未识别到账单';

  @override
  String get autoScreenBillingNoBillBody => '页面未识别到已成交交易,已跳过';

  @override
  String get autoScreenBillingRecognizeFailedTitle => '❌ 识别失败';

  @override
  String get autoScreenBillingRecognizeFailedBody => '无法从页面文本提取账单信息,请检查 AI 配置';

  @override
  String get autoScreenBillingProcessFailedTitle => '❌ 处理失败';

  @override
  String get autoBillingNotifyFileUnavailableTitle => '识别失败';

  @override
  String get autoBillingNotifyFileUnavailableBody => '截图文件不可用';

  @override
  String get autoBillingNotifyNoLedgerTitle => '❌ 自动记账失败';

  @override
  String get autoBillingNotifyNoLedgerBody => '无可用账本，请先创建账本';

  @override
  String get autoBillingNotifyNoAmountBody => '未能识别出金额信息';

  @override
  String get autoBillingNotifyCreateFailedTitle => '❌ 创建失败';

  @override
  String get autoBillingNotifyCreateFailedBody => '无法创建交易记录';

  @override
  String get autoBillingNotifyProcessFailedTitle => '❌ 处理失败';

  @override
  String autoBillingNotifyProcessFailedBody(String error) {
    return '错误：$error';
  }

  @override
  String autoBillingNotifySuccessSingleTitle(String amount) {
    return '✅ 自动记账成功 ¥$amount';
  }

  @override
  String autoBillingNotifySuccessMultiTitle(int count) {
    return '✅ 自动记账成功 $count 笔';
  }

  @override
  String autoBillingNotifySuccessMultiBody(String amount) {
    return '合计 ¥$amount';
  }

  @override
  String get autoBillingNotifyPendingTitle => '自动记账待确认';

  @override
  String homePendingConfirmBanner(Object count) {
    return '有 $count 笔自动记账待确认';
  }

  @override
  String autoBillingNotifyPendingBody(Object amount, Object count) {
    return '$count 笔支出待确认，合计 ¥$amount';
  }

  @override
  String autoBillingNotifySuccessSingleBodyNote(String note) {
    return '备注：$note';
  }

  @override
  String get autoBillingNotifySuccessSingleBodyDefault => '已自动创建记录';

  @override
  String get aiOcrNoLedger => '未找到账本';

  @override
  String aiBillingRateMissingHint(String currency) {
    return '⚠️ 未取到 $currency 汇率，已按 1:1 暂记，可在统计页「补折算」修正';
  }

  @override
  String get aiPromptVarCurrencies => '账本主币种 + 已在用的外币账户';

  @override
  String get aiPromptVarBillGuard => '账单过滤段（仅截图 / 自动记账时注入）';

  @override
  String aiPromptMissingVarsHint(String vars) {
    return '你的自定义模板缺少这些变量，对应能力会失效：$vars';
  }

  @override
  String aiPromptInsertVarSection(String name) {
    return '插入 $name 段落';
  }

  @override
  String aiPromptVarSectionInserted(String name) {
    return '已追加 $name 段落，确认后保存';
  }

  @override
  String aiOcrSuccess(String type, String amount) {
    return '✅ $type账单创建成功 ¥$amount';
  }

  @override
  String aiOcrFailed(String error) {
    return '识别失败: $error';
  }

  @override
  String get aiOcrCreateFailed => '创建账单失败';

  @override
  String get aiTypeIncome => '收入';

  @override
  String get aiTypeExpense => '支出';

  @override
  String get cloudSyncPageTitle => '云同步';

  @override
  String get cloudSyncPageSubtitle => '手动上传和下载账本数据';

  @override
  String get cloudTutorialTitle => '使用教程';

  @override
  String get cloudTutorialIntro => '智记 是可以自建的云同步服务端,支持多设备实时协同。流程很简单:';

  @override
  String get cloudTutorialStep1Title => '第一步:部署或选择服务器';

  @override
  String get cloudTutorialStep1Desc => '自己部署:Docker 一行命令拉起(见 GitHub README 的 Docker 指南)。或直接使用朋友/团队已有的智记 服务器。';

  @override
  String get cloudTutorialStep2Title => '第二步:获取账号';

  @override
  String get cloudTutorialStep2Desc => '智记 不支持自助注册(避免公网服务被滥用)。自己部署的同学:首次启动 Docker 日志里会打印随机管理员账号密码,直接用。加入他人服务器的同学:让管理员在 Web 后台 →「用户」里帮你添加账号。';

  @override
  String get cloudTutorialStep3Title => '第三步:登录并开启同步';

  @override
  String get cloudTutorialStep3Desc => 'App 里选「智记」,填服务器地址 + 管理员给你的账号,登录。首次会全量上传你本地所有账本数据,之后每次编辑实时推送。';

  @override
  String get cloudTutorialStep4Title => '第四步:其他设备登录';

  @override
  String get cloudTutorialStep4Desc => '手机、平板、Web 三端用同一账号登录,数据即刻互通。修改几秒内互相感知。';

  @override
  String get cloudTutorialTipTitle => '小贴士';

  @override
  String get cloudTutorialTipDesc => 'Web 端地址 = 服务器地址,浏览器直接访问即可。登录后可以管理账本、成员、查看日志。';

  @override
  String get cloudTutorialFeaturesTitle => '特色功能';

  @override
  String get cloudTutorialFeature1 => '📱 多设备实时协同:手机 A + 手机 B + Web 三端同账号,数据秒级同步';

  @override
  String get cloudTutorialFeature2 => '🌐 自带 Web 管理端:一个 Docker 镜像包含 server + web,浏览器即可使用';

  @override
  String get cloudTutorialFeature3 => '👥 多用户独立:一个服务器可以多人注册,各自数据完全隔离';

  @override
  String get cloudTutorialFeature4 => '🤝 共享账本:邀请家人 / 团队一起记同一本,实时秒级同步';

  @override
  String get cloudTutorialGotIt => '我知道了';

  @override
  String get cloudSyncHint => '下载时可自动对比差异并逐条预览。非实时同步，请避免多设备同时编辑同一账本。同步范围为账本数据（含关联的账户、分类、标签），不含附件。';

  @override
  String get cloudSyncNow => '立即同步';

  @override
  String get cloudSyncNowHint => '推送本地变更并拉取远端更新';

  @override
  String get cloudSyncInProgress => '正在同步...';

  @override
  String cloudSyncComplete(int pushed, int pulled) {
    return '同步完成：推送 $pushed 条，拉取 $pulled 条';
  }

  @override
  String get cloudAutoSyncHint => '数据变更后自动同步到云端';

  @override
  String get dataManagement => '数据管理';

  @override
  String get dataManagementDesc => '导入导出、分类账户管理';

  @override
  String get dataManagementPageTitle => '数据管理';

  @override
  String get dataManagementPageSubtitle => '管理账单数据和分类';

  @override
  String get dataManagementAttachmentHint => '还原数据时，请先导入附件包，再导入账本数据（CSV或云同步），以确保附件正确关联。';

  @override
  String get smartBilling => '智能记账';

  @override
  String get smartBillingDesc => 'AI 助手、智能识别、自动记账';

  @override
  String get smartBillingPageTitle => '智能记账';

  @override
  String get smartBillingPageSubtitle => 'AI和自动化记账功能';

  @override
  String get smartBillingGuideHint => '长按底部中间的 AI 助手按钮呼出扇形菜单，或在 AI 助手对话页中使用';

  @override
  String get smartBillingTryNow => '立即体验';

  @override
  String get smartBillingImageBilling => '图片记账';

  @override
  String get smartBillingImageBillingDesc => '从相册选择支付截图识别（长按 AI 助手或在对话中使用）';

  @override
  String get smartBillingImageBillingGuide => '可在首页底部长按「AI 助手」按钮滑动选择「相册」，或进入「AI 助手」对话页点击输入框左侧「+」选择「相册」。AI 视觉模型会自动识别截图中的金额、商家、时间等信息。\n\n提示：也可在手机桌面长按应用图标，或在相册中将截图直接分享给智记。';

  @override
  String get smartBillingVisionAIRequired => '图片识别必须配置 AI 视觉服务，请先在「我的 → AI 设置」中配置';

  @override
  String get smartBillingCameraBilling => '拍照记账';

  @override
  String get smartBillingCameraBillingDesc => '拍摄纸质小票或账单识别（长按 AI 助手或在对话中使用）';

  @override
  String get smartBillingCameraBillingGuide => '可在首页底部长按「AI 助手」按钮滑动选择「拍照」，或进入「AI 助手」对话页点击输入框左侧「+」选择「拍照」。AI 视觉模型会自动识别小票中的金额、商家、时间等信息。';

  @override
  String get smartBillingVoiceBilling => '语音记账';

  @override
  String get smartBillingVoiceBillingDesc => '语音口述日常收支记账（长按 AI 助手或在对话中使用）';

  @override
  String get smartBillingVoiceBillingGuide => '可在首页底部长按「AI 助手」按钮滑动选择「语音」，或进入「AI 助手」对话页按住麦克风说话。AI 会自动转写语音并智能提取账单信息入账。';

  @override
  String get smartBillingAIRequired => '语音记账必须配置 AI 语音识别服务，请先在「我的 → AI 设置」中配置';

  @override
  String get smartBillingAutoTags => '自动关联标签';

  @override
  String get smartBillingAutoTagsDesc => '智能记账时自动根据分类关联常用标签';

  @override
  String get smartBillingAutoAttachment => '自动添加附件';

  @override
  String get smartBillingAutoAttachmentDesc => '图片/拍照记账时自动将原图添加为附件';

  @override
  String get autoScreenshotBillingIosTitle => '自动记账';

  @override
  String get autoScreenshotBillingIosDesc => '通过快捷指令自动识别支付信息记账';

  @override
  String get shareBilling => '分享记账';

  @override
  String get shareBillingDesc => '从支付宝/微信分享支付截图即可记账';

  @override
  String get shareBillingGuide => '在支付宝、微信、相册等应用中看到支付截图时，点击「分享」并选择「智记」，即可自动识别金额、商家、时间等信息并记账，无需先保存截图。';

  @override
  String get shareBillingActionHint => '分享后会在后台自动识别记账，无需手动打开智记';

  @override
  String get automation => '自动化';

  @override
  String get automationDesc => '周期记账、记账提醒';

  @override
  String get automationPageTitle => '自动化功能';

  @override
  String get automationPageSubtitle => '周期记账和提醒设置';

  @override
  String get appearanceSettings => '个性化设置';

  @override
  String get appearanceSettingsDesc => '主题、字体、语言、应用锁等';

  @override
  String get appearanceSettingsPageTitle => '个性化设置';

  @override
  String get appearanceSettingsPageSubtitle => '外观、显示、安全等应用偏好';

  @override
  String get about => '关于';

  @override
  String get aboutDesc => '版本信息、帮助与反馈';

  @override
  String get aboutPageTitle => '关于';

  @override
  String get aboutPageSubtitle => '应用信息和帮助';

  @override
  String get mineRateApp => '给应用评分';

  @override
  String get mineRateAppSubtitle => '在App Store上为我们打分';

  @override
  String get aboutPageLoadingVersion => '加载版本号中...';

  @override
  String get aboutWebsite => '官方网站';

  @override
  String get aboutGitHubRepo => 'GitHub 仓库';

  @override
  String get aboutXiaohongshu => '小红书';

  @override
  String get aboutDouyin => '抖音';

  @override
  String get aboutTelegram => 'Telegram 群';

  @override
  String get aboutSupportDevelopment => '支持开发';

  @override
  String get aboutSupportDevelopmentSubtitle => '请开发者喝杯咖啡';

  @override
  String get aboutDeveloperStoryTitle => '开发者的话';

  @override
  String get aboutDeveloperStory => '从 2015 年实习起，我坚持记账至今已超过十年。因为担心记账软件的广告、付费、隐私泄露和停运跑路，我决定自己做一个——最初只是给自己和家人用的小工具。\n\n2025 年 9 月，智记发布了第一个版本。说实话，那时候心里没什么底，不知道会不会有人用。但慢慢地，开始收到用户的反馈——有人说终于找到了一款干净的记账软件，有人提了很好的建议，也有人默默给了五星好评。每一条反馈都让我觉得，这件事值得继续做下去。\n\n智记没有广告、没有会员、完全免费开源。你的每一笔数据都只存在你自己的手机里，不会被上传到任何第三方服务器。但上架和维护一款 App 并非零成本——开发者账号、服务器等开支目前靠社区捐赠勉强支撑，每一次适配新系统、修复 Bug、开发新功能，也都是工作之余一点点完成的。\n\n如果你觉得智记对你有帮助，一个好评、一次分享或一笔捐赠，都能让这个小项目走得更远。谢谢你的信任。';

  @override
  String get aboutRelatedProducts => '更多产品';

  @override
  String get aboutBeeAssets => '蜜蜂家当 BeeAssets';

  @override
  String get aboutBeeAssetsSubtitle => '可视化你的全部资产配置';

  @override
  String get aboutBeeAssetsIntro => '智记侧重日常流水,蜜蜂家当是它的姐妹产品,专注资产配置可视化:跨账户净资产趋势、房产 / 投资 / 加密资产分类、收益率与持仓时长、配置占比一目了然。';

  @override
  String get aboutBeeDNS => '蜜蜂域名 BeeDNS';

  @override
  String get aboutBeeDNSSubtitle => '简洁高效的 DNS 管理工具';

  @override
  String get aboutBeeDNSIntro => '如果你的域名分散在 Cloudflare 和阿里云,蜜蜂域名把它们聚合在一处管理:批量改记录、A/AAAA 切换、解析迁移、子域名批量管理 — 不用在两家控制台来回切。';

  @override
  String get productPromoAndroidTitle => '申请加入内测';

  @override
  String get productPromoAndroidMessage => '这款 App 还在 Google Play 内测阶段,需要邀请才能下载。\n\n申请方式:发邮件给我们,告诉我们你的 Google 账号邮箱(必填),以及简单说明使用场景(可选)。我们会在 1-3 天内回复并加你到内测白名单。';

  @override
  String get productPromoOpenStore => '前往应用商店';

  @override
  String get productPromoTestFlight => 'TestFlight 内测';

  @override
  String get productPromoLearnMore => 'Pro';

  @override
  String get productPromoEmailLabel => '申请邮箱(点击复制)';

  @override
  String get productPromoCopiedToast => '邮箱已复制到剪贴板';

  @override
  String get productPromoMailUnavailable => '未检测到邮件应用,邮箱已复制到剪贴板,请打开任意邮件应用粘贴发送';

  @override
  String get productPromoEmailButton => '发送邮件';

  @override
  String get productPromoWebsiteButton => '前往官网';

  @override
  String productPromoEmailSubject(String productName) {
    return '申请内测 - $productName';
  }

  @override
  String productPromoEmailBody(String productName) {
    return '你好,\n\n我希望加入「$productName」的 Google Play 内测,我的 Google 账号邮箱是:\n\n(请填写你的 Gmail / Google 账号邮箱)\n\n谢谢!';
  }

  @override
  String get logCenterTitle => '日志中心';

  @override
  String get logCenterSubtitle => '查看应用运行日志';

  @override
  String get logCenterSearchHint => '搜索日志内容或标签...';

  @override
  String get logCenterFilterLevel => '日志级别';

  @override
  String get logCenterFilterPlatform => '平台';

  @override
  String get logCenterTotal => '全部';

  @override
  String get logCenterFiltered => '已过滤';

  @override
  String get logCenterEmpty => '暂无日志';

  @override
  String get logCenterExport => '导出';

  @override
  String get logCenterClear => '清空';

  @override
  String get logCenterExportFailed => '导出失败';

  @override
  String get logCenterClearConfirmTitle => '清空日志';

  @override
  String get logCenterClearConfirmMessage => '确定要清空所有日志吗？此操作不可恢复。';

  @override
  String get logCenterCleared => '日志已清空';

  @override
  String get logCenterCopied => '已复制到剪贴板';

  @override
  String get configImportExportTitle => '配置导入导出';

  @override
  String get configImportExportSubtitle => '备份和恢复应用配置';

  @override
  String get configImportExportInfoTitle => '功能说明';

  @override
  String get configImportExportInfoMessage => '此功能用于导出和导入应用配置，包括云服务配置、AI配置等。配置文件采用YAML格式，方便查看和编辑。\n\n⚠️ 配置文件包含敏感信息（如API密钥、密码等），请妥善保管。';

  @override
  String get configExportTitle => '导出配置';

  @override
  String get configExportSubtitle => '将当前配置导出为YAML文件';

  @override
  String get configExportShareSubject => '智记 配置文件';

  @override
  String get configExportSuccess => '配置导出成功';

  @override
  String get configExportFailed => '配置导出失败';

  @override
  String get configImportTitle => '导入配置';

  @override
  String get configImportSubtitle => '从YAML文件恢复配置';

  @override
  String get configImportNoFilePath => '未选择文件';

  @override
  String get configImportConfirmTitle => '确认导入';

  @override
  String get configImportSuccess => '配置导入成功';

  @override
  String get configImportFailed => '配置导入失败';

  @override
  String get configImportRestartTitle => '需要重启';

  @override
  String get configImportRestartMessage => '配置已导入，部分配置需要重启应用后生效。';

  @override
  String get configImportExportIncludesTitle => '包含的配置项';

  @override
  String configExportSavedTo(String path) {
    return '已保存至: $path';
  }

  @override
  String get configExportViewContent => '查看内容';

  @override
  String get configExportCopyContent => '复制内容';

  @override
  String get configExportContentCopied => '已复制到剪贴板';

  @override
  String get configExportReadFileFailed => '读取文件失败';

  @override
  String get configIncludeLedgers => '账本';

  @override
  String get configIncludeSupabase => 'Supabase 云服务配置';

  @override
  String get configIncludeWebdav => 'WebDAV 云服务配置';

  @override
  String get configIncludeS3 => 'S3 云服务配置';

  @override
  String get configIncludeAI => 'AI 智能识别配置';

  @override
  String get configIncludeAISubtitle => '服务商、能力绑定、模型设置等';

  @override
  String get configIncludeAppSettings => '应用设置（语言、外观、提醒、默认账户等）';

  @override
  String get configIncludeRecurringTransactions => '周期账单';

  @override
  String get configIncludeAccounts => '账户';

  @override
  String get configIncludeCategories => '分类';

  @override
  String get configIncludeTags => '标签';

  @override
  String get configIncludeBudgets => '预算';

  @override
  String get configIncludeOtherSettings => '其他设置';

  @override
  String get configIncludeOtherSettingsSubtitle => '包含云服务配置、AI配置、应用设置等';

  @override
  String get configExportSelectTitle => '选择导出内容';

  @override
  String get configExportPreviewTitle => '导出预览';

  @override
  String get configExportConfirmTitle => '确认导出';

  @override
  String get configImportSelectTitle => '选择导入内容';

  @override
  String get configImportPreviewTitle => '导入预览';

  @override
  String get ledgersLocal => '本地账本';

  @override
  String get ledgersRemote => '云端账本';

  @override
  String get ledgersEmpty => '暂无账本';

  @override
  String get ledgersRestoreAll => '全部恢复';

  @override
  String ledgersSwitched(String name) {
    return '已切换到账本\"$name\"';
  }

  @override
  String get ledgersDownloadTitle => '下载账本';

  @override
  String ledgersDownloadMessage(String name) {
    return '确认下载账本\"$name\"到本地？';
  }

  @override
  String get ledgersDownloading => '下载中...';

  @override
  String ledgersDownloadSuccess(String name) {
    return '账本\"$name\"下载成功';
  }

  @override
  String get ledgersDownload => '下载';

  @override
  String get ledgersDeleteRemote => '删除云端账本';

  @override
  String get ledgersDeleteRemoteConfirm => '删除云端账本';

  @override
  String ledgersDeleteRemoteMessage(String name) {
    return '确认删除云端账本\"$name\"？此操作不可恢复。';
  }

  @override
  String get ledgersDeleting => '删除中...';

  @override
  String get ledgersDeleteRemoteSuccess => '已删除云端账本';

  @override
  String get ledgersCannotDeleteLastOne => '无法删除最后一个账本';

  @override
  String get ledgersRestoreAllTitle => '批量恢复';

  @override
  String ledgersRestoreAllMessage(int count) {
    return '确认恢复所有云端账本？共 $count 个。';
  }

  @override
  String get ledgersRestoring => '恢复中...';

  @override
  String get ledgersRestoreComplete => '恢复完成';

  @override
  String ledgersRestoreResult(int success, int failed) {
    return '成功: $success，失败: $failed';
  }

  @override
  String get ledgersConflictTitle => '同步冲突';

  @override
  String get ledgersConflictMessage => '本地和云端账本数据不一致，请选择操作：';

  @override
  String ledgersConflictLocalInfo(int count) {
    return '本地：$count 笔账单';
  }

  @override
  String ledgersConflictRemoteInfo(int count) {
    return '云端：$count 笔账单';
  }

  @override
  String ledgersConflictRemoteUpdated(String time) {
    return '云端更新：$time';
  }

  @override
  String ledgersConflictLocalFingerprint(String fp) {
    return '本地指纹：$fp';
  }

  @override
  String ledgersConflictRemoteFingerprint(String fp) {
    return '云端指纹：$fp';
  }

  @override
  String get ledgersConflictUpload => '上传到云端';

  @override
  String get ledgersConflictDownload => '下载到本地';

  @override
  String get ledgersConflictUploading => '正在上传...';

  @override
  String get ledgersConflictDownloading => '正在下载...';

  @override
  String get ledgersConflictUploadSuccess => '上传成功';

  @override
  String ledgersConflictDownloadSuccess(int inserted) {
    return '下载成功，已合并 $inserted 笔账单';
  }

  @override
  String get storageManagementTitle => '存储空间管理';

  @override
  String get storageManagementSubtitle => '清理缓存释放空间';

  @override
  String get storageAIModels => 'AI模型';

  @override
  String get storageAPKFiles => '安装包';

  @override
  String get storageNoData => '无数据';

  @override
  String get storageFiles => '个文件';

  @override
  String get storageHint => '点击项目可清理对应的缓存文件';

  @override
  String get storageClearConfirmTitle => '确认清理';

  @override
  String storageClearAIModelsMessage(String size) {
    return '确定要清理所有AI模型吗？大小: $size';
  }

  @override
  String storageClearAPKMessage(String size) {
    return '确定要清理所有安装包吗？大小: $size';
  }

  @override
  String get storageClearSuccess => '清理成功';

  @override
  String get accountNoTransactions => '暂无交易记录';

  @override
  String get accountTransactionHistory => '交易记录';

  @override
  String get accountTotalBalance => '净资产';

  @override
  String get accountCurrencyLocked => '该账户已有交易记录，不允许修改币种';

  @override
  String get accountDefaultIncomeTitle => '默认收入账户';

  @override
  String get accountDefaultExpenseTitle => '默认支出账户';

  @override
  String get accountDefaultNone => '不设置';

  @override
  String get commonNotice => '提示';

  @override
  String get transferTitle => '转账';

  @override
  String get transferIconSettings => '转账图标设置';

  @override
  String get transferIconSettingsDesc => '自定义转账记录的显示图标';

  @override
  String get transferFromAccount => '转出账户';

  @override
  String get transferToAccount => '转入账户';

  @override
  String get transferSelectAccount => '选择账户';

  @override
  String get transferCreateSuccess => '转账创建成功';

  @override
  String get transferUpdateSuccess => '转账更新成功';

  @override
  String get transferDifferentCurrencyError => '转账仅支持相同币种的账户';

  @override
  String get transferToPrefix => '转账至';

  @override
  String get transferFromPrefix => '来自';

  @override
  String get welcomeCategoryModeTitle => '选择分类模式';

  @override
  String get welcomeCategoryModeDescription => '选择更适合您使用习惯的分类方式';

  @override
  String get welcomeCategoryModeFlatTitle => '一级分类';

  @override
  String get welcomeCategoryModeFlatDescription => '简单直观，快速记账';

  @override
  String get welcomeCategoryModeFlatFeature1 => '扁平化结构，操作简单';

  @override
  String get welcomeCategoryModeFlatFeature2 => '适合习惯简单分类的用户';

  @override
  String get welcomeCategoryModeFlatFeature3 => '快速选择，高效记账';

  @override
  String get welcomeCategoryModeHierarchicalTitle => '二级分类';

  @override
  String get welcomeCategoryModeHierarchicalDescription => '精细管理，清晰明了';

  @override
  String get welcomeCategoryModeHierarchicalFeature1 => '支持父子分类层级';

  @override
  String get welcomeCategoryModeHierarchicalFeature2 => '更细致的账单归类';

  @override
  String get welcomeCategoryModeHierarchicalFeature3 => '适合需要精细管理的用户';

  @override
  String get welcomeCategoryModeNoneTitle => '不创建分类';

  @override
  String get welcomeCategoryModeNoneDescription => '完全自定义，按需添加';

  @override
  String get welcomeCategoryModeNoneFeature1 => '不预置任何分类';

  @override
  String get welcomeCategoryModeNoneFeature2 => '完全按自己需求创建';

  @override
  String get welcomeCategoryModeNoneFeature3 => '适合有特殊分类需求的用户';

  @override
  String get welcomeExistingUserTitle => '老用户？';

  @override
  String get welcomeExistingUserButton => '导入配置';

  @override
  String get welcomeImportingConfig => '正在导入配置...';

  @override
  String get welcomeImportSuccess => '配置导入成功';

  @override
  String welcomeImportFailed(String error) {
    return '配置导入失败: $error';
  }

  @override
  String get welcomeImportNoFile => '未选择文件';

  @override
  String get welcomeImportAttachmentTitle => '导入附件';

  @override
  String get welcomeImportAttachmentDesc => '检测到您导入了配置文件，是否需要导入附件文件？';

  @override
  String get welcomeImportAttachmentButton => '选择附件文件';

  @override
  String get welcomeImportAttachmentSkip => '跳过';

  @override
  String welcomeImportAttachmentSuccess(int imported) {
    return '附件导入完成：导入 $imported 个';
  }

  @override
  String welcomeImportAttachmentFailed(String error) {
    return '附件导入失败: $error';
  }

  @override
  String get welcomeImportingAttachment => '正在导入附件...';

  @override
  String get iosVersionWarningTitle => '需要 iOS 16.0 或更高版本';

  @override
  String get iosVersionWarningDesc => '截图自动记账功能使用了 iOS 16 引入的 App Intents 框架。您的设备系统版本较低，暂不支持此功能。\n\n请升级到 iOS 16 或更高版本以使用此功能。';

  @override
  String get aiChatTitle => 'AI助手';

  @override
  String get aiChatImageLabel => '图片';

  @override
  String get aiChatRetry => '重新识别';

  @override
  String get aiChatVoiceLabel => '语音';

  @override
  String get aiChatClearHistory => '清除对话历史';

  @override
  String get aiChatClearHistoryDialogTitle => '清除对话历史';

  @override
  String get aiChatClearHistoryDialogContent => '确定要清除所有对话记录吗?此操作不可恢复。';

  @override
  String get aiChatInputHint => '例如: 买了杯咖啡35块';

  @override
  String get aiChatThinking => '思考中...';

  @override
  String get aiChatHistoryCleared => '对话历史已清空';

  @override
  String get aiChatCopy => '复制';

  @override
  String get aiChatCopied => '已复制到剪贴板';

  @override
  String get aiChatDeleteMessageConfirm => '确定要删除这条消息吗？';

  @override
  String get aiChatMessageDeleted => '消息已删除';

  @override
  String get aiChatUndone => '已撤销,30 天内可在「最近删除」恢复';

  @override
  String get aiChatUndoFailed => '撤销失败';

  @override
  String get aiChatTransactionNotFound => '交易记录不存在';

  @override
  String get aiChatOpenEditorFailed => '打开编辑页面失败';

  @override
  String get aiChatSendFailed => '发送失败';

  @override
  String get aiQuickCommandFinancialHealthTitle => '财务健康分析';

  @override
  String get aiQuickCommandFinancialHealthDesc => '分析收支平衡和储蓄率';

  @override
  String get aiQuickCommandFinancialHealthPrompt => '请根据以下数据分析我的财务健康状况：\n\n[monthlyStats]\n\n[recentTrends]\n\n请从收支平衡、储蓄率、消费趋势等角度给出专业分析和建议。请用简体中文回复。';

  @override
  String get aiQuickCommandMonthlyExpenseTitle => '本月支出总结';

  @override
  String get aiQuickCommandMonthlyExpenseDesc => '月度支出分析和建议';

  @override
  String get aiQuickCommandMonthlyExpensePrompt => '请总结我本月的支出情况：\n\n[monthlyStats]\n\n[categoryStats]\n\n请分析主要支出类别，并给出节约开支的建议。请用简体中文回复。';

  @override
  String get aiQuickCommandCategoryAnalysisTitle => '分类占比分析';

  @override
  String get aiQuickCommandCategoryAnalysisDesc => '各分类支出占比和趋势';

  @override
  String get aiQuickCommandCategoryAnalysisPrompt => '请分析我的各分类支出占比：\n\n[categoryStats]\n\n请指出哪些分类支出过高，并给出优化建议。请用简体中文回复。';

  @override
  String get aiQuickCommandBudgetPlanningTitle => '预算规划建议';

  @override
  String get aiQuickCommandBudgetPlanningDesc => '基于历史数据的预算建议';

  @override
  String get aiQuickCommandBudgetPlanningPrompt => '请基于以下数据帮我制定下月预算：\n\n[monthlyStats]\n\n[recentTrends]\n\n请给出各分类的预算建议和注意事项。请用简体中文回复。';

  @override
  String get aiQuickCommandAbnormalExpenseTitle => '异常支出提醒';

  @override
  String get aiQuickCommandAbnormalExpenseDesc => '识别大额或异常支出';

  @override
  String get aiQuickCommandAbnormalExpensePrompt => '请检查我最近是否有异常支出：\n\n[recentTransactions]\n\n[monthlyStats]\n\n请指出可能的异常消费，并分析原因。请用简体中文回复。';

  @override
  String get aiQuickCommandSavingTipsTitle => '省钱小贴士';

  @override
  String get aiQuickCommandSavingTipsDesc => '根据消费习惯给建议';

  @override
  String get aiQuickCommandSavingTipsPrompt => '请根据我的消费习惯给出省钱建议：\n\n[categoryStats]\n\n[recentTrends]\n\n请提供3-5条实用的省钱技巧。请用简体中文回复。';

  @override
  String get billCardSuccess => '记账成功';

  @override
  String get billCardUndone => '已撤销';

  @override
  String get billCardAmount => '💰 金额';

  @override
  String get billCardCategory => '🏷️ 分类';

  @override
  String get billCardTime => '📅 时间';

  @override
  String get billCardNote => '📝 备注';

  @override
  String get billCardAccount => '💳 账户';

  @override
  String get billCardUndo => '撤销';

  @override
  String get billCardEdit => '修改';

  @override
  String get billCardUnknownLedger => '未知账本';

  @override
  String get donationTitle => '捐赠';

  @override
  String get donationSubtitle => '请我喝杯咖啡';

  @override
  String get donationEntrySubtitle => '支持应用持续开发';

  @override
  String get donationDescription => '说明';

  @override
  String get donationDescriptionDetail => '感谢您使用智记！如果这个应用对您有帮助，欢迎请开发者喝杯咖啡作为鼓励。您的支持是我持续改进的动力。';

  @override
  String get donationNoFeatures => '注: 打赏不会解锁任何功能，所有功能继续完全免费。';

  @override
  String get donationNoProducts => '暂无可用商品';

  @override
  String get donationThankYouTitle => '感谢支持！';

  @override
  String donationThankYouMessage(String productName) {
    return '感谢您购买 $productName！您的支持对我意义重大，我会继续努力改进智记，让它变得更好用！';
  }

  @override
  String get aiPromptEditTitle => '提示词编辑';

  @override
  String get aiPromptEditSubtitle => '自定义AI账单识别提示词';

  @override
  String get aiPromptAdvancedSettings => '高级设置';

  @override
  String get aiAdvancedSettingsDesc => '模型选择、执行策略、本地模型、提示词';

  @override
  String get aiPromptEditEntry => '提示词编辑';

  @override
  String get aiPromptEditEntryDesc => '自定义AI账单识别提示词，可分享给其他用户';

  @override
  String get aiPromptVariables => '变量说明';

  @override
  String get aiPromptVariablesHint => '点击展开查看可用变量';

  @override
  String get aiPromptContent => '提示词内容';

  @override
  String get aiPromptUnsaved => '未保存';

  @override
  String get aiPromptInputHint => '输入提示词...';

  @override
  String get aiPromptPreview => '预览';

  @override
  String get aiPromptSave => '保存';

  @override
  String get aiPromptSaved => '提示词已保存';

  @override
  String get aiPromptResetDefault => '恢复默认';

  @override
  String get aiPromptResetConfirmTitle => '恢复默认';

  @override
  String get aiPromptResetConfirmMessage => '确定要恢复默认提示词吗？您的自定义内容将会丢失。';

  @override
  String get aiPromptPasted => '已粘贴';

  @override
  String get aiPromptPreviewTitle => '提示词预览';

  @override
  String get aiPromptPreviewNote => '以上预览使用示例数据替换变量，实际运行时会使用真实数据';

  @override
  String get aiPromptVarInputSource => '输入来源描述，如\"从以下支付账单文本中\"';

  @override
  String get aiPromptVarCurrentTime => '当前日期和时间，如\"2025-01-15 14:30\"';

  @override
  String get aiPromptVarCurrentDate => '当前日期，如\"2025-01-15\"';

  @override
  String get aiPromptVarOcrText => '用户输入的文本内容';

  @override
  String get aiPromptVarCategories => '支出和收入分类列表';

  @override
  String get aiPromptVarAccounts => '用户的账户列表（可能为空）';

  @override
  String get aiModelTitle => '文本推理模型';

  @override
  String get aiVisionModelTitle => '视觉模型';

  @override
  String get aiVisionConcurrency => '并发数';

  @override
  String get aiVisionConcurrencyHelper => '文字识别与图片识别同时进行的最大任务数(1-32)';

  @override
  String get aiModelFast => '快速';

  @override
  String get aiModelAccurate => '准确';

  @override
  String aiModelSwitched(String modelName) {
    return '已切换到 $modelName';
  }

  @override
  String get aiCustomBaseUrlHelper => '标准聊天补全API地址，例如 https://api.example.com/v1';

  @override
  String get aiTextModelTitle => '文本模型';

  @override
  String get aiAudioModelTitle => '语音模型';

  @override
  String get tagManageTitle => '标签管理';

  @override
  String get tagManageSubtitle => '管理交易标签';

  @override
  String get tagManageEmpty => '暂无标签';

  @override
  String get tagManageEmptyHint => '点击右上角添加标签';

  @override
  String get tagManageGenerateDefault => '生成默认标签';

  @override
  String get tagManageGenerateDefaultConfirm => '确定要生成默认标签吗？已有同名标签不会被覆盖。';

  @override
  String get tagManageGenerateDefaultSuccess => '默认标签已生成';

  @override
  String get tagEditTitle => '编辑标签';

  @override
  String get tagAddTitle => '新增标签';

  @override
  String get tagNameLabel => '标签名称';

  @override
  String get tagNameHint => '请输入标签名称';

  @override
  String get tagNameRequired => '标签名称不能为空';

  @override
  String get tagNameDuplicate => '标签名称已存在';

  @override
  String get tagColorLabel => '标签颜色';

  @override
  String get tagCreateSuccess => '标签创建成功';

  @override
  String get tagUpdateSuccess => '标签更新成功';

  @override
  String get tagDeleteConfirmTitle => '删除标签';

  @override
  String tagDeleteConfirmMessage(String name) {
    return '确定要删除标签「$name」吗？此操作不会影响已关联的交易记录。';
  }

  @override
  String get tagDeleteSuccess => '标签已删除';

  @override
  String get tagSelectTitle => '选择标签';

  @override
  String get tagSelectHint => '可多选';

  @override
  String get tagSelectCreateNew => '新建标签';

  @override
  String get tagSelectOwnerManaged => '共享账本标签由所有者管理';

  @override
  String get tagSelectRecentlyUsed => '最近使用';

  @override
  String get tagSelectAllTags => '全部标签';

  @override
  String tagTransactionCount(int count) {
    return '$count笔';
  }

  @override
  String get tagDetailTitle => '标签详情';

  @override
  String get tagDetailTotalCount => '交易笔数';

  @override
  String get tagDetailTotalExpense => '总支出';

  @override
  String get tagDetailTotalIncome => '总收入';

  @override
  String get tagDetailTransactionList => '关联交易';

  @override
  String get tagDetailNoTransactions => '暂无关联交易';

  @override
  String get tagDetailNoTransactionsHint => '使用此标签的交易将在此显示';

  @override
  String get tagNotFound => '标签不存在';

  @override
  String get tagDefaultMeituan => '美团';

  @override
  String get tagDefaultEleme => '饿了么';

  @override
  String get tagDefaultTaobao => '淘宝';

  @override
  String get tagDefaultJD => '京东';

  @override
  String get tagDefaultPDD => '拼多多';

  @override
  String get tagDefaultStarbucks => '星巴克';

  @override
  String get tagDefaultLuckin => '瑞幸咖啡';

  @override
  String get tagDefaultMcDonalds => '麦当劳';

  @override
  String get tagDefaultKFC => '肯德基';

  @override
  String get tagDefaultHema => '盒马';

  @override
  String get tagDefaultSams => '山姆';

  @override
  String get tagDefaultCostco => 'Costco';

  @override
  String get tagDefaultBusinessTrip => '出差';

  @override
  String get tagDefaultTravel => '旅行';

  @override
  String get tagDefaultDining => '聚餐';

  @override
  String get tagDefaultOnlineShopping => '网购';

  @override
  String get tagDefaultDaily => '日常';

  @override
  String get tagDefaultReimbursement => '报销';

  @override
  String get tagDefaultRefundable => '可退款';

  @override
  String get tagDefaultRefunded => '已退款';

  @override
  String get tagDefaultVoiceBilling => '语音记账';

  @override
  String get tagDefaultImageBilling => '图片记账';

  @override
  String get tagDefaultCameraBilling => '拍照记账';

  @override
  String get tagDefaultAiBilling => 'AI记账';

  @override
  String get tagDefaultSmsBilling => '短信';

  @override
  String get tagDefaultNotificationBilling => '通知';

  @override
  String get tagDefaultScreenBilling => '屏幕';

  @override
  String get tagShare => '分享标签';

  @override
  String get tagImport => '导入标签';

  @override
  String get tagClearUnused => '清理未使用';

  @override
  String tagShareSuccess(String path) {
    return '已保存到 $path';
  }

  @override
  String get tagShareSubject => '智记 标签配置';

  @override
  String get tagShareFailed => '分享失败';

  @override
  String get tagImportInvalidFile => '请选择 YAML 配置文件';

  @override
  String get tagImportNoTags => '文件中没有标签数据';

  @override
  String get tagImportModeTitle => '选择导入模式';

  @override
  String get tagImportModeMerge => '合并';

  @override
  String get tagImportModeMergeDesc => '保留现有标签，新增不存在的';

  @override
  String get tagImportModeOverwrite => '覆盖';

  @override
  String get tagImportModeOverwriteDesc => '清空未使用标签后导入';

  @override
  String get tagImportSuccess => '导入成功';

  @override
  String get tagImportFailed => '导入失败';

  @override
  String get tagClearUnusedEmpty => '没有未使用的标签';

  @override
  String get tagClearUnusedTitle => '清理未使用标签';

  @override
  String tagClearUnusedMessage(int count) {
    return '确定要删除 $count 个未使用的标签吗？';
  }

  @override
  String tagClearUnusedSuccess(int count) {
    return '已删除 $count 个标签';
  }

  @override
  String get tagClearUnusedFailed => '清理失败';

  @override
  String get homeSwitchLedger => '选择账本';

  @override
  String get homeManageLedgers => '管理账本';

  @override
  String get budgetTitle => '预算管理';

  @override
  String get budgetShowOnHome => '在首页显示预算';

  @override
  String get budgetEmptyHint => '还没有设置预算';

  @override
  String get budgetAddTotal => '添加总预算';

  @override
  String get budgetMonthlyBudget => '本月预算';

  @override
  String get budgetUsed => '已用';

  @override
  String get budgetRemaining => '剩余';

  @override
  String budgetDaysRemaining(int days) {
    return '剩余 $days 天';
  }

  @override
  String budgetDailyAvailable(String amount) {
    return '日均可用 $amount';
  }

  @override
  String get budgetCategoryBudgets => '分类预算';

  @override
  String get budgetEditTitle => '编辑预算';

  @override
  String get budgetAddTitle => '添加预算';

  @override
  String get budgetTypeTotalLabel => '总预算';

  @override
  String get budgetTypeCategoryLabel => '分类预算';

  @override
  String get budgetAmountLabel => '预算金额';

  @override
  String get budgetAmountHint => '请输入预算金额';

  @override
  String get budgetCategoryLabel => '选择分类';

  @override
  String get budgetCategoryHint => '请选择预算分类';

  @override
  String get budgetStartDayLabel => '起始日';

  @override
  String get budgetPeriodLabel => '周期';

  @override
  String get budgetSaveSuccess => '预算保存成功';

  @override
  String get budgetDeleteConfirm => '确定删除此预算？';

  @override
  String get budgetDeleteSuccess => '预算已删除';

  @override
  String get attachmentAdd => '添加图片';

  @override
  String get attachmentTakePhoto => '拍照';

  @override
  String get attachmentChooseFromGallery => '从相册选择';

  @override
  String get attachmentMaxReached => '已达到最大附件数量';

  @override
  String get attachmentDeleteConfirm => '确定删除此附件？';

  @override
  String attachmentCount(int count) {
    return '$count张图片';
  }

  @override
  String get commonDeleted => '已删除';

  @override
  String get attachmentExportTitle => '导出附件';

  @override
  String get attachmentExportSubtitle => '将所有附件打包导出为压缩文件';

  @override
  String get attachmentImportTitle => '导入附件';

  @override
  String get attachmentImportSubtitle => '从压缩文件导入附件';

  @override
  String get attachmentExportEmpty => '没有附件需要导出';

  @override
  String attachmentExportProgress(int current, int total) {
    return '正在导出附件 ($current/$total)';
  }

  @override
  String attachmentExportProgressDetail(int attachmentCount, int iconCount, int current, int total) {
    return '正在导出 $attachmentCount 个附件 + $iconCount 个图标 ($current/$total)';
  }

  @override
  String get attachmentExportSuccess => '附件导出成功';

  @override
  String attachmentExportSavedTo(String path) {
    return '已保存到: $path';
  }

  @override
  String get attachmentImportConflictStrategy => '冲突处理策略';

  @override
  String get attachmentImportConflictSkip => '跳过已存在的附件';

  @override
  String get attachmentImportConflictOverwrite => '覆盖已存在的附件';

  @override
  String attachmentImportProgress(int current, int total) {
    return '正在导入附件 ($current/$total)';
  }

  @override
  String attachmentImportResult(int imported, int skipped, int overwritten, int failed) {
    return '导入 $imported 张，跳过 $skipped 张，覆盖 $overwritten 张，失败 $failed 张';
  }

  @override
  String get attachmentImportFailed => '附件导入失败';

  @override
  String attachmentArchiveInfo(int count, String date) {
    return '$count 个附件，导出于 $date';
  }

  @override
  String get attachmentStartImport => '开始导入';

  @override
  String get attachmentPreview => '预览附件';

  @override
  String attachmentPreviewSubtitle(int count) {
    return '共 $count 张图片';
  }

  @override
  String get attachmentPreviewEmpty => '暂无附件';

  @override
  String get attachmentExportPreviewTitle => '导出预览';

  @override
  String get attachmentImportPreviewTitle => '导入预览';

  @override
  String get shortcutsGuide => '快捷指令';

  @override
  String get shortcutsGuideDesc => '快速打开语音、拍照等记账方式';

  @override
  String get shortcutsIntroTitle => '快速记账';

  @override
  String get shortcutsIntroDesc => '使用快捷指令，可以在桌面直接打开语音记账、拍照记账等功能，无需先打开 App。';

  @override
  String get availableShortcuts => '可用快捷指令';

  @override
  String get shortcutVoice => '语音记账';

  @override
  String get shortcutVoiceDesc => '通过语音快速记录账单';

  @override
  String get shortcutImage => '图片记账';

  @override
  String get shortcutImageDesc => '从相册选择图片识别账单';

  @override
  String get shortcutCamera => '拍照记账';

  @override
  String get shortcutCameraDesc => '拍照识别账单';

  @override
  String get shortcutNewExpense => '快捷记支出';

  @override
  String get shortcutNewExpenseDesc => '直接打开支出记账页面';

  @override
  String get shortcutNewIncome => '快捷记收入';

  @override
  String get shortcutNewIncomeDesc => '直接打开收入记账页面';

  @override
  String get shortcutNewTransfer => '快捷记转账';

  @override
  String get shortcutNewTransferDesc => '直接打开转账记账页面';

  @override
  String get shortcutUrlCopied => '链接已复制到剪贴板';

  @override
  String get howToAddShortcut => '如何添加快捷指令';

  @override
  String get iosShortcutStep1 => '打开「快捷指令」App';

  @override
  String get iosShortcutStep2 => '点击右上角「+」新建快捷指令';

  @override
  String get iosShortcutStep3 => '添加「打开 URL」操作';

  @override
  String get iosShortcutStep4 => '粘贴上方复制的链接（如 smartbook://voice）';

  @override
  String get iosShortcutStep5 => '保存后，可添加到桌面使用';

  @override
  String get androidShortcutStep1 => '下载支持创建快捷方式的应用（如 Shortcut Maker）';

  @override
  String get androidShortcutStep2 => '选择「URL 快捷方式」';

  @override
  String get androidShortcutStep3 => '粘贴上方复制的链接（如 smartbook://voice）';

  @override
  String get androidShortcutStep4 => '设置图标和名称后添加到桌面';

  @override
  String get shortcutsTip => '小贴士';

  @override
  String get shortcutsTipDesc => '快捷指令需要配合 AI 功能使用。请确保已开启智能识别并配置好 API Key。';

  @override
  String get shortcutOpenShortcutsApp => '打开快捷指令 App';

  @override
  String get shortcutAutoAdd => '自动记账接口';

  @override
  String get shortcutAutoAddDesc => '通过 URL 参数自动创建账单，适合与快捷指令、自动化工具配合使用。';

  @override
  String get shortcutAutoAddExample => '示例链接：';

  @override
  String get shortcutAutoAddParams => '支持的参数：';

  @override
  String get shortcutParamAmount => '金额（必填）';

  @override
  String get shortcutParamType => '类型：expense（支出）/ income（收入）/ transfer（转账）';

  @override
  String get shortcutParamCategory => '分类名称（需与App中已有分类匹配）';

  @override
  String get shortcutParamNote => '备注';

  @override
  String get shortcutParamAccount => '账户名称（需与App中已有账户匹配）';

  @override
  String get shortcutParamTags => '标签（多个用逗号分隔）';

  @override
  String get shortcutParamDate => '日期（ISO格式，如 2024-01-15）';

  @override
  String get quickActionImage => '图片记账';

  @override
  String get quickActionCamera => '拍照记账';

  @override
  String get quickActionVoice => '语音记账';

  @override
  String get quickActionAiChat => 'AI 小助手';

  @override
  String get calendarTitle => '日历';

  @override
  String get calendarToday => '今天';

  @override
  String get calendarNoTransactions => '当天无交易';

  @override
  String get calendarAddTransaction => '在该日记账';

  @override
  String get calendarAddTransactionTooltip => '添加该日记账';

  @override
  String get commonUncategorized => '未分类';

  @override
  String get commonSaved => '已保存';

  @override
  String get aiProviderManageTitle => '服务商管理';

  @override
  String get aiProviderManageSubtitle => '管理AI服务商配置';

  @override
  String get aiProviderAdd => '添加服务商';

  @override
  String get aiProviderBuiltIn => '内置';

  @override
  String get aiProviderEmpty => '暂无服务商配置';

  @override
  String get aiProviderNoApiKey => '未配置 API Key';

  @override
  String get aiProviderApiKeyKeepHint => '留空保持现有 Key 不变';

  @override
  String get automationDraftsDiscarded => '草稿已丢弃';

  @override
  String get automationDraftsImageGone => '原图已被系统清理，无法重试';

  @override
  String get automationDraftsRetryQueued => '已重新提交识别';

  @override
  String get automationDraftsDiscard => '丢弃草稿';

  @override
  String get automationDraftsRetry => '重试识别';

  @override
  String get automationDraftsEmpty => '暂无离线识别草稿';

  @override
  String get automationDraftsTitle => '草稿';

  @override
  String get aiProviderTapToEdit => '点击编辑';

  @override
  String get aiProviderDeleteTitle => '删除服务商';

  @override
  String aiProviderDeleteConfirm(String name) {
    return '确定删除服务商「$name」吗？使用该服务商的能力将自动切换到默认服务商。';
  }

  @override
  String get aiProviderDeleted => '服务商已删除';

  @override
  String get aiProviderEditTitle => '编辑服务商';

  @override
  String get aiProviderAddTitle => '添加服务商';

  @override
  String get aiProviderBasicInfo => '基本信息';

  @override
  String get aiProviderName => '服务商名称';

  @override
  String get aiProviderProtocol => '接口协议';

  @override
  String get aiProviderProtocolHint => 'Anthropic 协议不支持语音转文字';

  @override
  String get aiProviderNameHint => '如：硅基流动、DeepSeek';

  @override
  String get aiProviderNameRequired => '请输入服务商名称';

  @override
  String get aiProviderBaseUrlRequired => '请输入 Base URL';

  @override
  String get aiProviderModels => '模型配置';

  @override
  String get aiProviderModelsHint => '留空的能力将无法使用该服务商';

  @override
  String get aiCapabilityText => '文本';

  @override
  String get aiCapabilityVision => '视觉';

  @override
  String get aiCapabilitySpeech => '语音';

  @override
  String get aiCapabilitySelectTitle => '能力绑定';

  @override
  String get aiCapabilitySelectSubtitle => '为每个AI能力选择服务商';

  @override
  String get aiCapabilityTextChat => '文本对话';

  @override
  String get aiCapabilityTextChatDesc => '用于AI对话和文本账单提取';

  @override
  String get aiCapabilityImageUnderstand => '图片理解';

  @override
  String get aiCapabilityImageUnderstandDesc => '用于图片账单识别';

  @override
  String get aiCapabilitySpeechToText => '语音转文字';

  @override
  String get aiCapabilitySpeechToTextDesc => '用于语音记账';

  @override
  String get aiProviderTestRun => '点击测试';

  @override
  String get aiProviderTestRunning => '测试中...';

  @override
  String get aiProviderTestSuccess => '测试通过';

  @override
  String get aiProviderTestFailed => '测试失败';

  @override
  String get aiProviderTestAll => '一键测试全部';

  @override
  String get aiProviderTestAllRetry => '重新测试';

  @override
  String get aiModelInputHelper => '留空则使用默认模型';

  @override
  String get syncPreviewTitle => '同步预览';

  @override
  String get syncPreviewSelectAll => '全选';

  @override
  String get syncPreviewDeselectAll => '取消全选';

  @override
  String get syncPreviewAdded => '新增';

  @override
  String get syncPreviewModified => '修改';

  @override
  String get syncPreviewDeleted => '删除';

  @override
  String syncPreviewAddedCount(int count) {
    return '新增 $count 条';
  }

  @override
  String syncPreviewModifiedCount(int count) {
    return '修改 $count 条';
  }

  @override
  String syncPreviewDeletedCount(int count) {
    return '删除 $count 条';
  }

  @override
  String syncPreviewApply(int count) {
    return '应用 $count 项';
  }

  @override
  String get syncPreviewEmpty => '云端数据与本地一致，无需同步';

  @override
  String get syncPreviewOldFormat => '云端数据格式较旧，将执行全量替换';

  @override
  String get syncPreviewOldFormatMessage => '云端数据不包含同步标识，无法逐条对比。将清空当前账本数据并从云端重新导入。';

  @override
  String syncPreviewApplied(int count) {
    return '已应用 $count 项变更';
  }

  @override
  String get cloudSyncGuideTitle => '云同步使用指南';

  @override
  String get cloudSyncGuideGotIt => '我知道了';

  @override
  String get cloudSyncGuideHowItWorks => '工作原理';

  @override
  String get cloudSyncGuideHowItem1 => '上传：将当前账本的全部数据打包上传到云端，覆盖云端旧数据';

  @override
  String get cloudSyncGuideHowItem2 => '下载：从云端拉取数据，与本地逐条对比差异，你可以选择要同步哪些变更';

  @override
  String get cloudSyncGuideHowItem3 => '云端始终只保存最后一次上传的完整快照，不保留历史版本';

  @override
  String get cloudSyncGuideCorrect => '正确的使用方式';

  @override
  String get cloudSyncGuideCorrectItem1 => '同一时间只在一台设备上记账，完成后上传';

  @override
  String get cloudSyncGuideCorrectItem2 => '切换设备前，先在新设备上下载同步';

  @override
  String get cloudSyncGuideCorrectItem3 => '下载时仔细查看预览，确认每条变更再应用';

  @override
  String get cloudSyncGuideCorrectItem4 => '养成「编辑→上传→切换设备→下载→编辑」的习惯';

  @override
  String get cloudSyncGuideWrong => '应避免的用法';

  @override
  String get cloudSyncGuideWrongItem1 => '两台设备同时编辑同一个账本，后上传的会覆盖先上传的改动';

  @override
  String get cloudSyncGuideWrongItem2 => '上传后立刻在另一台设备下载，文件服务可能有几秒到几分钟的同步延迟，等一会再试';

  @override
  String get cloudSyncGuideWrongItem3 => '长时间不同步后一次性下载大量变更，容易遗漏需要处理的差异';

  @override
  String get cloudSyncGuideLimitations => '已知限制';

  @override
  String get cloudSyncGuideLimitItem1 => '非实时同步：需要手动点击上传和下载';

  @override
  String get cloudSyncGuideLimitItem2 => '无冲突合并：不会自动合并两端的修改，以最后上传的为准';

  @override
  String get cloudSyncGuideLimitItem3 => '文件服务延迟：上传后云端文件可能需要几秒到几分钟才能被其他设备读取，取决于你使用的云服务';

  @override
  String get cloudSyncGuideLimitItem4 => '不含附件：交易的图片附件不参与同步，需通过数据管理单独导出';

  @override
  String get mineMultiDeviceSyncTitle => '多设备同步';

  @override
  String get mineMultiDeviceSyncSubtitle => '进入页面时自动检查云端变更';

  @override
  String get appLockTitle => '应用锁';

  @override
  String get appLockDesc => 'PIN码与生物识别保护隐私';

  @override
  String get appLockEnable => '启用应用锁';

  @override
  String get appLockEnableDesc => '启动和切回应用时需要验证身份';

  @override
  String get appLockSetPin => '设置密码';

  @override
  String get appLockChangePin => '修改密码';

  @override
  String get appLockVerifyPin => '验证密码';

  @override
  String get appLockVerifyCurrentPin => '请输入当前密码';

  @override
  String get appLockSetNewPin => '请设置新密码';

  @override
  String get appLockConfirmPin => '请再次输入密码';

  @override
  String get appLockEnterPin => '请输入密码';

  @override
  String get appLockPinSetSuccess => '密码设置成功';

  @override
  String get appLockDisabled => '应用锁已关闭';

  @override
  String get appLockBiometric => '生物识别解锁';

  @override
  String get appLockBiometricDesc => '使用Face ID或指纹快速解锁';

  @override
  String get appLockBiometricReason => '请验证身份以解锁智记';

  @override
  String get appLockTimeout => '自动锁定时间';

  @override
  String get appLockTimeoutImmediate => '立即';

  @override
  String get appLockTimeout1Min => '1分钟后';

  @override
  String get appLockTimeout5Min => '5分钟后';

  @override
  String get appLockTimeout15Min => '15分钟后';

  @override
  String get creditCardSettings => '信用卡设置';

  @override
  String get accountTabValuation => '估值账户';

  @override
  String get creditCardDaysRequired => '请选择账单日和还款日';

  @override
  String get creditLimit => '信用额度';

  @override
  String get creditLimitHint => '请输入信用额度';

  @override
  String get billingDay => '账单日';

  @override
  String get paymentDueDay => '还款日';

  @override
  String get creditUsed => '已用额度';

  @override
  String get creditAvailable => '可用额度';

  @override
  String get creditCardOwed => '待还款';

  @override
  String dayOfMonth(int day) {
    return '每月$day日';
  }

  @override
  String get creditCardReminderTitle => '还款提醒';

  @override
  String get creditCardReminderDesc => '在还款日前提醒还款';

  @override
  String creditCardReminderDaysBefore(int days) {
    return '提前$days天提醒';
  }

  @override
  String get creditCardInitialBalanceHint => '当前欠款（填负数）';

  @override
  String get selectDay => '选择日期';

  @override
  String get accountBankName => '开户行';

  @override
  String get accountBankNameHint => '例如：工商银行';

  @override
  String get accountCardLastFour => '卡号后四位';

  @override
  String get accountCardLastFourHint => '例如：1234';

  @override
  String get accountNote => '备注';

  @override
  String get accountNoteHint => '添加备注信息';

  @override
  String get accountMetaInfo => '账户信息';

  @override
  String get accountBalanceTrend => '余额趋势';

  @override
  String get accountCategoryBreakdown => '分类统计';

  @override
  String get accountCategoryExpense => '支出';

  @override
  String get accountCategoryIncome => '收入';

  @override
  String get accountNoMoreData => '没有更多数据了';

  @override
  String get totalAssets => '总资产';

  @override
  String get totalLiabilities => '总负债';

  @override
  String get assetAccounts => '资产账户';

  @override
  String get liabilityAccounts => '负债账户';

  @override
  String get assetComposition => '资产构成';

  @override
  String get accountTypeInvestment => '投资理财';

  @override
  String get accountTypeLoan => '贷款';

  @override
  String get accountTypeReceivable => '应收款';

  @override
  String get accountTypeRealEstate => '不动产';

  @override
  String get accountTypeVehicle => '车辆';

  @override
  String get accountTypeInsurance => '保险';

  @override
  String get accountTypeSocialFund => '公积金/社保';

  @override
  String get valuationCurrentValue => '当前估值';

  @override
  String get valuationCurrentDebt => '当前欠款';

  @override
  String get valuationUpdateValue => '更新估值';

  @override
  String get valuationUpdateDebt => '更新欠款';

  @override
  String valuationLastUpdated(String date) {
    return '上次更新: $date';
  }

  @override
  String get valuationAccountHint => '请输入当前估值';

  @override
  String get valuationDebtHint => '请输入当前欠款金额';

  @override
  String get accountGroupTradable => '日常账户';

  @override
  String get accountGroupValuation => '资产/负债';

  @override
  String get adjustmentTransaction => '估值调整';

  @override
  String creditCardBillingInfo(int billingDay, int paymentDueDay) {
    return '每月$billingDay日出账 · $paymentDueDay日还款';
  }

  @override
  String creditCardDaysUntilPayment(int days) {
    return '距还款日还有$days天';
  }

  @override
  String get creditCardPaymentDueToday => '今天是还款日';

  @override
  String get creditCardQuickRepay => '记一笔还款';

  @override
  String get budgetManagement => '预算管理';

  @override
  String get budgetManagementDesc => '设置月度预算，控制支出';

  @override
  String get budgetSetupHint => '设置预算，轻松掌控每月开支';

  @override
  String get budgetSetupAction => '去设置';

  @override
  String get cloudCollabDevicesPageTitle => '设备会话';

  @override
  String get cloudCollabDevicesPageSubtitle => '管理当前账号活跃设备';

  @override
  String get cloudCollabDevicesViewAllSessions => '显示全部会话';

  @override
  String get cloudCollabDevicesViewModeHint => '默认展示近 30 天去重设备，可切换查看全部会话。';

  @override
  String get cloudCollabNoDevices => '当前没有活跃设备';

  @override
  String get cloudCollabUnknownDeviceName => '未知设备';

  @override
  String get cloudCollabDeviceCurrentTag => '当前设备';

  @override
  String get cloudCollabCurrentDeviceCannotRevoke => '当前设备不能远程下线。';

  @override
  String cloudCollabDeviceAppVersion(String version) {
    return '应用：$version';
  }

  @override
  String cloudCollabDeviceOsVersion(String version) {
    return '系统：$version';
  }

  @override
  String cloudCollabDeviceModel(String model) {
    return '型号：$model';
  }

  @override
  String cloudCollabDeviceLastIp(String ip) {
    return 'IP：$ip';
  }

  @override
  String cloudCollabDeviceSessionCount(String count) {
    return '会话数：$count';
  }

  @override
  String cloudCollabDeviceLastSeen(String time) {
    return '最近活跃：$time';
  }

  @override
  String cloudCollabDeviceCreatedAt(String time) {
    return '创建时间：$time';
  }

  @override
  String get cloudCollabDeviceRevokeTitle => '远程下线设备';

  @override
  String cloudCollabDeviceRevokeMessage(String name, String id) {
    return '确认下线设备 $name（$id）吗？';
  }

  @override
  String cloudCollabDeviceRevokeMultipleMessage(String name, String count) {
    return '确认下线设备 $name 的 $count 个会话吗？';
  }

  @override
  String get cloudCollabDeviceRevoked => '设备已下线';

  @override
  String get cloudCollabUnavailableMessage => '云同步功能暂不可用。';

  @override
  String get cloudCollabScopeDeniedHint => '服务端尚未开启 ALLOW_APP_RW_SCOPES，当前设备会话不可用。';

  @override
  String get cloudCollabScopeDeniedAction => '请在服务端 .env 或部署环境中设置 ALLOW_APP_RW_SCOPES=true，重启服务后重新登录 App。';

  @override
  String get syncHealthTitle => '同步状态';

  @override
  String get cloudSyncHelpTitle => '同步说明 · 为什么有时同步不动？';

  @override
  String get cloudSyncHelpModesTitle => '三种同步方式';

  @override
  String get cloudSyncHelpModesBody => '• 增量同步（日常自动）：记一笔 / 改一笔后，只把这条变化自动上传下载，快、无需手动操作 —— 平时一直在跑的就是它。\n• 全量上传：首次开启云同步、或云端还没有这个账本的数据时，把本地全部数据一次性推上云。\n• 全量下载：换新设备、重装、或本地为空时，从云端把全部数据拉下来。';

  @override
  String get cloudSyncHelpWhenFullTitle => '什么时候才会走全量？';

  @override
  String get cloudSyncHelpWhenFullBody => '全量只在某一端数据为空时才会自动触发（首次开启云同步 / 换新设备 / 重装 / 清空了本地或云端数据）。只要两端都有数据，之后一直走增量，不会无故重来。想强制重新全量同步，得先清空对应端的数据。';

  @override
  String get cloudSyncHelpStuckTitle => '为什么有时同步不动 / 卡住';

  @override
  String get cloudSyncHelpStuckBody => '• 全量上传 / 下载不支持断点续传：中途断网、或 App 被切到后台被系统杀掉，会从头重来，不会接着传。数据多时请用稳定网络（建议 Wi-Fi）耐心等它跑完，别中途切走。\n• 增量同步是断点安全的，日常同步不受影响。';

  @override
  String get cloudSyncHelpTroubleshootTitle => '排查办法';

  @override
  String get cloudSyncHelpTroubleshootBody => '• 先在本页下拉做一次「深度检测」，对比本地与云端差异。\n• 仍有问题，去「日志中心」查看同步日志（含失败原因），方便反馈。';

  @override
  String get cloudSyncHelpOpenLogCenter => '打开日志中心';

  @override
  String syncHealthCheckFailed(String msg) {
    return '检测失败：$msg';
  }

  @override
  String get syncHealthHasDiff => '检测到差异，已自动同步';

  @override
  String get syncHealthInSync => '本地与云端一致';

  @override
  String get syncHealthGroupCurrentLedger => '当前账本';

  @override
  String get syncHealthGroupAll => '全部账本';

  @override
  String get syncHealthRowTx => '交易';

  @override
  String get syncHealthRowAttachment => '附件';

  @override
  String get syncHealthRowCategoryIcon => '分类图标';

  @override
  String get syncHealthRowBudget => '预算';

  @override
  String get syncHealthRowAccount => '账户';

  @override
  String get syncHealthRowCategory => '分类';

  @override
  String get syncHealthRowTag => '标签';

  @override
  String get syncHealthRowUnpushed => '未推送变更';

  @override
  String syncHealthValue(int local, int remote) {
    return '本地 $local · 云端 $remote';
  }

  @override
  String syncHealthValueRemoteMissing(int local) {
    return '本地 $local · 云端 —';
  }

  @override
  String get syncForceRestoreTitle => '以服务端为准';

  @override
  String get syncForceRestoreConfirmTitle => '以服务端为准恢复？';

  @override
  String get syncForceRestoreConfirmBody => '将清空当前账本的本地交易与预算，并用服务端数据覆盖账户、分类与标签（本地多出的条目会被删除，且影响所有账本共用的数据）。此操作不可撤销。';

  @override
  String syncForceRestoreSuccess(int tx, int budget, int accounts, int categories, int tags) {
    return '已按服务端恢复：交易 $tx 笔、预算 $budget 笔、账户 $accounts 个、分类 $categories 个、标签 $tags 个';
  }

  @override
  String get syncForceRestoreFailed => '恢复失败';

  @override
  String get sharedRoleOwner => '所有者';

  @override
  String get sharedRoleEditor => '编辑者';

  @override
  String get sharedRoleViewer => '查看者';

  @override
  String get commonCopied => '已复制';

  @override
  String get commonRemove => '移除';

  @override
  String get sharedJoinPageTitle => '加入共享账本';

  @override
  String get sharedJoinPageSubtitle => '输入邀请码或点击对方分享的链接';

  @override
  String get sharedJoinEnterCode => '输入邀请码';

  @override
  String get sharedJoinEnterCodeHint => '邀请码 6 位,全大写字母数字。也可直接点击邀请方分享的短链跳过此步。';

  @override
  String get sharedJoinPreviewButton => '验证邀请码';

  @override
  String get sharedJoinAcceptButton => '加入账本';

  @override
  String sharedJoinInvitedBy(String name) {
    return '$name 邀请你加入';
  }

  @override
  String sharedJoinRoleLine(String role) {
    return '角色:$role';
  }

  @override
  String sharedJoinExpiresInMinutes(int n) {
    return '有效期还剩 $n 分钟';
  }

  @override
  String sharedJoinExpiresInHours(int n) {
    return '有效期还剩 $n 小时';
  }

  @override
  String sharedJoinExpiresInDays(int n) {
    return '有效期还剩 $n 天';
  }

  @override
  String sharedJoinSuccess(String name) {
    return '已加入「$name」';
  }

  @override
  String get sharedJoinCodeFormatError => '邀请码格式不对,请输入 6 位字母数字';

  @override
  String get sharedJoinInvalidOrExpired => '邀请码无效或已过期,请向邀请人索取新码';

  @override
  String get sharedJoinAlreadyMember => '你已经是该账本成员';

  @override
  String get sharedJoinMemberLimit => '该账本成员已满,请联系账本所有者';

  @override
  String get sharedInvitePageTitle => '邀请新成员';

  @override
  String get sharedInviteFormRole => '角色';

  @override
  String get sharedInviteFormExpiry => '有效期';

  @override
  String sharedInviteExpiryHours(int n) {
    return '$n 小时';
  }

  @override
  String sharedInviteExpiryDays(int n) {
    return '$n 天';
  }

  @override
  String get sharedInviteGenerate => '生成邀请码';

  @override
  String get sharedInviteGenerateAnother => '生成另一个邀请码';

  @override
  String get sharedInviteCopyCode => '复制邀请码';

  @override
  String get sharedInviteCopyLink => '复制链接';

  @override
  String get sharedInviteShareLink => '分享给好友';

  @override
  String sharedInviteExpiresAt(String dt) {
    return '邀请将在 $dt 失效';
  }

  @override
  String get sharedInviteWarning => '⚠️ 不要把邀请码发到公开群 / 朋友圈。拿到码的任何人都可加入账本;泄露后请到成员管理页撤销并重新生成。';

  @override
  String get sharedInviteInstruction => '把邀请码或短链发给对方。对方装上智记 后,点击链接或在「我的 → 加入共享账本」输入码即可加入。';

  @override
  String sharedInviteShareText(String ledger, String code, String url) {
    return '邀请你加入智记 共享账本「$ledger」\n\n邀请码:$code\n链接:$url\n\n点击链接或在智记 → 我的 → 加入共享账本输入此码即可。';
  }

  @override
  String get sharedMembersPageTitle => '成员管理';

  @override
  String get sharedMembersYou => '你';

  @override
  String get sharedMembersInviteCta => '邀请新成员';

  @override
  String get sharedMembersLeaveCta => '退出账本';

  @override
  String get sharedMembersLeaveTitle => '退出账本';

  @override
  String sharedMembersLeaveConfirm(String name) {
    return '退出「$name」后将无法再访问其中的交易。确定继续吗?';
  }

  @override
  String get sharedMembersLeaveDone => '已退出账本';

  @override
  String get sharedMembersRemoveTitle => '移除成员';

  @override
  String get sharedMembersRemoveCta => '移除该成员';

  @override
  String sharedMembersRemoveConfirm(String name) {
    return '确定移除 $name?ta 将立即失去对该账本的访问。';
  }

  @override
  String get sharedMembersRemoved => '已移除成员';

  @override
  String get sharedMembersTransferTitle => '转让所有权';

  @override
  String get sharedMembersTransferTo => '转让给该成员';

  @override
  String sharedMembersTransferConfirm(String name) {
    return '把账本所有权转给 $name?你将变为编辑者,无法再邀请人 / 改账本名 / 删账本。';
  }

  @override
  String get sharedMembersTransferConfirmCta => '确认转让';

  @override
  String get sharedMembersTransferDone => '已转让所有权';

  @override
  String sharedTxRecordedBy(String name) {
    return '$name 记的';
  }

  @override
  String sharedTxCreatedBy(String name) {
    return '$name 创建';
  }

  @override
  String sharedTxEditedBy(String name) {
    return '$name 最后编辑';
  }

  @override
  String sharedTxCreatedAndEditedBy(String name) {
    return '$name 创建并编辑';
  }

  @override
  String get sharedRequiresCloudSync => '请先启用云同步';

  @override
  String get sharedMembersStatsTitle => '成员收支';

  @override
  String get sharedMembersStatsEmpty => '本期暂无记账';

  @override
  String get sharedMembersStatsLoading => '加载中…';

  @override
  String get sharedMembersStatsIncome => '总收入';

  @override
  String get sharedMembersStatsExpense => '总支出';

  @override
  String sharedMembersStatsTxCount(int count) {
    return '$count笔';
  }

  @override
  String get maintenanceOrphanCleanupTitle => '数据清理';

  @override
  String get maintenanceOrphanCleanupSubtitle => '检查并清理本地孤儿数据';

  @override
  String get maintenanceOrphanRescan => '重新扫描';

  @override
  String get maintenanceOrphanEmpty => '本地数据干净,未发现孤儿数据';

  @override
  String get maintenanceOrphanGroupDb => '数据库孤儿';

  @override
  String get maintenanceOrphanGroupFile => '磁盘文件孤儿';

  @override
  String get maintenanceOrphanGroupSync => '同步状态孤儿';

  @override
  String maintenanceOrphanSummary(int count) {
    return '发现 $count 项异常';
  }

  @override
  String maintenanceOrphanSummarySize(String size) {
    return '可释放空间约 $size';
  }

  @override
  String get maintenanceOrphanSelectAll => '全选';

  @override
  String get maintenanceOrphanDeselectAll => '取消全选';

  @override
  String get maintenanceOrphanDeleteOne => '删除此项';

  @override
  String maintenanceOrphanSelectedHint(int count) {
    return '已选 $count 项';
  }

  @override
  String get maintenanceOrphanCleanSelected => '清理已选';

  @override
  String get maintenanceOrphanConfirmTitle => '确认清理';

  @override
  String maintenanceOrphanConfirmDeleteOne(String title) {
    return '确定清理「$title」吗？操作不可撤销。';
  }

  @override
  String maintenanceOrphanConfirmDeleteBatch(int count) {
    return '确定清理选中的 $count 项吗？操作不可撤销。';
  }

  @override
  String maintenanceOrphanCleanSuccess(int count) {
    return '已清理 $count 项';
  }

  @override
  String maintenanceOrphanCleanPartial(int ok, int fail) {
    return '成功 $ok 项,失败 $fail 项';
  }

  @override
  String get syncProgressTitle => '正在同步';

  @override
  String syncProgressCount(int applied, int total) {
    return '$applied / $total 条';
  }

  @override
  String get exchangeRatePageTitle => '汇率管理';

  @override
  String get exchangeRateEntrySubtitle => '自动获取汇率，支持手动修正';

  @override
  String get baseCurrencyLabel => '主币种';

  @override
  String get rateSourceAuto => '自动';

  @override
  String get rateSourceManual => '手动';

  @override
  String rateUpdatedAt(Object date) {
    return '$date 更新';
  }

  @override
  String get rateNotFetched => '未获取';

  @override
  String get rateTapToSet => '点击手动设置';

  @override
  String get rateEditTitle => '编辑汇率';

  @override
  String rateInverseHint(Object base, Object quote, Object rate) {
    return '反向参考:1 $base ≈ $rate $quote';
  }

  @override
  String get rateResetToAuto => '恢复自动';

  @override
  String get rateRefreshSuccess => '汇率已更新';

  @override
  String get rateRefreshFailed => '获取失败,可手动设置汇率';

  @override
  String get ratesEmptyHint => '给账户设置不同币种后,这里会出现可管理的汇率';

  @override
  String get rateDisclaimer => '数据来源:开源汇率数据,每日更新;折算仅供参考,可能与银行实际牌价有差异。';

  @override
  String convertedNetWorth(Object currency) {
    return '净资产(折$currency)';
  }

  @override
  String convertedFootnote(Object date) {
    return '按 $date 汇率折算,点击管理汇率';
  }

  @override
  String convertedPartialWarning(Object currencies) {
    return '$currencies 未折算,点击设置汇率';
  }

  @override
  String get unconvertedBadge => '未折算';

  @override
  String get commonDetail => '详情';

  @override
  String get conversionDetailTitle => '折算详情';

  @override
  String get assetConversionToggle => '按主币种折算';

  @override
  String rateManualApplied(Object count) {
    return '已应用 $count 条手动汇率';
  }

  @override
  String get netWorthTrendTitle => '净值趋势';

  @override
  String get netWorthTrend3M => '3个月';

  @override
  String get netWorthTrend6M => '6个月';

  @override
  String get netWorthTrend12M => '12个月';

  @override
  String get netWorthTrendAll => '全部';

  @override
  String get netWorthTrendLineNet => '净资产';

  @override
  String get netWorthTrendLineAssets => '总资产';

  @override
  String get netWorthTrendLineLiabilities => '总负债';

  @override
  String get netWorthTrendMultiCurrencyNote => '历史净值为各币种原值相加,未折算';

  @override
  String get txFlagExcludeFromStats => '不计入收支';

  @override
  String get txFlagExcludeFromBudget => '不计入预算';

  @override
  String get txFlagMoreOptions => '更多选项';

  @override
  String get txFlagDialogTitle => '账单标记';

  @override
  String get txFlagExcludeFromStatsHint => '不计入收支统计,但仍计入账户余额';

  @override
  String get txFlagExcludeFromBudgetHint => '不占用预算额度';

  @override
  String get txFlagExcludedTag => '不计收支';

  @override
  String get txFlagBudgetExcludedTag => '不计预算';

  @override
  String get txCurrencyLabel => '币种';

  @override
  String get txRateLabel => '汇率';

  @override
  String txConvertedPreview(Object amount, Object currency) {
    return '≈ $amount $currency';
  }

  @override
  String get txRateMissingHint => '请手动填写本笔汇率后保存';

  @override
  String get txCrossCurrencyTransferBlocked => '暂不支持跨币种转账,请分别记两笔或使用同币种账户';

  @override
  String get ledgerBaseCurrencyLabel => '主币种';

  @override
  String statsConvertedFootnote(Object currency) {
    return '含外币,已按各笔记账时汇率折算为 $currency';
  }

  @override
  String get ledgerCurrencyChangeRecalcHint => '修改本位币将按当前汇率重算全部历史交易的折算值';

  @override
  String get recalcForeignTxBanner => '检测到该账本有未折算的外币交易';

  @override
  String get recalcForeignTxAction => '按当前汇率重算折算';

  @override
  String recalcForeignTxDone(Object count) {
    return '已重算 $count 笔外币交易的折算值';
  }

  @override
  String get txCurrencyPickerTitle => '选择币种';

  @override
  String recalcSyncCountHint(Object count) {
    return '将重算并同步 $count 笔交易';
  }

  @override
  String get exportCsvHeaderCurrency => '币种';

  @override
  String get importFieldCurrency => '币种';

  @override
  String get currencyMOP => '澳门元';

  @override
  String get currencyMNT => '蒙古图格里克';

  @override
  String get currencyKPW => '朝鲜元';

  @override
  String get currencyKHR => '柬埔寨瑞尔';

  @override
  String get currencyLAK => '老挝基普';

  @override
  String get currencyBND => '文莱元';

  @override
  String get currencyNPR => '尼泊尔卢比';

  @override
  String get currencyBTN => '不丹努尔特鲁姆';

  @override
  String get currencyMVR => '马尔代夫拉菲亚';

  @override
  String get currencyAFN => '阿富汗尼';

  @override
  String get currencyUZS => '乌兹别克斯坦索姆';

  @override
  String get currencyTJS => '塔吉克斯坦索莫尼';

  @override
  String get currencyTMT => '土库曼斯坦马纳特';

  @override
  String get currencyKGS => '吉尔吉斯斯坦索姆';

  @override
  String get currencyQAR => '卡塔尔里亚尔';

  @override
  String get currencyKWD => '科威特第纳尔';

  @override
  String get currencyBHD => '巴林第纳尔';

  @override
  String get currencyOMR => '阿曼里亚尔';

  @override
  String get currencyJOD => '约旦第纳尔';

  @override
  String get currencyLBP => '黎巴嫩镑';

  @override
  String get currencyIQD => '伊拉克第纳尔';

  @override
  String get currencyIRR => '伊朗里亚尔';

  @override
  String get currencyYER => '也门里亚尔';

  @override
  String get currencySYP => '叙利亚镑';

  @override
  String get currencyGEL => '格鲁吉亚拉里';

  @override
  String get currencyAMD => '亚美尼亚德拉姆';

  @override
  String get currencyAZN => '阿塞拜疆马纳特';

  @override
  String get currencyRON => '罗马尼亚列伊';

  @override
  String get currencyBGN => '保加利亚列弗';

  @override
  String get currencyRSD => '塞尔维亚第纳尔';

  @override
  String get currencyISK => '冰岛克朗';

  @override
  String get currencyMDL => '摩尔多瓦列伊';

  @override
  String get currencyALL => '阿尔巴尼亚列克';

  @override
  String get currencyMKD => '北马其顿第纳尔';

  @override
  String get currencyBAM => '波黑可兑换马克';

  @override
  String get currencyGIP => '直布罗陀镑';

  @override
  String get currencyGTQ => '危地马拉格查尔';

  @override
  String get currencyHNL => '洪都拉斯伦皮拉';

  @override
  String get currencyNIO => '尼加拉瓜科多巴';

  @override
  String get currencyCRC => '哥斯达黎加科朗';

  @override
  String get currencyPAB => '巴拿马巴波亚';

  @override
  String get currencyDOP => '多米尼加比索';

  @override
  String get currencyCUP => '古巴比索';

  @override
  String get currencyJMD => '牙买加元';

  @override
  String get currencyTTD => '特立尼达和多巴哥元';

  @override
  String get currencyBSD => '巴哈马元';

  @override
  String get currencyBBD => '巴巴多斯元';

  @override
  String get currencyBZD => '伯利兹元';

  @override
  String get currencyHTG => '海地古德';

  @override
  String get currencyXCD => '东加勒比元';

  @override
  String get currencyKYD => '开曼群岛元';

  @override
  String get currencyAWG => '阿鲁巴弗罗林';

  @override
  String get currencyANG => '荷属安的列斯盾';

  @override
  String get currencyBMD => '百慕大元';

  @override
  String get currencyUYU => '乌拉圭比索';

  @override
  String get currencyPYG => '巴拉圭瓜拉尼';

  @override
  String get currencyBOB => '玻利维亚诺';

  @override
  String get currencyVES => '委内瑞拉玻利瓦尔';

  @override
  String get currencyGYD => '圭亚那元';

  @override
  String get currencySRD => '苏里南元';

  @override
  String get currencyFJD => '斐济元';

  @override
  String get currencyPGK => '巴布亚新几内亚基那';

  @override
  String get currencySBD => '所罗门群岛元';

  @override
  String get currencyTOP => '汤加潘加';

  @override
  String get currencyVUV => '瓦努阿图瓦图';

  @override
  String get currencyWST => '萨摩亚塔拉';

  @override
  String get currencyXPF => '太平洋法郎';

  @override
  String get currencyKES => '肯尼亚先令';

  @override
  String get currencyGHS => '加纳塞地';

  @override
  String get currencyMAD => '摩洛哥迪拉姆';

  @override
  String get currencyDZD => '阿尔及利亚第纳尔';

  @override
  String get currencyTND => '突尼斯第纳尔';

  @override
  String get currencyLYD => '利比亚第纳尔';

  @override
  String get currencyETB => '埃塞俄比亚比尔';

  @override
  String get currencyUGX => '乌干达先令';

  @override
  String get currencyTZS => '坦桑尼亚先令';

  @override
  String get currencyRWF => '卢旺达法郎';

  @override
  String get currencyXAF => '中非法郎';

  @override
  String get currencyXOF => '西非法郎';

  @override
  String get currencyMUR => '毛里求斯卢比';

  @override
  String get currencyBWP => '博茨瓦纳普拉';

  @override
  String get currencyNAD => '纳米比亚元';

  @override
  String get currencyZMW => '赞比亚克瓦查';

  @override
  String get currencyMWK => '马拉维克瓦查';

  @override
  String get currencyMZN => '莫桑比克梅蒂卡尔';

  @override
  String get currencyAOA => '安哥拉宽扎';

  @override
  String get currencyCDF => '刚果法郎';

  @override
  String get currencyGMD => '冈比亚达拉西';

  @override
  String get currencyGNF => '几内亚法郎';

  @override
  String get currencyLRD => '利比里亚元';

  @override
  String get currencySLE => '塞拉利昂利昂';

  @override
  String get currencySDG => '苏丹镑';

  @override
  String get currencySSP => '南苏丹镑';

  @override
  String get currencySOS => '索马里先令';

  @override
  String get currencyDJF => '吉布提法郎';

  @override
  String get currencyERN => '厄立特里亚纳克法';

  @override
  String get currencyBIF => '布隆迪法郎';

  @override
  String get currencyCVE => '佛得角埃斯库多';

  @override
  String get currencySTN => '圣多美多布拉';

  @override
  String get currencySCR => '塞舌尔卢比';

  @override
  String get currencyKMF => '科摩罗法郎';

  @override
  String get currencyLSL => '莱索托洛蒂';

  @override
  String get currencySZL => '斯威士兰里兰吉尼';

  @override
  String get currencyMGA => '马达加斯加阿里亚里';

  @override
  String get currencyMRU => '毛里塔尼亚乌吉亚';

  @override
  String get trashTitle => '最近删除';

  @override
  String get trashEntryDesc => '删除的交易保留 30 天,可恢复';

  @override
  String get trashEmpty => '回收站是空的';

  @override
  String get trashRetentionHint => '删除的交易保留 30 天后自动清理';

  @override
  String get trashRestored => '已恢复';

  @override
  String get trashRestoreFailed => '恢复失败';

  @override
  String get trashRestore => '恢复';

  @override
  String get trashPurgeTitle => '彻底删除';

  @override
  String trashPurgeAsk(Object amount, Object sign) {
    return '将永久删除 $sign$amount,且无法恢复。确定继续吗?';
  }

  @override
  String get trashPurgeConfirm => '彻底删除';

  @override
  String get trashDeletedAt => '删除于';

  @override
  String trashDaysLeft(Object count) {
    return '剩余 $count 天';
  }

  @override
  String get trashTypeIncome => '收入';

  @override
  String get trashTypeExpense => '支出';

  @override
  String get trashTypeTransfer => '转账';

  @override
  String get pendingCandidateReasonSettlementUnknown => '结算状态不明确,请核对是否已支付';

  @override
  String get pendingCandidateReasonTransferAccountMissing => '转账/还款缺少账户,请补充';

  @override
  String get pendingCandidateReasonAlreadyProcessed => '同一账单已处理过';
}
