import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh')
  ];

  /// No description provided for @aiConsentTitle.
  ///
  /// In zh, this message translates to:
  /// **'开启 AI 功能前,请知悉'**
  String get aiConsentTitle;

  /// No description provided for @aiConsentBody.
  ///
  /// In zh, this message translates to:
  /// **'AI 功能需将相关数据发送给你所配置的第三方 AI 服务商进行处理:\n\n• 发送给谁:默认「智谱 GLM」(open.bigmodel.cn,由智谱华章运营);若你自行配置了其它第三方 AI 服务商,则发送给你填写的服务商。\n• 发送什么:你主动用于识别/对话的内容 —— 账单图片、语音录音、你输入的文字,以及为完成识别/分析所需的分类名称、账户名称和相关交易记录。\n• 用途:仅用于账单识别、记账与你发起的对话分析;智记自身不收集、不存储这些数据。\n\n数据由该第三方服务商按其隐私政策处理。开启即表示你同意上述数据共享。'**
  String get aiConsentBody;

  /// No description provided for @aiConsentAgree.
  ///
  /// In zh, this message translates to:
  /// **'同意并开启'**
  String get aiConsentAgree;

  /// No description provided for @aboutPrivacyPolicy.
  ///
  /// In zh, this message translates to:
  /// **'隐私政策'**
  String get aboutPrivacyPolicy;

  /// No description provided for @aboutChangelog.
  ///
  /// In zh, this message translates to:
  /// **'更新日志'**
  String get aboutChangelog;

  /// No description provided for @appTitle.
  ///
  /// In zh, this message translates to:
  /// **'智记'**
  String get appTitle;

  /// No description provided for @tabHome.
  ///
  /// In zh, this message translates to:
  /// **'明细'**
  String get tabHome;

  /// No description provided for @tabInsights.
  ///
  /// In zh, this message translates to:
  /// **'洞察'**
  String get tabInsights;

  /// No description provided for @tabAssets.
  ///
  /// In zh, this message translates to:
  /// **'资产'**
  String get tabAssets;

  /// No description provided for @tabRecord.
  ///
  /// In zh, this message translates to:
  /// **'记账'**
  String get tabRecord;

  /// No description provided for @tabAiAssistant.
  ///
  /// In zh, this message translates to:
  /// **'AI 助手'**
  String get tabAiAssistant;

  /// No description provided for @tabMine.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get tabMine;

  /// No description provided for @commonCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get commonConfirm;

  /// No description provided for @commonSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get commonSave;

  /// No description provided for @commonDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get commonDelete;

  /// No description provided for @commonAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get commonAdd;

  /// No description provided for @commonEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get commonEdit;

  /// No description provided for @commonMore.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get commonMore;

  /// No description provided for @commonOk.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get commonOk;

  /// No description provided for @commonKnow.
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get commonKnow;

  /// No description provided for @commonNo.
  ///
  /// In zh, this message translates to:
  /// **'否'**
  String get commonNo;

  /// No description provided for @commonEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据'**
  String get commonEmpty;

  /// No description provided for @commonError.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get commonError;

  /// No description provided for @commonSuccess.
  ///
  /// In zh, this message translates to:
  /// **'成功'**
  String get commonSuccess;

  /// No description provided for @commonFailed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get commonFailed;

  /// No description provided for @commonBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get commonBack;

  /// No description provided for @commonNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get commonNext;

  /// No description provided for @fabActionCamera.
  ///
  /// In zh, this message translates to:
  /// **'拍照'**
  String get fabActionCamera;

  /// No description provided for @fabActionGallery.
  ///
  /// In zh, this message translates to:
  /// **'相册'**
  String get fabActionGallery;

  /// No description provided for @fabActionVoice.
  ///
  /// In zh, this message translates to:
  /// **'语音'**
  String get fabActionVoice;

  /// No description provided for @fabActionVoiceDisabled.
  ///
  /// In zh, this message translates to:
  /// **'需要启用AI并配置API Key'**
  String get fabActionVoiceDisabled;

  /// No description provided for @fabActionManual.
  ///
  /// In zh, this message translates to:
  /// **'记一笔'**
  String get fabActionManual;

  /// No description provided for @voiceRecordingTitle.
  ///
  /// In zh, this message translates to:
  /// **'语音记账'**
  String get voiceRecordingTitle;

  /// No description provided for @voiceRecordingPreparing.
  ///
  /// In zh, this message translates to:
  /// **'准备录音...'**
  String get voiceRecordingPreparing;

  /// No description provided for @voiceRecordingInProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在录音...'**
  String get voiceRecordingInProgress;

  /// No description provided for @voiceRecordingProcessing.
  ///
  /// In zh, this message translates to:
  /// **'正在识别...'**
  String get voiceRecordingProcessing;

  /// No description provided for @voiceRecordingDuration.
  ///
  /// In zh, this message translates to:
  /// **'录音时长: {duration}秒'**
  String voiceRecordingDuration(int duration);

  /// No description provided for @voiceRecordingSuccess.
  ///
  /// In zh, this message translates to:
  /// **'语音记账成功'**
  String get voiceRecordingSuccess;

  /// No description provided for @voiceRecordingNoLedger.
  ///
  /// In zh, this message translates to:
  /// **'未找到当前账本'**
  String get voiceRecordingNoLedger;

  /// No description provided for @voiceRecordingNoInfo.
  ///
  /// In zh, this message translates to:
  /// **'未识别到记账信息'**
  String get voiceRecordingNoInfo;

  /// No description provided for @voiceRecordingPermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'需要麦克风权限才能录音'**
  String get voiceRecordingPermissionDenied;

  /// No description provided for @voiceRecordingPermissionDeniedTitle.
  ///
  /// In zh, this message translates to:
  /// **'需要麦克风权限'**
  String get voiceRecordingPermissionDeniedTitle;

  /// No description provided for @voiceRecordingPermissionDeniedMessage.
  ///
  /// In zh, this message translates to:
  /// **'语音记账功能需要使用麦克风权限。请在系统设置中允许智记访问麦克风。'**
  String get voiceRecordingPermissionDeniedMessage;

  /// No description provided for @voiceRecordingStartFailed.
  ///
  /// In zh, this message translates to:
  /// **'启动录音失败: {error}'**
  String voiceRecordingStartFailed(String error);

  /// No description provided for @voiceRecordingFailed.
  ///
  /// In zh, this message translates to:
  /// **'录音失败: {error}'**
  String voiceRecordingFailed(String error);

  /// No description provided for @voiceRecordingRecognizeFailed.
  ///
  /// In zh, this message translates to:
  /// **'识别失败: {error}'**
  String voiceRecordingRecognizeFailed(String error);

  /// No description provided for @voiceRecordingNoInfoDetected.
  ///
  /// In zh, this message translates to:
  /// **'未能识别账单信息: {text}'**
  String voiceRecordingNoInfoDetected(String text);

  /// No description provided for @voiceRecordingNoSpeech.
  ///
  /// In zh, this message translates to:
  /// **'未检测到语音输入'**
  String get voiceRecordingNoSpeech;

  /// No description provided for @voiceRecordingHoldToTalk.
  ///
  /// In zh, this message translates to:
  /// **'按住 说话'**
  String get voiceRecordingHoldToTalk;

  /// No description provided for @voiceRecordingReleaseToFinish.
  ///
  /// In zh, this message translates to:
  /// **'松手结束录音'**
  String get voiceRecordingReleaseToFinish;

  /// No description provided for @voiceRecordingTooShort.
  ///
  /// In zh, this message translates to:
  /// **'录音时间过短'**
  String get voiceRecordingTooShort;

  /// No description provided for @voiceRecordingResultLabel.
  ///
  /// In zh, this message translates to:
  /// **'识别结果：'**
  String get voiceRecordingResultLabel;

  /// No description provided for @voiceRecordingAutoHintSpoken.
  ///
  /// In zh, this message translates to:
  /// **'说完后停顿即可自动识别'**
  String get voiceRecordingAutoHintSpoken;

  /// No description provided for @voiceRecordingAutoHintWaiting.
  ///
  /// In zh, this message translates to:
  /// **'请开始说话...'**
  String get voiceRecordingAutoHintWaiting;

  /// No description provided for @smartBillingVoiceTrigger.
  ///
  /// In zh, this message translates to:
  /// **'语音触发方式'**
  String get smartBillingVoiceTrigger;

  /// No description provided for @voiceTriggerModeAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动检测停顿'**
  String get voiceTriggerModeAuto;

  /// No description provided for @voiceTriggerModeAutoDesc.
  ///
  /// In zh, this message translates to:
  /// **'录音后自动判断说完，适合短句快速记账'**
  String get voiceTriggerModeAutoDesc;

  /// No description provided for @voiceTriggerModeHold.
  ///
  /// In zh, this message translates to:
  /// **'按住说话'**
  String get voiceTriggerModeHold;

  /// No description provided for @voiceTriggerModeHoldDesc.
  ///
  /// In zh, this message translates to:
  /// **'长按录音、松开结束，适合一次说较多内容'**
  String get voiceTriggerModeHoldDesc;

  /// No description provided for @smartBillingVoiceSilenceTimeout.
  ///
  /// In zh, this message translates to:
  /// **'停顿结束时长'**
  String get smartBillingVoiceSilenceTimeout;

  /// No description provided for @smartBillingVoiceSilenceTimeoutValue.
  ///
  /// In zh, this message translates to:
  /// **'停顿 {seconds} 秒后自动结束识别'**
  String smartBillingVoiceSilenceTimeoutValue(String seconds);

  /// No description provided for @commonPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一步'**
  String get commonPrevious;

  /// No description provided for @commonFinish.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get commonFinish;

  /// No description provided for @commonClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get commonClose;

  /// No description provided for @commonOther.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get commonOther;

  /// No description provided for @commonYesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天'**
  String get commonYesterday;

  /// No description provided for @commonSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get commonSearch;

  /// No description provided for @commonNoteHint.
  ///
  /// In zh, this message translates to:
  /// **'备注…'**
  String get commonNoteHint;

  /// No description provided for @commonSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get commonSettings;

  /// No description provided for @commonGoSettings.
  ///
  /// In zh, this message translates to:
  /// **'前往设置'**
  String get commonGoSettings;

  /// No description provided for @commonLanguage.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get commonLanguage;

  /// No description provided for @commonWeekdayMonday.
  ///
  /// In zh, this message translates to:
  /// **'星期一'**
  String get commonWeekdayMonday;

  /// No description provided for @commonWeekdayTuesday.
  ///
  /// In zh, this message translates to:
  /// **'星期二'**
  String get commonWeekdayTuesday;

  /// No description provided for @commonWeekdayWednesday.
  ///
  /// In zh, this message translates to:
  /// **'星期三'**
  String get commonWeekdayWednesday;

  /// No description provided for @commonWeekdayThursday.
  ///
  /// In zh, this message translates to:
  /// **'星期四'**
  String get commonWeekdayThursday;

  /// No description provided for @commonWeekdayFriday.
  ///
  /// In zh, this message translates to:
  /// **'星期五'**
  String get commonWeekdayFriday;

  /// No description provided for @commonWeekdaySaturday.
  ///
  /// In zh, this message translates to:
  /// **'星期六'**
  String get commonWeekdaySaturday;

  /// No description provided for @commonWeekdaySunday.
  ///
  /// In zh, this message translates to:
  /// **'星期日'**
  String get commonWeekdaySunday;

  /// No description provided for @commonCurrent.
  ///
  /// In zh, this message translates to:
  /// **'当前'**
  String get commonCurrent;

  /// No description provided for @commonTutorial.
  ///
  /// In zh, this message translates to:
  /// **'教程'**
  String get commonTutorial;

  /// No description provided for @commonConfigure.
  ///
  /// In zh, this message translates to:
  /// **'配置'**
  String get commonConfigure;

  /// No description provided for @commonPressAgainToExit.
  ///
  /// In zh, this message translates to:
  /// **'再按一次退出应用'**
  String get commonPressAgainToExit;

  /// No description provided for @homeIncome.
  ///
  /// In zh, this message translates to:
  /// **'收入'**
  String get homeIncome;

  /// No description provided for @homeExpense.
  ///
  /// In zh, this message translates to:
  /// **'支出'**
  String get homeExpense;

  /// No description provided for @homeBalance.
  ///
  /// In zh, this message translates to:
  /// **'结余'**
  String get homeBalance;

  /// No description provided for @homeNoRecords.
  ///
  /// In zh, this message translates to:
  /// **'还没有记账'**
  String get homeNoRecords;

  /// No description provided for @homeSelectDate.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get homeSelectDate;

  /// No description provided for @homeAppTitle.
  ///
  /// In zh, this message translates to:
  /// **'智记'**
  String get homeAppTitle;

  /// No description provided for @homeSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get homeSearch;

  /// No description provided for @homeYear.
  ///
  /// In zh, this message translates to:
  /// **'{year}年'**
  String homeYear(Object year);

  /// No description provided for @homeMonth.
  ///
  /// In zh, this message translates to:
  /// **'{month}月'**
  String homeMonth(Object month);

  /// No description provided for @homeNoRecordsSubtext.
  ///
  /// In zh, this message translates to:
  /// **'点击下方「AI 助手」记账，长按可手动记一笔'**
  String get homeNoRecordsSubtext;

  /// No description provided for @homeNewRecordsCount.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 条新记录'**
  String homeNewRecordsCount(int count);

  /// No description provided for @homeViewNewRecords.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get homeViewNewRecords;

  /// No description provided for @homeLastMonthReportSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'查看上月消费报告并分享'**
  String get homeLastMonthReportSubtitle;

  /// No description provided for @homeLastMonthReportView.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get homeLastMonthReportView;

  /// No description provided for @homeAnnualReportReminder.
  ///
  /// In zh, this message translates to:
  /// **'{year}年度账单已生成，回顾你的财务足迹'**
  String homeAnnualReportReminder(int year);

  /// No description provided for @homeAnnualReportView.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get homeAnnualReportView;

  /// No description provided for @widgetTodayExpense.
  ///
  /// In zh, this message translates to:
  /// **'今日支出'**
  String get widgetTodayExpense;

  /// No description provided for @widgetTodayIncome.
  ///
  /// In zh, this message translates to:
  /// **'今日收入'**
  String get widgetTodayIncome;

  /// No description provided for @widgetMonthExpense.
  ///
  /// In zh, this message translates to:
  /// **'本月支出'**
  String get widgetMonthExpense;

  /// No description provided for @widgetMonthIncome.
  ///
  /// In zh, this message translates to:
  /// **'本月收入'**
  String get widgetMonthIncome;

  /// No description provided for @widgetMonthSuffix.
  ///
  /// In zh, this message translates to:
  /// **'月'**
  String get widgetMonthSuffix;

  /// No description provided for @widgetToday.
  ///
  /// In zh, this message translates to:
  /// **'今日'**
  String get widgetToday;

  /// No description provided for @widgetQuickAddLabel.
  ///
  /// In zh, this message translates to:
  /// **'记一笔'**
  String get widgetQuickAddLabel;

  /// No description provided for @widgetBudgetTotal.
  ///
  /// In zh, this message translates to:
  /// **'总额'**
  String get widgetBudgetTotal;

  /// No description provided for @widgetBudgetRemaining.
  ///
  /// In zh, this message translates to:
  /// **'剩'**
  String get widgetBudgetRemaining;

  /// No description provided for @widgetNoBudget.
  ///
  /// In zh, this message translates to:
  /// **'未设预算'**
  String get widgetNoBudget;

  /// No description provided for @widgetNoTransactions.
  ///
  /// In zh, this message translates to:
  /// **'暂无交易'**
  String get widgetNoTransactions;

  /// No description provided for @widgetRecentTransactions.
  ///
  /// In zh, this message translates to:
  /// **'最近交易'**
  String get widgetRecentTransactions;

  /// No description provided for @widgetNoAccounts.
  ///
  /// In zh, this message translates to:
  /// **'暂无账户'**
  String get widgetNoAccounts;

  /// No description provided for @searchTitle.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get searchTitle;

  /// No description provided for @searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索备注、分类或金额...'**
  String get searchHint;

  /// No description provided for @searchCategoryHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索分类名称...'**
  String get searchCategoryHint;

  /// No description provided for @searchCategoryFilter.
  ///
  /// In zh, this message translates to:
  /// **'分类筛选'**
  String get searchCategoryFilter;

  /// No description provided for @searchMinAmount.
  ///
  /// In zh, this message translates to:
  /// **'最小金额'**
  String get searchMinAmount;

  /// No description provided for @searchMaxAmount.
  ///
  /// In zh, this message translates to:
  /// **'最大金额'**
  String get searchMaxAmount;

  /// No description provided for @searchNoInput.
  ///
  /// In zh, this message translates to:
  /// **'输入关键词开始搜索'**
  String get searchNoInput;

  /// No description provided for @searchNoResults.
  ///
  /// In zh, this message translates to:
  /// **'未找到匹配的结果'**
  String get searchNoResults;

  /// No description provided for @searchBatchMode.
  ///
  /// In zh, this message translates to:
  /// **'批量操作'**
  String get searchBatchMode;

  /// No description provided for @searchBatchModeWithCount.
  ///
  /// In zh, this message translates to:
  /// **'批量操作 ({selected}/{total})'**
  String searchBatchModeWithCount(int selected, int total);

  /// No description provided for @searchExitBatchMode.
  ///
  /// In zh, this message translates to:
  /// **'退出批量操作'**
  String get searchExitBatchMode;

  /// No description provided for @searchSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get searchSelectAll;

  /// No description provided for @searchDeselectAll.
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get searchDeselectAll;

  /// No description provided for @searchSelectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选择 {count} 项'**
  String searchSelectedCount(int count);

  /// No description provided for @searchBatchSetNote.
  ///
  /// In zh, this message translates to:
  /// **'设置备注'**
  String get searchBatchSetNote;

  /// No description provided for @searchBatchChangeCategory.
  ///
  /// In zh, this message translates to:
  /// **'调整分类'**
  String get searchBatchChangeCategory;

  /// No description provided for @searchBatchDeleteConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认删除'**
  String get searchBatchDeleteConfirmTitle;

  /// No description provided for @searchBatchDeleteConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除选中的 {count} 笔记账吗?\n此操作无法撤销。'**
  String searchBatchDeleteConfirmMessage(int count);

  /// No description provided for @searchBatchSetNoteTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量设置备注'**
  String get searchBatchSetNoteTitle;

  /// No description provided for @searchBatchSetNoteMessage.
  ///
  /// In zh, this message translates to:
  /// **'将为选中的 {count} 笔记账设置相同的备注'**
  String searchBatchSetNoteMessage(int count);

  /// No description provided for @searchBatchSetNoteHint.
  ///
  /// In zh, this message translates to:
  /// **'输入备注内容 (留空则清空备注)'**
  String get searchBatchSetNoteHint;

  /// No description provided for @searchBatchDeleteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'成功删除 {count} 笔记账'**
  String searchBatchDeleteSuccess(int count);

  /// No description provided for @searchBatchDeleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除失败: {error}'**
  String searchBatchDeleteFailed(String error);

  /// No description provided for @searchBatchSetNoteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'成功为 {count} 笔记账设置备注'**
  String searchBatchSetNoteSuccess(int count);

  /// No description provided for @searchBatchSetNoteFailed.
  ///
  /// In zh, this message translates to:
  /// **'设置备注失败: {error}'**
  String searchBatchSetNoteFailed(String error);

  /// No description provided for @searchBatchChangeCategorySuccess.
  ///
  /// In zh, this message translates to:
  /// **'成功为 {count} 笔记账调整分类'**
  String searchBatchChangeCategorySuccess(int count);

  /// No description provided for @searchBatchChangeCategoryFailed.
  ///
  /// In zh, this message translates to:
  /// **'调整分类失败: {error}'**
  String searchBatchChangeCategoryFailed(String error);

  /// No description provided for @searchResultsCount.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 条结果'**
  String searchResultsCount(int count);

  /// No description provided for @searchSummaryIncome.
  ///
  /// In zh, this message translates to:
  /// **'收入'**
  String get searchSummaryIncome;

  /// No description provided for @searchSummaryExpense.
  ///
  /// In zh, this message translates to:
  /// **'支出'**
  String get searchSummaryExpense;

  /// No description provided for @searchFilterTitle.
  ///
  /// In zh, this message translates to:
  /// **'筛选'**
  String get searchFilterTitle;

  /// No description provided for @searchAmountFilter.
  ///
  /// In zh, this message translates to:
  /// **'金额筛选'**
  String get searchAmountFilter;

  /// No description provided for @searchDateFilter.
  ///
  /// In zh, this message translates to:
  /// **'时间筛选'**
  String get searchDateFilter;

  /// No description provided for @searchStartDate.
  ///
  /// In zh, this message translates to:
  /// **'开始日期'**
  String get searchStartDate;

  /// No description provided for @searchEndDate.
  ///
  /// In zh, this message translates to:
  /// **'结束日期'**
  String get searchEndDate;

  /// No description provided for @searchNotSet.
  ///
  /// In zh, this message translates to:
  /// **'未设置'**
  String get searchNotSet;

  /// No description provided for @searchClearFilter.
  ///
  /// In zh, this message translates to:
  /// **'清空筛选'**
  String get searchClearFilter;

  /// No description provided for @searchBatchCategoryTransferError.
  ///
  /// In zh, this message translates to:
  /// **'选中的交易包含转账，无法修改分类'**
  String get searchBatchCategoryTransferError;

  /// No description provided for @searchBatchCategoryTypeError.
  ///
  /// In zh, this message translates to:
  /// **'选中的交易类型不一致，请选择全部为收入或全部为支出的交易'**
  String get searchBatchCategoryTypeError;

  /// No description provided for @searchDateStart.
  ///
  /// In zh, this message translates to:
  /// **'开始'**
  String get searchDateStart;

  /// No description provided for @searchDateEnd.
  ///
  /// In zh, this message translates to:
  /// **'结束'**
  String get searchDateEnd;

  /// No description provided for @analyticsMonth.
  ///
  /// In zh, this message translates to:
  /// **'月'**
  String get analyticsMonth;

  /// No description provided for @analyticsYear.
  ///
  /// In zh, this message translates to:
  /// **'年'**
  String get analyticsYear;

  /// No description provided for @analyticsAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get analyticsAll;

  /// No description provided for @analyticsCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get analyticsCustom;

  /// No description provided for @analyticsCompareLastMonth.
  ///
  /// In zh, this message translates to:
  /// **'较上月'**
  String get analyticsCompareLastMonth;

  /// No description provided for @analyticsCompareSameMonthLastYear.
  ///
  /// In zh, this message translates to:
  /// **'较去年同月'**
  String get analyticsCompareSameMonthLastYear;

  /// No description provided for @analyticsCompareLastYear.
  ///
  /// In zh, this message translates to:
  /// **'较去年'**
  String get analyticsCompareLastYear;

  /// No description provided for @analyticsComparePrevPrevYear.
  ///
  /// In zh, this message translates to:
  /// **'较前年'**
  String get analyticsComparePrevPrevYear;

  /// No description provided for @analyticsAccountBreakdown.
  ///
  /// In zh, this message translates to:
  /// **'账户分布'**
  String get analyticsAccountBreakdown;

  /// No description provided for @analyticsTopMerchants.
  ///
  /// In zh, this message translates to:
  /// **'商户 Top'**
  String get analyticsTopMerchants;

  /// No description provided for @analyticsNoAccount.
  ///
  /// In zh, this message translates to:
  /// **'未指定账户'**
  String get analyticsNoAccount;

  /// No description provided for @analyticsCategoryRanking.
  ///
  /// In zh, this message translates to:
  /// **'分类排行'**
  String get analyticsCategoryRanking;

  /// No description provided for @analyticsTotalAmount.
  ///
  /// In zh, this message translates to:
  /// **'总计'**
  String get analyticsTotalAmount;

  /// No description provided for @analyticsNoDataSubtext.
  ///
  /// In zh, this message translates to:
  /// **'可左右滑动切换周期，或点击按钮切换收入/支出'**
  String get analyticsNoDataSubtext;

  /// No description provided for @analyticsSwipeHint.
  ///
  /// In zh, this message translates to:
  /// **'左右滑动切换周期'**
  String get analyticsSwipeHint;

  /// No description provided for @analyticsSwitchTo.
  ///
  /// In zh, this message translates to:
  /// **'切换到{type}'**
  String analyticsSwitchTo(Object type);

  /// No description provided for @analyticsTipHeader.
  ///
  /// In zh, this message translates to:
  /// **'提示：顶部胶囊可切换 月/年/全部'**
  String get analyticsTipHeader;

  /// No description provided for @analyticsSwipeToSwitch.
  ///
  /// In zh, this message translates to:
  /// **'横滑切换'**
  String get analyticsSwipeToSwitch;

  /// No description provided for @analyticsAllYears.
  ///
  /// In zh, this message translates to:
  /// **'全部年份'**
  String get analyticsAllYears;

  /// No description provided for @analyticsToday.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get analyticsToday;

  /// No description provided for @splashAppName.
  ///
  /// In zh, this message translates to:
  /// **'智记'**
  String get splashAppName;

  /// No description provided for @splashSlogan.
  ///
  /// In zh, this message translates to:
  /// **'一笔一蜜'**
  String get splashSlogan;

  /// No description provided for @splashSecurityTitle.
  ///
  /// In zh, this message translates to:
  /// **'开源数据安全'**
  String get splashSecurityTitle;

  /// No description provided for @splashSecurityFeature1.
  ///
  /// In zh, this message translates to:
  /// **'• 数据本地存储，隐私完全自控'**
  String get splashSecurityFeature1;

  /// No description provided for @splashSecurityFeature2.
  ///
  /// In zh, this message translates to:
  /// **'• 开源代码透明，安全值得信赖'**
  String get splashSecurityFeature2;

  /// No description provided for @splashSecurityFeature3.
  ///
  /// In zh, this message translates to:
  /// **'• 可选云端同步，多设备数据一致'**
  String get splashSecurityFeature3;

  /// No description provided for @splashInitializing.
  ///
  /// In zh, this message translates to:
  /// **'正在初始化数据...'**
  String get splashInitializing;

  /// No description provided for @ledgersTitle.
  ///
  /// In zh, this message translates to:
  /// **'账本管理'**
  String get ledgersTitle;

  /// No description provided for @ledgersNew.
  ///
  /// In zh, this message translates to:
  /// **'新建账本'**
  String get ledgersNew;

  /// No description provided for @ledgersClear.
  ///
  /// In zh, this message translates to:
  /// **'清空账本'**
  String get ledgersClear;

  /// No description provided for @ledgersClearMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要清空账本\"{name}\"的所有账单吗？此操作不可恢复。\\n账本本身会保留，仅删除账单数据。'**
  String ledgersClearMessage(String name);

  /// No description provided for @ledgerDefaultName.
  ///
  /// In zh, this message translates to:
  /// **'默认账本'**
  String get ledgerDefaultName;

  /// No description provided for @ledgersEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑账本'**
  String get ledgersEdit;

  /// No description provided for @ledgersDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除账本'**
  String get ledgersDelete;

  /// No description provided for @ledgersDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'删除账本'**
  String get ledgersDeleteConfirm;

  /// No description provided for @ledgersDeleteMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除该账本及其全部记录吗？此操作不可恢复。\\n若云端存在备份，也会一并删除。'**
  String get ledgersDeleteMessage;

  /// No description provided for @ledgersDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get ledgersDeleted;

  /// No description provided for @ledgersDeleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除失败'**
  String get ledgersDeleteFailed;

  /// No description provided for @ledgersClearTitle.
  ///
  /// In zh, this message translates to:
  /// **'清空账本'**
  String get ledgersClearTitle;

  /// No description provided for @ledgersClearSuccess.
  ///
  /// In zh, this message translates to:
  /// **'账本已清空'**
  String get ledgersClearSuccess;

  /// No description provided for @ledgersDeleteLocal.
  ///
  /// In zh, this message translates to:
  /// **'仅删除本地账本'**
  String get ledgersDeleteLocal;

  /// No description provided for @ledgersDeleteLocalTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除本地账本'**
  String get ledgersDeleteLocalTitle;

  /// No description provided for @ledgersDeleteLocalMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除本地账本\"{name}\"吗？\\n云端备份会保留，您可以随时恢复。'**
  String ledgersDeleteLocalMessage(String name);

  /// No description provided for @ledgersDeleteLocalSuccess.
  ///
  /// In zh, this message translates to:
  /// **'本地账本已删除'**
  String get ledgersDeleteLocalSuccess;

  /// No description provided for @ledgersName.
  ///
  /// In zh, this message translates to:
  /// **'名称'**
  String get ledgersName;

  /// No description provided for @ledgersDefaultLedgerName.
  ///
  /// In zh, this message translates to:
  /// **'默认账本'**
  String get ledgersDefaultLedgerName;

  /// No description provided for @ledgersCurrency.
  ///
  /// In zh, this message translates to:
  /// **'币种'**
  String get ledgersCurrency;

  /// No description provided for @ledgersMonthStartDay.
  ///
  /// In zh, this message translates to:
  /// **'每月起始日'**
  String get ledgersMonthStartDay;

  /// No description provided for @ledgersMonthStartDayHint.
  ///
  /// In zh, this message translates to:
  /// **'统计与预算按该日作为每月周期起点（1-28）'**
  String get ledgersMonthStartDayHint;

  /// No description provided for @ledgersMonthStartDayNatural.
  ///
  /// In zh, this message translates to:
  /// **'1日（自然月）'**
  String get ledgersMonthStartDayNatural;

  /// No description provided for @ledgersMonthStartDayValue.
  ///
  /// In zh, this message translates to:
  /// **'每月{day}日'**
  String ledgersMonthStartDayValue(Object day);

  /// No description provided for @ledgersSelectCurrency.
  ///
  /// In zh, this message translates to:
  /// **'选择币种'**
  String get ledgersSelectCurrency;

  /// No description provided for @ledgersSearchCurrency.
  ///
  /// In zh, this message translates to:
  /// **'搜索：中文或代码'**
  String get ledgersSearchCurrency;

  /// No description provided for @ledgersCreate.
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get ledgersCreate;

  /// No description provided for @ledgersActions.
  ///
  /// In zh, this message translates to:
  /// **'操作'**
  String get ledgersActions;

  /// No description provided for @ledgersRecords.
  ///
  /// In zh, this message translates to:
  /// **'笔数：{count}'**
  String ledgersRecords(Object count);

  /// No description provided for @ledgersBalance.
  ///
  /// In zh, this message translates to:
  /// **'余额：{balance}'**
  String ledgersBalance(Object balance);

  /// No description provided for @ledgerCardDownloadCloud.
  ///
  /// In zh, this message translates to:
  /// **'下载云账本'**
  String get ledgerCardDownloadCloud;

  /// No description provided for @categoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'分类管理'**
  String get categoryTitle;

  /// No description provided for @categoryNew.
  ///
  /// In zh, this message translates to:
  /// **'新建分类'**
  String get categoryNew;

  /// No description provided for @categoryExpense.
  ///
  /// In zh, this message translates to:
  /// **'支出'**
  String get categoryExpense;

  /// No description provided for @categoryIncome.
  ///
  /// In zh, this message translates to:
  /// **'收入'**
  String get categoryIncome;

  /// No description provided for @categoryEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无分类'**
  String get categoryEmpty;

  /// No description provided for @categoryDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认分类'**
  String get categoryDefault;

  /// No description provided for @categoryReorderTip.
  ///
  /// In zh, this message translates to:
  /// **'长按分类可拖拽调整顺序'**
  String get categoryReorderTip;

  /// No description provided for @categoryLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败: {error}'**
  String categoryLoadFailed(Object error);

  /// No description provided for @iconPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择图标'**
  String get iconPickerTitle;

  /// No description provided for @iconCategoryTransport.
  ///
  /// In zh, this message translates to:
  /// **'交通'**
  String get iconCategoryTransport;

  /// No description provided for @iconCategoryShopping.
  ///
  /// In zh, this message translates to:
  /// **'购物'**
  String get iconCategoryShopping;

  /// No description provided for @iconCategoryEntertainment.
  ///
  /// In zh, this message translates to:
  /// **'娱乐'**
  String get iconCategoryEntertainment;

  /// No description provided for @iconCategoryLife.
  ///
  /// In zh, this message translates to:
  /// **'生活'**
  String get iconCategoryLife;

  /// No description provided for @iconCategoryHealth.
  ///
  /// In zh, this message translates to:
  /// **'健康'**
  String get iconCategoryHealth;

  /// No description provided for @iconCategoryEducation.
  ///
  /// In zh, this message translates to:
  /// **'学习'**
  String get iconCategoryEducation;

  /// No description provided for @iconCategoryWork.
  ///
  /// In zh, this message translates to:
  /// **'工作'**
  String get iconCategoryWork;

  /// No description provided for @iconCategoryFinance.
  ///
  /// In zh, this message translates to:
  /// **'理财'**
  String get iconCategoryFinance;

  /// No description provided for @iconCategoryReward.
  ///
  /// In zh, this message translates to:
  /// **'奖励'**
  String get iconCategoryReward;

  /// No description provided for @iconCategoryOther.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get iconCategoryOther;

  /// No description provided for @importTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入账单'**
  String get importTitle;

  /// No description provided for @importBillType.
  ///
  /// In zh, this message translates to:
  /// **'账单类型'**
  String get importBillType;

  /// No description provided for @importBillTypeGeneric.
  ///
  /// In zh, this message translates to:
  /// **'通用CSV'**
  String get importBillTypeGeneric;

  /// No description provided for @importBillTypeAlipay.
  ///
  /// In zh, this message translates to:
  /// **'支付宝'**
  String get importBillTypeAlipay;

  /// No description provided for @importBillTypeWechat.
  ///
  /// In zh, this message translates to:
  /// **'微信'**
  String get importBillTypeWechat;

  /// No description provided for @importChooseFile.
  ///
  /// In zh, this message translates to:
  /// **'选择文件'**
  String get importChooseFile;

  /// No description provided for @importNoFileSelected.
  ///
  /// In zh, this message translates to:
  /// **'未选择文件'**
  String get importNoFileSelected;

  /// No description provided for @importHint.
  ///
  /// In zh, this message translates to:
  /// **'提示：请选择一个文件开始导入（支持 CSV/TSV/XLSX）'**
  String get importHint;

  /// No description provided for @importReading.
  ///
  /// In zh, this message translates to:
  /// **'读取文件中…'**
  String get importReading;

  /// No description provided for @importPreparing.
  ///
  /// In zh, this message translates to:
  /// **'准备中…'**
  String get importPreparing;

  /// No description provided for @importFileOpenError.
  ///
  /// In zh, this message translates to:
  /// **'无法打开文件选择器：{error}'**
  String importFileOpenError(String error);

  /// No description provided for @mineTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get mineTitle;

  /// No description provided for @mineReminder.
  ///
  /// In zh, this message translates to:
  /// **'提醒设置'**
  String get mineReminder;

  /// No description provided for @mineImport.
  ///
  /// In zh, this message translates to:
  /// **'导入数据'**
  String get mineImport;

  /// No description provided for @mineExport.
  ///
  /// In zh, this message translates to:
  /// **'导出数据'**
  String get mineExport;

  /// No description provided for @mineCloud.
  ///
  /// In zh, this message translates to:
  /// **'云服务'**
  String get mineCloud;

  /// No description provided for @mineUpdate.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get mineUpdate;

  /// No description provided for @mineLanguageSettings.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get mineLanguageSettings;

  /// No description provided for @languageTitle.
  ///
  /// In zh, this message translates to:
  /// **'语言设置'**
  String get languageTitle;

  /// No description provided for @languageChinese.
  ///
  /// In zh, this message translates to:
  /// **'中文'**
  String get languageChinese;

  /// No description provided for @languageSystemDefault.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get languageSystemDefault;

  /// No description provided for @deleteConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除确认'**
  String get deleteConfirmTitle;

  /// No description provided for @deleteConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这条记账吗？'**
  String get deleteConfirmMessage;

  /// No description provided for @mineSlogan.
  ///
  /// In zh, this message translates to:
  /// **'智记，智能自动'**
  String get mineSlogan;

  /// No description provided for @mineDisplayNameEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置昵称'**
  String get mineDisplayNameEditTitle;

  /// No description provided for @mineDisplayNameHint.
  ///
  /// In zh, this message translates to:
  /// **'输入昵称'**
  String get mineDisplayNameHint;

  /// No description provided for @mineDisplayNameSaved.
  ///
  /// In zh, this message translates to:
  /// **'昵称已更新'**
  String get mineDisplayNameSaved;

  /// No description provided for @mineGreetingMorning.
  ///
  /// In zh, this message translates to:
  /// **'早上好'**
  String get mineGreetingMorning;

  /// No description provided for @mineGreetingNoon.
  ///
  /// In zh, this message translates to:
  /// **'中午好'**
  String get mineGreetingNoon;

  /// No description provided for @mineGreetingAfternoon.
  ///
  /// In zh, this message translates to:
  /// **'下午好'**
  String get mineGreetingAfternoon;

  /// No description provided for @mineGreetingEvening.
  ///
  /// In zh, this message translates to:
  /// **'晚上好'**
  String get mineGreetingEvening;

  /// No description provided for @mineGreetingNight.
  ///
  /// In zh, this message translates to:
  /// **'夜深了'**
  String get mineGreetingNight;

  /// No description provided for @mineGreetingNamed.
  ///
  /// In zh, this message translates to:
  /// **'{greeting}，{name}'**
  String mineGreetingNamed(Object greeting, Object name);

  /// No description provided for @mineProfileEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑资料'**
  String get mineProfileEditTitle;

  /// No description provided for @headerSkinTitle.
  ///
  /// In zh, this message translates to:
  /// **'皮肤'**
  String get headerSkinTitle;

  /// No description provided for @headerSkinSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'跟随主题色,叠在头部之上'**
  String get headerSkinSubtitle;

  /// No description provided for @headerSkinGroupBasic.
  ///
  /// In zh, this message translates to:
  /// **'基础'**
  String get headerSkinGroupBasic;

  /// No description provided for @headerSkinGroupAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'周年纪念'**
  String get headerSkinGroupAnniversary;

  /// No description provided for @headerSkinGroupGradient.
  ///
  /// In zh, this message translates to:
  /// **'渐变'**
  String get headerSkinGroupGradient;

  /// No description provided for @headerSkinGroupScene.
  ///
  /// In zh, this message translates to:
  /// **'场景'**
  String get headerSkinGroupScene;

  /// No description provided for @headerSkinGroupPattern.
  ///
  /// In zh, this message translates to:
  /// **'图案'**
  String get headerSkinGroupPattern;

  /// No description provided for @headerSkinGroupGeometric.
  ///
  /// In zh, this message translates to:
  /// **'几何艺术'**
  String get headerSkinGroupGeometric;

  /// No description provided for @headerSkinNone.
  ///
  /// In zh, this message translates to:
  /// **'纯色'**
  String get headerSkinNone;

  /// No description provided for @headerSkinAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'一岁星座'**
  String get headerSkinAnniversary;

  /// No description provided for @headerSkinAnnivCake.
  ///
  /// In zh, this message translates to:
  /// **'周年蛋糕'**
  String get headerSkinAnnivCake;

  /// No description provided for @headerSkinTabAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get headerSkinTabAll;

  /// No description provided for @headerSkinTabAnimated.
  ///
  /// In zh, this message translates to:
  /// **'动态'**
  String get headerSkinTabAnimated;

  /// No description provided for @headerSkinTabStatic.
  ///
  /// In zh, this message translates to:
  /// **'静态'**
  String get headerSkinTabStatic;

  /// No description provided for @headerSkinAnimatedBadge.
  ///
  /// In zh, this message translates to:
  /// **'动'**
  String get headerSkinAnimatedBadge;

  /// No description provided for @headerSkinFixedPalette.
  ///
  /// In zh, this message translates to:
  /// **'自带配色'**
  String get headerSkinFixedPalette;

  /// No description provided for @personalizeLockedBySkin.
  ///
  /// In zh, this message translates to:
  /// **'当前皮肤「{skin}」自带配色,主题色已随皮肤设定,暂不可更改。换回其它皮肤即可恢复你原来的颜色。'**
  String personalizeLockedBySkin(String skin);

  /// No description provided for @personalizeFixedSkinAction.
  ///
  /// In zh, this message translates to:
  /// **'换皮肤'**
  String get personalizeFixedSkinAction;

  /// No description provided for @headerSkinAurora.
  ///
  /// In zh, this message translates to:
  /// **'极光'**
  String get headerSkinAurora;

  /// No description provided for @headerSkinMountains.
  ///
  /// In zh, this message translates to:
  /// **'山峦'**
  String get headerSkinMountains;

  /// No description provided for @headerSkinBokeh.
  ///
  /// In zh, this message translates to:
  /// **'光斑'**
  String get headerSkinBokeh;

  /// No description provided for @headerSkinWaves.
  ///
  /// In zh, this message translates to:
  /// **'波浪'**
  String get headerSkinWaves;

  /// No description provided for @headerSkinSunset.
  ///
  /// In zh, this message translates to:
  /// **'日落'**
  String get headerSkinSunset;

  /// No description provided for @headerSkinClouds.
  ///
  /// In zh, this message translates to:
  /// **'云朵'**
  String get headerSkinClouds;

  /// No description provided for @headerSkinExample.
  ///
  /// In zh, this message translates to:
  /// **'示例'**
  String get headerSkinExample;

  /// No description provided for @headerSkinHoneycomb.
  ///
  /// In zh, this message translates to:
  /// **'蜂巢'**
  String get headerSkinHoneycomb;

  /// No description provided for @headerSkinStarry.
  ///
  /// In zh, this message translates to:
  /// **'星河'**
  String get headerSkinStarry;

  /// No description provided for @headerSkinStripes.
  ///
  /// In zh, this message translates to:
  /// **'斜纹'**
  String get headerSkinStripes;

  /// No description provided for @headerSkinSkyline.
  ///
  /// In zh, this message translates to:
  /// **'城市'**
  String get headerSkinSkyline;

  /// No description provided for @headerSkinSakura.
  ///
  /// In zh, this message translates to:
  /// **'樱花'**
  String get headerSkinSakura;

  /// No description provided for @headerSkinMeteor.
  ///
  /// In zh, this message translates to:
  /// **'流星'**
  String get headerSkinMeteor;

  /// No description provided for @headerSkinMemphis.
  ///
  /// In zh, this message translates to:
  /// **'孟菲斯'**
  String get headerSkinMemphis;

  /// No description provided for @headerSkinSilk.
  ///
  /// In zh, this message translates to:
  /// **'丝带'**
  String get headerSkinSilk;

  /// No description provided for @headerSkinBubbles.
  ///
  /// In zh, this message translates to:
  /// **'气泡'**
  String get headerSkinBubbles;

  /// No description provided for @headerSkinGalaxy.
  ///
  /// In zh, this message translates to:
  /// **'星系'**
  String get headerSkinGalaxy;

  /// No description provided for @headerSkinLowPoly.
  ///
  /// In zh, this message translates to:
  /// **'低多边形'**
  String get headerSkinLowPoly;

  /// No description provided for @headerSkinPrism.
  ///
  /// In zh, this message translates to:
  /// **'棱镜'**
  String get headerSkinPrism;

  /// No description provided for @headerSkinTerrazzo.
  ///
  /// In zh, this message translates to:
  /// **'水磨石'**
  String get headerSkinTerrazzo;

  /// No description provided for @mineAvatarTitle.
  ///
  /// In zh, this message translates to:
  /// **'头像设置'**
  String get mineAvatarTitle;

  /// No description provided for @mineAvatarFromGallery.
  ///
  /// In zh, this message translates to:
  /// **'从相册选择'**
  String get mineAvatarFromGallery;

  /// No description provided for @mineAvatarFromCamera.
  ///
  /// In zh, this message translates to:
  /// **'拍照'**
  String get mineAvatarFromCamera;

  /// No description provided for @mineAvatarDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除头像'**
  String get mineAvatarDelete;

  /// No description provided for @annualReportTitle.
  ///
  /// In zh, this message translates to:
  /// **'年度账单'**
  String get annualReportTitle;

  /// No description provided for @annualReportSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'回顾你的{year}年财务足迹'**
  String annualReportSubtitle(int year);

  /// No description provided for @annualReportEntrySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'生成专属年度报告，分享你的记账故事'**
  String get annualReportEntrySubtitle;

  /// No description provided for @annualReportNoData.
  ///
  /// In zh, this message translates to:
  /// **'暂无{year}年数据'**
  String annualReportNoData(int year);

  /// No description provided for @annualReportPage1Title.
  ///
  /// In zh, this message translates to:
  /// **'年度总览'**
  String get annualReportPage1Title;

  /// No description provided for @annualReportPage1Subtitle.
  ///
  /// In zh, this message translates to:
  /// **'{year}年记账之旅'**
  String annualReportPage1Subtitle(int year);

  /// No description provided for @annualReportTotalDays.
  ///
  /// In zh, this message translates to:
  /// **'记账天数'**
  String get annualReportTotalDays;

  /// No description provided for @annualReportTotalRecords.
  ///
  /// In zh, this message translates to:
  /// **'记账笔数'**
  String get annualReportTotalRecords;

  /// No description provided for @annualReportTotalIncome.
  ///
  /// In zh, this message translates to:
  /// **'总收入'**
  String get annualReportTotalIncome;

  /// No description provided for @annualReportTotalExpense.
  ///
  /// In zh, this message translates to:
  /// **'总支出'**
  String get annualReportTotalExpense;

  /// No description provided for @annualReportNetSavings.
  ///
  /// In zh, this message translates to:
  /// **'年度结余'**
  String get annualReportNetSavings;

  /// No description provided for @annualReportPage2Title.
  ///
  /// In zh, this message translates to:
  /// **'支出分析'**
  String get annualReportPage2Title;

  /// No description provided for @annualReportPage2Subtitle.
  ///
  /// In zh, this message translates to:
  /// **'你的钱花在哪了'**
  String get annualReportPage2Subtitle;

  /// No description provided for @annualReportPage3Title.
  ///
  /// In zh, this message translates to:
  /// **'月度趋势'**
  String get annualReportPage3Title;

  /// No description provided for @annualReportPage3Subtitle.
  ///
  /// In zh, this message translates to:
  /// **'12个月的收支变化'**
  String get annualReportPage3Subtitle;

  /// No description provided for @annualReportHighestMonth.
  ///
  /// In zh, this message translates to:
  /// **'支出最高月份'**
  String get annualReportHighestMonth;

  /// No description provided for @annualReportLowestMonth.
  ///
  /// In zh, this message translates to:
  /// **'支出最低月份'**
  String get annualReportLowestMonth;

  /// No description provided for @annualReportPage4Title.
  ///
  /// In zh, this message translates to:
  /// **'特别时刻'**
  String get annualReportPage4Title;

  /// No description provided for @annualReportPage4Subtitle.
  ///
  /// In zh, this message translates to:
  /// **'那些值得铭记的账单'**
  String get annualReportPage4Subtitle;

  /// No description provided for @annualReportLargestExpense.
  ///
  /// In zh, this message translates to:
  /// **'年度最大支出'**
  String get annualReportLargestExpense;

  /// No description provided for @annualReportLargestIncome.
  ///
  /// In zh, this message translates to:
  /// **'年度最大收入'**
  String get annualReportLargestIncome;

  /// No description provided for @annualReportFirstRecord.
  ///
  /// In zh, this message translates to:
  /// **'第一笔记录'**
  String get annualReportFirstRecord;

  /// No description provided for @annualReportPage5Title.
  ///
  /// In zh, this message translates to:
  /// **'年度成就'**
  String get annualReportPage5Title;

  /// No description provided for @annualReportPage5Subtitle.
  ///
  /// In zh, this message translates to:
  /// **'你的记账成就徽章'**
  String get annualReportPage5Subtitle;

  /// No description provided for @annualReportAchievementConsistent.
  ///
  /// In zh, this message translates to:
  /// **'持之以恒'**
  String get annualReportAchievementConsistent;

  /// No description provided for @annualReportAchievementConsistentDesc.
  ///
  /// In zh, this message translates to:
  /// **'连续记账超过{days}天'**
  String annualReportAchievementConsistentDesc(int days);

  /// No description provided for @annualReportAchievementSaver.
  ///
  /// In zh, this message translates to:
  /// **'精打细算'**
  String get annualReportAchievementSaver;

  /// No description provided for @annualReportAchievementSaverDesc.
  ///
  /// In zh, this message translates to:
  /// **'年度结余为正'**
  String get annualReportAchievementSaverDesc;

  /// No description provided for @annualReportAchievementDetail.
  ///
  /// In zh, this message translates to:
  /// **'明察秋毫'**
  String get annualReportAchievementDetail;

  /// No description provided for @annualReportAchievementDetailDesc.
  ///
  /// In zh, this message translates to:
  /// **'记账笔数超过{count}笔'**
  String annualReportAchievementDetailDesc(int count);

  /// No description provided for @annualReportShareButton.
  ///
  /// In zh, this message translates to:
  /// **'生成分享海报'**
  String get annualReportShareButton;

  /// No description provided for @annualReportGenerating.
  ///
  /// In zh, this message translates to:
  /// **'正在生成年度报告...'**
  String get annualReportGenerating;

  /// No description provided for @annualReportSaveSuccess.
  ///
  /// In zh, this message translates to:
  /// **'年度报告海报已保存'**
  String get annualReportSaveSuccess;

  /// No description provided for @mineShareApp.
  ///
  /// In zh, this message translates to:
  /// **'分享应用'**
  String get mineShareApp;

  /// No description provided for @mineShareWithFriends.
  ///
  /// In zh, this message translates to:
  /// **'和好友分享智记'**
  String get mineShareWithFriends;

  /// No description provided for @mineCopyPromoText.
  ///
  /// In zh, this message translates to:
  /// **'复制推广文案'**
  String get mineCopyPromoText;

  /// No description provided for @mineCopyPromoSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'一键复制分享给好友'**
  String get mineCopyPromoSubtitle;

  /// No description provided for @mineShareGenerating.
  ///
  /// In zh, this message translates to:
  /// **'正在生成分享海报...'**
  String get mineShareGenerating;

  /// No description provided for @sharePosterAppName.
  ///
  /// In zh, this message translates to:
  /// **'智记'**
  String get sharePosterAppName;

  /// No description provided for @sharePosterSlogan.
  ///
  /// In zh, this message translates to:
  /// **'一笔一蜜，记录美好生活'**
  String get sharePosterSlogan;

  /// No description provided for @sharePosterFeature1.
  ///
  /// In zh, this message translates to:
  /// **'数据安全·你做主'**
  String get sharePosterFeature1;

  /// No description provided for @sharePosterFeature2.
  ///
  /// In zh, this message translates to:
  /// **'完全开源·可审计'**
  String get sharePosterFeature2;

  /// No description provided for @sharePosterFeature3.
  ///
  /// In zh, this message translates to:
  /// **'AI智能记账·图片语音'**
  String get sharePosterFeature3;

  /// No description provided for @sharePosterFeature4.
  ///
  /// In zh, this message translates to:
  /// **'拍照记账·自动识别'**
  String get sharePosterFeature4;

  /// No description provided for @sharePosterFeature5.
  ///
  /// In zh, this message translates to:
  /// **'多账本·暗黑模式'**
  String get sharePosterFeature5;

  /// No description provided for @sharePosterFeature6.
  ///
  /// In zh, this message translates to:
  /// **'自建云同步·永久免费'**
  String get sharePosterFeature6;

  /// No description provided for @sharePosterScanText.
  ///
  /// In zh, this message translates to:
  /// **'扫码访问开源项目'**
  String get sharePosterScanText;

  /// No description provided for @appPromoTagOpenSource.
  ///
  /// In zh, this message translates to:
  /// **'开源'**
  String get appPromoTagOpenSource;

  /// No description provided for @appPromoTagFree.
  ///
  /// In zh, this message translates to:
  /// **'免费'**
  String get appPromoTagFree;

  /// No description provided for @appPromoFooterText.
  ///
  /// In zh, this message translates to:
  /// **'让每一笔都有迹可循'**
  String get appPromoFooterText;

  /// No description provided for @userProfileJourneyYears.
  ///
  /// In zh, this message translates to:
  /// **'记账达人 {years} 年'**
  String userProfileJourneyYears(int years);

  /// No description provided for @userProfileJourneyOneYear.
  ///
  /// In zh, this message translates to:
  /// **'记账满一年'**
  String get userProfileJourneyOneYear;

  /// No description provided for @userProfileJourneyHalfYear.
  ///
  /// In zh, this message translates to:
  /// **'坚持记账半年'**
  String get userProfileJourneyHalfYear;

  /// No description provided for @userProfileJourneyThreeMonths.
  ///
  /// In zh, this message translates to:
  /// **'记账三个月'**
  String get userProfileJourneyThreeMonths;

  /// No description provided for @userProfileJourneyOneMonth.
  ///
  /// In zh, this message translates to:
  /// **'记账满一个月'**
  String get userProfileJourneyOneMonth;

  /// No description provided for @userProfileJourneyOneWeek.
  ///
  /// In zh, this message translates to:
  /// **'记账一周'**
  String get userProfileJourneyOneWeek;

  /// No description provided for @userProfileJourneyStart.
  ///
  /// In zh, this message translates to:
  /// **'开始记账之旅'**
  String get userProfileJourneyStart;

  /// No description provided for @userProfileDailyAverage.
  ///
  /// In zh, this message translates to:
  /// **'日均记账'**
  String get userProfileDailyAverage;

  /// No description provided for @sharePosterSave.
  ///
  /// In zh, this message translates to:
  /// **'保存到相册'**
  String get sharePosterSave;

  /// No description provided for @sharePosterShare.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get sharePosterShare;

  /// No description provided for @sharePosterHideIncome.
  ///
  /// In zh, this message translates to:
  /// **'隐藏收入'**
  String get sharePosterHideIncome;

  /// No description provided for @sharePosterShowIncome.
  ///
  /// In zh, this message translates to:
  /// **'显示收入'**
  String get sharePosterShowIncome;

  /// No description provided for @sharePosterSaveSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已保存到相册'**
  String get sharePosterSaveSuccess;

  /// No description provided for @shareGuidanceCopyText.
  ///
  /// In zh, this message translates to:
  /// **'用智记记录生活，开源免费无广告！🐝 下载地址：https://github.com/TNT-Likely/BeeCount'**
  String get shareGuidanceCopyText;

  /// No description provided for @shareGuidanceCopied.
  ///
  /// In zh, this message translates to:
  /// **'文案已复制'**
  String get shareGuidanceCopied;

  /// No description provided for @sharePosterSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败'**
  String get sharePosterSaveFailed;

  /// No description provided for @sharePosterPermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'相册权限被拒绝，请在设置中开启'**
  String get sharePosterPermissionDenied;

  /// No description provided for @sharePosterGenerating.
  ///
  /// In zh, this message translates to:
  /// **'生成中...'**
  String get sharePosterGenerating;

  /// No description provided for @sharePosterGenerateFailed.
  ///
  /// In zh, this message translates to:
  /// **'生成海报失败，请重试'**
  String get sharePosterGenerateFailed;

  /// No description provided for @sharePosterNoLedger.
  ///
  /// In zh, this message translates to:
  /// **'请先选择一个账本'**
  String get sharePosterNoLedger;

  /// No description provided for @sharePosterYearTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的记账年度报告'**
  String get sharePosterYearTitle;

  /// No description provided for @sharePosterYearSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'用数据记录生活 用理性规划未来'**
  String get sharePosterYearSubtitle;

  /// No description provided for @sharePosterMonthTitle.
  ///
  /// In zh, this message translates to:
  /// **'月度账单报告'**
  String get sharePosterMonthTitle;

  /// No description provided for @sharePosterMonthSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'精打细算 理性消费'**
  String get sharePosterMonthSubtitle;

  /// No description provided for @sharePosterLedgerTitle.
  ///
  /// In zh, this message translates to:
  /// **'账本统计报告'**
  String get sharePosterLedgerTitle;

  /// No description provided for @sharePosterRecordDays.
  ///
  /// In zh, this message translates to:
  /// **'记账天数'**
  String get sharePosterRecordDays;

  /// No description provided for @sharePosterRecordCount.
  ///
  /// In zh, this message translates to:
  /// **'记账笔数'**
  String get sharePosterRecordCount;

  /// No description provided for @sharePosterTotalExpense.
  ///
  /// In zh, this message translates to:
  /// **'总支出'**
  String get sharePosterTotalExpense;

  /// No description provided for @sharePosterTotalIncome.
  ///
  /// In zh, this message translates to:
  /// **'总收入'**
  String get sharePosterTotalIncome;

  /// No description provided for @sharePosterYearBalance.
  ///
  /// In zh, this message translates to:
  /// **'年度结余'**
  String get sharePosterYearBalance;

  /// No description provided for @sharePosterYearDeficit.
  ///
  /// In zh, this message translates to:
  /// **'年度赤字'**
  String get sharePosterYearDeficit;

  /// No description provided for @sharePosterMonthBalance.
  ///
  /// In zh, this message translates to:
  /// **'月度结余'**
  String get sharePosterMonthBalance;

  /// No description provided for @sharePosterBalance.
  ///
  /// In zh, this message translates to:
  /// **'总结余'**
  String get sharePosterBalance;

  /// No description provided for @sharePosterAvgMonthlyExpense.
  ///
  /// In zh, this message translates to:
  /// **'月均支出'**
  String get sharePosterAvgMonthlyExpense;

  /// No description provided for @sharePosterAvgMonthlyIncome.
  ///
  /// In zh, this message translates to:
  /// **'月均收入'**
  String get sharePosterAvgMonthlyIncome;

  /// No description provided for @sharePosterAvgDailyExpense.
  ///
  /// In zh, this message translates to:
  /// **'日均支出'**
  String get sharePosterAvgDailyExpense;

  /// No description provided for @sharePosterMaxExpenseMonth.
  ///
  /// In zh, this message translates to:
  /// **'支出最高月份'**
  String get sharePosterMaxExpenseMonth;

  /// No description provided for @sharePosterTopExpense.
  ///
  /// In zh, this message translates to:
  /// **'TOP 3 支出'**
  String get sharePosterTopExpense;

  /// No description provided for @sharePosterCompareLastMonth.
  ///
  /// In zh, this message translates to:
  /// **'环比上月'**
  String get sharePosterCompareLastMonth;

  /// No description provided for @sharePosterIncreaseRate.
  ///
  /// In zh, this message translates to:
  /// **'较上月增长'**
  String get sharePosterIncreaseRate;

  /// No description provided for @sharePosterDecreaseRate.
  ///
  /// In zh, this message translates to:
  /// **'较上月减少'**
  String get sharePosterDecreaseRate;

  /// No description provided for @sharePosterSavedMoneyTitle.
  ///
  /// In zh, this message translates to:
  /// **'恭喜！本月比上月省了'**
  String get sharePosterSavedMoneyTitle;

  /// No description provided for @sharePosterLedgerName.
  ///
  /// In zh, this message translates to:
  /// **'账本名称'**
  String get sharePosterLedgerName;

  /// No description provided for @sharePosterUnitDay.
  ///
  /// In zh, this message translates to:
  /// **'天'**
  String get sharePosterUnitDay;

  /// No description provided for @sharePosterUnitCount.
  ///
  /// In zh, this message translates to:
  /// **'笔'**
  String get sharePosterUnitCount;

  /// No description provided for @sharePosterUnitYuan.
  ///
  /// In zh, this message translates to:
  /// **'元'**
  String get sharePosterUnitYuan;

  /// No description provided for @userProfilePosterStartDate.
  ///
  /// In zh, this message translates to:
  /// **'记账始于 {date}'**
  String userProfilePosterStartDate(String date);

  /// No description provided for @userProfilePosterRecordDays.
  ///
  /// In zh, this message translates to:
  /// **'记账天数'**
  String get userProfilePosterRecordDays;

  /// No description provided for @userProfilePosterDaysUnit.
  ///
  /// In zh, this message translates to:
  /// **'天'**
  String get userProfilePosterDaysUnit;

  /// No description provided for @userProfilePosterRecordCount.
  ///
  /// In zh, this message translates to:
  /// **'记账笔数'**
  String get userProfilePosterRecordCount;

  /// No description provided for @userProfilePosterCountUnit.
  ///
  /// In zh, this message translates to:
  /// **'笔'**
  String get userProfilePosterCountUnit;

  /// No description provided for @userProfilePosterLedgerCount.
  ///
  /// In zh, this message translates to:
  /// **'账本数量'**
  String get userProfilePosterLedgerCount;

  /// No description provided for @userProfilePosterLedgerUnit.
  ///
  /// In zh, this message translates to:
  /// **'本'**
  String get userProfilePosterLedgerUnit;

  /// No description provided for @mineDaysCount.
  ///
  /// In zh, this message translates to:
  /// **'记账天数'**
  String get mineDaysCount;

  /// No description provided for @mineTotalRecords.
  ///
  /// In zh, this message translates to:
  /// **'总笔数'**
  String get mineTotalRecords;

  /// No description provided for @mineCurrentBalance.
  ///
  /// In zh, this message translates to:
  /// **'账本结余'**
  String get mineCurrentBalance;

  /// No description provided for @mineCloudService.
  ///
  /// In zh, this message translates to:
  /// **'云服务'**
  String get mineCloudService;

  /// No description provided for @mineCloudServiceLoading.
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get mineCloudServiceLoading;

  /// No description provided for @mineCloudServiceOffline.
  ///
  /// In zh, this message translates to:
  /// **'默认模式 (离线)'**
  String get mineCloudServiceOffline;

  /// No description provided for @mineCloudServiceCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义 Supabase'**
  String get mineCloudServiceCustom;

  /// No description provided for @mineCloudServiceWebDAV.
  ///
  /// In zh, this message translates to:
  /// **'自定义云服务 (WebDAV)'**
  String get mineCloudServiceWebDAV;

  /// No description provided for @mineSyncTitle.
  ///
  /// In zh, this message translates to:
  /// **'同步'**
  String get mineSyncTitle;

  /// No description provided for @mineSyncNotLoggedIn.
  ///
  /// In zh, this message translates to:
  /// **'未登录'**
  String get mineSyncNotLoggedIn;

  /// No description provided for @mineSyncNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置云端'**
  String get mineSyncNotConfigured;

  /// No description provided for @mineSyncNoRemote.
  ///
  /// In zh, this message translates to:
  /// **'云端暂无数据'**
  String get mineSyncNoRemote;

  /// No description provided for @mineSyncInSync.
  ///
  /// In zh, this message translates to:
  /// **'已同步 (本地{count}条)'**
  String mineSyncInSync(Object count);

  /// No description provided for @mineSyncInSyncSimple.
  ///
  /// In zh, this message translates to:
  /// **'已同步'**
  String get mineSyncInSyncSimple;

  /// No description provided for @mineSyncLocalNewer.
  ///
  /// In zh, this message translates to:
  /// **'本地有更新 (本地{count}条, 建议上传)'**
  String mineSyncLocalNewer(Object count);

  /// No description provided for @mineSyncLocalNewerSimple.
  ///
  /// In zh, this message translates to:
  /// **'本地有更新'**
  String get mineSyncLocalNewerSimple;

  /// No description provided for @mineSyncCloudNewer.
  ///
  /// In zh, this message translates to:
  /// **'云端有更新 (建议下载同步)'**
  String get mineSyncCloudNewer;

  /// No description provided for @mineSyncCloudNewerSimple.
  ///
  /// In zh, this message translates to:
  /// **'云端有更新'**
  String get mineSyncCloudNewerSimple;

  /// No description provided for @mineSyncDifferent.
  ///
  /// In zh, this message translates to:
  /// **'本地与云端有差异，建议下载对比'**
  String get mineSyncDifferent;

  /// No description provided for @mineSyncError.
  ///
  /// In zh, this message translates to:
  /// **'状态获取失败'**
  String get mineSyncError;

  /// No description provided for @mineSyncDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'同步状态详情'**
  String get mineSyncDetailTitle;

  /// No description provided for @mineSyncLocalRecords.
  ///
  /// In zh, this message translates to:
  /// **'本地记录数: {count}'**
  String mineSyncLocalRecords(Object count);

  /// No description provided for @mineSyncCloudRecords.
  ///
  /// In zh, this message translates to:
  /// **'云端记录数: {count}'**
  String mineSyncCloudRecords(Object count);

  /// No description provided for @mineSyncCloudLatest.
  ///
  /// In zh, this message translates to:
  /// **'云端最新记账时间: {time}'**
  String mineSyncCloudLatest(Object time);

  /// No description provided for @mineSyncLocalFingerprint.
  ///
  /// In zh, this message translates to:
  /// **'本地指纹: {fingerprint}'**
  String mineSyncLocalFingerprint(Object fingerprint);

  /// No description provided for @mineSyncCloudFingerprint.
  ///
  /// In zh, this message translates to:
  /// **'云端指纹: {fingerprint}'**
  String mineSyncCloudFingerprint(Object fingerprint);

  /// No description provided for @mineSyncMessage.
  ///
  /// In zh, this message translates to:
  /// **'说明: {message}'**
  String mineSyncMessage(Object message);

  /// No description provided for @mineUploadTitle.
  ///
  /// In zh, this message translates to:
  /// **'上传'**
  String get mineUploadTitle;

  /// No description provided for @mineUploadNeedLogin.
  ///
  /// In zh, this message translates to:
  /// **'需登录'**
  String get mineUploadNeedLogin;

  /// No description provided for @mineUploadNeedCloudService.
  ///
  /// In zh, this message translates to:
  /// **'仅限云服务模式可用'**
  String get mineUploadNeedCloudService;

  /// No description provided for @mineUploadInProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在上传中…'**
  String get mineUploadInProgress;

  /// No description provided for @mineUploadRefreshing.
  ///
  /// In zh, this message translates to:
  /// **'刷新中…'**
  String get mineUploadRefreshing;

  /// No description provided for @mineUploadSynced.
  ///
  /// In zh, this message translates to:
  /// **'已同步'**
  String get mineUploadSynced;

  /// No description provided for @mineUploadSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已上传'**
  String get mineUploadSuccess;

  /// No description provided for @mineUploadSuccessMessage.
  ///
  /// In zh, this message translates to:
  /// **'当前账本已同步到云端'**
  String get mineUploadSuccessMessage;

  /// No description provided for @mineDownloadTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载同步'**
  String get mineDownloadTitle;

  /// No description provided for @mineDownloadNeedCloudService.
  ///
  /// In zh, this message translates to:
  /// **'仅限云服务模式可用'**
  String get mineDownloadNeedCloudService;

  /// No description provided for @mineDownloadComplete.
  ///
  /// In zh, this message translates to:
  /// **'同步完成'**
  String get mineDownloadComplete;

  /// No description provided for @mineDownloadResult.
  ///
  /// In zh, this message translates to:
  /// **'导入：{inserted} 条'**
  String mineDownloadResult(Object inserted);

  /// No description provided for @mineLoginTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get mineLoginTitle;

  /// No description provided for @mineLoginSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'仅在同步时需要'**
  String get mineLoginSubtitle;

  /// No description provided for @cloudReloginTitle.
  ///
  /// In zh, this message translates to:
  /// **'重新登录'**
  String get cloudReloginTitle;

  /// No description provided for @cloudReloginSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已重新登录'**
  String get cloudReloginSuccess;

  /// No description provided for @cloudReloginFailed.
  ///
  /// In zh, this message translates to:
  /// **'重新登录失败'**
  String get cloudReloginFailed;

  /// No description provided for @mineLoggedInEmail.
  ///
  /// In zh, this message translates to:
  /// **'已登录'**
  String get mineLoggedInEmail;

  /// No description provided for @mineLogoutSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'点击可退出登录'**
  String get mineLogoutSubtitle;

  /// No description provided for @mineLogoutConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get mineLogoutConfirmTitle;

  /// No description provided for @mineLogoutConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要退出当前账号登录吗？\n退出后将无法使用云同步功能。'**
  String get mineLogoutConfirmMessage;

  /// No description provided for @mineLogoutButton.
  ///
  /// In zh, this message translates to:
  /// **'退出'**
  String get mineLogoutButton;

  /// No description provided for @mineAutoSyncTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动同步账本'**
  String get mineAutoSyncTitle;

  /// No description provided for @mineAutoSyncSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'记账后自动上传到云端'**
  String get mineAutoSyncSubtitle;

  /// No description provided for @mineAutoSyncNeedLogin.
  ///
  /// In zh, this message translates to:
  /// **'需登录后可开启'**
  String get mineAutoSyncNeedLogin;

  /// No description provided for @mineImportProgressTitle.
  ///
  /// In zh, this message translates to:
  /// **'后台导入中…'**
  String get mineImportProgressTitle;

  /// No description provided for @mineImportProgressSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'进度：{done}/{total}，成功 {ok}，失败 {fail}'**
  String mineImportProgressSubtitle(Object done, Object fail, Object ok, Object total);

  /// No description provided for @mineImportCompleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入完成'**
  String get mineImportCompleteTitle;

  /// No description provided for @mineCategoryManagement.
  ///
  /// In zh, this message translates to:
  /// **'分类管理'**
  String get mineCategoryManagement;

  /// No description provided for @mineCategoryManagementSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑自定义分类'**
  String get mineCategoryManagementSubtitle;

  /// No description provided for @mineCategoryMigration.
  ///
  /// In zh, this message translates to:
  /// **'分类迁移'**
  String get mineCategoryMigration;

  /// No description provided for @mineCategoryMigrationSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'将分类数据迁移到其他分类'**
  String get mineCategoryMigrationSubtitle;

  /// No description provided for @mineRecurringTransactions.
  ///
  /// In zh, this message translates to:
  /// **'周期账单'**
  String get mineRecurringTransactions;

  /// No description provided for @mineRecurringTransactionsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'管理周期性账单'**
  String get mineRecurringTransactionsSubtitle;

  /// No description provided for @mineReminderSettings.
  ///
  /// In zh, this message translates to:
  /// **'记账提醒'**
  String get mineReminderSettings;

  /// No description provided for @mineReminderSettingsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'设置每日记账提醒'**
  String get mineReminderSettingsSubtitle;

  /// No description provided for @minePersonalize.
  ///
  /// In zh, this message translates to:
  /// **'个性装扮'**
  String get minePersonalize;

  /// No description provided for @mineDisplayScale.
  ///
  /// In zh, this message translates to:
  /// **'显示缩放'**
  String get mineDisplayScale;

  /// No description provided for @mineDisplayScaleSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'调整文字和界面元素大小'**
  String get mineDisplayScaleSubtitle;

  /// No description provided for @mineCheckUpdate.
  ///
  /// In zh, this message translates to:
  /// **'检测更新'**
  String get mineCheckUpdate;

  /// No description provided for @mineCheckUpdateSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'正在检查最新版本'**
  String get mineCheckUpdateSubtitle;

  /// No description provided for @mineUpdateDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载更新'**
  String get mineUpdateDownload;

  /// No description provided for @mineFeedback.
  ///
  /// In zh, this message translates to:
  /// **'问题反馈'**
  String get mineFeedback;

  /// No description provided for @mineFeedbackSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'提交问题或建议'**
  String get mineFeedbackSubtitle;

  /// No description provided for @mineHelp.
  ///
  /// In zh, this message translates to:
  /// **'使用帮助'**
  String get mineHelp;

  /// No description provided for @helpCenterOpenInBrowser.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器中打开'**
  String get helpCenterOpenInBrowser;

  /// No description provided for @helpCenterLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败，请检查网络'**
  String get helpCenterLoadFailed;

  /// No description provided for @helpCenterRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get helpCenterRetry;

  /// No description provided for @mineHelpSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'查看使用文档和常见问题'**
  String get mineHelpSubtitle;

  /// No description provided for @mineSupportAuthor.
  ///
  /// In zh, this message translates to:
  /// **'给项目 Star ⭐️'**
  String get mineSupportAuthor;

  /// No description provided for @mineSupportAuthorSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'开源免费，已有 {count} 人 Star'**
  String mineSupportAuthorSubtitle(String count);

  /// No description provided for @githubStarGuideTitle.
  ///
  /// In zh, this message translates to:
  /// **'如何给项目 Star'**
  String get githubStarGuideTitle;

  /// No description provided for @githubStarGuideContent.
  ///
  /// In zh, this message translates to:
  /// **'点击下方按钮打开 GitHub 页面后，点击图中标注的位置即可完成 Star'**
  String get githubStarGuideContent;

  /// No description provided for @githubStarGuideButton.
  ///
  /// In zh, this message translates to:
  /// **'前往 GitHub'**
  String get githubStarGuideButton;

  /// No description provided for @categoryEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑分类'**
  String get categoryEditTitle;

  /// No description provided for @categoryNewTitle.
  ///
  /// In zh, this message translates to:
  /// **'新建分类'**
  String get categoryNewTitle;

  /// No description provided for @categoryDetailTooltip.
  ///
  /// In zh, this message translates to:
  /// **'分类详情'**
  String get categoryDetailTooltip;

  /// No description provided for @categoryMigrationTooltip.
  ///
  /// In zh, this message translates to:
  /// **'分类迁移'**
  String get categoryMigrationTooltip;

  /// No description provided for @categoryMigrationTitle.
  ///
  /// In zh, this message translates to:
  /// **'分类迁移'**
  String get categoryMigrationTitle;

  /// No description provided for @categoryMigrationDescription.
  ///
  /// In zh, this message translates to:
  /// **'分类迁移说明'**
  String get categoryMigrationDescription;

  /// No description provided for @categoryMigrationDescriptionContent.
  ///
  /// In zh, this message translates to:
  /// **'• 将指定分类的所有交易记录迁移到另一个分类\n• 迁移后，原分类的交易数据将全部转移到目标分类\n• 此操作不可撤销，请谨慎选择'**
  String get categoryMigrationDescriptionContent;

  /// No description provided for @categoryMigrationTypeLabel.
  ///
  /// In zh, this message translates to:
  /// **'选择类型'**
  String get categoryMigrationTypeLabel;

  /// No description provided for @categoryMigrationFromLabel.
  ///
  /// In zh, this message translates to:
  /// **'迁出分类'**
  String get categoryMigrationFromLabel;

  /// No description provided for @categoryMigrationFromHint.
  ///
  /// In zh, this message translates to:
  /// **'选择要迁出的分类'**
  String get categoryMigrationFromHint;

  /// No description provided for @categoryMigrationToLabel.
  ///
  /// In zh, this message translates to:
  /// **'迁入分类'**
  String get categoryMigrationToLabel;

  /// No description provided for @categoryMigrationToHint.
  ///
  /// In zh, this message translates to:
  /// **'选择迁入的分类'**
  String get categoryMigrationToHint;

  /// No description provided for @categoryMigrationToHintFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先选择迁出分类'**
  String get categoryMigrationToHintFirst;

  /// No description provided for @categoryMigrationStartButton.
  ///
  /// In zh, this message translates to:
  /// **'开始迁移'**
  String get categoryMigrationStartButton;

  /// No description provided for @categoryMigrationCannotTitle.
  ///
  /// In zh, this message translates to:
  /// **'无法迁移'**
  String get categoryMigrationCannotTitle;

  /// No description provided for @categoryMigrationCannotMessage.
  ///
  /// In zh, this message translates to:
  /// **'选择的分类无法进行迁移，请检查分类状态。'**
  String get categoryMigrationCannotMessage;

  /// No description provided for @categoryExpenseType.
  ///
  /// In zh, this message translates to:
  /// **'支出分类'**
  String get categoryExpenseType;

  /// No description provided for @categoryIncomeType.
  ///
  /// In zh, this message translates to:
  /// **'收入分类'**
  String get categoryIncomeType;

  /// No description provided for @categoryDefaultTitle.
  ///
  /// In zh, this message translates to:
  /// **'默认分类'**
  String get categoryDefaultTitle;

  /// No description provided for @categoryNameLabel.
  ///
  /// In zh, this message translates to:
  /// **'分类名称'**
  String get categoryNameLabel;

  /// No description provided for @categoryNameHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入分类名称'**
  String get categoryNameHint;

  /// No description provided for @categoryNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入分类名称'**
  String get categoryNameRequired;

  /// No description provided for @categoryNameTooLong.
  ///
  /// In zh, this message translates to:
  /// **'分类名称不能超过4个字'**
  String get categoryNameTooLong;

  /// No description provided for @categoryNameDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'分类名称已存在'**
  String get categoryNameDuplicate;

  /// No description provided for @categoryIconLabel.
  ///
  /// In zh, this message translates to:
  /// **'分类图标'**
  String get categoryIconLabel;

  /// No description provided for @categoryCustomIconTitle.
  ///
  /// In zh, this message translates to:
  /// **'自定义图标'**
  String get categoryCustomIconTitle;

  /// No description provided for @categoryCustomIconTapToSelect.
  ///
  /// In zh, this message translates to:
  /// **'点击选择图片'**
  String get categoryCustomIconTapToSelect;

  /// No description provided for @categoryCustomIconTapToChange.
  ///
  /// In zh, this message translates to:
  /// **'点击更换图片'**
  String get categoryCustomIconTapToChange;

  /// No description provided for @categoryCustomIconError.
  ///
  /// In zh, this message translates to:
  /// **'选择图片时出错'**
  String get categoryCustomIconError;

  /// No description provided for @categoryCustomIconRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择自定义图标图片'**
  String get categoryCustomIconRequired;

  /// No description provided for @categoryCustomIconCrop.
  ///
  /// In zh, this message translates to:
  /// **'裁剪图标'**
  String get categoryCustomIconCrop;

  /// No description provided for @categoryDangerousOperations.
  ///
  /// In zh, this message translates to:
  /// **'危险操作'**
  String get categoryDangerousOperations;

  /// No description provided for @categoryDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除分类'**
  String get categoryDeleteTitle;

  /// No description provided for @categoryDeleteSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'删除后无法恢复'**
  String get categoryDeleteSubtitle;

  /// No description provided for @categorySaveError.
  ///
  /// In zh, this message translates to:
  /// **'保存失败'**
  String get categorySaveError;

  /// No description provided for @categoryUpdated.
  ///
  /// In zh, this message translates to:
  /// **'分类\"{name}\"已更新'**
  String categoryUpdated(Object name);

  /// No description provided for @categoryCreated.
  ///
  /// In zh, this message translates to:
  /// **'分类\"{name}\"已创建'**
  String categoryCreated(Object name);

  /// No description provided for @categoryCannotDelete.
  ///
  /// In zh, this message translates to:
  /// **'无法删除'**
  String get categoryCannotDelete;

  /// No description provided for @categoryCannotDeleteMessage.
  ///
  /// In zh, this message translates to:
  /// **'该分类下还有 {count} 笔交易记录，请先处理这些记录。'**
  String categoryCannotDeleteMessage(Object count);

  /// No description provided for @categoryShare.
  ///
  /// In zh, this message translates to:
  /// **'分享分类'**
  String get categoryShare;

  /// No description provided for @categoryImport.
  ///
  /// In zh, this message translates to:
  /// **'导入分类'**
  String get categoryImport;

  /// No description provided for @categoryClearUnused.
  ///
  /// In zh, this message translates to:
  /// **'清空未使用分类'**
  String get categoryClearUnused;

  /// No description provided for @categoryClearUnusedTitle.
  ///
  /// In zh, this message translates to:
  /// **'清空未使用分类'**
  String get categoryClearUnusedTitle;

  /// No description provided for @categoryClearUnusedMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除 {count} 个未使用的分类吗？此操作无法撤销。'**
  String categoryClearUnusedMessage(int count);

  /// No description provided for @categoryClearUnusedListTitle.
  ///
  /// In zh, this message translates to:
  /// **'将被删除的分类：'**
  String get categoryClearUnusedListTitle;

  /// No description provided for @categoryClearUnusedEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有未使用的分类'**
  String get categoryClearUnusedEmpty;

  /// No description provided for @categoryClearUnusedSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已删除 {count} 个分类'**
  String categoryClearUnusedSuccess(int count);

  /// No description provided for @categoryClearUnusedFailed.
  ///
  /// In zh, this message translates to:
  /// **'清空失败'**
  String get categoryClearUnusedFailed;

  /// No description provided for @categoryShareScopeTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择分享范围'**
  String get categoryShareScopeTitle;

  /// No description provided for @categoryShareScopeExpense.
  ///
  /// In zh, this message translates to:
  /// **'仅支出分类'**
  String get categoryShareScopeExpense;

  /// No description provided for @categoryShareScopeIncome.
  ///
  /// In zh, this message translates to:
  /// **'仅收入分类'**
  String get categoryShareScopeIncome;

  /// No description provided for @categoryShareScopeAll.
  ///
  /// In zh, this message translates to:
  /// **'全部分类'**
  String get categoryShareScopeAll;

  /// No description provided for @categoryShareSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已保存到 {path}'**
  String categoryShareSuccess(String path);

  /// No description provided for @categoryShareSubject.
  ///
  /// In zh, this message translates to:
  /// **'智记 分类配置'**
  String get categoryShareSubject;

  /// No description provided for @categoryShareFailed.
  ///
  /// In zh, this message translates to:
  /// **'分享失败'**
  String get categoryShareFailed;

  /// No description provided for @categoryImportInvalidFile.
  ///
  /// In zh, this message translates to:
  /// **'请选择分类包文件（.zip）'**
  String get categoryImportInvalidFile;

  /// No description provided for @categoryImportModeTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择导入模式'**
  String get categoryImportModeTitle;

  /// No description provided for @categoryImportModeMerge.
  ///
  /// In zh, this message translates to:
  /// **'合并'**
  String get categoryImportModeMerge;

  /// No description provided for @categoryImportModeMergeDesc.
  ///
  /// In zh, this message translates to:
  /// **'保留现有分类，新增不存在的'**
  String get categoryImportModeMergeDesc;

  /// No description provided for @categoryImportModeOverwrite.
  ///
  /// In zh, this message translates to:
  /// **'覆盖'**
  String get categoryImportModeOverwrite;

  /// No description provided for @categoryImportModeOverwriteDesc.
  ///
  /// In zh, this message translates to:
  /// **'清空未使用分类后导入'**
  String get categoryImportModeOverwriteDesc;

  /// No description provided for @categoryImportSuccess.
  ///
  /// In zh, this message translates to:
  /// **'导入成功'**
  String get categoryImportSuccess;

  /// No description provided for @categoryImportSuccessDetail.
  ///
  /// In zh, this message translates to:
  /// **'已导入 {imported} 个分类，跳过 {skipped} 个，导入 {icons} 个图标'**
  String categoryImportSuccessDetail(int imported, int skipped, int icons);

  /// No description provided for @categoryImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导入失败'**
  String get categoryImportFailed;

  /// No description provided for @categoryDeleteConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除分类'**
  String get categoryDeleteConfirmTitle;

  /// No description provided for @categoryDeleteConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除分类\"{name}\"吗？此操作无法撤销。'**
  String categoryDeleteConfirmMessage(Object name);

  /// No description provided for @categoryDeleteError.
  ///
  /// In zh, this message translates to:
  /// **'删除失败'**
  String get categoryDeleteError;

  /// No description provided for @categoryDeleted.
  ///
  /// In zh, this message translates to:
  /// **'分类\"{name}\"已删除'**
  String categoryDeleted(Object name);

  /// No description provided for @categorySubCategoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'二级分类'**
  String get categorySubCategoryTitle;

  /// No description provided for @categorySubCategoryDescriptionEnabled.
  ///
  /// In zh, this message translates to:
  /// **'此分类属于某个一级分类'**
  String get categorySubCategoryDescriptionEnabled;

  /// No description provided for @categorySubCategoryDescriptionDisabled.
  ///
  /// In zh, this message translates to:
  /// **'此分类为独立的一级分类'**
  String get categorySubCategoryDescriptionDisabled;

  /// No description provided for @categoryParentCategoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'父分类'**
  String get categoryParentCategoryTitle;

  /// No description provided for @categoryParentCategoryHint.
  ///
  /// In zh, this message translates to:
  /// **'请选择父分类'**
  String get categoryParentCategoryHint;

  /// No description provided for @categorySelectParentTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择父分类'**
  String get categorySelectParentTitle;

  /// No description provided for @categorySubCategoryCreated.
  ///
  /// In zh, this message translates to:
  /// **'已添加二级分类：{name}'**
  String categorySubCategoryCreated(Object name);

  /// No description provided for @categoryParentRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择父分类'**
  String get categoryParentRequired;

  /// No description provided for @categoryParentRequiredTitle.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get categoryParentRequiredTitle;

  /// No description provided for @categoryExpenseList.
  ///
  /// In zh, this message translates to:
  /// **'餐饮-交通-购物-娱乐-居家-家庭-通讯-水电-住房-医疗-教育-宠物-运动-数码-旅行-烟酒-母婴-美容-维修-社交-学习-汽车-打车-地铁-外卖-物业-停车-捐赠-送礼-纳税-饮料-服装-零食-发红包-水果-游戏-书-爱人-装修-日用品-彩票-股票-社保-快递-工作'**
  String get categoryExpenseList;

  /// No description provided for @categoryIncomeList.
  ///
  /// In zh, this message translates to:
  /// **'工资-理财-收红包-奖金-报销-兼职-收礼-利息-退款-投资收益-二手转卖-社会保障-退税退费-公积金'**
  String get categoryIncomeList;

  /// No description provided for @categoryExpenseDining.
  ///
  /// In zh, this message translates to:
  /// **'餐饮-早餐-午餐-晚餐-美团外卖-饿了么外卖-京东外卖-餐厅-美食'**
  String get categoryExpenseDining;

  /// No description provided for @categoryExpenseSnacks.
  ///
  /// In zh, this message translates to:
  /// **'零食-饼干-薯片-糖果-巧克力-坚果'**
  String get categoryExpenseSnacks;

  /// No description provided for @categoryExpenseFruit.
  ///
  /// In zh, this message translates to:
  /// **'水果-苹果-香蕉-橙子-葡萄-西瓜-其他水果'**
  String get categoryExpenseFruit;

  /// No description provided for @categoryExpenseBeverage.
  ///
  /// In zh, this message translates to:
  /// **'饮品-奶茶-咖啡-果汁-汽水-矿泉水'**
  String get categoryExpenseBeverage;

  /// No description provided for @categoryExpensePastry.
  ///
  /// In zh, this message translates to:
  /// **'糕点-蛋糕-面包-甜点-曲奇'**
  String get categoryExpensePastry;

  /// No description provided for @categoryExpenseCooking.
  ///
  /// In zh, this message translates to:
  /// **'做饭食材-蔬菜-肉类-水产-调料-粮油'**
  String get categoryExpenseCooking;

  /// No description provided for @categoryExpenseShopping.
  ///
  /// In zh, this message translates to:
  /// **'购物-服装-鞋帽-包包-配饰-日用百货'**
  String get categoryExpenseShopping;

  /// No description provided for @categoryExpensePets.
  ///
  /// In zh, this message translates to:
  /// **'宠物-宠物食品-宠物用品-宠物医疗-宠物美容'**
  String get categoryExpensePets;

  /// No description provided for @categoryExpenseTransport.
  ///
  /// In zh, this message translates to:
  /// **'交通-地铁-公交-出租车-网约车-停车费-加油'**
  String get categoryExpenseTransport;

  /// No description provided for @categoryExpenseCar.
  ///
  /// In zh, this message translates to:
  /// **'汽车-汽车保养-汽车维修-汽车保险-洗车-违章罚款'**
  String get categoryExpenseCar;

  /// No description provided for @categoryExpenseClothing.
  ///
  /// In zh, this message translates to:
  /// **'服饰-上衣-裤子-裙子-鞋子-服饰配件'**
  String get categoryExpenseClothing;

  /// No description provided for @categoryExpenseDailyGoods.
  ///
  /// In zh, this message translates to:
  /// **'日用品-洗护用品-纸品-清洁用品-厨房用品'**
  String get categoryExpenseDailyGoods;

  /// No description provided for @categoryExpenseEducation.
  ///
  /// In zh, this message translates to:
  /// **'教育-学费-培训费-书籍-文具-办公用品'**
  String get categoryExpenseEducation;

  /// No description provided for @categoryExpenseInvestLoss.
  ///
  /// In zh, this message translates to:
  /// **'投资亏损-股票亏损-基金亏损-其他投资亏损'**
  String get categoryExpenseInvestLoss;

  /// No description provided for @categoryExpenseEntertainment.
  ///
  /// In zh, this message translates to:
  /// **'娱乐-电影-KTV-游乐场-酒吧-其他娱乐'**
  String get categoryExpenseEntertainment;

  /// No description provided for @categoryExpenseGame.
  ///
  /// In zh, this message translates to:
  /// **'游戏-游戏充值-游戏装备-游戏会员'**
  String get categoryExpenseGame;

  /// No description provided for @categoryExpenseHealthProducts.
  ///
  /// In zh, this message translates to:
  /// **'保健品-维生素-保健食品-营养品'**
  String get categoryExpenseHealthProducts;

  /// No description provided for @categoryExpenseSubscription.
  ///
  /// In zh, this message translates to:
  /// **'订阅服务-视频会员-音乐会员-云存储-其他订阅'**
  String get categoryExpenseSubscription;

  /// No description provided for @categoryExpenseSports.
  ///
  /// In zh, this message translates to:
  /// **'运动-健身房-运动装备-运动课程-户外活动'**
  String get categoryExpenseSports;

  /// No description provided for @categoryExpenseHousing.
  ///
  /// In zh, this message translates to:
  /// **'住房-房租-物业费-房贷-装修'**
  String get categoryExpenseHousing;

  /// No description provided for @categoryExpenseHome.
  ///
  /// In zh, this message translates to:
  /// **'居家-家具-家电-装饰品-床上用品'**
  String get categoryExpenseHome;

  /// No description provided for @categoryExpenseBeauty.
  ///
  /// In zh, this message translates to:
  /// **'美容-护肤品-化妆品-美容美发-美甲'**
  String get categoryExpenseBeauty;

  /// No description provided for @categoryIncomeSalary.
  ///
  /// In zh, this message translates to:
  /// **'工资-基本工资-绩效奖金-年终奖-加班费'**
  String get categoryIncomeSalary;

  /// No description provided for @categoryIncomeInvestment.
  ///
  /// In zh, this message translates to:
  /// **'理财-基金收益-股票分红-理财产品-其他理财'**
  String get categoryIncomeInvestment;

  /// No description provided for @categoryIncomeRedPacket.
  ///
  /// In zh, this message translates to:
  /// **'红包-节日红包-生日红包-随礼回礼'**
  String get categoryIncomeRedPacket;

  /// No description provided for @categoryIncomeBonus.
  ///
  /// In zh, this message translates to:
  /// **'奖金-年度奖金-季度奖-项目奖金-其他奖金'**
  String get categoryIncomeBonus;

  /// No description provided for @categoryIncomeReimbursement.
  ///
  /// In zh, this message translates to:
  /// **'报销-差旅报销-餐费报销-其他报销'**
  String get categoryIncomeReimbursement;

  /// No description provided for @categoryIncomePartTime.
  ///
  /// In zh, this message translates to:
  /// **'兼职-兼职收入-外快'**
  String get categoryIncomePartTime;

  /// No description provided for @categoryIncomeGift.
  ///
  /// In zh, this message translates to:
  /// **'礼金-结婚礼金-生日礼金-其他礼金'**
  String get categoryIncomeGift;

  /// No description provided for @categoryIncomeInterest.
  ///
  /// In zh, this message translates to:
  /// **'利息-银行利息-其他利息'**
  String get categoryIncomeInterest;

  /// No description provided for @categoryIncomeRefund.
  ///
  /// In zh, this message translates to:
  /// **'退款-购物退款-服务退款-其他退款'**
  String get categoryIncomeRefund;

  /// No description provided for @categoryIncomeInvestIncome.
  ///
  /// In zh, this message translates to:
  /// **'投资收益-股票收益-基金投资-其他投资收益'**
  String get categoryIncomeInvestIncome;

  /// No description provided for @categoryIncomeSecondHand.
  ///
  /// In zh, this message translates to:
  /// **'二手交易-闲置物品-二手商品'**
  String get categoryIncomeSecondHand;

  /// No description provided for @categoryIncomeSocialBenefit.
  ///
  /// In zh, this message translates to:
  /// **'社会福利-失业保险-生育津贴-其他补贴'**
  String get categoryIncomeSocialBenefit;

  /// No description provided for @categoryIncomeTaxRefund.
  ///
  /// In zh, this message translates to:
  /// **'退税-个税退税-其他退费'**
  String get categoryIncomeTaxRefund;

  /// No description provided for @categoryIncomeProvidentFund.
  ///
  /// In zh, this message translates to:
  /// **'公积金-公积金提取-公积金利息'**
  String get categoryIncomeProvidentFund;

  /// No description provided for @personalizeTitle.
  ///
  /// In zh, this message translates to:
  /// **'主题色'**
  String get personalizeTitle;

  /// No description provided for @personalizeSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'选择或自定义应用主题色'**
  String get personalizeSubtitle;

  /// No description provided for @personalizeCustomColor.
  ///
  /// In zh, this message translates to:
  /// **'选择自定义颜色'**
  String get personalizeCustomColor;

  /// No description provided for @personalizeCustomTitle.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get personalizeCustomTitle;

  /// No description provided for @personalizeHue.
  ///
  /// In zh, this message translates to:
  /// **'色相 ({value}°)'**
  String personalizeHue(Object value);

  /// No description provided for @personalizeSaturation.
  ///
  /// In zh, this message translates to:
  /// **'饱和度 ({value}%)'**
  String personalizeSaturation(Object value);

  /// No description provided for @personalizeBrightness.
  ///
  /// In zh, this message translates to:
  /// **'亮度 ({value}%)'**
  String personalizeBrightness(Object value);

  /// No description provided for @personalizeSelectColor.
  ///
  /// In zh, this message translates to:
  /// **'选择此颜色'**
  String get personalizeSelectColor;

  /// No description provided for @appearanceThemeMode.
  ///
  /// In zh, this message translates to:
  /// **'外观模式'**
  String get appearanceThemeMode;

  /// No description provided for @appearanceThemeModeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get appearanceThemeModeSystem;

  /// No description provided for @appearanceThemeModeLight.
  ///
  /// In zh, this message translates to:
  /// **'亮色模式'**
  String get appearanceThemeModeLight;

  /// No description provided for @appearanceThemeModeDark.
  ///
  /// In zh, this message translates to:
  /// **'暗黑模式'**
  String get appearanceThemeModeDark;

  /// No description provided for @appearanceDarkModePattern.
  ///
  /// In zh, this message translates to:
  /// **'暗黑模式头部图案'**
  String get appearanceDarkModePattern;

  /// No description provided for @appearancePatternNone.
  ///
  /// In zh, this message translates to:
  /// **'无'**
  String get appearancePatternNone;

  /// No description provided for @appearancePatternIcons.
  ///
  /// In zh, this message translates to:
  /// **'图标平铺'**
  String get appearancePatternIcons;

  /// No description provided for @appearancePatternParticles.
  ///
  /// In zh, this message translates to:
  /// **'粒子星星'**
  String get appearancePatternParticles;

  /// No description provided for @appearancePatternHoneycomb.
  ///
  /// In zh, this message translates to:
  /// **'蜂巢六边形'**
  String get appearancePatternHoneycomb;

  /// No description provided for @appearanceAmountFormat.
  ///
  /// In zh, this message translates to:
  /// **'余额显示格式'**
  String get appearanceAmountFormat;

  /// No description provided for @appearanceAmountFormatFull.
  ///
  /// In zh, this message translates to:
  /// **'完整金额'**
  String get appearanceAmountFormatFull;

  /// No description provided for @appearanceAmountFormatFullDesc.
  ///
  /// In zh, this message translates to:
  /// **'显示完整金额，如 123,456.78'**
  String get appearanceAmountFormatFullDesc;

  /// No description provided for @appearanceAmountFormatCompact.
  ///
  /// In zh, this message translates to:
  /// **'简洁显示'**
  String get appearanceAmountFormatCompact;

  /// No description provided for @appearanceAmountFormatCompactDesc.
  ///
  /// In zh, this message translates to:
  /// **'大金额缩写，如 12.3万（仅对账户余额生效）'**
  String get appearanceAmountFormatCompactDesc;

  /// No description provided for @appearanceSkinAnimation.
  ///
  /// In zh, this message translates to:
  /// **'皮肤动效'**
  String get appearanceSkinAnimation;

  /// No description provided for @appearanceSkinAnimationDesc.
  ///
  /// In zh, this message translates to:
  /// **'关闭后动态皮肤停在静止画面，更省电'**
  String get appearanceSkinAnimationDesc;

  /// No description provided for @appearanceShowTransactionTime.
  ///
  /// In zh, this message translates to:
  /// **'显示交易时间'**
  String get appearanceShowTransactionTime;

  /// No description provided for @appearanceShowTransactionTimeDesc.
  ///
  /// In zh, this message translates to:
  /// **'在账单列表显示时分，编辑时可选择时间'**
  String get appearanceShowTransactionTimeDesc;

  /// No description provided for @appearanceNoteDisplay.
  ///
  /// In zh, this message translates to:
  /// **'备注显示方式'**
  String get appearanceNoteDisplay;

  /// No description provided for @appearanceNoteDisplayCategory.
  ///
  /// In zh, this message translates to:
  /// **'分类优先'**
  String get appearanceNoteDisplayCategory;

  /// No description provided for @appearanceNoteDisplayCategoryDesc.
  ///
  /// In zh, this message translates to:
  /// **'显示分类名,备注以括号附在后面'**
  String get appearanceNoteDisplayCategoryDesc;

  /// No description provided for @appearanceNoteDisplayNote.
  ///
  /// In zh, this message translates to:
  /// **'备注优先'**
  String get appearanceNoteDisplayNote;

  /// No description provided for @appearanceNoteDisplayNoteDesc.
  ///
  /// In zh, this message translates to:
  /// **'有备注时显示备注,无备注时显示分类名'**
  String get appearanceNoteDisplayNoteDesc;

  /// No description provided for @appearanceNoteHistory.
  ///
  /// In zh, this message translates to:
  /// **'历史备注'**
  String get appearanceNoteHistory;

  /// No description provided for @appearanceNoteHistoryScope.
  ///
  /// In zh, this message translates to:
  /// **'展示范围'**
  String get appearanceNoteHistoryScope;

  /// No description provided for @appearanceNoteHistoryScopeAllCategories.
  ///
  /// In zh, this message translates to:
  /// **'全部分类'**
  String get appearanceNoteHistoryScopeAllCategories;

  /// No description provided for @appearanceNoteHistoryScopeCurrentCategory.
  ///
  /// In zh, this message translates to:
  /// **'当前分类'**
  String get appearanceNoteHistoryScopeCurrentCategory;

  /// No description provided for @appearanceNoteHistorySort.
  ///
  /// In zh, this message translates to:
  /// **'排序方式'**
  String get appearanceNoteHistorySort;

  /// No description provided for @appearanceNoteHistorySortFrequency.
  ///
  /// In zh, this message translates to:
  /// **'使用频次'**
  String get appearanceNoteHistorySortFrequency;

  /// No description provided for @appearanceNoteHistorySortRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近使用'**
  String get appearanceNoteHistorySortRecent;

  /// No description provided for @appearanceNoteHistoryLimit.
  ///
  /// In zh, this message translates to:
  /// **'显示数量'**
  String get appearanceNoteHistoryLimit;

  /// No description provided for @appearanceNoteHistoryLimitHint.
  ///
  /// In zh, this message translates to:
  /// **'可设置 1 至 100 条'**
  String get appearanceNoteHistoryLimitHint;

  /// No description provided for @appearanceNoteHistoryLimitInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入 1 至 100 的整数'**
  String get appearanceNoteHistoryLimitInvalid;

  /// No description provided for @appearanceColorScheme.
  ///
  /// In zh, this message translates to:
  /// **'收支颜色方案'**
  String get appearanceColorScheme;

  /// No description provided for @appearanceColorSchemeOn.
  ///
  /// In zh, this message translates to:
  /// **'红色收入 · 绿色支出'**
  String get appearanceColorSchemeOn;

  /// No description provided for @appearanceColorSchemeOff.
  ///
  /// In zh, this message translates to:
  /// **'红色支出 · 绿色收入'**
  String get appearanceColorSchemeOff;

  /// No description provided for @appearanceColorSchemeOnDesc.
  ///
  /// In zh, this message translates to:
  /// **'红色表示收入，绿色表示支出'**
  String get appearanceColorSchemeOnDesc;

  /// No description provided for @appearanceColorSchemeOffDesc.
  ///
  /// In zh, this message translates to:
  /// **'红色表示支出，绿色表示收入'**
  String get appearanceColorSchemeOffDesc;

  /// No description provided for @fontSettingsCurrentScale.
  ///
  /// In zh, this message translates to:
  /// **'当前缩放：x{scale}'**
  String fontSettingsCurrentScale(Object scale);

  /// No description provided for @fontSettingsPreview.
  ///
  /// In zh, this message translates to:
  /// **'实时预览'**
  String get fontSettingsPreview;

  /// No description provided for @fontSettingsPreviewText.
  ///
  /// In zh, this message translates to:
  /// **'今天吃饭花了 23.50 元，记一笔；\n本月已记账 45 天，共 320 条记录；\n坚持就是胜利！'**
  String get fontSettingsPreviewText;

  /// No description provided for @fontSettingsCurrentLevel.
  ///
  /// In zh, this message translates to:
  /// **'当前档位：{level}  (倍率 x{scale})'**
  String fontSettingsCurrentLevel(Object level, Object scale);

  /// No description provided for @fontSettingsQuickLevel.
  ///
  /// In zh, this message translates to:
  /// **'快速档位'**
  String get fontSettingsQuickLevel;

  /// No description provided for @fontSettingsCustomAdjust.
  ///
  /// In zh, this message translates to:
  /// **'自定义调整'**
  String get fontSettingsCustomAdjust;

  /// No description provided for @fontSettingsDescription.
  ///
  /// In zh, this message translates to:
  /// **'说明：此设置确保所有设备在1.0倍时显示效果一致，设备差异已自动补偿；调整数值可在一致基础上进行个性化缩放。'**
  String get fontSettingsDescription;

  /// No description provided for @fontSettingsExtraSmall.
  ///
  /// In zh, this message translates to:
  /// **'极小'**
  String get fontSettingsExtraSmall;

  /// No description provided for @fontSettingsVerySmall.
  ///
  /// In zh, this message translates to:
  /// **'很小'**
  String get fontSettingsVerySmall;

  /// No description provided for @fontSettingsSmall.
  ///
  /// In zh, this message translates to:
  /// **'较小'**
  String get fontSettingsSmall;

  /// No description provided for @fontSettingsStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get fontSettingsStandard;

  /// No description provided for @fontSettingsLarge.
  ///
  /// In zh, this message translates to:
  /// **'较大'**
  String get fontSettingsLarge;

  /// No description provided for @fontSettingsBig.
  ///
  /// In zh, this message translates to:
  /// **'大'**
  String get fontSettingsBig;

  /// No description provided for @fontSettingsVeryBig.
  ///
  /// In zh, this message translates to:
  /// **'很大'**
  String get fontSettingsVeryBig;

  /// No description provided for @fontSettingsExtraBig.
  ///
  /// In zh, this message translates to:
  /// **'极大'**
  String get fontSettingsExtraBig;

  /// No description provided for @fontSettingsMoreStyles.
  ///
  /// In zh, this message translates to:
  /// **'更多风格'**
  String get fontSettingsMoreStyles;

  /// No description provided for @fontSettingsPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'页面标题'**
  String get fontSettingsPageTitle;

  /// No description provided for @fontSettingsBlockTitle.
  ///
  /// In zh, this message translates to:
  /// **'区块标题'**
  String get fontSettingsBlockTitle;

  /// No description provided for @fontSettingsBodyExample.
  ///
  /// In zh, this message translates to:
  /// **'正文示例'**
  String get fontSettingsBodyExample;

  /// No description provided for @fontSettingsLabelExample.
  ///
  /// In zh, this message translates to:
  /// **'标签说明'**
  String get fontSettingsLabelExample;

  /// No description provided for @fontSettingsStrongNumber.
  ///
  /// In zh, this message translates to:
  /// **'强调数字'**
  String get fontSettingsStrongNumber;

  /// No description provided for @fontSettingsListTitle.
  ///
  /// In zh, this message translates to:
  /// **'列表项标题'**
  String get fontSettingsListTitle;

  /// No description provided for @fontSettingsListSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'辅助说明文本'**
  String get fontSettingsListSubtitle;

  /// No description provided for @fontSettingsScreenInfo.
  ///
  /// In zh, this message translates to:
  /// **'屏幕适配信息'**
  String get fontSettingsScreenInfo;

  /// No description provided for @fontSettingsScreenDensity.
  ///
  /// In zh, this message translates to:
  /// **'屏幕密度'**
  String get fontSettingsScreenDensity;

  /// No description provided for @fontSettingsScreenWidth.
  ///
  /// In zh, this message translates to:
  /// **'屏幕宽度'**
  String get fontSettingsScreenWidth;

  /// No description provided for @fontSettingsDeviceScale.
  ///
  /// In zh, this message translates to:
  /// **'设备缩放'**
  String get fontSettingsDeviceScale;

  /// No description provided for @fontSettingsUserScale.
  ///
  /// In zh, this message translates to:
  /// **'用户缩放'**
  String get fontSettingsUserScale;

  /// No description provided for @fontSettingsFinalScale.
  ///
  /// In zh, this message translates to:
  /// **'最终缩放'**
  String get fontSettingsFinalScale;

  /// No description provided for @fontSettingsBaseDevice.
  ///
  /// In zh, this message translates to:
  /// **'基准设备'**
  String get fontSettingsBaseDevice;

  /// No description provided for @fontSettingsRecommendedScale.
  ///
  /// In zh, this message translates to:
  /// **'推荐缩放'**
  String get fontSettingsRecommendedScale;

  /// No description provided for @fontSettingsYes.
  ///
  /// In zh, this message translates to:
  /// **'是'**
  String get fontSettingsYes;

  /// No description provided for @fontSettingsNo.
  ///
  /// In zh, this message translates to:
  /// **'否'**
  String get fontSettingsNo;

  /// No description provided for @fontSettingsScaleExample.
  ///
  /// In zh, this message translates to:
  /// **'此方框和间距会根据设备自动缩放'**
  String get fontSettingsScaleExample;

  /// No description provided for @fontSettingsPreciseAdjust.
  ///
  /// In zh, this message translates to:
  /// **'精确调整'**
  String get fontSettingsPreciseAdjust;

  /// No description provided for @fontSettingsResetTo1x.
  ///
  /// In zh, this message translates to:
  /// **'重置到1.0x'**
  String get fontSettingsResetTo1x;

  /// No description provided for @fontSettingsAdaptBase.
  ///
  /// In zh, this message translates to:
  /// **'适配基准'**
  String get fontSettingsAdaptBase;

  /// No description provided for @reminderTitle.
  ///
  /// In zh, this message translates to:
  /// **'记账提醒'**
  String get reminderTitle;

  /// No description provided for @reminderSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'设置每日记账提醒时间'**
  String get reminderSubtitle;

  /// No description provided for @reminderDailyTitle.
  ///
  /// In zh, this message translates to:
  /// **'每日记账提醒'**
  String get reminderDailyTitle;

  /// No description provided for @reminderDailySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'开启后将在指定时间提醒您记账'**
  String get reminderDailySubtitle;

  /// No description provided for @reminderTimeTitle.
  ///
  /// In zh, this message translates to:
  /// **'提醒时间'**
  String get reminderTimeTitle;

  /// No description provided for @commonSelectTime.
  ///
  /// In zh, this message translates to:
  /// **'选择时间'**
  String get commonSelectTime;

  /// No description provided for @reminderTestNotification.
  ///
  /// In zh, this message translates to:
  /// **'发送测试通知'**
  String get reminderTestNotification;

  /// No description provided for @reminderTestSent.
  ///
  /// In zh, this message translates to:
  /// **'测试通知已发送'**
  String get reminderTestSent;

  /// No description provided for @reminderTestTitle.
  ///
  /// In zh, this message translates to:
  /// **'测试通知'**
  String get reminderTestTitle;

  /// No description provided for @reminderTestBody.
  ///
  /// In zh, this message translates to:
  /// **'这是一条测试通知，点击查看效果'**
  String get reminderTestBody;

  /// No description provided for @reminderCheckBattery.
  ///
  /// In zh, this message translates to:
  /// **'检查电池优化状态'**
  String get reminderCheckBattery;

  /// No description provided for @reminderBatteryStatus.
  ///
  /// In zh, this message translates to:
  /// **'电池优化状态'**
  String get reminderBatteryStatus;

  /// No description provided for @reminderManufacturer.
  ///
  /// In zh, this message translates to:
  /// **'设备制造商: {value}'**
  String reminderManufacturer(Object value);

  /// No description provided for @reminderModel.
  ///
  /// In zh, this message translates to:
  /// **'设备型号: {value}'**
  String reminderModel(Object value);

  /// No description provided for @reminderAndroidVersion.
  ///
  /// In zh, this message translates to:
  /// **'Android版本: {value}'**
  String reminderAndroidVersion(Object value);

  /// No description provided for @reminderBatteryIgnored.
  ///
  /// In zh, this message translates to:
  /// **'电池优化状态: 已忽略 ✅'**
  String get reminderBatteryIgnored;

  /// No description provided for @reminderBatteryNotIgnored.
  ///
  /// In zh, this message translates to:
  /// **'电池优化状态: 未忽略 ⚠️'**
  String get reminderBatteryNotIgnored;

  /// No description provided for @reminderBatteryAdvice.
  ///
  /// In zh, this message translates to:
  /// **'建议关闭电池优化以确保通知正常工作'**
  String get reminderBatteryAdvice;

  /// No description provided for @reminderCheckChannel.
  ///
  /// In zh, this message translates to:
  /// **'检查通知渠道设置'**
  String get reminderCheckChannel;

  /// No description provided for @reminderChannelStatus.
  ///
  /// In zh, this message translates to:
  /// **'通知渠道状态'**
  String get reminderChannelStatus;

  /// No description provided for @reminderChannelEnabled.
  ///
  /// In zh, this message translates to:
  /// **'渠道启用: 是 ✅'**
  String get reminderChannelEnabled;

  /// No description provided for @reminderChannelDisabled.
  ///
  /// In zh, this message translates to:
  /// **'渠道启用: 否 ❌'**
  String get reminderChannelDisabled;

  /// No description provided for @reminderChannelImportance.
  ///
  /// In zh, this message translates to:
  /// **'重要性: {value}'**
  String reminderChannelImportance(Object value);

  /// No description provided for @reminderChannelSoundOn.
  ///
  /// In zh, this message translates to:
  /// **'声音: 开启 🔊'**
  String get reminderChannelSoundOn;

  /// No description provided for @reminderChannelSoundOff.
  ///
  /// In zh, this message translates to:
  /// **'声音: 关闭 🔇'**
  String get reminderChannelSoundOff;

  /// No description provided for @reminderChannelVibrationOn.
  ///
  /// In zh, this message translates to:
  /// **'震动: 开启 📳'**
  String get reminderChannelVibrationOn;

  /// No description provided for @reminderChannelVibrationOff.
  ///
  /// In zh, this message translates to:
  /// **'震动: 关闭'**
  String get reminderChannelVibrationOff;

  /// No description provided for @reminderChannelDndBypass.
  ///
  /// In zh, this message translates to:
  /// **'勿扰模式: 可绕过'**
  String get reminderChannelDndBypass;

  /// No description provided for @reminderChannelDndNoBypass.
  ///
  /// In zh, this message translates to:
  /// **'勿扰模式: 不可绕过'**
  String get reminderChannelDndNoBypass;

  /// No description provided for @reminderChannelAdvice.
  ///
  /// In zh, this message translates to:
  /// **'⚠️ 建议设置：'**
  String get reminderChannelAdvice;

  /// No description provided for @reminderChannelAdviceImportance.
  ///
  /// In zh, this message translates to:
  /// **'• 重要性：紧急或高'**
  String get reminderChannelAdviceImportance;

  /// No description provided for @reminderChannelAdviceSound.
  ///
  /// In zh, this message translates to:
  /// **'• 开启声音和震动'**
  String get reminderChannelAdviceSound;

  /// No description provided for @reminderChannelAdviceBanner.
  ///
  /// In zh, this message translates to:
  /// **'• 允许横幅通知'**
  String get reminderChannelAdviceBanner;

  /// No description provided for @reminderChannelAdviceXiaomi.
  ///
  /// In zh, this message translates to:
  /// **'• 小米手机需单独设置每个渠道'**
  String get reminderChannelAdviceXiaomi;

  /// No description provided for @reminderChannelGood.
  ///
  /// In zh, this message translates to:
  /// **'✅ 通知渠道配置良好'**
  String get reminderChannelGood;

  /// No description provided for @reminderOpenAppSettings.
  ///
  /// In zh, this message translates to:
  /// **'打开应用设置'**
  String get reminderOpenAppSettings;

  /// No description provided for @reminderAppSettingsMessage.
  ///
  /// In zh, this message translates to:
  /// **'请在设置中允许通知、关闭电池优化'**
  String get reminderAppSettingsMessage;

  /// No description provided for @reminderDescription.
  ///
  /// In zh, this message translates to:
  /// **'提示：开启记账提醒后，系统会在每天指定时间发送通知提醒您记录收支。'**
  String get reminderDescription;

  /// No description provided for @reminderIOSInstructions.
  ///
  /// In zh, this message translates to:
  /// **'🍎 iOS通知设置：\n• 设置 > 通知 > 智记\n• 开启\"允许通知\"\n• 设置通知样式：横幅或提醒\n• 开启声音和震动\n\n⚠️ 重要提示：\n• iOS本地通知依赖应用进程\n• 请勿在任务管理器中划掉应用\n• 应用在后台或前台时通知正常\n• 完全关闭应用会导致通知失效\n\n💡 使用建议：\n• 日常使用后直接按Home键退出\n• iOS会自动管理后台应用\n• 保持应用在后台即可收到提醒'**
  String get reminderIOSInstructions;

  /// No description provided for @reminderAndroidInstructions.
  ///
  /// In zh, this message translates to:
  /// **'如果通知无法正常工作，请检查：\n• 已允许应用发送通知\n• 关闭应用的电池优化/省电模式\n• 允许应用在后台运行和自启动\n• Android 12+需要精确闹钟权限\n\n📱 小米手机特殊设置：\n• 设置 > 应用管理 > 智记 > 通知管理\n• 点击\"记账提醒\"渠道\n• 设置重要性为\"紧急\"或\"高\"\n• 开启\"横幅通知\"、\"声音\"、\"震动\"\n• 安全中心 > 应用管理 > 权限 > 自启动\n\n🔒 锁定后台方法：\n• 最近任务中找到智记\n• 向下拉动应用卡片显示锁定图标\n• 点击锁定图标防止被清理'**
  String get reminderAndroidInstructions;

  /// No description provided for @categoryDetailLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get categoryDetailLoadFailed;

  /// No description provided for @categoryDetailSummaryTitle.
  ///
  /// In zh, this message translates to:
  /// **'分类汇总'**
  String get categoryDetailSummaryTitle;

  /// No description provided for @categoryDetailTotalCount.
  ///
  /// In zh, this message translates to:
  /// **'总笔数'**
  String get categoryDetailTotalCount;

  /// No description provided for @categoryDetailTotalAmount.
  ///
  /// In zh, this message translates to:
  /// **'总金额'**
  String get categoryDetailTotalAmount;

  /// No description provided for @categoryDetailAverageAmount.
  ///
  /// In zh, this message translates to:
  /// **'平均金额'**
  String get categoryDetailAverageAmount;

  /// No description provided for @categoryDetailSortTitle.
  ///
  /// In zh, this message translates to:
  /// **'排序'**
  String get categoryDetailSortTitle;

  /// No description provided for @categoryDetailSortTimeDesc.
  ///
  /// In zh, this message translates to:
  /// **'时间↓'**
  String get categoryDetailSortTimeDesc;

  /// No description provided for @categoryDetailSortTimeAsc.
  ///
  /// In zh, this message translates to:
  /// **'时间↑'**
  String get categoryDetailSortTimeAsc;

  /// No description provided for @categoryDetailSortAmountDesc.
  ///
  /// In zh, this message translates to:
  /// **'金额↓'**
  String get categoryDetailSortAmountDesc;

  /// No description provided for @categoryDetailSortAmountAsc.
  ///
  /// In zh, this message translates to:
  /// **'金额↑'**
  String get categoryDetailSortAmountAsc;

  /// No description provided for @categoryDetailNoTransactions.
  ///
  /// In zh, this message translates to:
  /// **'暂无交易记录'**
  String get categoryDetailNoTransactions;

  /// No description provided for @categoryDetailNoTransactionsSubtext.
  ///
  /// In zh, this message translates to:
  /// **'该分类下还没有任何交易记录'**
  String get categoryDetailNoTransactionsSubtext;

  /// No description provided for @categoryDetailDeleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除失败'**
  String get categoryDetailDeleteFailed;

  /// No description provided for @categoryMigrationConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认迁移'**
  String get categoryMigrationConfirmTitle;

  /// No description provided for @categoryMigrationConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要将「{fromName}」的 {count} 笔交易迁移到「{toName}」吗？\n\n此操作不可撤销！'**
  String categoryMigrationConfirmMessage(Object count, Object fromName, Object toName);

  /// No description provided for @categoryMigrationConfirmOk.
  ///
  /// In zh, this message translates to:
  /// **'确认迁移'**
  String get categoryMigrationConfirmOk;

  /// No description provided for @categoryMigrationCompleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'迁移完成'**
  String get categoryMigrationCompleteTitle;

  /// No description provided for @categoryMigrationCompleteMessage.
  ///
  /// In zh, this message translates to:
  /// **'成功将 {count} 笔交易从「{fromName}」迁移到「{toName}」。'**
  String categoryMigrationCompleteMessage(Object count, Object fromName, Object toName);

  /// No description provided for @categoryMigrationFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'迁移失败'**
  String get categoryMigrationFailedTitle;

  /// No description provided for @categoryMigrationFailedMessage.
  ///
  /// In zh, this message translates to:
  /// **'迁移过程中发生错误：{error}'**
  String categoryMigrationFailedMessage(Object error);

  /// No description provided for @categoryMigrationTransactionLabel.
  ///
  /// In zh, this message translates to:
  /// **'{count}笔'**
  String categoryMigrationTransactionLabel(Object count);

  /// No description provided for @importColumnNumber.
  ///
  /// In zh, this message translates to:
  /// **'第 {number} 列'**
  String importColumnNumber(Object number);

  /// No description provided for @importConfirmMapping.
  ///
  /// In zh, this message translates to:
  /// **'确认映射'**
  String get importConfirmMapping;

  /// No description provided for @importCategoryMapping.
  ///
  /// In zh, this message translates to:
  /// **'分类映射'**
  String get importCategoryMapping;

  /// No description provided for @importNoDataParsed.
  ///
  /// In zh, this message translates to:
  /// **'未解析到任何数据，请返回上一页检查 CSV 内容或分隔符。'**
  String get importNoDataParsed;

  /// No description provided for @importFieldDate.
  ///
  /// In zh, this message translates to:
  /// **'日期'**
  String get importFieldDate;

  /// No description provided for @importFieldType.
  ///
  /// In zh, this message translates to:
  /// **'类型'**
  String get importFieldType;

  /// No description provided for @importFieldAmount.
  ///
  /// In zh, this message translates to:
  /// **'金额'**
  String get importFieldAmount;

  /// No description provided for @importFieldCategory.
  ///
  /// In zh, this message translates to:
  /// **'分类'**
  String get importFieldCategory;

  /// No description provided for @importFieldAccount.
  ///
  /// In zh, this message translates to:
  /// **'账户'**
  String get importFieldAccount;

  /// No description provided for @importFieldNote.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get importFieldNote;

  /// No description provided for @importPreview.
  ///
  /// In zh, this message translates to:
  /// **'预览：'**
  String get importPreview;

  /// No description provided for @importPreviewLimit.
  ///
  /// In zh, this message translates to:
  /// **'仅预览前 {shown} 行，共 {total} 行'**
  String importPreviewLimit(Object shown, Object total);

  /// No description provided for @importCategoryNotSelected.
  ///
  /// In zh, this message translates to:
  /// **'未选择\"分类\"列，请点击\"上一步\"返回并设置\"分类\"的列，再继续。'**
  String get importCategoryNotSelected;

  /// No description provided for @importCategoryMappingDescription.
  ///
  /// In zh, this message translates to:
  /// **'请将左侧\"源分类名\"映射到系统内已有分类（或保持原名自动创建/合并）'**
  String get importCategoryMappingDescription;

  /// No description provided for @importKeepOriginalName.
  ///
  /// In zh, this message translates to:
  /// **'保持原名（自动创建/合并）'**
  String get importKeepOriginalName;

  /// No description provided for @importProgress.
  ///
  /// In zh, this message translates to:
  /// **'导入中… 成功 {ok}，失败 {fail}'**
  String importProgress(Object fail, Object ok);

  /// No description provided for @importCancelImport.
  ///
  /// In zh, this message translates to:
  /// **'取消导入'**
  String get importCancelImport;

  /// No description provided for @importCompleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入完成'**
  String get importCompleteTitle;

  /// No description provided for @importSelectCategoryFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先选择\"分类\"列再继续'**
  String get importSelectCategoryFirst;

  /// No description provided for @importNextStep.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get importNextStep;

  /// No description provided for @importPreviousStep.
  ///
  /// In zh, this message translates to:
  /// **'上一步'**
  String get importPreviousStep;

  /// No description provided for @importStartImport.
  ///
  /// In zh, this message translates to:
  /// **'开始导入'**
  String get importStartImport;

  /// No description provided for @importAutoDetect.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get importAutoDetect;

  /// No description provided for @importInProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在导入…'**
  String get importInProgress;

  /// No description provided for @importProgressDetail.
  ///
  /// In zh, this message translates to:
  /// **'已完成：{done}/{total}，成功 {ok}，失败 {fail}'**
  String importProgressDetail(Object done, Object fail, Object ok, Object total);

  /// No description provided for @importBackgroundImport.
  ///
  /// In zh, this message translates to:
  /// **'后台导入'**
  String get importBackgroundImport;

  /// No description provided for @importCancelled.
  ///
  /// In zh, this message translates to:
  /// **'（已取消）'**
  String get importCancelled;

  /// No description provided for @importCompleted.
  ///
  /// In zh, this message translates to:
  /// **'导入完成{cancelled}：成功 {ok} 条，失败 {fail} 条'**
  String importCompleted(Object cancelled, Object fail, Object ok);

  /// No description provided for @importSkippedNonTransactionTypes.
  ///
  /// In zh, this message translates to:
  /// **'跳过 {count} 条非收支记录（债务等）'**
  String importSkippedNonTransactionTypes(Object count);

  /// No description provided for @importTransactionFailed.
  ///
  /// In zh, this message translates to:
  /// **'导入失败，已回滚所有更改：{error}'**
  String importTransactionFailed(Object error);

  /// No description provided for @mineImportCompleteAllSuccess.
  ///
  /// In zh, this message translates to:
  /// **'全部成功'**
  String get mineImportCompleteAllSuccess;

  /// No description provided for @mineCheckUpdateDetecting.
  ///
  /// In zh, this message translates to:
  /// **'检测更新中...'**
  String get mineCheckUpdateDetecting;

  /// No description provided for @mineCheckUpdateSubtitleDetecting.
  ///
  /// In zh, this message translates to:
  /// **'正在检查最新版本'**
  String get mineCheckUpdateSubtitleDetecting;

  /// No description provided for @mineUpdateDownloadTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载更新'**
  String get mineUpdateDownloadTitle;

  /// No description provided for @cloudTest.
  ///
  /// In zh, this message translates to:
  /// **'测试'**
  String get cloudTest;

  /// No description provided for @cloudSwitched.
  ///
  /// In zh, this message translates to:
  /// **'已切换'**
  String get cloudSwitched;

  /// No description provided for @cloudSwitchFailed.
  ///
  /// In zh, this message translates to:
  /// **'切换失败'**
  String get cloudSwitchFailed;

  /// No description provided for @cloudSupabaseUrlLabel.
  ///
  /// In zh, this message translates to:
  /// **'Supabase URL'**
  String get cloudSupabaseUrlLabel;

  /// No description provided for @cloudSupabaseUrlHint.
  ///
  /// In zh, this message translates to:
  /// **'https://xxx.supabase.co'**
  String get cloudSupabaseUrlHint;

  /// No description provided for @cloudAnonKeyLabel.
  ///
  /// In zh, this message translates to:
  /// **'Anon Key'**
  String get cloudAnonKeyLabel;

  /// No description provided for @cloudSelectServiceType.
  ///
  /// In zh, this message translates to:
  /// **'选择云服务类型'**
  String get cloudSelectServiceType;

  /// No description provided for @cloudMultiDeviceWarningTitle.
  ///
  /// In zh, this message translates to:
  /// **'多设备使用提醒'**
  String get cloudMultiDeviceWarningTitle;

  /// No description provided for @cloudMultiDeviceWarningMessage.
  ///
  /// In zh, this message translates to:
  /// **'换设备前记得先上传，到新设备后先下载再记账。不要同时在两台设备上记同一个账本。点击查看详情 →'**
  String get cloudMultiDeviceWarningMessage;

  /// No description provided for @cloudWebdavUrlLabel.
  ///
  /// In zh, this message translates to:
  /// **'WebDAV 服务器地址'**
  String get cloudWebdavUrlLabel;

  /// No description provided for @cloudWebdavUrlHint.
  ///
  /// In zh, this message translates to:
  /// **'https://dav.jianguoyun.com/dav/'**
  String get cloudWebdavUrlHint;

  /// No description provided for @cloudWebdavUsernameLabel.
  ///
  /// In zh, this message translates to:
  /// **'用户名'**
  String get cloudWebdavUsernameLabel;

  /// No description provided for @cloudWebdavPasswordLabel.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get cloudWebdavPasswordLabel;

  /// No description provided for @cloudWebdavPathHint.
  ///
  /// In zh, this message translates to:
  /// **'/SmartBook 智记'**
  String get cloudWebdavPathHint;

  /// No description provided for @cloudS3EndpointLabel.
  ///
  /// In zh, this message translates to:
  /// **'端点地址'**
  String get cloudS3EndpointLabel;

  /// No description provided for @cloudS3EndpointHint.
  ///
  /// In zh, this message translates to:
  /// **'s3.amazonaws.com 或自定义端点'**
  String get cloudS3EndpointHint;

  /// No description provided for @cloudS3RegionLabel.
  ///
  /// In zh, this message translates to:
  /// **'区域'**
  String get cloudS3RegionLabel;

  /// No description provided for @cloudS3RegionHint.
  ///
  /// In zh, this message translates to:
  /// **'us-east-1（留空自动）'**
  String get cloudS3RegionHint;

  /// No description provided for @cloudS3AccessKeyLabel.
  ///
  /// In zh, this message translates to:
  /// **'Access Key'**
  String get cloudS3AccessKeyLabel;

  /// No description provided for @cloudS3AccessKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'您的 Access Key ID'**
  String get cloudS3AccessKeyHint;

  /// No description provided for @cloudS3SecretKeyLabel.
  ///
  /// In zh, this message translates to:
  /// **'Secret Key'**
  String get cloudS3SecretKeyLabel;

  /// No description provided for @cloudS3SecretKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'您的 Secret Access Key'**
  String get cloudS3SecretKeyHint;

  /// No description provided for @cloudS3BucketLabel.
  ///
  /// In zh, this message translates to:
  /// **'存储桶名称'**
  String get cloudS3BucketLabel;

  /// No description provided for @cloudS3BucketHint.
  ///
  /// In zh, this message translates to:
  /// **'smartbook-data'**
  String get cloudS3BucketHint;

  /// No description provided for @cloudS3UseSSLLabel.
  ///
  /// In zh, this message translates to:
  /// **'使用 HTTPS'**
  String get cloudS3UseSSLLabel;

  /// No description provided for @cloudS3PortLabel.
  ///
  /// In zh, this message translates to:
  /// **'端口（可选）'**
  String get cloudS3PortLabel;

  /// No description provided for @cloudS3PortHint.
  ///
  /// In zh, this message translates to:
  /// **'留空使用默认端口'**
  String get cloudS3PortHint;

  /// No description provided for @cloudSupabaseBucketLabel.
  ///
  /// In zh, this message translates to:
  /// **'Storage Bucket 名称'**
  String get cloudSupabaseBucketLabel;

  /// No description provided for @cloudSupabaseBucketHint.
  ///
  /// In zh, this message translates to:
  /// **'留空使用默认值 beecount-backups'**
  String get cloudSupabaseBucketHint;

  /// No description provided for @authRememberAccount.
  ///
  /// In zh, this message translates to:
  /// **'记住账号密码'**
  String get authRememberAccount;

  /// No description provided for @authRememberAccountHint.
  ///
  /// In zh, this message translates to:
  /// **'下次登录时自动填充（仅Supabase）'**
  String get authRememberAccountHint;

  /// No description provided for @cloudConfigSaved.
  ///
  /// In zh, this message translates to:
  /// **'配置已保存'**
  String get cloudConfigSaved;

  /// No description provided for @cloudTestSuccess.
  ///
  /// In zh, this message translates to:
  /// **'连接测试成功！'**
  String get cloudTestSuccess;

  /// No description provided for @cloudTestFailed.
  ///
  /// In zh, this message translates to:
  /// **'连接测试失败，请检查配置是否正确。'**
  String get cloudTestFailed;

  /// No description provided for @cloudTestError.
  ///
  /// In zh, this message translates to:
  /// **'测试失败'**
  String get cloudTestError;

  /// No description provided for @cloudLocalStorageTitle.
  ///
  /// In zh, this message translates to:
  /// **'本地存储'**
  String get cloudLocalStorageTitle;

  /// No description provided for @cloudLocalStorageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'数据仅保存在本地设备'**
  String get cloudLocalStorageSubtitle;

  /// No description provided for @cloudCustomSupabaseTitle.
  ///
  /// In zh, this message translates to:
  /// **'自定义 Supabase'**
  String get cloudCustomSupabaseTitle;

  /// No description provided for @cloudCustomWebdavTitle.
  ///
  /// In zh, this message translates to:
  /// **'自定义 WebDAV'**
  String get cloudCustomWebdavTitle;

  /// No description provided for @cloudSwitchConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'切换云服务'**
  String get cloudSwitchConfirmTitle;

  /// No description provided for @cloudSwitchConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'切换云服务将登出当前账号,确认切换?'**
  String get cloudSwitchConfirmMessage;

  /// No description provided for @cloudSwitchFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'切换失败'**
  String get cloudSwitchFailedTitle;

  /// No description provided for @cloudSwitchFailedConfigMissing.
  ///
  /// In zh, this message translates to:
  /// **'请先配置该云服务'**
  String get cloudSwitchFailedConfigMissing;

  /// No description provided for @cloudConfigInvalidTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置无效'**
  String get cloudConfigInvalidTitle;

  /// No description provided for @cloudConfigInvalidMessage.
  ///
  /// In zh, this message translates to:
  /// **'请填写完整信息'**
  String get cloudConfigInvalidMessage;

  /// No description provided for @cloudSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败'**
  String get cloudSaveFailed;

  /// No description provided for @cloudSwitchedTo.
  ///
  /// In zh, this message translates to:
  /// **'已切换到{type}'**
  String cloudSwitchedTo(String type);

  /// No description provided for @cloudConfigureSupabaseTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置 Supabase'**
  String get cloudConfigureSupabaseTitle;

  /// No description provided for @cloudConfigureWebdavTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置 WebDAV'**
  String get cloudConfigureWebdavTitle;

  /// No description provided for @cloudConfigureS3Title.
  ///
  /// In zh, this message translates to:
  /// **'配置 S3'**
  String get cloudConfigureS3Title;

  /// No description provided for @cloudWebdavRemotePathHelp.
  ///
  /// In zh, this message translates to:
  /// **'数据存储的远程目录路径'**
  String get cloudWebdavRemotePathHelp;

  /// No description provided for @authLogin.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get authLogin;

  /// No description provided for @authEmail.
  ///
  /// In zh, this message translates to:
  /// **'邮箱'**
  String get authEmail;

  /// No description provided for @authPassword.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get authPassword;

  /// No description provided for @authInvalidEmail.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的邮箱地址'**
  String get authInvalidEmail;

  /// No description provided for @authNoAccountYet.
  ///
  /// In zh, this message translates to:
  /// **'还没有账号？'**
  String get authNoAccountYet;

  /// No description provided for @authViewRegisterGuide.
  ///
  /// In zh, this message translates to:
  /// **'查看注册指引'**
  String get authViewRegisterGuide;

  /// No description provided for @authErrorInvalidCredentials.
  ///
  /// In zh, this message translates to:
  /// **'邮箱或密码不正确。'**
  String get authErrorInvalidCredentials;

  /// No description provided for @authErrorEmailNotConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'邮箱未验证，请先到邮箱完成验证再登录。'**
  String get authErrorEmailNotConfirmed;

  /// No description provided for @authErrorRateLimit.
  ///
  /// In zh, this message translates to:
  /// **'操作过于频繁，请稍后再试。'**
  String get authErrorRateLimit;

  /// No description provided for @authErrorNetworkIssue.
  ///
  /// In zh, this message translates to:
  /// **'网络异常，请检查网络后重试。'**
  String get authErrorNetworkIssue;

  /// No description provided for @authErrorLoginFailed.
  ///
  /// In zh, this message translates to:
  /// **'登录失败，请稍后再试。'**
  String get authErrorLoginFailed;

  /// No description provided for @authErrorEmailInvalid.
  ///
  /// In zh, this message translates to:
  /// **'邮箱地址无效，请检查是否拼写有误。'**
  String get authErrorEmailInvalid;

  /// No description provided for @authErrorWeakPassword.
  ///
  /// In zh, this message translates to:
  /// **'密码过于简单，请包含字母和数字，长度至少 6 位。'**
  String get authErrorWeakPassword;

  /// No description provided for @importSelectCsvFile.
  ///
  /// In zh, this message translates to:
  /// **'请选择文件进行导入（支持 CSV/TSV/XLSX 格式）'**
  String get importSelectCsvFile;

  /// No description provided for @exportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出'**
  String get exportTitle;

  /// No description provided for @exportDescription.
  ///
  /// In zh, this message translates to:
  /// **'支持导出的数据类型：\n• 交易记录（收入/支出/转账）\n• 分类信息\n• 账户信息\n\n点击下方按钮选择保存位置，开始导出当前账本为 CSV 文件。'**
  String get exportDescription;

  /// No description provided for @exportButtonIOS.
  ///
  /// In zh, this message translates to:
  /// **'导出并分享'**
  String get exportButtonIOS;

  /// No description provided for @exportButtonAndroid.
  ///
  /// In zh, this message translates to:
  /// **'导出数据'**
  String get exportButtonAndroid;

  /// No description provided for @exportJsonButton.
  ///
  /// In zh, this message translates to:
  /// **'JSON 结构化导出(备份)'**
  String get exportJsonButton;

  /// No description provided for @privacyPanelTitle.
  ///
  /// In zh, this message translates to:
  /// **'隐私面板'**
  String get privacyPanelTitle;

  /// No description provided for @privacyPanelDesc.
  ///
  /// In zh, this message translates to:
  /// **'原文数据保留策略与一键清理'**
  String get privacyPanelDesc;

  /// No description provided for @privacyStatsAttachments.
  ///
  /// In zh, this message translates to:
  /// **'截图/图片原文'**
  String get privacyStatsAttachments;

  /// No description provided for @privacyStatsAttachmentsDesc.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个文件,占用 {size}'**
  String privacyStatsAttachmentsDesc(Object count, Object size);

  /// No description provided for @privacyStatsPending.
  ///
  /// In zh, this message translates to:
  /// **'待确认候选:{count} 项'**
  String privacyStatsPending(Object count);

  /// No description provided for @privacyNoOriginalForSmsNotifyTitle.
  ///
  /// In zh, this message translates to:
  /// **'短信/通知原文不落盘'**
  String get privacyNoOriginalForSmsNotifyTitle;

  /// No description provided for @privacyNoOriginalForSmsNotifyDesc.
  ///
  /// In zh, this message translates to:
  /// **'短信与支付通知原文在 AI 解析后即丢弃,不持久化(设计保证);仅保留解析出的结构化交易。'**
  String get privacyNoOriginalForSmsNotifyDesc;

  /// No description provided for @privacyClearAttachments.
  ///
  /// In zh, this message translates to:
  /// **'一键清除截图/图片原文'**
  String get privacyClearAttachments;

  /// No description provided for @privacyClearAttachmentsConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认清除原文?'**
  String get privacyClearAttachmentsConfirmTitle;

  /// No description provided for @privacyClearAttachmentsConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'将删除 {count} 个截图/图片原文文件,不影响交易记录与统计。建议先导出备份。'**
  String privacyClearAttachmentsConfirmBody(Object count);

  /// No description provided for @privacyCleared.
  ///
  /// In zh, this message translates to:
  /// **'已清除 {count} 个原文文件(交易数据保留)'**
  String privacyCleared(Object count);

  /// No description provided for @exportSavedTo.
  ///
  /// In zh, this message translates to:
  /// **'已保存到：{path}'**
  String exportSavedTo(String path);

  /// No description provided for @exportCsvHeaderType.
  ///
  /// In zh, this message translates to:
  /// **'类型'**
  String get exportCsvHeaderType;

  /// No description provided for @exportCsvHeaderCategory.
  ///
  /// In zh, this message translates to:
  /// **'分类'**
  String get exportCsvHeaderCategory;

  /// No description provided for @exportCsvHeaderSubCategory.
  ///
  /// In zh, this message translates to:
  /// **'二级分类'**
  String get exportCsvHeaderSubCategory;

  /// No description provided for @exportCsvHeaderAmount.
  ///
  /// In zh, this message translates to:
  /// **'金额'**
  String get exportCsvHeaderAmount;

  /// No description provided for @exportCsvHeaderAccount.
  ///
  /// In zh, this message translates to:
  /// **'账户'**
  String get exportCsvHeaderAccount;

  /// No description provided for @exportCsvHeaderFromAccount.
  ///
  /// In zh, this message translates to:
  /// **'转出账户'**
  String get exportCsvHeaderFromAccount;

  /// No description provided for @exportCsvHeaderToAccount.
  ///
  /// In zh, this message translates to:
  /// **'转入账户'**
  String get exportCsvHeaderToAccount;

  /// No description provided for @exportCsvHeaderNote.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get exportCsvHeaderNote;

  /// No description provided for @exportCsvHeaderTime.
  ///
  /// In zh, this message translates to:
  /// **'时间'**
  String get exportCsvHeaderTime;

  /// No description provided for @exportCsvHeaderTags.
  ///
  /// In zh, this message translates to:
  /// **'标签'**
  String get exportCsvHeaderTags;

  /// No description provided for @exportCsvHeaderAttachments.
  ///
  /// In zh, this message translates to:
  /// **'附件'**
  String get exportCsvHeaderAttachments;

  /// No description provided for @exportShareText.
  ///
  /// In zh, this message translates to:
  /// **'智记 导出文件'**
  String get exportShareText;

  /// No description provided for @exportSuccessTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出成功'**
  String get exportSuccessTitle;

  /// No description provided for @exportSuccessMessageIOS.
  ///
  /// In zh, this message translates to:
  /// **'已保存并可在分享历史中找到：\n{path}'**
  String exportSuccessMessageIOS(String path);

  /// No description provided for @exportSuccessMessageAndroid.
  ///
  /// In zh, this message translates to:
  /// **'已保存到：\n{path}'**
  String exportSuccessMessageAndroid(String path);

  /// No description provided for @exportFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出失败'**
  String get exportFailedTitle;

  /// No description provided for @exportTypeIncome.
  ///
  /// In zh, this message translates to:
  /// **'收入'**
  String get exportTypeIncome;

  /// No description provided for @exportTypeExpense.
  ///
  /// In zh, this message translates to:
  /// **'支出'**
  String get exportTypeExpense;

  /// No description provided for @exportTypeTransfer.
  ///
  /// In zh, this message translates to:
  /// **'转账'**
  String get exportTypeTransfer;

  /// No description provided for @personalizeThemeHoney.
  ///
  /// In zh, this message translates to:
  /// **'蜜蜂黄'**
  String get personalizeThemeHoney;

  /// No description provided for @personalizeThemeOrange.
  ///
  /// In zh, this message translates to:
  /// **'火焰橙'**
  String get personalizeThemeOrange;

  /// No description provided for @personalizeThemeGreen.
  ///
  /// In zh, this message translates to:
  /// **'琉璃绿'**
  String get personalizeThemeGreen;

  /// No description provided for @personalizeThemePurple.
  ///
  /// In zh, this message translates to:
  /// **'青莲紫'**
  String get personalizeThemePurple;

  /// No description provided for @personalizeThemePink.
  ///
  /// In zh, this message translates to:
  /// **'樱绯红'**
  String get personalizeThemePink;

  /// No description provided for @personalizeThemeBlue.
  ///
  /// In zh, this message translates to:
  /// **'晴空蓝'**
  String get personalizeThemeBlue;

  /// No description provided for @personalizeThemeMint.
  ///
  /// In zh, this message translates to:
  /// **'林间月'**
  String get personalizeThemeMint;

  /// No description provided for @personalizeThemeSand.
  ///
  /// In zh, this message translates to:
  /// **'黄昏沙丘'**
  String get personalizeThemeSand;

  /// No description provided for @personalizeThemeLavender.
  ///
  /// In zh, this message translates to:
  /// **'雪与松'**
  String get personalizeThemeLavender;

  /// No description provided for @personalizeThemeSky.
  ///
  /// In zh, this message translates to:
  /// **'迷雾仙境'**
  String get personalizeThemeSky;

  /// No description provided for @personalizeThemeWarmOrange.
  ///
  /// In zh, this message translates to:
  /// **'暖阳橘'**
  String get personalizeThemeWarmOrange;

  /// No description provided for @personalizeThemeMintGreen.
  ///
  /// In zh, this message translates to:
  /// **'薄荷青'**
  String get personalizeThemeMintGreen;

  /// No description provided for @personalizeThemeRoseGold.
  ///
  /// In zh, this message translates to:
  /// **'玫瑰金'**
  String get personalizeThemeRoseGold;

  /// No description provided for @personalizeThemeDeepBlue.
  ///
  /// In zh, this message translates to:
  /// **'深海蓝'**
  String get personalizeThemeDeepBlue;

  /// No description provided for @personalizeThemeMapleRed.
  ///
  /// In zh, this message translates to:
  /// **'枫叶红'**
  String get personalizeThemeMapleRed;

  /// No description provided for @personalizeThemeEmerald.
  ///
  /// In zh, this message translates to:
  /// **'翡翠绿'**
  String get personalizeThemeEmerald;

  /// No description provided for @personalizeThemeLavenderPurple.
  ///
  /// In zh, this message translates to:
  /// **'薰衣草'**
  String get personalizeThemeLavenderPurple;

  /// No description provided for @personalizeThemeAmber.
  ///
  /// In zh, this message translates to:
  /// **'琥珀黄'**
  String get personalizeThemeAmber;

  /// No description provided for @personalizeThemeRouge.
  ///
  /// In zh, this message translates to:
  /// **'胭脂红'**
  String get personalizeThemeRouge;

  /// No description provided for @personalizeThemeIndigo.
  ///
  /// In zh, this message translates to:
  /// **'靛青蓝'**
  String get personalizeThemeIndigo;

  /// No description provided for @personalizeThemeOlive.
  ///
  /// In zh, this message translates to:
  /// **'橄榄绿'**
  String get personalizeThemeOlive;

  /// No description provided for @personalizeThemeCoral.
  ///
  /// In zh, this message translates to:
  /// **'珊瑚粉'**
  String get personalizeThemeCoral;

  /// No description provided for @personalizeThemeDarkGreen.
  ///
  /// In zh, this message translates to:
  /// **'墨绿色'**
  String get personalizeThemeDarkGreen;

  /// No description provided for @personalizeThemeViolet.
  ///
  /// In zh, this message translates to:
  /// **'紫罗兰'**
  String get personalizeThemeViolet;

  /// No description provided for @personalizeThemeSunset.
  ///
  /// In zh, this message translates to:
  /// **'日落橙'**
  String get personalizeThemeSunset;

  /// No description provided for @personalizeThemePeacock.
  ///
  /// In zh, this message translates to:
  /// **'孔雀蓝'**
  String get personalizeThemePeacock;

  /// No description provided for @personalizeThemeLime.
  ///
  /// In zh, this message translates to:
  /// **'柠檬绿'**
  String get personalizeThemeLime;

  /// No description provided for @analyticsMonthlyAvg.
  ///
  /// In zh, this message translates to:
  /// **'月均'**
  String get analyticsMonthlyAvg;

  /// No description provided for @analyticsDailyAvg.
  ///
  /// In zh, this message translates to:
  /// **'日均'**
  String get analyticsDailyAvg;

  /// No description provided for @analyticsOverallAvg.
  ///
  /// In zh, this message translates to:
  /// **'平均值'**
  String get analyticsOverallAvg;

  /// No description provided for @analyticsTotalIncome.
  ///
  /// In zh, this message translates to:
  /// **'总收入： '**
  String get analyticsTotalIncome;

  /// No description provided for @analyticsTotalExpense.
  ///
  /// In zh, this message translates to:
  /// **'总支出： '**
  String get analyticsTotalExpense;

  /// No description provided for @analyticsBalance.
  ///
  /// In zh, this message translates to:
  /// **'结余： '**
  String get analyticsBalance;

  /// No description provided for @analyticsAvgIncome.
  ///
  /// In zh, this message translates to:
  /// **'{avgLabel}收入： '**
  String analyticsAvgIncome(Object avgLabel);

  /// No description provided for @analyticsAvgExpense.
  ///
  /// In zh, this message translates to:
  /// **'{avgLabel}支出： '**
  String analyticsAvgExpense(Object avgLabel);

  /// No description provided for @analyticsExpense.
  ///
  /// In zh, this message translates to:
  /// **'支出'**
  String get analyticsExpense;

  /// No description provided for @analyticsIncome.
  ///
  /// In zh, this message translates to:
  /// **'收入'**
  String get analyticsIncome;

  /// No description provided for @analyticsTotal.
  ///
  /// In zh, this message translates to:
  /// **'总{type}： '**
  String analyticsTotal(Object type);

  /// No description provided for @analyticsAverage.
  ///
  /// In zh, this message translates to:
  /// **'{avgLabel}： '**
  String analyticsAverage(Object avgLabel);

  /// No description provided for @updateCheckTitle.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get updateCheckTitle;

  /// No description provided for @updateNewVersionTitle.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String updateNewVersionTitle(Object version);

  /// No description provided for @updateNoApkFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到APK下载链接'**
  String get updateNoApkFound;

  /// No description provided for @updateAlreadyLatest.
  ///
  /// In zh, this message translates to:
  /// **'当前已是最新版本'**
  String get updateAlreadyLatest;

  /// No description provided for @updateCheckFailed.
  ///
  /// In zh, this message translates to:
  /// **'检查更新失败'**
  String get updateCheckFailed;

  /// No description provided for @updatePermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'权限被拒绝'**
  String get updatePermissionDenied;

  /// No description provided for @updateUserCancelled.
  ///
  /// In zh, this message translates to:
  /// **'用户取消'**
  String get updateUserCancelled;

  /// No description provided for @updateDownloadTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载更新'**
  String get updateDownloadTitle;

  /// No description provided for @updateDownloading.
  ///
  /// In zh, this message translates to:
  /// **'下载中: {percent}%'**
  String updateDownloading(Object percent);

  /// No description provided for @updateDownloadBackgroundHint.
  ///
  /// In zh, this message translates to:
  /// **'可以将应用切换到后台，下载会继续进行'**
  String get updateDownloadBackgroundHint;

  /// No description provided for @updateCancelButton.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get updateCancelButton;

  /// No description provided for @updateBackgroundDownload.
  ///
  /// In zh, this message translates to:
  /// **'后台下载'**
  String get updateBackgroundDownload;

  /// No description provided for @updateLaterButton.
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get updateLaterButton;

  /// No description provided for @updateDownloadButton.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get updateDownloadButton;

  /// No description provided for @updateInstallingCachedApk.
  ///
  /// In zh, this message translates to:
  /// **'正在安装缓存的APK'**
  String get updateInstallingCachedApk;

  /// No description provided for @updateDownloadComplete.
  ///
  /// In zh, this message translates to:
  /// **'下载完成'**
  String get updateDownloadComplete;

  /// No description provided for @updateInstallStarted.
  ///
  /// In zh, this message translates to:
  /// **'下载完成，安装程序已启动'**
  String get updateInstallStarted;

  /// No description provided for @updateInstallFailed.
  ///
  /// In zh, this message translates to:
  /// **'安装失败'**
  String get updateInstallFailed;

  /// No description provided for @updateDownloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败'**
  String get updateDownloadFailed;

  /// No description provided for @updateInstallNow.
  ///
  /// In zh, this message translates to:
  /// **'立即安装'**
  String get updateInstallNow;

  /// No description provided for @updateNotificationPermissionTitle.
  ///
  /// In zh, this message translates to:
  /// **'通知权限被拒绝'**
  String get updateNotificationPermissionTitle;

  /// No description provided for @updateCheckFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'检测更新失败'**
  String get updateCheckFailedTitle;

  /// No description provided for @updateDownloadFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载失败'**
  String get updateDownloadFailedTitle;

  /// No description provided for @updateGoToGitHub.
  ///
  /// In zh, this message translates to:
  /// **'前往GitHub'**
  String get updateGoToGitHub;

  /// No description provided for @updateCannotOpenLink.
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接'**
  String get updateCannotOpenLink;

  /// No description provided for @updateManualVisit.
  ///
  /// In zh, this message translates to:
  /// **'请手动在浏览器中访问：\\nhttps://github.com/TNT-Likely/BeeCount/releases'**
  String get updateManualVisit;

  /// No description provided for @updateNoLocalApkTitle.
  ///
  /// In zh, this message translates to:
  /// **'未找到更新包'**
  String get updateNoLocalApkTitle;

  /// No description provided for @updateInstallPackageTitle.
  ///
  /// In zh, this message translates to:
  /// **'安装更新包'**
  String get updateInstallPackageTitle;

  /// No description provided for @updateMultiplePackagesTitle.
  ///
  /// In zh, this message translates to:
  /// **'找到多个更新包'**
  String get updateMultiplePackagesTitle;

  /// No description provided for @updateSearchFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'查找失败'**
  String get updateSearchFailedTitle;

  /// No description provided for @updateFoundCachedPackageTitle.
  ///
  /// In zh, this message translates to:
  /// **'发现已下载的更新包'**
  String get updateFoundCachedPackageTitle;

  /// No description provided for @updateIgnoreButton.
  ///
  /// In zh, this message translates to:
  /// **'忽略'**
  String get updateIgnoreButton;

  /// No description provided for @updateInstallFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'安装失败'**
  String get updateInstallFailedTitle;

  /// No description provided for @updateInstallFailedMessage.
  ///
  /// In zh, this message translates to:
  /// **'无法启动APK安装程序，请检查文件权限。'**
  String get updateInstallFailedMessage;

  /// No description provided for @updateErrorTitle.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get updateErrorTitle;

  /// No description provided for @updateCheckingPermissions.
  ///
  /// In zh, this message translates to:
  /// **'检查权限...'**
  String get updateCheckingPermissions;

  /// No description provided for @updateCheckingCache.
  ///
  /// In zh, this message translates to:
  /// **'检查本地缓存...'**
  String get updateCheckingCache;

  /// No description provided for @updatePreparingDownload.
  ///
  /// In zh, this message translates to:
  /// **'准备下载...'**
  String get updatePreparingDownload;

  /// No description provided for @updateUserCancelledDownload.
  ///
  /// In zh, this message translates to:
  /// **'用户取消下载'**
  String get updateUserCancelledDownload;

  /// No description provided for @updateStartingInstaller.
  ///
  /// In zh, this message translates to:
  /// **'正在启动安装...'**
  String get updateStartingInstaller;

  /// No description provided for @updateInstallerStarted.
  ///
  /// In zh, this message translates to:
  /// **'安装程序已启动'**
  String get updateInstallerStarted;

  /// No description provided for @updateInstallationFailed.
  ///
  /// In zh, this message translates to:
  /// **'安装失败'**
  String get updateInstallationFailed;

  /// No description provided for @updateDownloadCompleted.
  ///
  /// In zh, this message translates to:
  /// **'下载完成'**
  String get updateDownloadCompleted;

  /// No description provided for @updateDownloadCompletedManual.
  ///
  /// In zh, this message translates to:
  /// **'下载完成，可以手动安装'**
  String get updateDownloadCompletedManual;

  /// No description provided for @updateDownloadCompletedDialog.
  ///
  /// In zh, this message translates to:
  /// **'下载完成，请手动安装（弹窗异常）'**
  String get updateDownloadCompletedDialog;

  /// No description provided for @updateDownloadCompletedContext.
  ///
  /// In zh, this message translates to:
  /// **'下载完成，请手动安装'**
  String get updateDownloadCompletedContext;

  /// No description provided for @updateDownloadFailedGeneric.
  ///
  /// In zh, this message translates to:
  /// **'下载失败'**
  String get updateDownloadFailedGeneric;

  /// No description provided for @updateCheckingUpdate.
  ///
  /// In zh, this message translates to:
  /// **'正在检查更新...'**
  String get updateCheckingUpdate;

  /// No description provided for @updateCurrentLatestVersion.
  ///
  /// In zh, this message translates to:
  /// **'当前已是最新版本'**
  String get updateCurrentLatestVersion;

  /// No description provided for @updateCheckFailedGeneric.
  ///
  /// In zh, this message translates to:
  /// **'检查更新失败'**
  String get updateCheckFailedGeneric;

  /// No description provided for @updateDownloadProgress.
  ///
  /// In zh, this message translates to:
  /// **'下载中: {percent}%'**
  String updateDownloadProgress(Object percent);

  /// No description provided for @updateCheckingUpdateError.
  ///
  /// In zh, this message translates to:
  /// **'检查更新失败: {error}'**
  String updateCheckingUpdateError(Object error);

  /// No description provided for @updateNoLocalApkFoundMessage.
  ///
  /// In zh, this message translates to:
  /// **'没有找到已下载的更新包文件。\n\n请先通过\"检查更新\"下载新版本。'**
  String get updateNoLocalApkFoundMessage;

  /// No description provided for @updateInstallPackageFoundMessage.
  ///
  /// In zh, this message translates to:
  /// **'找到更新包：\n\n文件名：{fileName}\n大小：{fileSize}MB\n下载时间：{time}\n\n是否立即安装？'**
  String updateInstallPackageFoundMessage(Object fileName, Object fileSize, Object time);

  /// No description provided for @updateMultiplePackagesFoundMessage.
  ///
  /// In zh, this message translates to:
  /// **'找到 {count} 个更新包文件。\n\n建议使用最新下载的版本，或手动到文件管理器中安装。\n\n文件位置：{path}'**
  String updateMultiplePackagesFoundMessage(Object count, Object path);

  /// No description provided for @updateSearchLocalApkError.
  ///
  /// In zh, this message translates to:
  /// **'查找本地更新包时发生错误：{error}'**
  String updateSearchLocalApkError(Object error);

  /// No description provided for @updateCachedPackageFoundMessage.
  ///
  /// In zh, this message translates to:
  /// **'检测到之前下载的更新包：\n\n文件名：{fileName}\n大小：{fileSize}MB\n\n是否立即安装？'**
  String updateCachedPackageFoundMessage(Object fileName, Object fileSize);

  /// No description provided for @updateReadCachedPackageError.
  ///
  /// In zh, this message translates to:
  /// **'读取缓存更新包失败：{error}'**
  String updateReadCachedPackageError(Object error);

  /// No description provided for @iconCategoryDining.
  ///
  /// In zh, this message translates to:
  /// **'餐饮'**
  String get iconCategoryDining;

  /// No description provided for @updateOk.
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get updateOk;

  /// No description provided for @updateCannotOpenLinkTitle.
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接'**
  String get updateCannotOpenLinkTitle;

  /// No description provided for @updateNotificationPermissionGuideText.
  ///
  /// In zh, this message translates to:
  /// **'下载进度通知被关闭，但不影响下载功能。如需查看进度：'**
  String get updateNotificationPermissionGuideText;

  /// No description provided for @updateNotificationGuideStep1.
  ///
  /// In zh, this message translates to:
  /// **'进入系统设置 > 应用管理'**
  String get updateNotificationGuideStep1;

  /// No description provided for @updateNotificationGuideStep2.
  ///
  /// In zh, this message translates to:
  /// **'找到\\\"智记\\\"应用'**
  String get updateNotificationGuideStep2;

  /// No description provided for @updateNotificationGuideStep3.
  ///
  /// In zh, this message translates to:
  /// **'开启通知权限'**
  String get updateNotificationGuideStep3;

  /// No description provided for @updateNotificationGuideInfo.
  ///
  /// In zh, this message translates to:
  /// **'即使不开启通知，下载也会在后台正常进行'**
  String get updateNotificationGuideInfo;

  /// No description provided for @updateCachedVersionTitle.
  ///
  /// In zh, this message translates to:
  /// **'发现已下载版本'**
  String get updateCachedVersionTitle;

  /// No description provided for @updateCachedVersionMessage.
  ///
  /// In zh, this message translates to:
  /// **'已找到之前下载的安装包...点击\\\"确定\\\"立即安装，点击\\\"取消\\\"关闭...'**
  String get updateCachedVersionMessage;

  /// No description provided for @updateCorruptedFileTitle.
  ///
  /// In zh, this message translates to:
  /// **'安装包已损坏'**
  String get updateCorruptedFileTitle;

  /// No description provided for @updateCorruptedFileMessage.
  ///
  /// In zh, this message translates to:
  /// **'检测到之前下载的安装包不完整或已损坏，是否删除并重新下载？'**
  String get updateCorruptedFileMessage;

  /// No description provided for @updateConfirmDownload.
  ///
  /// In zh, this message translates to:
  /// **'立即下载并安装'**
  String get updateConfirmDownload;

  /// No description provided for @updateDownloadCompleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载完成'**
  String get updateDownloadCompleteTitle;

  /// No description provided for @updateInstallConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'新版本已下载完成，是否立即安装？'**
  String get updateInstallConfirmMessage;

  /// No description provided for @updateMirrorSelectTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择下载加速器'**
  String get updateMirrorSelectTitle;

  /// No description provided for @updateMirrorSelectHint.
  ///
  /// In zh, this message translates to:
  /// **'如果下载缓慢，可以选择一个加速镜像。点击「测速」检测各镜像延迟。'**
  String get updateMirrorSelectHint;

  /// No description provided for @updateMirrorTestButton.
  ///
  /// In zh, this message translates to:
  /// **'测速'**
  String get updateMirrorTestButton;

  /// No description provided for @updateMirrorTesting.
  ///
  /// In zh, this message translates to:
  /// **'正在测试 {completed}/{total}...'**
  String updateMirrorTesting(int completed, int total);

  /// No description provided for @updateMirrorDirectHint.
  ///
  /// In zh, this message translates to:
  /// **'适合网络通畅的用户'**
  String get updateMirrorDirectHint;

  /// No description provided for @updateDownloadMirror.
  ///
  /// In zh, this message translates to:
  /// **'下载源: {mirror}'**
  String updateDownloadMirror(String mirror);

  /// No description provided for @updateMirrorSettingTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载加速器'**
  String get updateMirrorSettingTitle;

  /// No description provided for @currencyCNY.
  ///
  /// In zh, this message translates to:
  /// **'人民币'**
  String get currencyCNY;

  /// No description provided for @currencyUSD.
  ///
  /// In zh, this message translates to:
  /// **'美元'**
  String get currencyUSD;

  /// No description provided for @currencyEUR.
  ///
  /// In zh, this message translates to:
  /// **'欧元'**
  String get currencyEUR;

  /// No description provided for @currencyJPY.
  ///
  /// In zh, this message translates to:
  /// **'日元'**
  String get currencyJPY;

  /// No description provided for @currencyHKD.
  ///
  /// In zh, this message translates to:
  /// **'港币'**
  String get currencyHKD;

  /// No description provided for @currencyTWD.
  ///
  /// In zh, this message translates to:
  /// **'新台币'**
  String get currencyTWD;

  /// No description provided for @currencyGBP.
  ///
  /// In zh, this message translates to:
  /// **'英镑'**
  String get currencyGBP;

  /// No description provided for @currencyAUD.
  ///
  /// In zh, this message translates to:
  /// **'澳元'**
  String get currencyAUD;

  /// No description provided for @currencyCAD.
  ///
  /// In zh, this message translates to:
  /// **'加元'**
  String get currencyCAD;

  /// No description provided for @currencyKRW.
  ///
  /// In zh, this message translates to:
  /// **'韩元'**
  String get currencyKRW;

  /// No description provided for @currencySGD.
  ///
  /// In zh, this message translates to:
  /// **'新加坡元'**
  String get currencySGD;

  /// No description provided for @currencyMYR.
  ///
  /// In zh, this message translates to:
  /// **'马来西亚林吉特'**
  String get currencyMYR;

  /// No description provided for @currencyTHB.
  ///
  /// In zh, this message translates to:
  /// **'泰铢'**
  String get currencyTHB;

  /// No description provided for @currencyIDR.
  ///
  /// In zh, this message translates to:
  /// **'印尼卢比'**
  String get currencyIDR;

  /// No description provided for @currencyPHP.
  ///
  /// In zh, this message translates to:
  /// **'菲律宾比索'**
  String get currencyPHP;

  /// No description provided for @currencyVND.
  ///
  /// In zh, this message translates to:
  /// **'越南盾'**
  String get currencyVND;

  /// No description provided for @currencyINR.
  ///
  /// In zh, this message translates to:
  /// **'印度卢比'**
  String get currencyINR;

  /// No description provided for @currencyRUB.
  ///
  /// In zh, this message translates to:
  /// **'俄罗斯卢布'**
  String get currencyRUB;

  /// No description provided for @currencyBYN.
  ///
  /// In zh, this message translates to:
  /// **'白俄罗斯卢布'**
  String get currencyBYN;

  /// No description provided for @currencyNZD.
  ///
  /// In zh, this message translates to:
  /// **'新西兰元'**
  String get currencyNZD;

  /// No description provided for @currencyCHF.
  ///
  /// In zh, this message translates to:
  /// **'瑞士法郎'**
  String get currencyCHF;

  /// No description provided for @currencySEK.
  ///
  /// In zh, this message translates to:
  /// **'瑞典克朗'**
  String get currencySEK;

  /// No description provided for @currencyNOK.
  ///
  /// In zh, this message translates to:
  /// **'挪威克朗'**
  String get currencyNOK;

  /// No description provided for @currencyDKK.
  ///
  /// In zh, this message translates to:
  /// **'丹麦克朗'**
  String get currencyDKK;

  /// No description provided for @currencyBRL.
  ///
  /// In zh, this message translates to:
  /// **'巴西雷亚尔'**
  String get currencyBRL;

  /// No description provided for @currencyMXN.
  ///
  /// In zh, this message translates to:
  /// **'墨西哥比索'**
  String get currencyMXN;

  /// No description provided for @currencyTRY.
  ///
  /// In zh, this message translates to:
  /// **'土耳其里拉'**
  String get currencyTRY;

  /// No description provided for @currencyZAR.
  ///
  /// In zh, this message translates to:
  /// **'南非兰特'**
  String get currencyZAR;

  /// No description provided for @currencyAED.
  ///
  /// In zh, this message translates to:
  /// **'阿联酋迪拉姆'**
  String get currencyAED;

  /// No description provided for @currencySAR.
  ///
  /// In zh, this message translates to:
  /// **'沙特里亚尔'**
  String get currencySAR;

  /// No description provided for @currencyPLN.
  ///
  /// In zh, this message translates to:
  /// **'波兰兹罗提'**
  String get currencyPLN;

  /// No description provided for @currencyCZK.
  ///
  /// In zh, this message translates to:
  /// **'捷克克朗'**
  String get currencyCZK;

  /// No description provided for @currencyHUF.
  ///
  /// In zh, this message translates to:
  /// **'匈牙利福林'**
  String get currencyHUF;

  /// No description provided for @currencyARS.
  ///
  /// In zh, this message translates to:
  /// **'阿根廷比索'**
  String get currencyARS;

  /// No description provided for @currencyCLP.
  ///
  /// In zh, this message translates to:
  /// **'智利比索'**
  String get currencyCLP;

  /// No description provided for @currencyCOP.
  ///
  /// In zh, this message translates to:
  /// **'哥伦比亚比索'**
  String get currencyCOP;

  /// No description provided for @currencyPEN.
  ///
  /// In zh, this message translates to:
  /// **'秘鲁索尔'**
  String get currencyPEN;

  /// No description provided for @currencyEGP.
  ///
  /// In zh, this message translates to:
  /// **'埃及镑'**
  String get currencyEGP;

  /// No description provided for @currencyNGN.
  ///
  /// In zh, this message translates to:
  /// **'尼日利亚奈拉'**
  String get currencyNGN;

  /// No description provided for @currencyKZT.
  ///
  /// In zh, this message translates to:
  /// **'哈萨克斯坦坚戈'**
  String get currencyKZT;

  /// No description provided for @currencyUAH.
  ///
  /// In zh, this message translates to:
  /// **'乌克兰格里夫纳'**
  String get currencyUAH;

  /// No description provided for @currencyILS.
  ///
  /// In zh, this message translates to:
  /// **'以色列新谢克尔'**
  String get currencyILS;

  /// No description provided for @currencyPKR.
  ///
  /// In zh, this message translates to:
  /// **'巴基斯坦卢比'**
  String get currencyPKR;

  /// No description provided for @currencyBDT.
  ///
  /// In zh, this message translates to:
  /// **'孟加拉塔卡'**
  String get currencyBDT;

  /// No description provided for @currencyLKR.
  ///
  /// In zh, this message translates to:
  /// **'斯里兰卡卢比'**
  String get currencyLKR;

  /// No description provided for @currencyMMK.
  ///
  /// In zh, this message translates to:
  /// **'缅甸元'**
  String get currencyMMK;

  /// No description provided for @webdavConfiguredTitle.
  ///
  /// In zh, this message translates to:
  /// **'WebDAV 云服务已配置'**
  String get webdavConfiguredTitle;

  /// No description provided for @webdavConfiguredMessage.
  ///
  /// In zh, this message translates to:
  /// **'WebDAV 云服务使用配置时提供的凭据，无需额外登录。'**
  String get webdavConfiguredMessage;

  /// No description provided for @recurringTransactionTitle.
  ///
  /// In zh, this message translates to:
  /// **'周期账单'**
  String get recurringTransactionTitle;

  /// No description provided for @recurringTransactionAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加周期账单'**
  String get recurringTransactionAdd;

  /// No description provided for @recurringTransactionEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑周期账单'**
  String get recurringTransactionEdit;

  /// No description provided for @recurringTransactionFrequency.
  ///
  /// In zh, this message translates to:
  /// **'周期频率'**
  String get recurringTransactionFrequency;

  /// No description provided for @recurringTransactionDaily.
  ///
  /// In zh, this message translates to:
  /// **'每天'**
  String get recurringTransactionDaily;

  /// No description provided for @recurringTransactionWeekly.
  ///
  /// In zh, this message translates to:
  /// **'每周'**
  String get recurringTransactionWeekly;

  /// No description provided for @recurringTransactionMonthly.
  ///
  /// In zh, this message translates to:
  /// **'每月'**
  String get recurringTransactionMonthly;

  /// No description provided for @recurringTransactionYearly.
  ///
  /// In zh, this message translates to:
  /// **'每年'**
  String get recurringTransactionYearly;

  /// No description provided for @recurringTransactionInterval.
  ///
  /// In zh, this message translates to:
  /// **'间隔'**
  String get recurringTransactionInterval;

  /// No description provided for @recurringTransactionDayOfMonth.
  ///
  /// In zh, this message translates to:
  /// **'每月第几天'**
  String get recurringTransactionDayOfMonth;

  /// No description provided for @recurringTransactionStartDate.
  ///
  /// In zh, this message translates to:
  /// **'开始日期'**
  String get recurringTransactionStartDate;

  /// No description provided for @recurringTransactionEndDate.
  ///
  /// In zh, this message translates to:
  /// **'结束日期'**
  String get recurringTransactionEndDate;

  /// No description provided for @recurringTransactionNoEndDate.
  ///
  /// In zh, this message translates to:
  /// **'永久周期'**
  String get recurringTransactionNoEndDate;

  /// No description provided for @recurringTransactionDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这个周期账单吗？'**
  String get recurringTransactionDeleteConfirm;

  /// No description provided for @recurringTransactionEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无周期账单'**
  String get recurringTransactionEmpty;

  /// No description provided for @recurringTransactionEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'点击右上角 + 按钮添加'**
  String get recurringTransactionEmptyHint;

  /// No description provided for @recurringTransactionEveryNDays.
  ///
  /// In zh, this message translates to:
  /// **'每 {n} 天'**
  String recurringTransactionEveryNDays(int n);

  /// No description provided for @recurringTransactionEveryNWeeks.
  ///
  /// In zh, this message translates to:
  /// **'每 {n} 周'**
  String recurringTransactionEveryNWeeks(int n);

  /// No description provided for @recurringTransactionEveryNMonths.
  ///
  /// In zh, this message translates to:
  /// **'每 {n} 个月'**
  String recurringTransactionEveryNMonths(int n);

  /// No description provided for @recurringTransactionEveryNYears.
  ///
  /// In zh, this message translates to:
  /// **'每 {n} 年'**
  String recurringTransactionEveryNYears(int n);

  /// No description provided for @recurringTransactionUsageTitle.
  ///
  /// In zh, this message translates to:
  /// **'使用说明'**
  String get recurringTransactionUsageTitle;

  /// No description provided for @recurringTransactionUsageContent.
  ///
  /// In zh, this message translates to:
  /// **'周期记账会在每次冷启动进入App时自动扫描并生成账单。设置日期后，系统会在该日期之后的冷启动时创建对应账单。例如：设置11月27日，则会在11月27日之后的首次启动时自动记账。'**
  String get recurringTransactionUsageContent;

  /// No description provided for @ledgerSelectTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择账本'**
  String get ledgerSelectTitle;

  /// No description provided for @ledgerSelect.
  ///
  /// In zh, this message translates to:
  /// **'选择账本'**
  String get ledgerSelect;

  /// No description provided for @syncNotConfiguredMessage.
  ///
  /// In zh, this message translates to:
  /// **'未配置云端'**
  String get syncNotConfiguredMessage;

  /// No description provided for @syncNotLoggedInMessage.
  ///
  /// In zh, this message translates to:
  /// **'未登录'**
  String get syncNotLoggedInMessage;

  /// No description provided for @syncCloudBackupCorruptedMessage.
  ///
  /// In zh, this message translates to:
  /// **'云端备份内容无法解析，可能是早期版本编码问题造成的损坏。请点击\\\"上传当前账本到云端\\\"覆盖修复。'**
  String get syncCloudBackupCorruptedMessage;

  /// No description provided for @syncNoCloudBackupMessage.
  ///
  /// In zh, this message translates to:
  /// **'云端暂无备份'**
  String get syncNoCloudBackupMessage;

  /// No description provided for @syncAccessDeniedMessage.
  ///
  /// In zh, this message translates to:
  /// **'403 拒绝访问（检查 storage RLS 策略与路径）'**
  String get syncAccessDeniedMessage;

  /// No description provided for @cloudTestConnection.
  ///
  /// In zh, this message translates to:
  /// **'测试连接'**
  String get cloudTestConnection;

  /// No description provided for @cloudCustomSupabaseSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'点击配置自建Supabase服务'**
  String get cloudCustomSupabaseSubtitle;

  /// No description provided for @cloudCustomWebdavSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'点击配置坚果云/Nextcloud等'**
  String get cloudCustomWebdavSubtitle;

  /// No description provided for @cloudCustomS3Title.
  ///
  /// In zh, this message translates to:
  /// **'S3 协议存储'**
  String get cloudCustomS3Title;

  /// No description provided for @cloudCustomS3Subtitle.
  ///
  /// In zh, this message translates to:
  /// **'AWS S3 / Cloudflare R2 / MinIO'**
  String get cloudCustomS3Subtitle;

  /// No description provided for @cloudSmartBookCloudTitle.
  ///
  /// In zh, this message translates to:
  /// **'智记'**
  String get cloudSmartBookCloudTitle;

  /// No description provided for @cloudSmartBookCloudSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'自建云服务 · 增量同步 · 多设备协同'**
  String get cloudSmartBookCloudSubtitle;

  /// No description provided for @cloudConfigureSmartBookCloudTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置智记'**
  String get cloudConfigureSmartBookCloudTitle;

  /// No description provided for @cloudSmartBookCloudUrlLabel.
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get cloudSmartBookCloudUrlLabel;

  /// No description provided for @cloudSmartBookCloudUrlHint.
  ///
  /// In zh, this message translates to:
  /// **'https://your-server.com'**
  String get cloudSmartBookCloudUrlHint;

  /// No description provided for @cloudSmartBookCloudApiPrefixLabel.
  ///
  /// In zh, this message translates to:
  /// **'API 前缀'**
  String get cloudSmartBookCloudApiPrefixLabel;

  /// No description provided for @cloudSmartBookCloudApiPrefixHint.
  ///
  /// In zh, this message translates to:
  /// **'/api/v1'**
  String get cloudSmartBookCloudApiPrefixHint;

  /// No description provided for @cloudSmartBookCloudEmailLabel.
  ///
  /// In zh, this message translates to:
  /// **'邮箱'**
  String get cloudSmartBookCloudEmailLabel;

  /// No description provided for @cloudSmartBookCloudEmailHint.
  ///
  /// In zh, this message translates to:
  /// **'your@email.com'**
  String get cloudSmartBookCloudEmailHint;

  /// No description provided for @cloudSmartBookCloudPasswordLabel.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get cloudSmartBookCloudPasswordLabel;

  /// No description provided for @cloudSmartBookCloudPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'输入密码'**
  String get cloudSmartBookCloudPasswordHint;

  /// No description provided for @cloudSmartBookCloudLoginSuccess.
  ///
  /// In zh, this message translates to:
  /// **'登录成功'**
  String get cloudSmartBookCloudLoginSuccess;

  /// No description provided for @cloudSmartBookCloudLoginFailed.
  ///
  /// In zh, this message translates to:
  /// **'登录失败'**
  String get cloudSmartBookCloudLoginFailed;

  /// No description provided for @cloudSmartBookCloudSyncSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'增量同步 · 多设备协同'**
  String get cloudSmartBookCloudSyncSubtitle;

  /// No description provided for @cloudSmartBookCloudConnected.
  ///
  /// In zh, this message translates to:
  /// **'已连接'**
  String get cloudSmartBookCloudConnected;

  /// No description provided for @cloudSmartBookCloudNotConnected.
  ///
  /// In zh, this message translates to:
  /// **'未连接'**
  String get cloudSmartBookCloudNotConnected;

  /// No description provided for @cloudSmartBookCloudNotConnectedHint.
  ///
  /// In zh, this message translates to:
  /// **'请先在云服务设置中配置并登录'**
  String get cloudSmartBookCloudNotConnectedHint;

  /// No description provided for @cloudSmartBookCloudAutoSync.
  ///
  /// In zh, this message translates to:
  /// **'增量同步'**
  String get cloudSmartBookCloudAutoSync;

  /// No description provided for @cloudSmartBookCloudAutoSyncHint.
  ///
  /// In zh, this message translates to:
  /// **'数据变更自动同步到云端，无需手动操作'**
  String get cloudSmartBookCloudAutoSyncHint;

  /// No description provided for @cloudSmartBookCloudMultiDevice.
  ///
  /// In zh, this message translates to:
  /// **'多设备协同'**
  String get cloudSmartBookCloudMultiDevice;

  /// No description provided for @cloudSmartBookCloudMultiDeviceHint.
  ///
  /// In zh, this message translates to:
  /// **'多台设备间自动保持数据一致'**
  String get cloudSmartBookCloudMultiDeviceHint;

  /// No description provided for @cloudSmartBookCloudAttachment.
  ///
  /// In zh, this message translates to:
  /// **'附件同步'**
  String get cloudSmartBookCloudAttachment;

  /// No description provided for @cloudSmartBookCloudAttachmentHint.
  ///
  /// In zh, this message translates to:
  /// **'账单图片等附件自动云端备份'**
  String get cloudSmartBookCloudAttachmentHint;

  /// No description provided for @cloudTabOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线模式'**
  String get cloudTabOffline;

  /// No description provided for @cloudTabBackup.
  ///
  /// In zh, this message translates to:
  /// **'备份同步'**
  String get cloudTabBackup;

  /// No description provided for @cloudTabCloudSync.
  ///
  /// In zh, this message translates to:
  /// **'云端协同'**
  String get cloudTabCloudSync;

  /// No description provided for @cloudIcloudSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'使用 Apple ID 自动同步'**
  String get cloudIcloudSubtitle;

  /// No description provided for @cloudIcloudNotAvailableTitle.
  ///
  /// In zh, this message translates to:
  /// **'iCloud 不可用'**
  String get cloudIcloudNotAvailableTitle;

  /// No description provided for @cloudIcloudNotAvailableMessage.
  ///
  /// In zh, this message translates to:
  /// **'请在系统设置中登录 iCloud 账户后再试'**
  String get cloudIcloudNotAvailableMessage;

  /// No description provided for @cloudIcloudHelpTitle.
  ///
  /// In zh, this message translates to:
  /// **'iCloud 使用说明'**
  String get cloudIcloudHelpTitle;

  /// No description provided for @cloudIcloudHelpPrerequisites.
  ///
  /// In zh, this message translates to:
  /// **'前提条件'**
  String get cloudIcloudHelpPrerequisites;

  /// No description provided for @cloudIcloudHelpPrereq1.
  ///
  /// In zh, this message translates to:
  /// **'1. 设备已登录 Apple ID'**
  String get cloudIcloudHelpPrereq1;

  /// No description provided for @cloudIcloudHelpPrereq2.
  ///
  /// In zh, this message translates to:
  /// **'2. 已开启 iCloud Drive'**
  String get cloudIcloudHelpPrereq2;

  /// No description provided for @cloudIcloudHelpPrereq3.
  ///
  /// In zh, this message translates to:
  /// **'3. 设备已联网'**
  String get cloudIcloudHelpPrereq3;

  /// No description provided for @cloudIcloudHelpCheckTitle.
  ///
  /// In zh, this message translates to:
  /// **'如何检查 iCloud Drive'**
  String get cloudIcloudHelpCheckTitle;

  /// No description provided for @cloudIcloudHelpCheck1.
  ///
  /// In zh, this message translates to:
  /// **'1. 打开「设置」'**
  String get cloudIcloudHelpCheck1;

  /// No description provided for @cloudIcloudHelpCheck2.
  ///
  /// In zh, this message translates to:
  /// **'2. 点击顶部的 Apple ID'**
  String get cloudIcloudHelpCheck2;

  /// No description provided for @cloudIcloudHelpCheck3.
  ///
  /// In zh, this message translates to:
  /// **'3. 点击「iCloud」'**
  String get cloudIcloudHelpCheck3;

  /// No description provided for @cloudIcloudHelpCheck4.
  ///
  /// In zh, this message translates to:
  /// **'4. 确保「iCloud 云盘」已开启'**
  String get cloudIcloudHelpCheck4;

  /// No description provided for @cloudIcloudHelpFaqTitle.
  ///
  /// In zh, this message translates to:
  /// **'常见问题'**
  String get cloudIcloudHelpFaqTitle;

  /// No description provided for @cloudIcloudHelpFaq1.
  ///
  /// In zh, this message translates to:
  /// **'如果提示不可用，请检查 iCloud Drive 是否开启'**
  String get cloudIcloudHelpFaq1;

  /// No description provided for @cloudIcloudHelpFaq2.
  ///
  /// In zh, this message translates to:
  /// **'首次使用可能需要等待几秒钟初始化'**
  String get cloudIcloudHelpFaq2;

  /// No description provided for @cloudIcloudHelpFaq3.
  ///
  /// In zh, this message translates to:
  /// **'数据存储在您的私人 iCloud 空间中'**
  String get cloudIcloudHelpFaq3;

  /// No description provided for @cloudIcloudHelpFaq4.
  ///
  /// In zh, this message translates to:
  /// **'同一 Apple ID 的设备可自动同步'**
  String get cloudIcloudHelpFaq4;

  /// No description provided for @cloudIcloudHelpNote.
  ///
  /// In zh, this message translates to:
  /// **'iCloud 同步使用您的 Apple ID，无需额外配置'**
  String get cloudIcloudHelpNote;

  /// No description provided for @cloudSupabaseHelpTitle.
  ///
  /// In zh, this message translates to:
  /// **'Supabase 配置说明'**
  String get cloudSupabaseHelpTitle;

  /// No description provided for @cloudSupabaseHelpIntro.
  ///
  /// In zh, this message translates to:
  /// **'什么是 Supabase'**
  String get cloudSupabaseHelpIntro;

  /// No description provided for @cloudSupabaseHelpIntro1.
  ///
  /// In zh, this message translates to:
  /// **'Supabase 是一个开源的后端即服务平台'**
  String get cloudSupabaseHelpIntro1;

  /// No description provided for @cloudSupabaseHelpIntro2.
  ///
  /// In zh, this message translates to:
  /// **'提供免费套餐，足够个人使用'**
  String get cloudSupabaseHelpIntro2;

  /// No description provided for @cloudSupabaseHelpIntro3.
  ///
  /// In zh, this message translates to:
  /// **'数据完全由您掌控'**
  String get cloudSupabaseHelpIntro3;

  /// No description provided for @cloudSupabaseHelpSteps.
  ///
  /// In zh, this message translates to:
  /// **'配置步骤'**
  String get cloudSupabaseHelpSteps;

  /// No description provided for @cloudSupabaseHelpStep1.
  ///
  /// In zh, this message translates to:
  /// **'1. 访问 supabase.com 注册账号'**
  String get cloudSupabaseHelpStep1;

  /// No description provided for @cloudSupabaseHelpStep2.
  ///
  /// In zh, this message translates to:
  /// **'2. 创建新项目（选择免费套餐）'**
  String get cloudSupabaseHelpStep2;

  /// No description provided for @cloudSupabaseHelpStep3.
  ///
  /// In zh, this message translates to:
  /// **'3. 进入项目设置 > API'**
  String get cloudSupabaseHelpStep3;

  /// No description provided for @cloudSupabaseHelpStep4.
  ///
  /// In zh, this message translates to:
  /// **'4. 复制 Project URL 和 anon key'**
  String get cloudSupabaseHelpStep4;

  /// No description provided for @cloudSupabaseHelpStep5.
  ///
  /// In zh, this message translates to:
  /// **'5. 粘贴到应用的配置中'**
  String get cloudSupabaseHelpStep5;

  /// No description provided for @cloudSupabaseHelpFaq.
  ///
  /// In zh, this message translates to:
  /// **'常见问题'**
  String get cloudSupabaseHelpFaq;

  /// No description provided for @cloudSupabaseHelpFaq1.
  ///
  /// In zh, this message translates to:
  /// **'免费套餐有 500MB 存储空间'**
  String get cloudSupabaseHelpFaq1;

  /// No description provided for @cloudSupabaseHelpFaq2.
  ///
  /// In zh, this message translates to:
  /// **'数据加密存储，安全可靠'**
  String get cloudSupabaseHelpFaq2;

  /// No description provided for @cloudSupabaseHelpFaq3.
  ///
  /// In zh, this message translates to:
  /// **'支持多设备同步'**
  String get cloudSupabaseHelpFaq3;

  /// No description provided for @cloudSupabaseHelpNote.
  ///
  /// In zh, this message translates to:
  /// **'配置完成后需要注册/登录账号才能使用同步功能'**
  String get cloudSupabaseHelpNote;

  /// No description provided for @cloudDetailedTutorial.
  ///
  /// In zh, this message translates to:
  /// **'详细教程'**
  String get cloudDetailedTutorial;

  /// No description provided for @cloudWebdavHelpTitle.
  ///
  /// In zh, this message translates to:
  /// **'WebDAV 配置说明'**
  String get cloudWebdavHelpTitle;

  /// No description provided for @cloudWebdavHelpIntro.
  ///
  /// In zh, this message translates to:
  /// **'什么是 WebDAV'**
  String get cloudWebdavHelpIntro;

  /// No description provided for @cloudWebdavHelpIntro1.
  ///
  /// In zh, this message translates to:
  /// **'WebDAV 是一种网络文件协议'**
  String get cloudWebdavHelpIntro1;

  /// No description provided for @cloudWebdavHelpIntro2.
  ///
  /// In zh, this message translates to:
  /// **'支持多种云盘和NAS设备'**
  String get cloudWebdavHelpIntro2;

  /// No description provided for @cloudWebdavHelpIntro3.
  ///
  /// In zh, this message translates to:
  /// **'数据存储在您自己的服务器上'**
  String get cloudWebdavHelpIntro3;

  /// No description provided for @cloudWebdavHelpProviders.
  ///
  /// In zh, this message translates to:
  /// **'支持的服务商'**
  String get cloudWebdavHelpProviders;

  /// No description provided for @cloudWebdavHelpProvider1.
  ///
  /// In zh, this message translates to:
  /// **'• 坚果云（推荐国内用户）'**
  String get cloudWebdavHelpProvider1;

  /// No description provided for @cloudWebdavHelpProvider2.
  ///
  /// In zh, this message translates to:
  /// **'• Nextcloud / ownCloud'**
  String get cloudWebdavHelpProvider2;

  /// No description provided for @cloudWebdavHelpProvider3.
  ///
  /// In zh, this message translates to:
  /// **'• 群晖 / 威联通 NAS'**
  String get cloudWebdavHelpProvider3;

  /// No description provided for @cloudWebdavHelpProvider4.
  ///
  /// In zh, this message translates to:
  /// **'• 其他支持 WebDAV 的服务'**
  String get cloudWebdavHelpProvider4;

  /// No description provided for @cloudWebdavHelpSteps.
  ///
  /// In zh, this message translates to:
  /// **'配置步骤（以坚果云为例）'**
  String get cloudWebdavHelpSteps;

  /// No description provided for @cloudWebdavHelpStep1.
  ///
  /// In zh, this message translates to:
  /// **'1. 登录坚果云网页版'**
  String get cloudWebdavHelpStep1;

  /// No description provided for @cloudWebdavHelpStep2.
  ///
  /// In zh, this message translates to:
  /// **'2. 点击右上角账户名 > 账户信息'**
  String get cloudWebdavHelpStep2;

  /// No description provided for @cloudWebdavHelpStep3.
  ///
  /// In zh, this message translates to:
  /// **'3. 选择「安全选项」标签'**
  String get cloudWebdavHelpStep3;

  /// No description provided for @cloudWebdavHelpStep4.
  ///
  /// In zh, this message translates to:
  /// **'4. 添加应用密码（用于第三方应用）'**
  String get cloudWebdavHelpStep4;

  /// No description provided for @cloudWebdavHelpStep5.
  ///
  /// In zh, this message translates to:
  /// **'5. 复制服务器地址、账号、应用密码'**
  String get cloudWebdavHelpStep5;

  /// No description provided for @cloudWebdavHelpNote.
  ///
  /// In zh, this message translates to:
  /// **'建议使用应用专用密码，而非账号密码'**
  String get cloudWebdavHelpNote;

  /// No description provided for @cloudS3HelpTitle.
  ///
  /// In zh, this message translates to:
  /// **'S3 存储配置说明'**
  String get cloudS3HelpTitle;

  /// No description provided for @cloudS3HelpIntro.
  ///
  /// In zh, this message translates to:
  /// **'什么是 S3'**
  String get cloudS3HelpIntro;

  /// No description provided for @cloudS3HelpIntro1.
  ///
  /// In zh, this message translates to:
  /// **'S3 是一种标准的对象存储协议'**
  String get cloudS3HelpIntro1;

  /// No description provided for @cloudS3HelpIntro2.
  ///
  /// In zh, this message translates to:
  /// **'支持多家云服务商'**
  String get cloudS3HelpIntro2;

  /// No description provided for @cloudS3HelpIntro3.
  ///
  /// In zh, this message translates to:
  /// **'数据存储在您选择的云服务中'**
  String get cloudS3HelpIntro3;

  /// No description provided for @cloudS3HelpProviders.
  ///
  /// In zh, this message translates to:
  /// **'支持的服务商'**
  String get cloudS3HelpProviders;

  /// No description provided for @cloudS3HelpProvider1.
  ///
  /// In zh, this message translates to:
  /// **'• AWS S3（Amazon Web Services）'**
  String get cloudS3HelpProvider1;

  /// No description provided for @cloudS3HelpProvider2.
  ///
  /// In zh, this message translates to:
  /// **'• Cloudflare R2（免费 10GB/月）'**
  String get cloudS3HelpProvider2;

  /// No description provided for @cloudS3HelpProvider3.
  ///
  /// In zh, this message translates to:
  /// **'• Backblaze B2（免费 10GB）'**
  String get cloudS3HelpProvider3;

  /// No description provided for @cloudS3HelpProvider4.
  ///
  /// In zh, this message translates to:
  /// **'• MinIO（自建服务）'**
  String get cloudS3HelpProvider4;

  /// No description provided for @cloudS3HelpProvider5.
  ///
  /// In zh, this message translates to:
  /// **'• 阿里云 OSS'**
  String get cloudS3HelpProvider5;

  /// No description provided for @cloudS3HelpProvider6.
  ///
  /// In zh, this message translates to:
  /// **'• 腾讯云 COS'**
  String get cloudS3HelpProvider6;

  /// No description provided for @cloudS3HelpProvider7.
  ///
  /// In zh, this message translates to:
  /// **'• 七牛云 Kodo'**
  String get cloudS3HelpProvider7;

  /// No description provided for @cloudS3HelpSteps.
  ///
  /// In zh, this message translates to:
  /// **'配置步骤（以 Cloudflare R2 为例）'**
  String get cloudS3HelpSteps;

  /// No description provided for @cloudS3HelpStep1.
  ///
  /// In zh, this message translates to:
  /// **'1. 登录 Cloudflare 控制台'**
  String get cloudS3HelpStep1;

  /// No description provided for @cloudS3HelpStep2.
  ///
  /// In zh, this message translates to:
  /// **'2. 进入 R2 > 创建存储桶'**
  String get cloudS3HelpStep2;

  /// No description provided for @cloudS3HelpStep3.
  ///
  /// In zh, this message translates to:
  /// **'3. 进入 R2 > 管理 R2 API 令牌'**
  String get cloudS3HelpStep3;

  /// No description provided for @cloudS3HelpStep4.
  ///
  /// In zh, this message translates to:
  /// **'4. 创建 API 令牌并复制凭据'**
  String get cloudS3HelpStep4;

  /// No description provided for @cloudS3HelpStep5.
  ///
  /// In zh, this message translates to:
  /// **'5. 粘贴端点、访问密钥、私密密钥和存储桶名称'**
  String get cloudS3HelpStep5;

  /// No description provided for @cloudS3HelpNote.
  ///
  /// In zh, this message translates to:
  /// **'推荐使用 Cloudflare R2，提供 10GB 免费存储且无流量费'**
  String get cloudS3HelpNote;

  /// No description provided for @cloudStatusNotTested.
  ///
  /// In zh, this message translates to:
  /// **'未测试'**
  String get cloudStatusNotTested;

  /// No description provided for @cloudStatusNormal.
  ///
  /// In zh, this message translates to:
  /// **'连接正常'**
  String get cloudStatusNormal;

  /// No description provided for @cloudStatusFailed.
  ///
  /// In zh, this message translates to:
  /// **'连接失败'**
  String get cloudStatusFailed;

  /// No description provided for @cloudCannotOpenLink.
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接'**
  String get cloudCannotOpenLink;

  /// No description provided for @cloudErrorAuthFailed.
  ///
  /// In zh, this message translates to:
  /// **'认证失败: API Key 无效'**
  String get cloudErrorAuthFailed;

  /// No description provided for @cloudErrorServerStatus.
  ///
  /// In zh, this message translates to:
  /// **'服务器返回状态码 {code}'**
  String cloudErrorServerStatus(String code);

  /// No description provided for @cloudErrorWebdavNotSupported.
  ///
  /// In zh, this message translates to:
  /// **'服务器不支持 WebDAV 协议'**
  String get cloudErrorWebdavNotSupported;

  /// No description provided for @cloudErrorAuthFailedCredentials.
  ///
  /// In zh, this message translates to:
  /// **'认证失败: 用户名或密码错误'**
  String get cloudErrorAuthFailedCredentials;

  /// No description provided for @cloudErrorAccessDenied.
  ///
  /// In zh, this message translates to:
  /// **'访问被拒绝: 请检查权限'**
  String get cloudErrorAccessDenied;

  /// No description provided for @cloudErrorPathNotFound.
  ///
  /// In zh, this message translates to:
  /// **'服务器路径不存在: {path}'**
  String cloudErrorPathNotFound(String path);

  /// No description provided for @cloudErrorNetwork.
  ///
  /// In zh, this message translates to:
  /// **'网络错误: {message}'**
  String cloudErrorNetwork(String message);

  /// No description provided for @cloudTestSuccessTitle.
  ///
  /// In zh, this message translates to:
  /// **'测试成功'**
  String get cloudTestSuccessTitle;

  /// No description provided for @cloudTestSuccessMessage.
  ///
  /// In zh, this message translates to:
  /// **'连接正常,配置有效'**
  String get cloudTestSuccessMessage;

  /// No description provided for @cloudTestFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'测试失败'**
  String get cloudTestFailedTitle;

  /// No description provided for @cloudTestFailedMessage.
  ///
  /// In zh, this message translates to:
  /// **'连接失败'**
  String get cloudTestFailedMessage;

  /// No description provided for @cloudTestErrorTitle.
  ///
  /// In zh, this message translates to:
  /// **'测试错误'**
  String get cloudTestErrorTitle;

  /// No description provided for @cloudSupabaseAnonKeyHintLong.
  ///
  /// In zh, this message translates to:
  /// **'粘贴完整的 anon key'**
  String get cloudSupabaseAnonKeyHintLong;

  /// No description provided for @cloudWebdavRemotePathLabel.
  ///
  /// In zh, this message translates to:
  /// **'远程路径'**
  String get cloudWebdavRemotePathLabel;

  /// No description provided for @cloudWebdavRemotePathHelperText.
  ///
  /// In zh, this message translates to:
  /// **'数据存储的远程目录路径'**
  String get cloudWebdavRemotePathHelperText;

  /// No description provided for @accountsTitle.
  ///
  /// In zh, this message translates to:
  /// **'资产管理'**
  String get accountsTitle;

  /// No description provided for @accountsEmptyMessage.
  ///
  /// In zh, this message translates to:
  /// **'还没有账户，点击右上角添加'**
  String get accountsEmptyMessage;

  /// No description provided for @accountAddTooltip.
  ///
  /// In zh, this message translates to:
  /// **'添加账户'**
  String get accountAddTooltip;

  /// No description provided for @accountAddButton.
  ///
  /// In zh, this message translates to:
  /// **'添加账户'**
  String get accountAddButton;

  /// No description provided for @accountBalance.
  ///
  /// In zh, this message translates to:
  /// **'余额'**
  String get accountBalance;

  /// No description provided for @accountEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑账户'**
  String get accountEditTitle;

  /// No description provided for @accountNewTitle.
  ///
  /// In zh, this message translates to:
  /// **'新建账户'**
  String get accountNewTitle;

  /// No description provided for @accountNameLabel.
  ///
  /// In zh, this message translates to:
  /// **'账户名称'**
  String get accountNameLabel;

  /// No description provided for @accountNameHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：工商银行、支付宝等'**
  String get accountNameHint;

  /// No description provided for @accountNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入账户名称'**
  String get accountNameRequired;

  /// No description provided for @accountNameDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'账户名称已存在，请使用其他名称'**
  String get accountNameDuplicate;

  /// No description provided for @accountTypeLabel.
  ///
  /// In zh, this message translates to:
  /// **'账户类型'**
  String get accountTypeLabel;

  /// No description provided for @accountTypeCash.
  ///
  /// In zh, this message translates to:
  /// **'现金'**
  String get accountTypeCash;

  /// No description provided for @accountTypeBankCard.
  ///
  /// In zh, this message translates to:
  /// **'银行卡'**
  String get accountTypeBankCard;

  /// No description provided for @accountTypeCreditCard.
  ///
  /// In zh, this message translates to:
  /// **'信用卡'**
  String get accountTypeCreditCard;

  /// No description provided for @accountTypeAlipay.
  ///
  /// In zh, this message translates to:
  /// **'支付宝'**
  String get accountTypeAlipay;

  /// No description provided for @accountTypeWechat.
  ///
  /// In zh, this message translates to:
  /// **'微信'**
  String get accountTypeWechat;

  /// No description provided for @accountTypeOther.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get accountTypeOther;

  /// No description provided for @accountInitialBalance.
  ///
  /// In zh, this message translates to:
  /// **'初始资金'**
  String get accountInitialBalance;

  /// No description provided for @accountInitialBalanceHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入初始资金（可选）'**
  String get accountInitialBalanceHint;

  /// No description provided for @accountInitialBalanceLocked.
  ///
  /// In zh, this message translates to:
  /// **'初始值创建后不可修改，如需调整请使用「调整余额」'**
  String get accountInitialBalanceLocked;

  /// No description provided for @accountAdjustBalanceLabel.
  ///
  /// In zh, this message translates to:
  /// **'调整余额'**
  String get accountAdjustBalanceLabel;

  /// No description provided for @accountAdjustBalanceHint.
  ///
  /// In zh, this message translates to:
  /// **'输入调整后的当前余额（如与银行对账单核对）'**
  String get accountAdjustBalanceHint;

  /// No description provided for @accountAdjustBalanceNote.
  ///
  /// In zh, this message translates to:
  /// **'余额调整'**
  String get accountAdjustBalanceNote;

  /// No description provided for @accountAdjustmentsTitle.
  ///
  /// In zh, this message translates to:
  /// **'调整记录'**
  String get accountAdjustmentsTitle;

  /// No description provided for @accountAdjustmentsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无余额调整记录'**
  String get accountAdjustmentsEmpty;

  /// No description provided for @accountAdjustmentsViewAction.
  ///
  /// In zh, this message translates to:
  /// **'调整记录'**
  String get accountAdjustmentsViewAction;

  /// No description provided for @accountBalanceAdjustedToast.
  ///
  /// In zh, this message translates to:
  /// **'已记录余额调整，入账同步中'**
  String get accountBalanceAdjustedToast;

  /// No description provided for @accountAdjustBalanceSame.
  ///
  /// In zh, this message translates to:
  /// **'余额与输入一致，无需调整'**
  String get accountAdjustBalanceSame;

  /// No description provided for @accountAdjustBalanceNewValue.
  ///
  /// In zh, this message translates to:
  /// **'调整后余额'**
  String get accountAdjustBalanceNewValue;

  /// No description provided for @accountAdjustBalanceUpdate.
  ///
  /// In zh, this message translates to:
  /// **'确认更新'**
  String get accountAdjustBalanceUpdate;

  /// No description provided for @accountAdjustBalanceInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的金额'**
  String get accountAdjustBalanceInvalid;

  /// No description provided for @accountDeleteWarningTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认删除'**
  String get accountDeleteWarningTitle;

  /// No description provided for @accountDeleteWarningMessage.
  ///
  /// In zh, this message translates to:
  /// **'该账户有 {count} 笔关联交易，删除后交易记录中的账户信息将被清空。确认删除吗？'**
  String accountDeleteWarningMessage(int count);

  /// No description provided for @accountDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认删除该账户吗？'**
  String get accountDeleteConfirm;

  /// No description provided for @accountSelectTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择账户'**
  String get accountSelectTitle;

  /// No description provided for @accountNone.
  ///
  /// In zh, this message translates to:
  /// **'不选择账户'**
  String get accountNone;

  /// No description provided for @accountsEnableFeature.
  ///
  /// In zh, this message translates to:
  /// **'启用账户功能'**
  String get accountsEnableFeature;

  /// No description provided for @accountHide.
  ///
  /// In zh, this message translates to:
  /// **'隐藏账户'**
  String get accountHide;

  /// No description provided for @accountUnhide.
  ///
  /// In zh, this message translates to:
  /// **'恢复账户'**
  String get accountUnhide;

  /// No description provided for @accountRestore.
  ///
  /// In zh, this message translates to:
  /// **'恢复'**
  String get accountRestore;

  /// No description provided for @accountHiddenTag.
  ///
  /// In zh, this message translates to:
  /// **'已隐藏'**
  String get accountHiddenTag;

  /// No description provided for @accountHiddenSection.
  ///
  /// In zh, this message translates to:
  /// **'已隐藏'**
  String get accountHiddenSection;

  /// No description provided for @accountHiddenSectionSummary.
  ///
  /// In zh, this message translates to:
  /// **'已隐藏 {count} · 合计 {total}'**
  String accountHiddenSectionSummary(Object count, Object total);

  /// No description provided for @accountHideConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'隐藏此账户？'**
  String get accountHideConfirmTitle;

  /// No description provided for @accountHideConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'隐藏后无法再记账到它，新增记账时也不再显示；历史交易与余额保留，可随时恢复。'**
  String get accountHideConfirmBody;

  /// No description provided for @accountHideRecurringWarn.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 个周期账单在用此账户，隐藏后这些账单将跳过生成，建议先改到其他账户。'**
  String accountHideRecurringWarn(Object count);

  /// No description provided for @accountHideClearedDefault.
  ///
  /// In zh, this message translates to:
  /// **'已取消其默认账户设置'**
  String get accountHideClearedDefault;

  /// No description provided for @accountHiddenToast.
  ///
  /// In zh, this message translates to:
  /// **'已隐藏'**
  String get accountHiddenToast;

  /// No description provided for @accountRestoredToast.
  ///
  /// In zh, this message translates to:
  /// **'已恢复'**
  String get accountRestoredToast;

  /// No description provided for @privacyOpenSourceUrlError.
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接'**
  String get privacyOpenSourceUrlError;

  /// No description provided for @welcomeTitle.
  ///
  /// In zh, this message translates to:
  /// **'欢迎使用智记'**
  String get welcomeTitle;

  /// No description provided for @welcomeDescription.
  ///
  /// In zh, this message translates to:
  /// **'一个真正尊重您隐私的记账应用'**
  String get welcomeDescription;

  /// No description provided for @welcomeCurrencyDescription.
  ///
  /// In zh, this message translates to:
  /// **'选择您常用的货币，之后可以随时在设置中更改'**
  String get welcomeCurrencyDescription;

  /// No description provided for @welcomeCreateDefaultLedger.
  ///
  /// In zh, this message translates to:
  /// **'创建默认账本'**
  String get welcomeCreateDefaultLedger;

  /// No description provided for @welcomePrivacyTitle.
  ///
  /// In zh, this message translates to:
  /// **'开源透明 · 社群驱动'**
  String get welcomePrivacyTitle;

  /// No description provided for @welcomePrivacyFeature1.
  ///
  /// In zh, this message translates to:
  /// **'100% 开源代码，接受社区监督'**
  String get welcomePrivacyFeature1;

  /// No description provided for @welcomePrivacyFeature2.
  ///
  /// In zh, this message translates to:
  /// **'无隐私顾虑，数据完全本地存储'**
  String get welcomePrivacyFeature2;

  /// No description provided for @welcomeOpenSourceFeature1.
  ///
  /// In zh, this message translates to:
  /// **'活跃的开发者社群，持续改进'**
  String get welcomeOpenSourceFeature1;

  /// No description provided for @welcomeViewGitHub.
  ///
  /// In zh, this message translates to:
  /// **'访问 GitHub 仓库'**
  String get welcomeViewGitHub;

  /// No description provided for @welcomeCloudSyncTitle.
  ///
  /// In zh, this message translates to:
  /// **'可选的云同步'**
  String get welcomeCloudSyncTitle;

  /// No description provided for @welcomeCloudSyncDescription.
  ///
  /// In zh, this message translates to:
  /// **'智记 支持多种同步方式，数据完全由你掌控'**
  String get welcomeCloudSyncDescription;

  /// No description provided for @welcomeCloudSyncFeature1.
  ///
  /// In zh, this message translates to:
  /// **'完全离线使用，无需云服务'**
  String get welcomeCloudSyncFeature1;

  /// No description provided for @welcomeCloudSyncFeature2.
  ///
  /// In zh, this message translates to:
  /// **'智记 自建云（多设备实时协同 + Web 端）'**
  String get welcomeCloudSyncFeature2;

  /// No description provided for @welcomeCloudSyncFeature3.
  ///
  /// In zh, this message translates to:
  /// **'iCloud / WebDAV / Supabase / S3 任选'**
  String get welcomeCloudSyncFeature3;

  /// No description provided for @widgetManagement.
  ///
  /// In zh, this message translates to:
  /// **'桌面小组件'**
  String get widgetManagement;

  /// No description provided for @widgetManagementDesc.
  ///
  /// In zh, this message translates to:
  /// **'在主屏幕快速查看收支情况'**
  String get widgetManagementDesc;

  /// No description provided for @widgetPreview.
  ///
  /// In zh, this message translates to:
  /// **'小组件预览'**
  String get widgetPreview;

  /// No description provided for @widgetPreviewDesc.
  ///
  /// In zh, this message translates to:
  /// **'小组件会自动显示当前账本的实际数据，主题色跟随应用设置'**
  String get widgetPreviewDesc;

  /// No description provided for @widgetGalleryTitle.
  ///
  /// In zh, this message translates to:
  /// **'组件库'**
  String get widgetGalleryTitle;

  /// No description provided for @widgetGalleryDesc.
  ///
  /// In zh, this message translates to:
  /// **'以下为示例效果，实际将显示当前账本的真实数据，主题色跟随 App 设置'**
  String get widgetGalleryDesc;

  /// No description provided for @widgetGalleryGlanceTitle.
  ///
  /// In zh, this message translates to:
  /// **'收支速览'**
  String get widgetGalleryGlanceTitle;

  /// No description provided for @widgetGalleryGlanceDesc.
  ///
  /// In zh, this message translates to:
  /// **'今日和本月收支一目了然'**
  String get widgetGalleryGlanceDesc;

  /// No description provided for @widgetGalleryNetWorthDesc.
  ///
  /// In zh, this message translates to:
  /// **'总资产、总负债与净值趋势'**
  String get widgetGalleryNetWorthDesc;

  /// No description provided for @widgetGalleryQuickAddTitle.
  ///
  /// In zh, this message translates to:
  /// **'快速记账'**
  String get widgetGalleryQuickAddTitle;

  /// No description provided for @widgetGalleryQuickAddDesc.
  ///
  /// In zh, this message translates to:
  /// **'常用分类一键速记'**
  String get widgetGalleryQuickAddDesc;

  /// No description provided for @widgetGalleryBudgetDesc.
  ///
  /// In zh, this message translates to:
  /// **'预算进度实时掌握'**
  String get widgetGalleryBudgetDesc;

  /// No description provided for @widgetGalleryRecentDesc.
  ///
  /// In zh, this message translates to:
  /// **'快速查看最近几笔账单'**
  String get widgetGalleryRecentDesc;

  /// No description provided for @widgetGalleryDashboardTitle.
  ///
  /// In zh, this message translates to:
  /// **'综合仪表盘'**
  String get widgetGalleryDashboardTitle;

  /// No description provided for @widgetDashboardTitle.
  ///
  /// In zh, this message translates to:
  /// **'本月概览'**
  String get widgetDashboardTitle;

  /// No description provided for @widgetGalleryDashboardDesc.
  ///
  /// In zh, this message translates to:
  /// **'收支、趋势与最近交易一屏看尽'**
  String get widgetGalleryDashboardDesc;

  /// No description provided for @widgetSizeSmall.
  ///
  /// In zh, this message translates to:
  /// **'小号'**
  String get widgetSizeSmall;

  /// No description provided for @widgetSizeMedium.
  ///
  /// In zh, this message translates to:
  /// **'中号'**
  String get widgetSizeMedium;

  /// No description provided for @widgetSizeLarge.
  ///
  /// In zh, this message translates to:
  /// **'大号'**
  String get widgetSizeLarge;

  /// No description provided for @howToAddWidget.
  ///
  /// In zh, this message translates to:
  /// **'如何添加小组件'**
  String get howToAddWidget;

  /// No description provided for @iosWidgetStep1.
  ///
  /// In zh, this message translates to:
  /// **'长按主屏幕空白区域，进入编辑模式'**
  String get iosWidgetStep1;

  /// No description provided for @iosWidgetStep2.
  ///
  /// In zh, this message translates to:
  /// **'点击左上角的\"+\"按钮'**
  String get iosWidgetStep2;

  /// No description provided for @iosWidgetStep3.
  ///
  /// In zh, this message translates to:
  /// **'搜索并选择\"智记\"'**
  String get iosWidgetStep3;

  /// No description provided for @iosWidgetStep4.
  ///
  /// In zh, this message translates to:
  /// **'选择中型小组件，添加到主屏幕'**
  String get iosWidgetStep4;

  /// No description provided for @androidWidgetStep1.
  ///
  /// In zh, this message translates to:
  /// **'长按主屏幕空白区域'**
  String get androidWidgetStep1;

  /// No description provided for @androidWidgetStep2.
  ///
  /// In zh, this message translates to:
  /// **'选择\"小组件\"或\"Widgets\"'**
  String get androidWidgetStep2;

  /// No description provided for @androidWidgetStep3.
  ///
  /// In zh, this message translates to:
  /// **'找到并长按\"智记\"小组件'**
  String get androidWidgetStep3;

  /// No description provided for @androidWidgetStep4.
  ///
  /// In zh, this message translates to:
  /// **'拖动到主屏幕合适位置'**
  String get androidWidgetStep4;

  /// No description provided for @aboutWidget.
  ///
  /// In zh, this message translates to:
  /// **'关于小组件'**
  String get aboutWidget;

  /// No description provided for @widgetDescription.
  ///
  /// In zh, this message translates to:
  /// **'小组件会自动同步显示今日和本月的收支数据，每30分钟自动刷新一次。打开应用后会立即更新数据。'**
  String get widgetDescription;

  /// No description provided for @widgetQuickEntryTitle.
  ///
  /// In zh, this message translates to:
  /// **'快捷记账'**
  String get widgetQuickEntryTitle;

  /// No description provided for @widgetQuickEntryDesc.
  ///
  /// In zh, this message translates to:
  /// **'点击小组件左侧区域可快速新建支出，点击右侧区域可快速新建收入。也可通过快捷指令使用 smartbook://new?type=transfer 快速发起转账。'**
  String get widgetQuickEntryDesc;

  /// No description provided for @appName.
  ///
  /// In zh, this message translates to:
  /// **'智记'**
  String get appName;

  /// No description provided for @monthSuffix.
  ///
  /// In zh, this message translates to:
  /// **'月'**
  String get monthSuffix;

  /// No description provided for @todayExpense.
  ///
  /// In zh, this message translates to:
  /// **'今日支出'**
  String get todayExpense;

  /// No description provided for @todayIncome.
  ///
  /// In zh, this message translates to:
  /// **'今日收入'**
  String get todayIncome;

  /// No description provided for @monthExpense.
  ///
  /// In zh, this message translates to:
  /// **'本月支出'**
  String get monthExpense;

  /// No description provided for @monthIncome.
  ///
  /// In zh, this message translates to:
  /// **'本月收入'**
  String get monthIncome;

  /// No description provided for @autoScreenshotBilling.
  ///
  /// In zh, this message translates to:
  /// **'截图自动记账'**
  String get autoScreenshotBilling;

  /// No description provided for @autoScreenshotBillingDesc.
  ///
  /// In zh, this message translates to:
  /// **'截图后自动识别支付信息'**
  String get autoScreenshotBillingDesc;

  /// No description provided for @autoScreenshotBillingTitle.
  ///
  /// In zh, this message translates to:
  /// **'截图自动记账'**
  String get autoScreenshotBillingTitle;

  /// No description provided for @featureDescription.
  ///
  /// In zh, this message translates to:
  /// **'功能说明'**
  String get featureDescription;

  /// No description provided for @featureDescriptionContent.
  ///
  /// In zh, this message translates to:
  /// **'截图支付页面后，系统会自动识别金额和商家信息，并创建支出记录。\n\n⚡ 识别速度约 2-3 秒（部分设备可能更长）\n🤖 智能匹配分类\n📝 自动填写备注\n\n⚠️ 注意：\n• 不同设备截图入库速度不同，识别延迟可能 5-10 秒\n• 部分设备可能无法正常工作，取决于系统实现\n• 识别成功后会自动跳过已处理的截图\n• 受Android分区存储限制（Android 10+），应用无法删除系统截图，需手动清理相册'**
  String get featureDescriptionContent;

  /// No description provided for @autoBilling.
  ///
  /// In zh, this message translates to:
  /// **'自动记账'**
  String get autoBilling;

  /// No description provided for @enabled.
  ///
  /// In zh, this message translates to:
  /// **'已启用'**
  String get enabled;

  /// No description provided for @disabled.
  ///
  /// In zh, this message translates to:
  /// **'已禁用'**
  String get disabled;

  /// No description provided for @photosPermissionRequired.
  ///
  /// In zh, this message translates to:
  /// **'需要照片权限才能监听截图'**
  String get photosPermissionRequired;

  /// No description provided for @photosPermissionLimitedHint.
  ///
  /// In zh, this message translates to:
  /// **'截图自动记账需要「允许所有照片」权限,请在系统设置中把智记的照片权限改为「允许所有照片」'**
  String get photosPermissionLimitedHint;

  /// No description provided for @enableSuccess.
  ///
  /// In zh, this message translates to:
  /// **'自动记账已启用'**
  String get enableSuccess;

  /// No description provided for @disableSuccess.
  ///
  /// In zh, this message translates to:
  /// **'自动记账已禁用'**
  String get disableSuccess;

  /// No description provided for @autoBillingBatteryTitle.
  ///
  /// In zh, this message translates to:
  /// **'保持后台运行'**
  String get autoBillingBatteryTitle;

  /// No description provided for @autoBillingBatteryGuideTitle.
  ///
  /// In zh, this message translates to:
  /// **'电池优化设置'**
  String get autoBillingBatteryGuideTitle;

  /// No description provided for @autoBillingBatteryDesc.
  ///
  /// In zh, this message translates to:
  /// **'自动记账需要应用在后台保持运行。部分手机会在锁屏后自动清理后台应用，导致自动记账功能失效。建议关闭电池优化以确保功能正常工作。'**
  String get autoBillingBatteryDesc;

  /// No description provided for @autoBillingCheckBattery.
  ///
  /// In zh, this message translates to:
  /// **'检查电池优化状态'**
  String get autoBillingCheckBattery;

  /// No description provided for @autoBillingBatteryWarning.
  ///
  /// In zh, this message translates to:
  /// **'⚠️ 未关闭电池优化，应用可能会被系统自动清理，导致自动记账失效。建议点击上方\"去设置\"按钮关闭电池优化。'**
  String get autoBillingBatteryWarning;

  /// No description provided for @enableFailed.
  ///
  /// In zh, this message translates to:
  /// **'启用失败'**
  String get enableFailed;

  /// No description provided for @disableFailed.
  ///
  /// In zh, this message translates to:
  /// **'禁用失败'**
  String get disableFailed;

  /// No description provided for @iosAutoFeatureDesc.
  ///
  /// In zh, this message translates to:
  /// **'通过iOS\"快捷指令\"应用，实现截图后自动识别支付信息并记账。设置后，每次截图都会自动触发识别。'**
  String get iosAutoFeatureDesc;

  /// No description provided for @iosAutoShortcutConfigTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置步骤：'**
  String get iosAutoShortcutConfigTitle;

  /// No description provided for @iosAutoShortcutStep1.
  ///
  /// In zh, this message translates to:
  /// **'打开\"快捷指令\"应用，点击右上角\"+\"创建新快捷指令'**
  String get iosAutoShortcutStep1;

  /// No description provided for @iosAutoShortcutStep2.
  ///
  /// In zh, this message translates to:
  /// **'添加\"截屏\"操作'**
  String get iosAutoShortcutStep2;

  /// No description provided for @iosAutoShortcutStep3.
  ///
  /// In zh, this message translates to:
  /// **'搜索并添加\"智记 - 截图自动记账\"操作'**
  String get iosAutoShortcutStep3;

  /// No description provided for @iosAutoShortcutStep4.
  ///
  /// In zh, this message translates to:
  /// **'将\"智记\"的截图参数设置为上一步的\"截屏\"'**
  String get iosAutoShortcutStep4;

  /// No description provided for @iosAutoShortcutStep5.
  ///
  /// In zh, this message translates to:
  /// **'（可选）在系统设置 > 辅助功能 > 触控 > 轻点背面中，绑定此快捷指令'**
  String get iosAutoShortcutStep5;

  /// No description provided for @iosAutoShortcutStep6.
  ///
  /// In zh, this message translates to:
  /// **'完成！支付时双击手机背部即可快速记账'**
  String get iosAutoShortcutStep6;

  /// No description provided for @iosAutoShortcutRecommendedTip.
  ///
  /// In zh, this message translates to:
  /// **'✅ 推荐：在\"轻点背面\"中绑定快捷指令后，支付时双击手机背部即可自动截图并识别记账，无需手动截图。'**
  String get iosAutoShortcutRecommendedTip;

  /// No description provided for @iosAutoBackTapTitle.
  ///
  /// In zh, this message translates to:
  /// **'💡 双击背部快速触发（推荐）'**
  String get iosAutoBackTapTitle;

  /// No description provided for @iosAutoBackTapDesc.
  ///
  /// In zh, this message translates to:
  /// **'设置 > 辅助功能 > 触控 > 轻点背面\n• 选择\"轻点两下\"或\"轻点三下\"\n• 选择刚创建的快捷指令\n• 完成后，支付时双击手机背面即可自动记账，无需截图'**
  String get iosAutoBackTapDesc;

  /// No description provided for @iosAutoTutorialTitle.
  ///
  /// In zh, this message translates to:
  /// **'视频教程'**
  String get iosAutoTutorialTitle;

  /// No description provided for @iosAutoTutorialDesc.
  ///
  /// In zh, this message translates to:
  /// **'查看详细配置视频教程'**
  String get iosAutoTutorialDesc;

  /// No description provided for @iosAutoImportTitle.
  ///
  /// In zh, this message translates to:
  /// **'一键获取快捷指令'**
  String get iosAutoImportTitle;

  /// No description provided for @iosAutoImportDesc.
  ///
  /// In zh, this message translates to:
  /// **'点击下方按钮，自动导入已配置好的「截屏 → 自动记账」快捷指令，无需手动添加“截屏”操作和连接参数。导入后建议在「轻点背面」中绑定它。'**
  String get iosAutoImportDesc;

  /// No description provided for @iosAutoImportButton.
  ///
  /// In zh, this message translates to:
  /// **'获取快捷指令'**
  String get iosAutoImportButton;

  /// No description provided for @iosAutoImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开快捷指令链接，请检查网络后重试'**
  String get iosAutoImportFailed;

  /// No description provided for @iosAutoManualConfigTitle.
  ///
  /// In zh, this message translates to:
  /// **'手动配置（高级）'**
  String get iosAutoManualConfigTitle;

  /// No description provided for @iosAutoManualConfigDesc.
  ///
  /// In zh, this message translates to:
  /// **'若一键导入不可用，可按以下步骤手动创建快捷指令。'**
  String get iosAutoManualConfigDesc;

  /// No description provided for @aiSettingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'AI小助手'**
  String get aiSettingsTitle;

  /// No description provided for @aiSettingsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'配置AI模型和识别策略'**
  String get aiSettingsSubtitle;

  /// No description provided for @aiEnableTitle.
  ///
  /// In zh, this message translates to:
  /// **'启用AI小助手'**
  String get aiEnableTitle;

  /// No description provided for @aiEnableSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'使用 AI 视觉识别账单截图,提取金额、商家、时间等信息,并支持自然语言对话'**
  String get aiEnableSubtitle;

  /// No description provided for @aiEnableToastOn.
  ///
  /// In zh, this message translates to:
  /// **'AI小助手已启用'**
  String get aiEnableToastOn;

  /// No description provided for @aiEnableToastOff.
  ///
  /// In zh, this message translates to:
  /// **'AI小助手已关闭'**
  String get aiEnableToastOff;

  /// No description provided for @aiStrategyTitle.
  ///
  /// In zh, this message translates to:
  /// **'执行策略'**
  String get aiStrategyTitle;

  /// No description provided for @aiStrategyLocalFirst.
  ///
  /// In zh, this message translates to:
  /// **'本地优先（推荐）'**
  String get aiStrategyLocalFirst;

  /// No description provided for @aiStrategyCloudFirst.
  ///
  /// In zh, this message translates to:
  /// **'云端优先'**
  String get aiStrategyCloudFirst;

  /// No description provided for @aiStrategyCloudFirstDesc.
  ///
  /// In zh, this message translates to:
  /// **'优先使用云端API，失败后降级到本地'**
  String get aiStrategyCloudFirstDesc;

  /// No description provided for @aiStrategyLocalOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅本地'**
  String get aiStrategyLocalOnly;

  /// No description provided for @aiStrategyCloudOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅云端'**
  String get aiStrategyCloudOnly;

  /// No description provided for @aiStrategyCloudOnlyDesc.
  ///
  /// In zh, this message translates to:
  /// **'只使用云端API，不下载模型'**
  String get aiStrategyCloudOnlyDesc;

  /// No description provided for @aiStrategyUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'本地模型训练中，敬请期待'**
  String get aiStrategyUnavailable;

  /// No description provided for @aiStrategySwitched.
  ///
  /// In zh, this message translates to:
  /// **'已切换: {strategy}'**
  String aiStrategySwitched(String strategy);

  /// No description provided for @aiCloudApiKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'输入智谱AI的API Key'**
  String get aiCloudApiKeyHint;

  /// No description provided for @aiCloudApiKeyHintCustom.
  ///
  /// In zh, this message translates to:
  /// **'输入API Key'**
  String get aiCloudApiKeyHintCustom;

  /// No description provided for @aiCloudApiKeyHelper.
  ///
  /// In zh, this message translates to:
  /// **'GLM-*-Flash模型完全免费'**
  String get aiCloudApiKeyHelper;

  /// No description provided for @aiCloudApiGetKey.
  ///
  /// In zh, this message translates to:
  /// **'获取API Key'**
  String get aiCloudApiGetKey;

  /// No description provided for @aiCloudApiTutorial.
  ///
  /// In zh, this message translates to:
  /// **'详细教程'**
  String get aiCloudApiTutorial;

  /// No description provided for @aiCloudApiTestKey.
  ///
  /// In zh, this message translates to:
  /// **'测试连接'**
  String get aiCloudApiTestKey;

  /// No description provided for @aiChatConfigWarning.
  ///
  /// In zh, this message translates to:
  /// **'未配置 AI 服务商，请先在设置中添加并绑定'**
  String get aiChatConfigWarning;

  /// No description provided for @aiChatGoToSettings.
  ///
  /// In zh, this message translates to:
  /// **'去设置'**
  String get aiChatGoToSettings;

  /// No description provided for @aiOcrRecognizing.
  ///
  /// In zh, this message translates to:
  /// **'正在识别账单...'**
  String get aiOcrRecognizing;

  /// No description provided for @aiOcrNoAmount.
  ///
  /// In zh, this message translates to:
  /// **'未识别到有效金额，请手动记账'**
  String get aiOcrNoAmount;

  /// No description provided for @aiNotConfiguredHint.
  ///
  /// In zh, this message translates to:
  /// **'未配置 AI 服务，请前往「我的 → AI 设置」配置'**
  String get aiNotConfiguredHint;

  /// No description provided for @aiOcrCheckLog.
  ///
  /// In zh, this message translates to:
  /// **'识别失败，请查看日志了解详情'**
  String get aiOcrCheckLog;

  /// No description provided for @aiOcrNoBill.
  ///
  /// In zh, this message translates to:
  /// **'未识别到账单信息，请确认图片是账单后重试'**
  String get aiOcrNoBill;

  /// No description provided for @aiNotConfiguredNotificationTitle.
  ///
  /// In zh, this message translates to:
  /// **'❌ 无法识别截图'**
  String get aiNotConfiguredNotificationTitle;

  /// No description provided for @aiNotConfiguredNotificationBody.
  ///
  /// In zh, this message translates to:
  /// **'未配置 AI 服务，点击前往设置'**
  String get aiNotConfiguredNotificationBody;

  /// No description provided for @autoBillingNotifyDetectedTitle.
  ///
  /// In zh, this message translates to:
  /// **'✅ 检测到截图'**
  String get autoBillingNotifyDetectedTitle;

  /// No description provided for @autoBillingNotifyWaitingFileBody.
  ///
  /// In zh, this message translates to:
  /// **'正在等待文件写入...'**
  String get autoBillingNotifyWaitingFileBody;

  /// No description provided for @autoBillingNotifyRecognizingScreenshotTitle.
  ///
  /// In zh, this message translates to:
  /// **'正在识别截图...'**
  String get autoBillingNotifyRecognizingScreenshotTitle;

  /// No description provided for @autoBillingNotifyVisionAnalyzingBody.
  ///
  /// In zh, this message translates to:
  /// **'正在调用 AI 视觉分析支付信息，请稍候'**
  String get autoBillingNotifyVisionAnalyzingBody;

  /// No description provided for @autoBillingNotifyRecognizingTextTitle.
  ///
  /// In zh, this message translates to:
  /// **'⏳ 正在识别'**
  String get autoBillingNotifyRecognizingTextTitle;

  /// No description provided for @autoBillingNotifyTextAnalyzingBody.
  ///
  /// In zh, this message translates to:
  /// **'正在调用 AI 解析支付信息...'**
  String get autoBillingNotifyTextAnalyzingBody;

  /// No description provided for @autoSmsBillingRecognizingTitle.
  ///
  /// In zh, this message translates to:
  /// **'⏳ 正在识别短信'**
  String get autoSmsBillingRecognizingTitle;

  /// No description provided for @autoNotifyBillingRecognizingTitle.
  ///
  /// In zh, this message translates to:
  /// **'⏳ 正在识别通知'**
  String get autoNotifyBillingRecognizingTitle;

  /// No description provided for @autoNotifyBillingAnalyzingBody.
  ///
  /// In zh, this message translates to:
  /// **'正在从通知中提取记账信息...'**
  String get autoNotifyBillingAnalyzingBody;

  /// No description provided for @autoScreenBillingRecognizingTitle.
  ///
  /// In zh, this message translates to:
  /// **'⏳ 正在识别账单页'**
  String get autoScreenBillingRecognizingTitle;

  /// No description provided for @autoScreenBillingAnalyzingBody.
  ///
  /// In zh, this message translates to:
  /// **'正在从页面文本中提取记账信息...'**
  String get autoScreenBillingAnalyzingBody;

  /// No description provided for @autoSmsBillingAnalyzingBody.
  ///
  /// In zh, this message translates to:
  /// **'正在从短信中提取记账信息...'**
  String get autoSmsBillingAnalyzingBody;

  /// No description provided for @autoSmsBillingTitle.
  ///
  /// In zh, this message translates to:
  /// **'短信自动记账'**
  String get autoSmsBillingTitle;

  /// No description provided for @autoSmsBillingDesc.
  ///
  /// In zh, this message translates to:
  /// **'监听银行/支付短信,用 AI 自动记账'**
  String get autoSmsBillingDesc;

  /// No description provided for @autoSmsBillingDescEnabled.
  ///
  /// In zh, this message translates to:
  /// **'监听中,银行/支付短信将自动入账'**
  String get autoSmsBillingDescEnabled;

  /// No description provided for @smsPermissionRequired.
  ///
  /// In zh, this message translates to:
  /// **'需要「短信」权限才能自动记账'**
  String get smsPermissionRequired;

  /// No description provided for @autoBillingEntryTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动记账'**
  String get autoBillingEntryTitle;

  /// No description provided for @autoBillingHealthy.
  ///
  /// In zh, this message translates to:
  /// **'运行正常'**
  String get autoBillingHealthy;

  /// No description provided for @autoBillingPartial.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 项未就绪:{issues}'**
  String autoBillingPartial(Object count, Object issues);

  /// No description provided for @autoBillingSmsPermissionMissing.
  ///
  /// In zh, this message translates to:
  /// **'短信权限未授权,自动记账不完整'**
  String get autoBillingSmsPermissionMissing;

  /// No description provided for @autoBillingNotifyPermissionMissing.
  ///
  /// In zh, this message translates to:
  /// **'「通知使用权」未授权,通知自动记账不完整'**
  String get autoBillingNotifyPermissionMissing;

  /// No description provided for @autoBillingNotifyTitle.
  ///
  /// In zh, this message translates to:
  /// **'通知自动记账'**
  String get autoBillingNotifyTitle;

  /// No description provided for @autoBillingNotifyDesc.
  ///
  /// In zh, this message translates to:
  /// **'监听微信/支付宝/银行 App 支付通知自动记账'**
  String get autoBillingNotifyDesc;

  /// No description provided for @autoBillingNotifyDescEnabled.
  ///
  /// In zh, this message translates to:
  /// **'监听中,支付通知将自动入账'**
  String get autoBillingNotifyDescEnabled;

  /// No description provided for @autoBillingNotifyPermissionTitle.
  ///
  /// In zh, this message translates to:
  /// **'开启「通知使用权」'**
  String get autoBillingNotifyPermissionTitle;

  /// No description provided for @autoBillingNotifyPermissionContent.
  ///
  /// In zh, this message translates to:
  /// **'通知自动记账需要系统「通知使用权」授权。点击后跳转系统设置页,找到本应用并开启。'**
  String get autoBillingNotifyPermissionContent;

  /// No description provided for @autoBillingScreenTextTitle.
  ///
  /// In zh, this message translates to:
  /// **'详情页自动记账'**
  String get autoBillingScreenTextTitle;

  /// No description provided for @autoBillingScreenTextDesc.
  ///
  /// In zh, this message translates to:
  /// **'监听支付宝/抖音/京东/微信账单详情页,自动记账'**
  String get autoBillingScreenTextDesc;

  /// No description provided for @autoBillingScreenTextDescEnabled.
  ///
  /// In zh, this message translates to:
  /// **'监听中,打开账单详情页将自动入账'**
  String get autoBillingScreenTextDescEnabled;

  /// No description provided for @autoBillingScreenTextPermissionMissing.
  ///
  /// In zh, this message translates to:
  /// **'「无障碍」未授权,详情页自动记账不生效'**
  String get autoBillingScreenTextPermissionMissing;

  /// No description provided for @autoBillingScreenTextVivoHint.
  ///
  /// In zh, this message translates to:
  /// **'vivo/iQOO 用户注意:若开启后开关自动回弹关闭,请到「设置 → 快速与辅助 → 无障碍」找到本服务开启;仍被关闭时,需在「i 管家 → 隐私权限 → 受限设置」中允许本应用,并在「设置 → 电池 → 后台高耗电」中允许智记。'**
  String get autoBillingScreenTextVivoHint;

  /// No description provided for @autoBillingScreenTextPermissionTitle.
  ///
  /// In zh, this message translates to:
  /// **'开启「无障碍服务」'**
  String get autoBillingScreenTextPermissionTitle;

  /// No description provided for @autoBillingScreenTextPermissionContent.
  ///
  /// In zh, this message translates to:
  /// **'详情页自动记账需要系统「无障碍」授权。仅读取支付宝/抖音/京东/微信页面文字(含金额、商户),用于自动记账;文字不入日志、不存储,处理完即删。'**
  String get autoBillingScreenTextPermissionContent;

  /// No description provided for @autoBillingHealthIssueScreenshot.
  ///
  /// In zh, this message translates to:
  /// **'截图监听'**
  String get autoBillingHealthIssueScreenshot;

  /// No description provided for @autoBillingHealthIssueSms.
  ///
  /// In zh, this message translates to:
  /// **'短信监听'**
  String get autoBillingHealthIssueSms;

  /// No description provided for @autoBillingHealthIssueSmsPermission.
  ///
  /// In zh, this message translates to:
  /// **'短信权限'**
  String get autoBillingHealthIssueSmsPermission;

  /// No description provided for @autoBillingHealthIssueNotify.
  ///
  /// In zh, this message translates to:
  /// **'通知监听'**
  String get autoBillingHealthIssueNotify;

  /// No description provided for @autoBillingHealthIssueNotifyListener.
  ///
  /// In zh, this message translates to:
  /// **'通知使用权'**
  String get autoBillingHealthIssueNotifyListener;

  /// No description provided for @autoBillingHealthIssueAiText.
  ///
  /// In zh, this message translates to:
  /// **'AI 文本模型'**
  String get autoBillingHealthIssueAiText;

  /// No description provided for @autoBillingHealthIssueAiVision.
  ///
  /// In zh, this message translates to:
  /// **'AI 视觉模型'**
  String get autoBillingHealthIssueAiVision;

  /// No description provided for @autoBillingHealthIssueBattery.
  ///
  /// In zh, this message translates to:
  /// **'电池优化'**
  String get autoBillingHealthIssueBattery;

  /// No description provided for @autoStartTitle.
  ///
  /// In zh, this message translates to:
  /// **'自启动与后台保活'**
  String get autoStartTitle;

  /// No description provided for @autoStartDesc.
  ///
  /// In zh, this message translates to:
  /// **'vivo/OriginOS 等需手动允许自启动、关闭「后台高耗电」限制、最近任务锁定 App,否则被清理后收不到短信/通知'**
  String get autoStartDesc;

  /// No description provided for @autoStartGo.
  ///
  /// In zh, this message translates to:
  /// **'去设置'**
  String get autoStartGo;

  /// No description provided for @autoStartOpened.
  ///
  /// In zh, this message translates to:
  /// **'已跳转系统设置,请找到本应用开启自启动'**
  String get autoStartOpened;

  /// No description provided for @autoStartOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开厂商设置,请手动在应用详情页开启自启动'**
  String get autoStartOpenFailed;

  /// No description provided for @channelMappingTitle.
  ///
  /// In zh, this message translates to:
  /// **'渠道→账户映射'**
  String get channelMappingTitle;

  /// No description provided for @channelMappingDesc.
  ///
  /// In zh, this message translates to:
  /// **'短信/通知来源(如 招商银行、支付宝)忽略 AI 账户识别,直接记到指定资产账户'**
  String get channelMappingDesc;

  /// No description provided for @channelMappingAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加映射'**
  String get channelMappingAdd;

  /// No description provided for @channelMappingChannelLabel.
  ///
  /// In zh, this message translates to:
  /// **'渠道名称'**
  String get channelMappingChannelLabel;

  /// No description provided for @channelMappingAccountLabel.
  ///
  /// In zh, this message translates to:
  /// **'目标账户'**
  String get channelMappingAccountLabel;

  /// No description provided for @channelMappingEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无映射规则,添加后自动记账将按来源渠道落账'**
  String get channelMappingEmpty;

  /// No description provided for @channelMappingSaved.
  ///
  /// In zh, this message translates to:
  /// **'映射已保存'**
  String get channelMappingSaved;

  /// No description provided for @channelMappingDeleted.
  ///
  /// In zh, this message translates to:
  /// **'映射已删除'**
  String get channelMappingDeleted;

  /// No description provided for @autoBillingMockTitle.
  ///
  /// In zh, this message translates to:
  /// **'手动模拟测试'**
  String get autoBillingMockTitle;

  /// No description provided for @autoBillingMockDesc.
  ///
  /// In zh, this message translates to:
  /// **'不依赖真实短信/通知,注入模拟数据验证 AI 记账链路是否正常'**
  String get autoBillingMockDesc;

  /// No description provided for @autoBillingMockSms.
  ///
  /// In zh, this message translates to:
  /// **'模拟短信'**
  String get autoBillingMockSms;

  /// No description provided for @autoBillingMockNotify.
  ///
  /// In zh, this message translates to:
  /// **'模拟通知'**
  String get autoBillingMockNotify;

  /// No description provided for @autoBillingMockScreen.
  ///
  /// In zh, this message translates to:
  /// **'模拟屏幕文本'**
  String get autoBillingMockScreen;

  /// No description provided for @autoBillingMockSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'已提交,处理结果见系统通知'**
  String get autoBillingMockSubmitted;

  /// No description provided for @autoBillingMockCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义内容'**
  String get autoBillingMockCustom;

  /// No description provided for @autoBillingMockNotice.
  ///
  /// In zh, this message translates to:
  /// **'模拟数据与真实消息走同一套 AI 解析流程'**
  String get autoBillingMockNotice;

  /// No description provided for @autoRecognitionRecordsTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动识别记录'**
  String get autoRecognitionRecordsTitle;

  /// No description provided for @autoRecognitionRecordsDesc.
  ///
  /// In zh, this message translates to:
  /// **'自动记账的识别决策与入账结果'**
  String get autoRecognitionRecordsDesc;

  /// No description provided for @autoRecognitionRecordsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无记录。去打开一笔账单/订单详情页，再回到此页点刷新：\n· 出现新记录 → 决策码说明被哪道闸拦截（或已正常入账）\n· 始终无记录 → 无障碍监听未生效，请检查系统无障碍开关'**
  String get autoRecognitionRecordsEmpty;

  /// No description provided for @commonRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get commonRefresh;

  /// No description provided for @pendingConfirmationTitle.
  ///
  /// In zh, this message translates to:
  /// **'待确认记账'**
  String get pendingConfirmationTitle;

  /// No description provided for @pendingConfirmationDesc.
  ///
  /// In zh, this message translates to:
  /// **'自动记账中低置信/大额/疑似重复的候选,人工审核'**
  String get pendingConfirmationDesc;

  /// No description provided for @pendingConfirmationEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有待确认的记账'**
  String get pendingConfirmationEmpty;

  /// No description provided for @pendingConfirmationCountBadge.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 笔待确认,点击审核'**
  String pendingConfirmationCountBadge(Object count);

  /// No description provided for @pendingConfirmationConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认入账'**
  String get pendingConfirmationConfirm;

  /// No description provided for @pendingConfirmationEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑后入账'**
  String get pendingConfirmationEdit;

  /// No description provided for @pendingConfirmationReject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get pendingConfirmationReject;

  /// No description provided for @pendingConfirmationRejectAsk.
  ///
  /// In zh, this message translates to:
  /// **'确定拒绝并删除这条待确认记账?'**
  String get pendingConfirmationRejectAsk;

  /// No description provided for @pendingConfirmationApproved.
  ///
  /// In zh, this message translates to:
  /// **'已入账'**
  String get pendingConfirmationApproved;

  /// No description provided for @pendingConfirmationRejected.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝'**
  String get pendingConfirmationRejected;

  /// No description provided for @pendingConfirmationEditFailed.
  ///
  /// In zh, this message translates to:
  /// **'金额无效'**
  String get pendingConfirmationEditFailed;

  /// No description provided for @pendingConfirmationApproveFailed.
  ///
  /// In zh, this message translates to:
  /// **'入账失败'**
  String get pendingConfirmationApproveFailed;

  /// No description provided for @pendingConfirmationAmount.
  ///
  /// In zh, this message translates to:
  /// **'金额'**
  String get pendingConfirmationAmount;

  /// No description provided for @pendingConfirmationNote.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get pendingConfirmationNote;

  /// No description provided for @pendingConfirmationUncheckedReason.
  ///
  /// In zh, this message translates to:
  /// **'待确认'**
  String get pendingConfirmationUncheckedReason;

  /// No description provided for @pendingCandidateReasonDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'疑似重复:近期已有相似交易'**
  String get pendingCandidateReasonDuplicate;

  /// No description provided for @pendingCandidateReasonLarge.
  ///
  /// In zh, this message translates to:
  /// **'大额消费'**
  String get pendingCandidateReasonLarge;

  /// No description provided for @pendingCandidateReasonLowConfidence.
  ///
  /// In zh, this message translates to:
  /// **'识别把握较低,请核对'**
  String get pendingCandidateReasonLowConfidence;

  /// No description provided for @pendingCandidateReasonConfidenceMissing.
  ///
  /// In zh, this message translates to:
  /// **'识别结果缺少置信度,请核对'**
  String get pendingCandidateReasonConfidenceMissing;

  /// No description provided for @pendingCandidateReasonTimeInferred.
  ///
  /// In zh, this message translates to:
  /// **'交易时间是推测的,请核对'**
  String get pendingCandidateReasonTimeInferred;

  /// No description provided for @pendingCandidateReasonTimePrecisionWeak.
  ///
  /// In zh, this message translates to:
  /// **'交易时间不够精确,请核对'**
  String get pendingCandidateReasonTimePrecisionWeak;

  /// No description provided for @pendingCandidateReasonAnomaly.
  ///
  /// In zh, this message translates to:
  /// **'异常消费:高于近期基线'**
  String get pendingCandidateReasonAnomaly;

  /// No description provided for @pendingCandidateReasonAutoBookDisabled.
  ///
  /// In zh, this message translates to:
  /// **'自动入账已关闭,需手动确认'**
  String get pendingCandidateReasonAutoBookDisabled;

  /// No description provided for @pendingCandidatesArchivedHint.
  ///
  /// In zh, this message translates to:
  /// **'部分较旧候选已归档,请尽快处理'**
  String get pendingCandidatesArchivedHint;

  /// No description provided for @autoBookDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动记账详情'**
  String get autoBookDetailTitle;

  /// No description provided for @autoBookDetailState.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get autoBookDetailState;

  /// No description provided for @autoBookDetailSource.
  ///
  /// In zh, this message translates to:
  /// **'来源'**
  String get autoBookDetailSource;

  /// No description provided for @autoBookDetailCapturedAt.
  ///
  /// In zh, this message translates to:
  /// **'捕获时间'**
  String get autoBookDetailCapturedAt;

  /// No description provided for @autoBookDetailUpdatedAt.
  ///
  /// In zh, this message translates to:
  /// **'更新时间'**
  String get autoBookDetailUpdatedAt;

  /// No description provided for @autoBookDetailAttempts.
  ///
  /// In zh, this message translates to:
  /// **'尝试次数'**
  String get autoBookDetailAttempts;

  /// No description provided for @autoBookDetailError.
  ///
  /// In zh, this message translates to:
  /// **'错误信息'**
  String get autoBookDetailError;

  /// No description provided for @autoBookDetailReason.
  ///
  /// In zh, this message translates to:
  /// **'原因'**
  String get autoBookDetailReason;

  /// No description provided for @autoBookDetailEvidence.
  ///
  /// In zh, this message translates to:
  /// **'原始证据'**
  String get autoBookDetailEvidence;

  /// No description provided for @autoBookDetailEvidenceCleared.
  ///
  /// In zh, this message translates to:
  /// **'原始证据已按留存策略清理或未留存'**
  String get autoBookDetailEvidenceCleared;

  /// No description provided for @autoBookDetailItems.
  ///
  /// In zh, this message translates to:
  /// **'解析子项'**
  String get autoBookDetailItems;

  /// No description provided for @autoBookDetailNoItems.
  ///
  /// In zh, this message translates to:
  /// **'无子项记录'**
  String get autoBookDetailNoItems;

  /// No description provided for @autoBookDetailRelatedTx.
  ///
  /// In zh, this message translates to:
  /// **'关联交易'**
  String get autoBookDetailRelatedTx;

  /// No description provided for @autoBookDetailOpenTx.
  ///
  /// In zh, this message translates to:
  /// **'查看交易 #{id}'**
  String autoBookDetailOpenTx(int id);

  /// No description provided for @autoBookDetailRetry.
  ///
  /// In zh, this message translates to:
  /// **'手动重试'**
  String get autoBookDetailRetry;

  /// No description provided for @autoBillingNotifyMergeTitle.
  ///
  /// In zh, this message translates to:
  /// **'已合并到已有交易'**
  String get autoBillingNotifyMergeTitle;

  /// No description provided for @autoBillingNotifyMergeBody.
  ///
  /// In zh, this message translates to:
  /// **'{count} 笔与 {date} 的 ¥{amount} 判为同一笔，已合并，可在自动记账历史中撤销'**
  String autoBillingNotifyMergeBody(int count, String date, String amount);

  /// No description provided for @autoBookUndoMerge.
  ///
  /// In zh, this message translates to:
  /// **'撤销合并（恢复为一笔）'**
  String get autoBookUndoMerge;

  /// No description provided for @autoBookUndoMergeDone.
  ///
  /// In zh, this message translates to:
  /// **'已恢复到待确认，请处理'**
  String get autoBookUndoMergeDone;

  /// No description provided for @autoBookUndoMergeEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有可恢复的记录'**
  String get autoBookUndoMergeEmpty;

  /// No description provided for @dedupExemptTitle.
  ///
  /// In zh, this message translates to:
  /// **'判重豁免'**
  String get dedupExemptTitle;

  /// No description provided for @dedupExemptDesc.
  ///
  /// In zh, this message translates to:
  /// **'确认「仍记一笔」后，同商户同金额段不再被判重'**
  String get dedupExemptDesc;

  /// No description provided for @dedupExemptEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无豁免规则'**
  String get dedupExemptEmpty;

  /// No description provided for @dedupExemptClear.
  ///
  /// In zh, this message translates to:
  /// **'清空豁免'**
  String get dedupExemptClear;

  /// No description provided for @pendingBatchMode.
  ///
  /// In zh, this message translates to:
  /// **'批量管理'**
  String get pendingBatchMode;

  /// No description provided for @pendingBatchSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get pendingBatchSelectAll;

  /// No description provided for @pendingBatchApprove.
  ///
  /// In zh, this message translates to:
  /// **'批量确认'**
  String get pendingBatchApprove;

  /// No description provided for @pendingBatchReject.
  ///
  /// In zh, this message translates to:
  /// **'批量拒绝'**
  String get pendingBatchReject;

  /// No description provided for @pendingBatchApproved.
  ///
  /// In zh, this message translates to:
  /// **'成功确认 {count} 条，失败 {failed} 条（已保留）'**
  String pendingBatchApproved(int count, int failed);

  /// No description provided for @pendingBatchRejected.
  ///
  /// In zh, this message translates to:
  /// **'成功拒绝 {count} 条，失败 {failed} 条（已保留）'**
  String pendingBatchRejected(Object count, Object failed);

  /// No description provided for @pendingBatchRejectAsk.
  ///
  /// In zh, this message translates to:
  /// **'确定拒绝选中的 {count} 条候选吗？'**
  String pendingBatchRejectAsk(Object count);

  /// No description provided for @pendingConfirmationPickCategory.
  ///
  /// In zh, this message translates to:
  /// **'选择分类'**
  String get pendingConfirmationPickCategory;

  /// No description provided for @pendingConfirmationSimilarTransaction.
  ///
  /// In zh, this message translates to:
  /// **'相似已有交易'**
  String get pendingConfirmationSimilarTransaction;

  /// No description provided for @pendingConfirmationCompare.
  ///
  /// In zh, this message translates to:
  /// **'查看对比'**
  String get pendingConfirmationCompare;

  /// No description provided for @pendingConfirmationCandidate.
  ///
  /// In zh, this message translates to:
  /// **'待确认候选'**
  String get pendingConfirmationCandidate;

  /// No description provided for @pendingConfirmationExisting.
  ///
  /// In zh, this message translates to:
  /// **'已有交易'**
  String get pendingConfirmationExisting;

  /// No description provided for @pendingConfirmationRecordedAt.
  ///
  /// In zh, this message translates to:
  /// **'记录时间'**
  String get pendingConfirmationRecordedAt;

  /// No description provided for @pendingConfirmationMatchedMissing.
  ///
  /// In zh, this message translates to:
  /// **'这条已有交易已不存在或已删除'**
  String get pendingConfirmationMatchedMissing;

  /// No description provided for @pendingConfirmationOpenMatched.
  ///
  /// In zh, this message translates to:
  /// **'打开已有交易'**
  String get pendingConfirmationOpenMatched;

  /// No description provided for @pendingConfirmationMatchScoreLabel.
  ///
  /// In zh, this message translates to:
  /// **'匹配度'**
  String get pendingConfirmationMatchScoreLabel;

  /// No description provided for @autoDeleteScreenshotTitle.
  ///
  /// In zh, this message translates to:
  /// **'记账成功自动删截图'**
  String get autoDeleteScreenshotTitle;

  /// No description provided for @autoDeleteScreenshotDesc.
  ///
  /// In zh, this message translates to:
  /// **'截图被识别为账单并成功入账后,自动从相册删除;非账单、失败或进入「待确认」时保留'**
  String get autoDeleteScreenshotDesc;

  /// No description provided for @screenshotSourceFilterTitle.
  ///
  /// In zh, this message translates to:
  /// **'仅消费类App截图记账'**
  String get screenshotSourceFilterTitle;

  /// No description provided for @screenshotSourceFilterDesc.
  ///
  /// In zh, this message translates to:
  /// **'仅在金融/电商类App(支付宝、微信、银行、淘宝、京东等)内截图才自动记账,其它App截图不触发识别'**
  String get screenshotSourceFilterDesc;

  /// No description provided for @screenshotSourceFilterDescOff.
  ///
  /// In zh, this message translates to:
  /// **'已关闭:所有截图都会尝试识别记账'**
  String get screenshotSourceFilterDescOff;

  /// No description provided for @screenshotSourceFilterPermissionMissing.
  ///
  /// In zh, this message translates to:
  /// **'无法识别截图来源App:需开启无障碍服务或授权「使用情况访问」,否则截图不会自动记账'**
  String get screenshotSourceFilterPermissionMissing;

  /// No description provided for @autoBookCheckTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动入账总闸'**
  String get autoBookCheckTitle;

  /// No description provided for @autoBookCheckDesc.
  ///
  /// In zh, this message translates to:
  /// **'开启:低置信/疑似重复进待确认,其余自动入账'**
  String get autoBookCheckDesc;

  /// No description provided for @autoBookCheckDisabledDesc.
  ///
  /// In zh, this message translates to:
  /// **'已关闭:所有识别结果需手动确认后入账'**
  String get autoBookCheckDisabledDesc;

  /// No description provided for @smartBillingChecking.
  ///
  /// In zh, this message translates to:
  /// **'正在检查…'**
  String get smartBillingChecking;

  /// No description provided for @autoBillingNotifyRecognizeFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'❌ 识别失败'**
  String get autoBillingNotifyRecognizeFailedTitle;

  /// No description provided for @autoBillingNotifyRecognizeFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'无法从截图提取账单信息，请检查 AI 配置或图片'**
  String get autoBillingNotifyRecognizeFailedBody;

  /// No description provided for @autoBillingNotifyNoBillTitle.
  ///
  /// In zh, this message translates to:
  /// **'未识别到账单'**
  String get autoBillingNotifyNoBillTitle;

  /// No description provided for @autoBillingNotifyNoBillBody.
  ///
  /// In zh, this message translates to:
  /// **'这张截图未识别到账单信息，可能不是账单'**
  String get autoBillingNotifyNoBillBody;

  /// No description provided for @autoScreenBillingNoBillTitle.
  ///
  /// In zh, this message translates to:
  /// **'该页面未识别到账单'**
  String get autoScreenBillingNoBillTitle;

  /// No description provided for @autoScreenBillingNoBillBody.
  ///
  /// In zh, this message translates to:
  /// **'页面未识别到已成交交易,已跳过'**
  String get autoScreenBillingNoBillBody;

  /// No description provided for @autoScreenBillingRecognizeFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'❌ 识别失败'**
  String get autoScreenBillingRecognizeFailedTitle;

  /// No description provided for @autoScreenBillingRecognizeFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'无法从页面文本提取账单信息,请检查 AI 配置'**
  String get autoScreenBillingRecognizeFailedBody;

  /// No description provided for @autoScreenBillingProcessFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'❌ 处理失败'**
  String get autoScreenBillingProcessFailedTitle;

  /// No description provided for @autoBillingNotifyFileUnavailableTitle.
  ///
  /// In zh, this message translates to:
  /// **'识别失败'**
  String get autoBillingNotifyFileUnavailableTitle;

  /// No description provided for @autoBillingNotifyFileUnavailableBody.
  ///
  /// In zh, this message translates to:
  /// **'截图文件不可用'**
  String get autoBillingNotifyFileUnavailableBody;

  /// No description provided for @autoBillingNotifyNoLedgerTitle.
  ///
  /// In zh, this message translates to:
  /// **'❌ 自动记账失败'**
  String get autoBillingNotifyNoLedgerTitle;

  /// No description provided for @autoBillingNotifyNoLedgerBody.
  ///
  /// In zh, this message translates to:
  /// **'无可用账本，请先创建账本'**
  String get autoBillingNotifyNoLedgerBody;

  /// No description provided for @autoBillingNotifyNoAmountBody.
  ///
  /// In zh, this message translates to:
  /// **'未能识别出金额信息'**
  String get autoBillingNotifyNoAmountBody;

  /// No description provided for @autoBillingNotifyCreateFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'❌ 创建失败'**
  String get autoBillingNotifyCreateFailedTitle;

  /// No description provided for @autoBillingNotifyCreateFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'无法创建交易记录'**
  String get autoBillingNotifyCreateFailedBody;

  /// No description provided for @autoBillingNotifyProcessFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'❌ 处理失败'**
  String get autoBillingNotifyProcessFailedTitle;

  /// No description provided for @autoBillingNotifyProcessFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'错误：{error}'**
  String autoBillingNotifyProcessFailedBody(String error);

  /// No description provided for @autoBillingNotifySuccessSingleTitle.
  ///
  /// In zh, this message translates to:
  /// **'✅ 自动记账成功 ¥{amount}'**
  String autoBillingNotifySuccessSingleTitle(String amount);

  /// No description provided for @autoBillingNotifySuccessMultiTitle.
  ///
  /// In zh, this message translates to:
  /// **'✅ 自动记账成功 {count} 笔'**
  String autoBillingNotifySuccessMultiTitle(int count);

  /// No description provided for @autoBillingNotifySuccessMultiBody.
  ///
  /// In zh, this message translates to:
  /// **'合计 ¥{amount}'**
  String autoBillingNotifySuccessMultiBody(String amount);

  /// No description provided for @autoBillingNotifyPendingTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动记账待确认'**
  String get autoBillingNotifyPendingTitle;

  /// No description provided for @homePendingConfirmBanner.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 笔自动记账待确认'**
  String homePendingConfirmBanner(Object count);

  /// No description provided for @autoBillingNotifyPendingBody.
  ///
  /// In zh, this message translates to:
  /// **'{count} 笔支出待确认，合计 ¥{amount}'**
  String autoBillingNotifyPendingBody(Object amount, Object count);

  /// No description provided for @autoBillingNotifySuccessSingleBodyNote.
  ///
  /// In zh, this message translates to:
  /// **'备注：{note}'**
  String autoBillingNotifySuccessSingleBodyNote(String note);

  /// No description provided for @autoBillingNotifySuccessSingleBodyDefault.
  ///
  /// In zh, this message translates to:
  /// **'已自动创建记录'**
  String get autoBillingNotifySuccessSingleBodyDefault;

  /// No description provided for @aiOcrNoLedger.
  ///
  /// In zh, this message translates to:
  /// **'未找到账本'**
  String get aiOcrNoLedger;

  /// No description provided for @aiBillingRateMissingHint.
  ///
  /// In zh, this message translates to:
  /// **'⚠️ 未取到 {currency} 汇率，已按 1:1 暂记，可在统计页「补折算」修正'**
  String aiBillingRateMissingHint(String currency);

  /// No description provided for @aiPromptVarCurrencies.
  ///
  /// In zh, this message translates to:
  /// **'账本主币种 + 已在用的外币账户'**
  String get aiPromptVarCurrencies;

  /// No description provided for @aiPromptVarBillGuard.
  ///
  /// In zh, this message translates to:
  /// **'账单过滤段（仅截图 / 自动记账时注入）'**
  String get aiPromptVarBillGuard;

  /// No description provided for @aiPromptMissingVarsHint.
  ///
  /// In zh, this message translates to:
  /// **'你的自定义模板缺少这些变量，对应能力会失效：{vars}'**
  String aiPromptMissingVarsHint(String vars);

  /// No description provided for @aiPromptInsertVarSection.
  ///
  /// In zh, this message translates to:
  /// **'插入 {name} 段落'**
  String aiPromptInsertVarSection(String name);

  /// No description provided for @aiPromptVarSectionInserted.
  ///
  /// In zh, this message translates to:
  /// **'已追加 {name} 段落，确认后保存'**
  String aiPromptVarSectionInserted(String name);

  /// No description provided for @aiOcrSuccess.
  ///
  /// In zh, this message translates to:
  /// **'✅ {type}账单创建成功 ¥{amount}'**
  String aiOcrSuccess(String type, String amount);

  /// No description provided for @aiOcrFailed.
  ///
  /// In zh, this message translates to:
  /// **'识别失败: {error}'**
  String aiOcrFailed(String error);

  /// No description provided for @aiOcrCreateFailed.
  ///
  /// In zh, this message translates to:
  /// **'创建账单失败'**
  String get aiOcrCreateFailed;

  /// No description provided for @aiTypeIncome.
  ///
  /// In zh, this message translates to:
  /// **'收入'**
  String get aiTypeIncome;

  /// No description provided for @aiTypeExpense.
  ///
  /// In zh, this message translates to:
  /// **'支出'**
  String get aiTypeExpense;

  /// No description provided for @cloudSyncPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'云同步'**
  String get cloudSyncPageTitle;

  /// No description provided for @cloudSyncPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'手动上传和下载账本数据'**
  String get cloudSyncPageSubtitle;

  /// No description provided for @cloudTutorialTitle.
  ///
  /// In zh, this message translates to:
  /// **'使用教程'**
  String get cloudTutorialTitle;

  /// No description provided for @cloudTutorialIntro.
  ///
  /// In zh, this message translates to:
  /// **'智记 是可以自建的云同步服务端,支持多设备实时协同。流程很简单:'**
  String get cloudTutorialIntro;

  /// No description provided for @cloudTutorialStep1Title.
  ///
  /// In zh, this message translates to:
  /// **'第一步:部署或选择服务器'**
  String get cloudTutorialStep1Title;

  /// No description provided for @cloudTutorialStep1Desc.
  ///
  /// In zh, this message translates to:
  /// **'自己部署:Docker 一行命令拉起(见 GitHub README 的 Docker 指南)。或直接使用朋友/团队已有的智记 服务器。'**
  String get cloudTutorialStep1Desc;

  /// No description provided for @cloudTutorialStep2Title.
  ///
  /// In zh, this message translates to:
  /// **'第二步:获取账号'**
  String get cloudTutorialStep2Title;

  /// No description provided for @cloudTutorialStep2Desc.
  ///
  /// In zh, this message translates to:
  /// **'智记 不支持自助注册(避免公网服务被滥用)。自己部署的同学:首次启动 Docker 日志里会打印随机管理员账号密码,直接用。加入他人服务器的同学:让管理员在 Web 后台 →「用户」里帮你添加账号。'**
  String get cloudTutorialStep2Desc;

  /// No description provided for @cloudTutorialStep3Title.
  ///
  /// In zh, this message translates to:
  /// **'第三步:登录并开启同步'**
  String get cloudTutorialStep3Title;

  /// No description provided for @cloudTutorialStep3Desc.
  ///
  /// In zh, this message translates to:
  /// **'App 里选「智记」,填服务器地址 + 管理员给你的账号,登录。首次会全量上传你本地所有账本数据,之后每次编辑实时推送。'**
  String get cloudTutorialStep3Desc;

  /// No description provided for @cloudTutorialStep4Title.
  ///
  /// In zh, this message translates to:
  /// **'第四步:其他设备登录'**
  String get cloudTutorialStep4Title;

  /// No description provided for @cloudTutorialStep4Desc.
  ///
  /// In zh, this message translates to:
  /// **'手机、平板、Web 三端用同一账号登录,数据即刻互通。修改几秒内互相感知。'**
  String get cloudTutorialStep4Desc;

  /// No description provided for @cloudTutorialTipTitle.
  ///
  /// In zh, this message translates to:
  /// **'小贴士'**
  String get cloudTutorialTipTitle;

  /// No description provided for @cloudTutorialTipDesc.
  ///
  /// In zh, this message translates to:
  /// **'Web 端地址 = 服务器地址,浏览器直接访问即可。登录后可以管理账本、成员、查看日志。'**
  String get cloudTutorialTipDesc;

  /// No description provided for @cloudTutorialFeaturesTitle.
  ///
  /// In zh, this message translates to:
  /// **'特色功能'**
  String get cloudTutorialFeaturesTitle;

  /// No description provided for @cloudTutorialFeature1.
  ///
  /// In zh, this message translates to:
  /// **'📱 多设备实时协同:手机 A + 手机 B + Web 三端同账号,数据秒级同步'**
  String get cloudTutorialFeature1;

  /// No description provided for @cloudTutorialFeature2.
  ///
  /// In zh, this message translates to:
  /// **'🌐 自带 Web 管理端:一个 Docker 镜像包含 server + web,浏览器即可使用'**
  String get cloudTutorialFeature2;

  /// No description provided for @cloudTutorialFeature3.
  ///
  /// In zh, this message translates to:
  /// **'👥 多用户独立:一个服务器可以多人注册,各自数据完全隔离'**
  String get cloudTutorialFeature3;

  /// No description provided for @cloudTutorialFeature4.
  ///
  /// In zh, this message translates to:
  /// **'🤝 共享账本:邀请家人 / 团队一起记同一本,实时秒级同步'**
  String get cloudTutorialFeature4;

  /// No description provided for @cloudTutorialGotIt.
  ///
  /// In zh, this message translates to:
  /// **'我知道了'**
  String get cloudTutorialGotIt;

  /// No description provided for @cloudSyncHint.
  ///
  /// In zh, this message translates to:
  /// **'下载时可自动对比差异并逐条预览。非实时同步，请避免多设备同时编辑同一账本。同步范围为账本数据（含关联的账户、分类、标签），不含附件。'**
  String get cloudSyncHint;

  /// No description provided for @cloudSyncNow.
  ///
  /// In zh, this message translates to:
  /// **'立即同步'**
  String get cloudSyncNow;

  /// No description provided for @cloudSyncNowHint.
  ///
  /// In zh, this message translates to:
  /// **'推送本地变更并拉取远端更新'**
  String get cloudSyncNowHint;

  /// No description provided for @cloudSyncInProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在同步...'**
  String get cloudSyncInProgress;

  /// No description provided for @cloudSyncComplete.
  ///
  /// In zh, this message translates to:
  /// **'同步完成：推送 {pushed} 条，拉取 {pulled} 条'**
  String cloudSyncComplete(int pushed, int pulled);

  /// No description provided for @cloudAutoSyncHint.
  ///
  /// In zh, this message translates to:
  /// **'数据变更后自动同步到云端'**
  String get cloudAutoSyncHint;

  /// No description provided for @dataManagement.
  ///
  /// In zh, this message translates to:
  /// **'数据管理'**
  String get dataManagement;

  /// No description provided for @dataManagementDesc.
  ///
  /// In zh, this message translates to:
  /// **'导入导出、分类账户管理'**
  String get dataManagementDesc;

  /// No description provided for @dataManagementPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'数据管理'**
  String get dataManagementPageTitle;

  /// No description provided for @dataManagementPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'管理账单数据和分类'**
  String get dataManagementPageSubtitle;

  /// No description provided for @dataManagementAttachmentHint.
  ///
  /// In zh, this message translates to:
  /// **'还原数据时，请先导入附件包，再导入账本数据（CSV或云同步），以确保附件正确关联。'**
  String get dataManagementAttachmentHint;

  /// No description provided for @smartBilling.
  ///
  /// In zh, this message translates to:
  /// **'智能记账'**
  String get smartBilling;

  /// No description provided for @smartBillingDesc.
  ///
  /// In zh, this message translates to:
  /// **'AI 助手、智能识别、自动记账'**
  String get smartBillingDesc;

  /// No description provided for @smartBillingPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'智能记账'**
  String get smartBillingPageTitle;

  /// No description provided for @smartBillingPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'AI和自动化记账功能'**
  String get smartBillingPageSubtitle;

  /// No description provided for @smartBillingGuideHint.
  ///
  /// In zh, this message translates to:
  /// **'长按底部中间的 AI 助手按钮呼出扇形菜单，或在 AI 助手对话页中使用'**
  String get smartBillingGuideHint;

  /// No description provided for @smartBillingTryNow.
  ///
  /// In zh, this message translates to:
  /// **'立即体验'**
  String get smartBillingTryNow;

  /// No description provided for @smartBillingImageBilling.
  ///
  /// In zh, this message translates to:
  /// **'图片记账'**
  String get smartBillingImageBilling;

  /// No description provided for @smartBillingImageBillingDesc.
  ///
  /// In zh, this message translates to:
  /// **'从相册选择支付截图识别（长按 AI 助手或在对话中使用）'**
  String get smartBillingImageBillingDesc;

  /// No description provided for @smartBillingImageBillingGuide.
  ///
  /// In zh, this message translates to:
  /// **'可在首页底部长按「AI 助手」按钮滑动选择「相册」，或进入「AI 助手」对话页点击输入框左侧「+」选择「相册」。AI 视觉模型会自动识别截图中的金额、商家、时间等信息。\n\n提示：也可在手机桌面长按应用图标，或在相册中将截图直接分享给智记。'**
  String get smartBillingImageBillingGuide;

  /// No description provided for @smartBillingVisionAIRequired.
  ///
  /// In zh, this message translates to:
  /// **'图片识别必须配置 AI 视觉服务，请先在「我的 → AI 设置」中配置'**
  String get smartBillingVisionAIRequired;

  /// No description provided for @smartBillingCameraBilling.
  ///
  /// In zh, this message translates to:
  /// **'拍照记账'**
  String get smartBillingCameraBilling;

  /// No description provided for @smartBillingCameraBillingDesc.
  ///
  /// In zh, this message translates to:
  /// **'拍摄纸质小票或账单识别（长按 AI 助手或在对话中使用）'**
  String get smartBillingCameraBillingDesc;

  /// No description provided for @smartBillingCameraBillingGuide.
  ///
  /// In zh, this message translates to:
  /// **'可在首页底部长按「AI 助手」按钮滑动选择「拍照」，或进入「AI 助手」对话页点击输入框左侧「+」选择「拍照」。AI 视觉模型会自动识别小票中的金额、商家、时间等信息。'**
  String get smartBillingCameraBillingGuide;

  /// No description provided for @smartBillingVoiceBilling.
  ///
  /// In zh, this message translates to:
  /// **'语音记账'**
  String get smartBillingVoiceBilling;

  /// No description provided for @smartBillingVoiceBillingDesc.
  ///
  /// In zh, this message translates to:
  /// **'语音口述日常收支记账（长按 AI 助手或在对话中使用）'**
  String get smartBillingVoiceBillingDesc;

  /// No description provided for @smartBillingVoiceBillingGuide.
  ///
  /// In zh, this message translates to:
  /// **'可在首页底部长按「AI 助手」按钮滑动选择「语音」，或进入「AI 助手」对话页按住麦克风说话。AI 会自动转写语音并智能提取账单信息入账。'**
  String get smartBillingVoiceBillingGuide;

  /// No description provided for @smartBillingAIRequired.
  ///
  /// In zh, this message translates to:
  /// **'语音记账必须配置 AI 语音识别服务，请先在「我的 → AI 设置」中配置'**
  String get smartBillingAIRequired;

  /// No description provided for @smartBillingAutoTags.
  ///
  /// In zh, this message translates to:
  /// **'自动关联标签'**
  String get smartBillingAutoTags;

  /// No description provided for @smartBillingAutoTagsDesc.
  ///
  /// In zh, this message translates to:
  /// **'智能记账时自动根据分类关联常用标签'**
  String get smartBillingAutoTagsDesc;

  /// No description provided for @smartBillingAutoAttachment.
  ///
  /// In zh, this message translates to:
  /// **'自动添加附件'**
  String get smartBillingAutoAttachment;

  /// No description provided for @smartBillingAutoAttachmentDesc.
  ///
  /// In zh, this message translates to:
  /// **'图片/拍照记账时自动将原图添加为附件'**
  String get smartBillingAutoAttachmentDesc;

  /// No description provided for @autoScreenshotBillingIosTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动记账'**
  String get autoScreenshotBillingIosTitle;

  /// No description provided for @autoScreenshotBillingIosDesc.
  ///
  /// In zh, this message translates to:
  /// **'通过快捷指令自动识别支付信息记账'**
  String get autoScreenshotBillingIosDesc;

  /// No description provided for @shareBilling.
  ///
  /// In zh, this message translates to:
  /// **'分享记账'**
  String get shareBilling;

  /// No description provided for @shareBillingDesc.
  ///
  /// In zh, this message translates to:
  /// **'从支付宝/微信分享支付截图即可记账'**
  String get shareBillingDesc;

  /// No description provided for @shareBillingGuide.
  ///
  /// In zh, this message translates to:
  /// **'在支付宝、微信、相册等应用中看到支付截图时，点击「分享」并选择「智记」，即可自动识别金额、商家、时间等信息并记账，无需先保存截图。'**
  String get shareBillingGuide;

  /// No description provided for @shareBillingActionHint.
  ///
  /// In zh, this message translates to:
  /// **'分享后会在后台自动识别记账，无需手动打开智记'**
  String get shareBillingActionHint;

  /// No description provided for @automation.
  ///
  /// In zh, this message translates to:
  /// **'自动化'**
  String get automation;

  /// No description provided for @automationDesc.
  ///
  /// In zh, this message translates to:
  /// **'周期记账、记账提醒'**
  String get automationDesc;

  /// No description provided for @automationPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动化功能'**
  String get automationPageTitle;

  /// No description provided for @automationPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'周期记账和提醒设置'**
  String get automationPageSubtitle;

  /// No description provided for @appearanceSettings.
  ///
  /// In zh, this message translates to:
  /// **'个性化设置'**
  String get appearanceSettings;

  /// No description provided for @appearanceSettingsDesc.
  ///
  /// In zh, this message translates to:
  /// **'主题、字体、语言、应用锁等'**
  String get appearanceSettingsDesc;

  /// No description provided for @appearanceSettingsPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'个性化设置'**
  String get appearanceSettingsPageTitle;

  /// No description provided for @appearanceSettingsPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'外观、显示、安全等应用偏好'**
  String get appearanceSettingsPageSubtitle;

  /// No description provided for @about.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get about;

  /// No description provided for @aboutDesc.
  ///
  /// In zh, this message translates to:
  /// **'版本信息、帮助与反馈'**
  String get aboutDesc;

  /// No description provided for @aboutPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get aboutPageTitle;

  /// No description provided for @aboutPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'应用信息和帮助'**
  String get aboutPageSubtitle;

  /// No description provided for @mineRateApp.
  ///
  /// In zh, this message translates to:
  /// **'给应用评分'**
  String get mineRateApp;

  /// No description provided for @mineRateAppSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'在App Store上为我们打分'**
  String get mineRateAppSubtitle;

  /// No description provided for @aboutPageLoadingVersion.
  ///
  /// In zh, this message translates to:
  /// **'加载版本号中...'**
  String get aboutPageLoadingVersion;

  /// No description provided for @aboutWebsite.
  ///
  /// In zh, this message translates to:
  /// **'官方网站'**
  String get aboutWebsite;

  /// No description provided for @aboutGitHubRepo.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 仓库'**
  String get aboutGitHubRepo;

  /// No description provided for @aboutXiaohongshu.
  ///
  /// In zh, this message translates to:
  /// **'小红书'**
  String get aboutXiaohongshu;

  /// No description provided for @aboutDouyin.
  ///
  /// In zh, this message translates to:
  /// **'抖音'**
  String get aboutDouyin;

  /// No description provided for @aboutTelegram.
  ///
  /// In zh, this message translates to:
  /// **'Telegram 群'**
  String get aboutTelegram;

  /// No description provided for @aboutSupportDevelopment.
  ///
  /// In zh, this message translates to:
  /// **'支持开发'**
  String get aboutSupportDevelopment;

  /// No description provided for @aboutSupportDevelopmentSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'请开发者喝杯咖啡'**
  String get aboutSupportDevelopmentSubtitle;

  /// No description provided for @aboutDeveloperStoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'开发者的话'**
  String get aboutDeveloperStoryTitle;

  /// No description provided for @aboutDeveloperStory.
  ///
  /// In zh, this message translates to:
  /// **'从 2015 年实习起，我坚持记账至今已超过十年。因为担心记账软件的广告、付费、隐私泄露和停运跑路，我决定自己做一个——最初只是给自己和家人用的小工具。\n\n2025 年 9 月，智记发布了第一个版本。说实话，那时候心里没什么底，不知道会不会有人用。但慢慢地，开始收到用户的反馈——有人说终于找到了一款干净的记账软件，有人提了很好的建议，也有人默默给了五星好评。每一条反馈都让我觉得，这件事值得继续做下去。\n\n智记没有广告、没有会员、完全免费开源。你的每一笔数据都只存在你自己的手机里，不会被上传到任何第三方服务器。但上架和维护一款 App 并非零成本——开发者账号、服务器等开支目前靠社区捐赠勉强支撑，每一次适配新系统、修复 Bug、开发新功能，也都是工作之余一点点完成的。\n\n如果你觉得智记对你有帮助，一个好评、一次分享或一笔捐赠，都能让这个小项目走得更远。谢谢你的信任。'**
  String get aboutDeveloperStory;

  /// No description provided for @aboutRelatedProducts.
  ///
  /// In zh, this message translates to:
  /// **'更多产品'**
  String get aboutRelatedProducts;

  /// No description provided for @aboutBeeAssets.
  ///
  /// In zh, this message translates to:
  /// **'蜜蜂家当 BeeAssets'**
  String get aboutBeeAssets;

  /// No description provided for @aboutBeeAssetsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'可视化你的全部资产配置'**
  String get aboutBeeAssetsSubtitle;

  /// No description provided for @aboutBeeAssetsIntro.
  ///
  /// In zh, this message translates to:
  /// **'智记侧重日常流水,蜜蜂家当是它的姐妹产品,专注资产配置可视化:跨账户净资产趋势、房产 / 投资 / 加密资产分类、收益率与持仓时长、配置占比一目了然。'**
  String get aboutBeeAssetsIntro;

  /// No description provided for @aboutBeeDNS.
  ///
  /// In zh, this message translates to:
  /// **'蜜蜂域名 BeeDNS'**
  String get aboutBeeDNS;

  /// No description provided for @aboutBeeDNSSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'简洁高效的 DNS 管理工具'**
  String get aboutBeeDNSSubtitle;

  /// No description provided for @aboutBeeDNSIntro.
  ///
  /// In zh, this message translates to:
  /// **'如果你的域名分散在 Cloudflare 和阿里云,蜜蜂域名把它们聚合在一处管理:批量改记录、A/AAAA 切换、解析迁移、子域名批量管理 — 不用在两家控制台来回切。'**
  String get aboutBeeDNSIntro;

  /// No description provided for @productPromoAndroidTitle.
  ///
  /// In zh, this message translates to:
  /// **'申请加入内测'**
  String get productPromoAndroidTitle;

  /// No description provided for @productPromoAndroidMessage.
  ///
  /// In zh, this message translates to:
  /// **'这款 App 还在 Google Play 内测阶段,需要邀请才能下载。\n\n申请方式:发邮件给我们,告诉我们你的 Google 账号邮箱(必填),以及简单说明使用场景(可选)。我们会在 1-3 天内回复并加你到内测白名单。'**
  String get productPromoAndroidMessage;

  /// No description provided for @productPromoOpenStore.
  ///
  /// In zh, this message translates to:
  /// **'前往应用商店'**
  String get productPromoOpenStore;

  /// No description provided for @productPromoTestFlight.
  ///
  /// In zh, this message translates to:
  /// **'TestFlight 内测'**
  String get productPromoTestFlight;

  /// No description provided for @productPromoLearnMore.
  ///
  /// In zh, this message translates to:
  /// **'Pro'**
  String get productPromoLearnMore;

  /// No description provided for @productPromoEmailLabel.
  ///
  /// In zh, this message translates to:
  /// **'申请邮箱(点击复制)'**
  String get productPromoEmailLabel;

  /// No description provided for @productPromoCopiedToast.
  ///
  /// In zh, this message translates to:
  /// **'邮箱已复制到剪贴板'**
  String get productPromoCopiedToast;

  /// No description provided for @productPromoMailUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'未检测到邮件应用,邮箱已复制到剪贴板,请打开任意邮件应用粘贴发送'**
  String get productPromoMailUnavailable;

  /// No description provided for @productPromoEmailButton.
  ///
  /// In zh, this message translates to:
  /// **'发送邮件'**
  String get productPromoEmailButton;

  /// No description provided for @productPromoWebsiteButton.
  ///
  /// In zh, this message translates to:
  /// **'前往官网'**
  String get productPromoWebsiteButton;

  /// No description provided for @productPromoEmailSubject.
  ///
  /// In zh, this message translates to:
  /// **'申请内测 - {productName}'**
  String productPromoEmailSubject(String productName);

  /// No description provided for @productPromoEmailBody.
  ///
  /// In zh, this message translates to:
  /// **'你好,\n\n我希望加入「{productName}」的 Google Play 内测,我的 Google 账号邮箱是:\n\n(请填写你的 Gmail / Google 账号邮箱)\n\n谢谢!'**
  String productPromoEmailBody(String productName);

  /// No description provided for @logCenterTitle.
  ///
  /// In zh, this message translates to:
  /// **'日志中心'**
  String get logCenterTitle;

  /// No description provided for @logCenterSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'查看应用运行日志'**
  String get logCenterSubtitle;

  /// No description provided for @logCenterSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索日志内容或标签...'**
  String get logCenterSearchHint;

  /// No description provided for @logCenterFilterLevel.
  ///
  /// In zh, this message translates to:
  /// **'日志级别'**
  String get logCenterFilterLevel;

  /// No description provided for @logCenterFilterPlatform.
  ///
  /// In zh, this message translates to:
  /// **'平台'**
  String get logCenterFilterPlatform;

  /// No description provided for @logCenterTotal.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get logCenterTotal;

  /// No description provided for @logCenterFiltered.
  ///
  /// In zh, this message translates to:
  /// **'已过滤'**
  String get logCenterFiltered;

  /// No description provided for @logCenterEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get logCenterEmpty;

  /// No description provided for @logCenterExport.
  ///
  /// In zh, this message translates to:
  /// **'导出'**
  String get logCenterExport;

  /// No description provided for @logCenterClear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get logCenterClear;

  /// No description provided for @logCenterExportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导出失败'**
  String get logCenterExportFailed;

  /// No description provided for @logCenterClearConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'清空日志'**
  String get logCenterClearConfirmTitle;

  /// No description provided for @logCenterClearConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要清空所有日志吗？此操作不可恢复。'**
  String get logCenterClearConfirmMessage;

  /// No description provided for @logCenterCleared.
  ///
  /// In zh, this message translates to:
  /// **'日志已清空'**
  String get logCenterCleared;

  /// No description provided for @logCenterCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制到剪贴板'**
  String get logCenterCopied;

  /// No description provided for @configImportExportTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置导入导出'**
  String get configImportExportTitle;

  /// No description provided for @configImportExportSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'备份和恢复应用配置'**
  String get configImportExportSubtitle;

  /// No description provided for @configImportExportInfoTitle.
  ///
  /// In zh, this message translates to:
  /// **'功能说明'**
  String get configImportExportInfoTitle;

  /// No description provided for @configImportExportInfoMessage.
  ///
  /// In zh, this message translates to:
  /// **'此功能用于导出和导入应用配置，包括云服务配置、AI配置等。配置文件采用YAML格式，方便查看和编辑。\n\n⚠️ 配置文件包含敏感信息（如API密钥、密码等），请妥善保管。'**
  String get configImportExportInfoMessage;

  /// No description provided for @configExportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出配置'**
  String get configExportTitle;

  /// No description provided for @configExportSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'将当前配置导出为YAML文件'**
  String get configExportSubtitle;

  /// No description provided for @configExportShareSubject.
  ///
  /// In zh, this message translates to:
  /// **'智记 配置文件'**
  String get configExportShareSubject;

  /// No description provided for @configExportSuccess.
  ///
  /// In zh, this message translates to:
  /// **'配置导出成功'**
  String get configExportSuccess;

  /// No description provided for @configExportFailed.
  ///
  /// In zh, this message translates to:
  /// **'配置导出失败'**
  String get configExportFailed;

  /// No description provided for @configImportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入配置'**
  String get configImportTitle;

  /// No description provided for @configImportSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'从YAML文件恢复配置'**
  String get configImportSubtitle;

  /// No description provided for @configImportNoFilePath.
  ///
  /// In zh, this message translates to:
  /// **'未选择文件'**
  String get configImportNoFilePath;

  /// No description provided for @configImportConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认导入'**
  String get configImportConfirmTitle;

  /// No description provided for @configImportSuccess.
  ///
  /// In zh, this message translates to:
  /// **'配置导入成功'**
  String get configImportSuccess;

  /// No description provided for @configImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'配置导入失败'**
  String get configImportFailed;

  /// No description provided for @configImportRestartTitle.
  ///
  /// In zh, this message translates to:
  /// **'需要重启'**
  String get configImportRestartTitle;

  /// No description provided for @configImportRestartMessage.
  ///
  /// In zh, this message translates to:
  /// **'配置已导入，部分配置需要重启应用后生效。'**
  String get configImportRestartMessage;

  /// No description provided for @configImportExportIncludesTitle.
  ///
  /// In zh, this message translates to:
  /// **'包含的配置项'**
  String get configImportExportIncludesTitle;

  /// No description provided for @configExportSavedTo.
  ///
  /// In zh, this message translates to:
  /// **'已保存至: {path}'**
  String configExportSavedTo(String path);

  /// No description provided for @configExportViewContent.
  ///
  /// In zh, this message translates to:
  /// **'查看内容'**
  String get configExportViewContent;

  /// No description provided for @configExportCopyContent.
  ///
  /// In zh, this message translates to:
  /// **'复制内容'**
  String get configExportCopyContent;

  /// No description provided for @configExportContentCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制到剪贴板'**
  String get configExportContentCopied;

  /// No description provided for @configExportReadFileFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取文件失败'**
  String get configExportReadFileFailed;

  /// No description provided for @configIncludeLedgers.
  ///
  /// In zh, this message translates to:
  /// **'账本'**
  String get configIncludeLedgers;

  /// No description provided for @configIncludeSupabase.
  ///
  /// In zh, this message translates to:
  /// **'Supabase 云服务配置'**
  String get configIncludeSupabase;

  /// No description provided for @configIncludeWebdav.
  ///
  /// In zh, this message translates to:
  /// **'WebDAV 云服务配置'**
  String get configIncludeWebdav;

  /// No description provided for @configIncludeS3.
  ///
  /// In zh, this message translates to:
  /// **'S3 云服务配置'**
  String get configIncludeS3;

  /// No description provided for @configIncludeAI.
  ///
  /// In zh, this message translates to:
  /// **'AI 智能识别配置'**
  String get configIncludeAI;

  /// No description provided for @configIncludeAISubtitle.
  ///
  /// In zh, this message translates to:
  /// **'服务商、能力绑定、模型设置等'**
  String get configIncludeAISubtitle;

  /// No description provided for @configIncludeAppSettings.
  ///
  /// In zh, this message translates to:
  /// **'应用设置（语言、外观、提醒、默认账户等）'**
  String get configIncludeAppSettings;

  /// No description provided for @configIncludeRecurringTransactions.
  ///
  /// In zh, this message translates to:
  /// **'周期账单'**
  String get configIncludeRecurringTransactions;

  /// No description provided for @configIncludeAccounts.
  ///
  /// In zh, this message translates to:
  /// **'账户'**
  String get configIncludeAccounts;

  /// No description provided for @configIncludeCategories.
  ///
  /// In zh, this message translates to:
  /// **'分类'**
  String get configIncludeCategories;

  /// No description provided for @configIncludeTags.
  ///
  /// In zh, this message translates to:
  /// **'标签'**
  String get configIncludeTags;

  /// No description provided for @configIncludeBudgets.
  ///
  /// In zh, this message translates to:
  /// **'预算'**
  String get configIncludeBudgets;

  /// No description provided for @configIncludeOtherSettings.
  ///
  /// In zh, this message translates to:
  /// **'其他设置'**
  String get configIncludeOtherSettings;

  /// No description provided for @configIncludeOtherSettingsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'包含云服务配置、AI配置、应用设置等'**
  String get configIncludeOtherSettingsSubtitle;

  /// No description provided for @configExportSelectTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择导出内容'**
  String get configExportSelectTitle;

  /// No description provided for @configExportPreviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出预览'**
  String get configExportPreviewTitle;

  /// No description provided for @configExportConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认导出'**
  String get configExportConfirmTitle;

  /// No description provided for @configImportSelectTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择导入内容'**
  String get configImportSelectTitle;

  /// No description provided for @configImportPreviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入预览'**
  String get configImportPreviewTitle;

  /// No description provided for @ledgersLocal.
  ///
  /// In zh, this message translates to:
  /// **'本地账本'**
  String get ledgersLocal;

  /// No description provided for @ledgersRemote.
  ///
  /// In zh, this message translates to:
  /// **'云端账本'**
  String get ledgersRemote;

  /// No description provided for @ledgersEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无账本'**
  String get ledgersEmpty;

  /// No description provided for @ledgersRestoreAll.
  ///
  /// In zh, this message translates to:
  /// **'全部恢复'**
  String get ledgersRestoreAll;

  /// No description provided for @ledgersSwitched.
  ///
  /// In zh, this message translates to:
  /// **'已切换到账本\"{name}\"'**
  String ledgersSwitched(String name);

  /// No description provided for @ledgersDownloadTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载账本'**
  String get ledgersDownloadTitle;

  /// No description provided for @ledgersDownloadMessage.
  ///
  /// In zh, this message translates to:
  /// **'确认下载账本\"{name}\"到本地？'**
  String ledgersDownloadMessage(String name);

  /// No description provided for @ledgersDownloading.
  ///
  /// In zh, this message translates to:
  /// **'下载中...'**
  String get ledgersDownloading;

  /// No description provided for @ledgersDownloadSuccess.
  ///
  /// In zh, this message translates to:
  /// **'账本\"{name}\"下载成功'**
  String ledgersDownloadSuccess(String name);

  /// No description provided for @ledgersDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get ledgersDownload;

  /// No description provided for @ledgersDeleteRemote.
  ///
  /// In zh, this message translates to:
  /// **'删除云端账本'**
  String get ledgersDeleteRemote;

  /// No description provided for @ledgersDeleteRemoteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'删除云端账本'**
  String get ledgersDeleteRemoteConfirm;

  /// No description provided for @ledgersDeleteRemoteMessage.
  ///
  /// In zh, this message translates to:
  /// **'确认删除云端账本\"{name}\"？此操作不可恢复。'**
  String ledgersDeleteRemoteMessage(String name);

  /// No description provided for @ledgersDeleting.
  ///
  /// In zh, this message translates to:
  /// **'删除中...'**
  String get ledgersDeleting;

  /// No description provided for @ledgersDeleteRemoteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已删除云端账本'**
  String get ledgersDeleteRemoteSuccess;

  /// No description provided for @ledgersCannotDeleteLastOne.
  ///
  /// In zh, this message translates to:
  /// **'无法删除最后一个账本'**
  String get ledgersCannotDeleteLastOne;

  /// No description provided for @ledgersRestoreAllTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量恢复'**
  String get ledgersRestoreAllTitle;

  /// No description provided for @ledgersRestoreAllMessage.
  ///
  /// In zh, this message translates to:
  /// **'确认恢复所有云端账本？共 {count} 个。'**
  String ledgersRestoreAllMessage(int count);

  /// No description provided for @ledgersRestoring.
  ///
  /// In zh, this message translates to:
  /// **'恢复中...'**
  String get ledgersRestoring;

  /// No description provided for @ledgersRestoreComplete.
  ///
  /// In zh, this message translates to:
  /// **'恢复完成'**
  String get ledgersRestoreComplete;

  /// No description provided for @ledgersRestoreResult.
  ///
  /// In zh, this message translates to:
  /// **'成功: {success}，失败: {failed}'**
  String ledgersRestoreResult(int success, int failed);

  /// No description provided for @ledgersConflictTitle.
  ///
  /// In zh, this message translates to:
  /// **'同步冲突'**
  String get ledgersConflictTitle;

  /// No description provided for @ledgersConflictMessage.
  ///
  /// In zh, this message translates to:
  /// **'本地和云端账本数据不一致，请选择操作：'**
  String get ledgersConflictMessage;

  /// No description provided for @ledgersConflictLocalInfo.
  ///
  /// In zh, this message translates to:
  /// **'本地：{count} 笔账单'**
  String ledgersConflictLocalInfo(int count);

  /// No description provided for @ledgersConflictRemoteInfo.
  ///
  /// In zh, this message translates to:
  /// **'云端：{count} 笔账单'**
  String ledgersConflictRemoteInfo(int count);

  /// No description provided for @ledgersConflictRemoteUpdated.
  ///
  /// In zh, this message translates to:
  /// **'云端更新：{time}'**
  String ledgersConflictRemoteUpdated(String time);

  /// No description provided for @ledgersConflictLocalFingerprint.
  ///
  /// In zh, this message translates to:
  /// **'本地指纹：{fp}'**
  String ledgersConflictLocalFingerprint(String fp);

  /// No description provided for @ledgersConflictRemoteFingerprint.
  ///
  /// In zh, this message translates to:
  /// **'云端指纹：{fp}'**
  String ledgersConflictRemoteFingerprint(String fp);

  /// No description provided for @ledgersConflictUpload.
  ///
  /// In zh, this message translates to:
  /// **'上传到云端'**
  String get ledgersConflictUpload;

  /// No description provided for @ledgersConflictDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载到本地'**
  String get ledgersConflictDownload;

  /// No description provided for @ledgersConflictUploading.
  ///
  /// In zh, this message translates to:
  /// **'正在上传...'**
  String get ledgersConflictUploading;

  /// No description provided for @ledgersConflictDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载...'**
  String get ledgersConflictDownloading;

  /// No description provided for @ledgersConflictUploadSuccess.
  ///
  /// In zh, this message translates to:
  /// **'上传成功'**
  String get ledgersConflictUploadSuccess;

  /// No description provided for @ledgersConflictDownloadSuccess.
  ///
  /// In zh, this message translates to:
  /// **'下载成功，已合并 {inserted} 笔账单'**
  String ledgersConflictDownloadSuccess(int inserted);

  /// No description provided for @storageManagementTitle.
  ///
  /// In zh, this message translates to:
  /// **'存储空间管理'**
  String get storageManagementTitle;

  /// No description provided for @storageManagementSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'清理缓存释放空间'**
  String get storageManagementSubtitle;

  /// No description provided for @storageAIModels.
  ///
  /// In zh, this message translates to:
  /// **'AI模型'**
  String get storageAIModels;

  /// No description provided for @storageAPKFiles.
  ///
  /// In zh, this message translates to:
  /// **'安装包'**
  String get storageAPKFiles;

  /// No description provided for @storageNoData.
  ///
  /// In zh, this message translates to:
  /// **'无数据'**
  String get storageNoData;

  /// No description provided for @storageFiles.
  ///
  /// In zh, this message translates to:
  /// **'个文件'**
  String get storageFiles;

  /// No description provided for @storageHint.
  ///
  /// In zh, this message translates to:
  /// **'点击项目可清理对应的缓存文件'**
  String get storageHint;

  /// No description provided for @storageClearConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认清理'**
  String get storageClearConfirmTitle;

  /// No description provided for @storageClearAIModelsMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要清理所有AI模型吗？大小: {size}'**
  String storageClearAIModelsMessage(String size);

  /// No description provided for @storageClearAPKMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要清理所有安装包吗？大小: {size}'**
  String storageClearAPKMessage(String size);

  /// No description provided for @storageClearSuccess.
  ///
  /// In zh, this message translates to:
  /// **'清理成功'**
  String get storageClearSuccess;

  /// No description provided for @accountNoTransactions.
  ///
  /// In zh, this message translates to:
  /// **'暂无交易记录'**
  String get accountNoTransactions;

  /// No description provided for @accountTransactionHistory.
  ///
  /// In zh, this message translates to:
  /// **'交易记录'**
  String get accountTransactionHistory;

  /// No description provided for @accountTotalBalance.
  ///
  /// In zh, this message translates to:
  /// **'净资产'**
  String get accountTotalBalance;

  /// No description provided for @accountCurrencyLocked.
  ///
  /// In zh, this message translates to:
  /// **'该账户已有交易记录，不允许修改币种'**
  String get accountCurrencyLocked;

  /// No description provided for @accountDefaultIncomeTitle.
  ///
  /// In zh, this message translates to:
  /// **'默认收入账户'**
  String get accountDefaultIncomeTitle;

  /// No description provided for @accountDefaultExpenseTitle.
  ///
  /// In zh, this message translates to:
  /// **'默认支出账户'**
  String get accountDefaultExpenseTitle;

  /// No description provided for @accountDefaultNone.
  ///
  /// In zh, this message translates to:
  /// **'不设置'**
  String get accountDefaultNone;

  /// No description provided for @commonNotice.
  ///
  /// In zh, this message translates to:
  /// **'提示'**
  String get commonNotice;

  /// No description provided for @transferTitle.
  ///
  /// In zh, this message translates to:
  /// **'转账'**
  String get transferTitle;

  /// No description provided for @transferIconSettings.
  ///
  /// In zh, this message translates to:
  /// **'转账图标设置'**
  String get transferIconSettings;

  /// No description provided for @transferIconSettingsDesc.
  ///
  /// In zh, this message translates to:
  /// **'自定义转账记录的显示图标'**
  String get transferIconSettingsDesc;

  /// No description provided for @transferFromAccount.
  ///
  /// In zh, this message translates to:
  /// **'转出账户'**
  String get transferFromAccount;

  /// No description provided for @transferToAccount.
  ///
  /// In zh, this message translates to:
  /// **'转入账户'**
  String get transferToAccount;

  /// No description provided for @transferSelectAccount.
  ///
  /// In zh, this message translates to:
  /// **'选择账户'**
  String get transferSelectAccount;

  /// No description provided for @transferCreateSuccess.
  ///
  /// In zh, this message translates to:
  /// **'转账创建成功'**
  String get transferCreateSuccess;

  /// No description provided for @transferUpdateSuccess.
  ///
  /// In zh, this message translates to:
  /// **'转账更新成功'**
  String get transferUpdateSuccess;

  /// No description provided for @transferDifferentCurrencyError.
  ///
  /// In zh, this message translates to:
  /// **'转账仅支持相同币种的账户'**
  String get transferDifferentCurrencyError;

  /// No description provided for @transferToPrefix.
  ///
  /// In zh, this message translates to:
  /// **'转账至'**
  String get transferToPrefix;

  /// No description provided for @transferFromPrefix.
  ///
  /// In zh, this message translates to:
  /// **'来自'**
  String get transferFromPrefix;

  /// No description provided for @welcomeCategoryModeTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择分类模式'**
  String get welcomeCategoryModeTitle;

  /// No description provided for @welcomeCategoryModeDescription.
  ///
  /// In zh, this message translates to:
  /// **'选择更适合您使用习惯的分类方式'**
  String get welcomeCategoryModeDescription;

  /// No description provided for @welcomeCategoryModeFlatTitle.
  ///
  /// In zh, this message translates to:
  /// **'一级分类'**
  String get welcomeCategoryModeFlatTitle;

  /// No description provided for @welcomeCategoryModeFlatDescription.
  ///
  /// In zh, this message translates to:
  /// **'简单直观，快速记账'**
  String get welcomeCategoryModeFlatDescription;

  /// No description provided for @welcomeCategoryModeFlatFeature1.
  ///
  /// In zh, this message translates to:
  /// **'扁平化结构，操作简单'**
  String get welcomeCategoryModeFlatFeature1;

  /// No description provided for @welcomeCategoryModeFlatFeature2.
  ///
  /// In zh, this message translates to:
  /// **'适合习惯简单分类的用户'**
  String get welcomeCategoryModeFlatFeature2;

  /// No description provided for @welcomeCategoryModeFlatFeature3.
  ///
  /// In zh, this message translates to:
  /// **'快速选择，高效记账'**
  String get welcomeCategoryModeFlatFeature3;

  /// No description provided for @welcomeCategoryModeHierarchicalTitle.
  ///
  /// In zh, this message translates to:
  /// **'二级分类'**
  String get welcomeCategoryModeHierarchicalTitle;

  /// No description provided for @welcomeCategoryModeHierarchicalDescription.
  ///
  /// In zh, this message translates to:
  /// **'精细管理，清晰明了'**
  String get welcomeCategoryModeHierarchicalDescription;

  /// No description provided for @welcomeCategoryModeHierarchicalFeature1.
  ///
  /// In zh, this message translates to:
  /// **'支持父子分类层级'**
  String get welcomeCategoryModeHierarchicalFeature1;

  /// No description provided for @welcomeCategoryModeHierarchicalFeature2.
  ///
  /// In zh, this message translates to:
  /// **'更细致的账单归类'**
  String get welcomeCategoryModeHierarchicalFeature2;

  /// No description provided for @welcomeCategoryModeHierarchicalFeature3.
  ///
  /// In zh, this message translates to:
  /// **'适合需要精细管理的用户'**
  String get welcomeCategoryModeHierarchicalFeature3;

  /// No description provided for @welcomeCategoryModeNoneTitle.
  ///
  /// In zh, this message translates to:
  /// **'不创建分类'**
  String get welcomeCategoryModeNoneTitle;

  /// No description provided for @welcomeCategoryModeNoneDescription.
  ///
  /// In zh, this message translates to:
  /// **'完全自定义，按需添加'**
  String get welcomeCategoryModeNoneDescription;

  /// No description provided for @welcomeCategoryModeNoneFeature1.
  ///
  /// In zh, this message translates to:
  /// **'不预置任何分类'**
  String get welcomeCategoryModeNoneFeature1;

  /// No description provided for @welcomeCategoryModeNoneFeature2.
  ///
  /// In zh, this message translates to:
  /// **'完全按自己需求创建'**
  String get welcomeCategoryModeNoneFeature2;

  /// No description provided for @welcomeCategoryModeNoneFeature3.
  ///
  /// In zh, this message translates to:
  /// **'适合有特殊分类需求的用户'**
  String get welcomeCategoryModeNoneFeature3;

  /// No description provided for @welcomeExistingUserTitle.
  ///
  /// In zh, this message translates to:
  /// **'老用户？'**
  String get welcomeExistingUserTitle;

  /// No description provided for @welcomeExistingUserButton.
  ///
  /// In zh, this message translates to:
  /// **'导入配置'**
  String get welcomeExistingUserButton;

  /// No description provided for @welcomeImportingConfig.
  ///
  /// In zh, this message translates to:
  /// **'正在导入配置...'**
  String get welcomeImportingConfig;

  /// No description provided for @welcomeImportSuccess.
  ///
  /// In zh, this message translates to:
  /// **'配置导入成功'**
  String get welcomeImportSuccess;

  /// No description provided for @welcomeImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'配置导入失败: {error}'**
  String welcomeImportFailed(String error);

  /// No description provided for @welcomeImportNoFile.
  ///
  /// In zh, this message translates to:
  /// **'未选择文件'**
  String get welcomeImportNoFile;

  /// No description provided for @welcomeImportAttachmentTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入附件'**
  String get welcomeImportAttachmentTitle;

  /// No description provided for @welcomeImportAttachmentDesc.
  ///
  /// In zh, this message translates to:
  /// **'检测到您导入了配置文件，是否需要导入附件文件？'**
  String get welcomeImportAttachmentDesc;

  /// No description provided for @welcomeImportAttachmentButton.
  ///
  /// In zh, this message translates to:
  /// **'选择附件文件'**
  String get welcomeImportAttachmentButton;

  /// No description provided for @welcomeImportAttachmentSkip.
  ///
  /// In zh, this message translates to:
  /// **'跳过'**
  String get welcomeImportAttachmentSkip;

  /// No description provided for @welcomeImportAttachmentSuccess.
  ///
  /// In zh, this message translates to:
  /// **'附件导入完成：导入 {imported} 个'**
  String welcomeImportAttachmentSuccess(int imported);

  /// No description provided for @welcomeImportAttachmentFailed.
  ///
  /// In zh, this message translates to:
  /// **'附件导入失败: {error}'**
  String welcomeImportAttachmentFailed(String error);

  /// No description provided for @welcomeImportingAttachment.
  ///
  /// In zh, this message translates to:
  /// **'正在导入附件...'**
  String get welcomeImportingAttachment;

  /// No description provided for @iosVersionWarningTitle.
  ///
  /// In zh, this message translates to:
  /// **'需要 iOS 16.0 或更高版本'**
  String get iosVersionWarningTitle;

  /// No description provided for @iosVersionWarningDesc.
  ///
  /// In zh, this message translates to:
  /// **'截图自动记账功能使用了 iOS 16 引入的 App Intents 框架。您的设备系统版本较低，暂不支持此功能。\n\n请升级到 iOS 16 或更高版本以使用此功能。'**
  String get iosVersionWarningDesc;

  /// No description provided for @aiChatTitle.
  ///
  /// In zh, this message translates to:
  /// **'AI助手'**
  String get aiChatTitle;

  /// No description provided for @aiChatImageLabel.
  ///
  /// In zh, this message translates to:
  /// **'图片'**
  String get aiChatImageLabel;

  /// No description provided for @aiChatRetry.
  ///
  /// In zh, this message translates to:
  /// **'重新识别'**
  String get aiChatRetry;

  /// No description provided for @aiChatVoiceLabel.
  ///
  /// In zh, this message translates to:
  /// **'语音'**
  String get aiChatVoiceLabel;

  /// No description provided for @aiChatClearHistory.
  ///
  /// In zh, this message translates to:
  /// **'清除对话历史'**
  String get aiChatClearHistory;

  /// No description provided for @aiChatClearHistoryDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除对话历史'**
  String get aiChatClearHistoryDialogTitle;

  /// No description provided for @aiChatClearHistoryDialogContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除所有对话记录吗?此操作不可恢复。'**
  String get aiChatClearHistoryDialogContent;

  /// No description provided for @aiChatInputHint.
  ///
  /// In zh, this message translates to:
  /// **'例如: 买了杯咖啡35块'**
  String get aiChatInputHint;

  /// No description provided for @aiChatThinking.
  ///
  /// In zh, this message translates to:
  /// **'思考中...'**
  String get aiChatThinking;

  /// No description provided for @aiChatHistoryCleared.
  ///
  /// In zh, this message translates to:
  /// **'对话历史已清空'**
  String get aiChatHistoryCleared;

  /// No description provided for @aiChatCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get aiChatCopy;

  /// No description provided for @aiChatCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制到剪贴板'**
  String get aiChatCopied;

  /// No description provided for @aiChatDeleteMessageConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这条消息吗？'**
  String get aiChatDeleteMessageConfirm;

  /// No description provided for @aiChatMessageDeleted.
  ///
  /// In zh, this message translates to:
  /// **'消息已删除'**
  String get aiChatMessageDeleted;

  /// No description provided for @aiChatUndone.
  ///
  /// In zh, this message translates to:
  /// **'已撤销,30 天内可在「最近删除」恢复'**
  String get aiChatUndone;

  /// No description provided for @aiChatUndoFailed.
  ///
  /// In zh, this message translates to:
  /// **'撤销失败'**
  String get aiChatUndoFailed;

  /// No description provided for @aiChatTransactionNotFound.
  ///
  /// In zh, this message translates to:
  /// **'交易记录不存在'**
  String get aiChatTransactionNotFound;

  /// No description provided for @aiChatOpenEditorFailed.
  ///
  /// In zh, this message translates to:
  /// **'打开编辑页面失败'**
  String get aiChatOpenEditorFailed;

  /// No description provided for @aiChatSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'发送失败'**
  String get aiChatSendFailed;

  /// No description provided for @aiQuickCommandFinancialHealthTitle.
  ///
  /// In zh, this message translates to:
  /// **'财务健康分析'**
  String get aiQuickCommandFinancialHealthTitle;

  /// No description provided for @aiQuickCommandFinancialHealthDesc.
  ///
  /// In zh, this message translates to:
  /// **'分析收支平衡和储蓄率'**
  String get aiQuickCommandFinancialHealthDesc;

  /// No description provided for @aiQuickCommandFinancialHealthPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请根据以下数据分析我的财务健康状况：\n\n[monthlyStats]\n\n[recentTrends]\n\n请从收支平衡、储蓄率、消费趋势等角度给出专业分析和建议。请用简体中文回复。'**
  String get aiQuickCommandFinancialHealthPrompt;

  /// No description provided for @aiQuickCommandMonthlyExpenseTitle.
  ///
  /// In zh, this message translates to:
  /// **'本月支出总结'**
  String get aiQuickCommandMonthlyExpenseTitle;

  /// No description provided for @aiQuickCommandMonthlyExpenseDesc.
  ///
  /// In zh, this message translates to:
  /// **'月度支出分析和建议'**
  String get aiQuickCommandMonthlyExpenseDesc;

  /// No description provided for @aiQuickCommandMonthlyExpensePrompt.
  ///
  /// In zh, this message translates to:
  /// **'请总结我本月的支出情况：\n\n[monthlyStats]\n\n[categoryStats]\n\n请分析主要支出类别，并给出节约开支的建议。请用简体中文回复。'**
  String get aiQuickCommandMonthlyExpensePrompt;

  /// No description provided for @aiQuickCommandCategoryAnalysisTitle.
  ///
  /// In zh, this message translates to:
  /// **'分类占比分析'**
  String get aiQuickCommandCategoryAnalysisTitle;

  /// No description provided for @aiQuickCommandCategoryAnalysisDesc.
  ///
  /// In zh, this message translates to:
  /// **'各分类支出占比和趋势'**
  String get aiQuickCommandCategoryAnalysisDesc;

  /// No description provided for @aiQuickCommandCategoryAnalysisPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请分析我的各分类支出占比：\n\n[categoryStats]\n\n请指出哪些分类支出过高，并给出优化建议。请用简体中文回复。'**
  String get aiQuickCommandCategoryAnalysisPrompt;

  /// No description provided for @aiQuickCommandBudgetPlanningTitle.
  ///
  /// In zh, this message translates to:
  /// **'预算规划建议'**
  String get aiQuickCommandBudgetPlanningTitle;

  /// No description provided for @aiQuickCommandBudgetPlanningDesc.
  ///
  /// In zh, this message translates to:
  /// **'基于历史数据的预算建议'**
  String get aiQuickCommandBudgetPlanningDesc;

  /// No description provided for @aiQuickCommandBudgetPlanningPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请基于以下数据帮我制定下月预算：\n\n[monthlyStats]\n\n[recentTrends]\n\n请给出各分类的预算建议和注意事项。请用简体中文回复。'**
  String get aiQuickCommandBudgetPlanningPrompt;

  /// No description provided for @aiQuickCommandAbnormalExpenseTitle.
  ///
  /// In zh, this message translates to:
  /// **'异常支出提醒'**
  String get aiQuickCommandAbnormalExpenseTitle;

  /// No description provided for @aiQuickCommandAbnormalExpenseDesc.
  ///
  /// In zh, this message translates to:
  /// **'识别大额或异常支出'**
  String get aiQuickCommandAbnormalExpenseDesc;

  /// No description provided for @aiQuickCommandAbnormalExpensePrompt.
  ///
  /// In zh, this message translates to:
  /// **'请检查我最近是否有异常支出：\n\n[recentTransactions]\n\n[monthlyStats]\n\n请指出可能的异常消费，并分析原因。请用简体中文回复。'**
  String get aiQuickCommandAbnormalExpensePrompt;

  /// No description provided for @aiQuickCommandSavingTipsTitle.
  ///
  /// In zh, this message translates to:
  /// **'省钱小贴士'**
  String get aiQuickCommandSavingTipsTitle;

  /// No description provided for @aiQuickCommandSavingTipsDesc.
  ///
  /// In zh, this message translates to:
  /// **'根据消费习惯给建议'**
  String get aiQuickCommandSavingTipsDesc;

  /// No description provided for @aiQuickCommandSavingTipsPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请根据我的消费习惯给出省钱建议：\n\n[categoryStats]\n\n[recentTrends]\n\n请提供3-5条实用的省钱技巧。请用简体中文回复。'**
  String get aiQuickCommandSavingTipsPrompt;

  /// No description provided for @billCardSuccess.
  ///
  /// In zh, this message translates to:
  /// **'记账成功'**
  String get billCardSuccess;

  /// No description provided for @billCardUndone.
  ///
  /// In zh, this message translates to:
  /// **'已撤销'**
  String get billCardUndone;

  /// No description provided for @billCardAmount.
  ///
  /// In zh, this message translates to:
  /// **'💰 金额'**
  String get billCardAmount;

  /// No description provided for @billCardCategory.
  ///
  /// In zh, this message translates to:
  /// **'🏷️ 分类'**
  String get billCardCategory;

  /// No description provided for @billCardTime.
  ///
  /// In zh, this message translates to:
  /// **'📅 时间'**
  String get billCardTime;

  /// No description provided for @billCardNote.
  ///
  /// In zh, this message translates to:
  /// **'📝 备注'**
  String get billCardNote;

  /// No description provided for @billCardAccount.
  ///
  /// In zh, this message translates to:
  /// **'💳 账户'**
  String get billCardAccount;

  /// No description provided for @billCardUndo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get billCardUndo;

  /// No description provided for @billCardEdit.
  ///
  /// In zh, this message translates to:
  /// **'修改'**
  String get billCardEdit;

  /// No description provided for @billCardUnknownLedger.
  ///
  /// In zh, this message translates to:
  /// **'未知账本'**
  String get billCardUnknownLedger;

  /// No description provided for @donationTitle.
  ///
  /// In zh, this message translates to:
  /// **'捐赠'**
  String get donationTitle;

  /// No description provided for @donationSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'请我喝杯咖啡'**
  String get donationSubtitle;

  /// No description provided for @donationEntrySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'支持应用持续开发'**
  String get donationEntrySubtitle;

  /// No description provided for @donationDescription.
  ///
  /// In zh, this message translates to:
  /// **'说明'**
  String get donationDescription;

  /// No description provided for @donationDescriptionDetail.
  ///
  /// In zh, this message translates to:
  /// **'感谢您使用智记！如果这个应用对您有帮助，欢迎请开发者喝杯咖啡作为鼓励。您的支持是我持续改进的动力。'**
  String get donationDescriptionDetail;

  /// No description provided for @donationNoFeatures.
  ///
  /// In zh, this message translates to:
  /// **'注: 打赏不会解锁任何功能，所有功能继续完全免费。'**
  String get donationNoFeatures;

  /// No description provided for @donationNoProducts.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用商品'**
  String get donationNoProducts;

  /// No description provided for @donationThankYouTitle.
  ///
  /// In zh, this message translates to:
  /// **'感谢支持！'**
  String get donationThankYouTitle;

  /// No description provided for @donationThankYouMessage.
  ///
  /// In zh, this message translates to:
  /// **'感谢您购买 {productName}！您的支持对我意义重大，我会继续努力改进智记，让它变得更好用！'**
  String donationThankYouMessage(String productName);

  /// No description provided for @aiPromptEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'提示词编辑'**
  String get aiPromptEditTitle;

  /// No description provided for @aiPromptEditSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'自定义AI账单识别提示词'**
  String get aiPromptEditSubtitle;

  /// No description provided for @aiPromptAdvancedSettings.
  ///
  /// In zh, this message translates to:
  /// **'高级设置'**
  String get aiPromptAdvancedSettings;

  /// No description provided for @aiAdvancedSettingsDesc.
  ///
  /// In zh, this message translates to:
  /// **'模型选择、执行策略、本地模型、提示词'**
  String get aiAdvancedSettingsDesc;

  /// No description provided for @aiPromptEditEntry.
  ///
  /// In zh, this message translates to:
  /// **'提示词编辑'**
  String get aiPromptEditEntry;

  /// No description provided for @aiPromptEditEntryDesc.
  ///
  /// In zh, this message translates to:
  /// **'自定义AI账单识别提示词，可分享给其他用户'**
  String get aiPromptEditEntryDesc;

  /// No description provided for @aiPromptVariables.
  ///
  /// In zh, this message translates to:
  /// **'变量说明'**
  String get aiPromptVariables;

  /// No description provided for @aiPromptVariablesHint.
  ///
  /// In zh, this message translates to:
  /// **'点击展开查看可用变量'**
  String get aiPromptVariablesHint;

  /// No description provided for @aiPromptContent.
  ///
  /// In zh, this message translates to:
  /// **'提示词内容'**
  String get aiPromptContent;

  /// No description provided for @aiPromptUnsaved.
  ///
  /// In zh, this message translates to:
  /// **'未保存'**
  String get aiPromptUnsaved;

  /// No description provided for @aiPromptInputHint.
  ///
  /// In zh, this message translates to:
  /// **'输入提示词...'**
  String get aiPromptInputHint;

  /// No description provided for @aiPromptPreview.
  ///
  /// In zh, this message translates to:
  /// **'预览'**
  String get aiPromptPreview;

  /// No description provided for @aiPromptSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get aiPromptSave;

  /// No description provided for @aiPromptSaved.
  ///
  /// In zh, this message translates to:
  /// **'提示词已保存'**
  String get aiPromptSaved;

  /// No description provided for @aiPromptResetDefault.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get aiPromptResetDefault;

  /// No description provided for @aiPromptResetConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get aiPromptResetConfirmTitle;

  /// No description provided for @aiPromptResetConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要恢复默认提示词吗？您的自定义内容将会丢失。'**
  String get aiPromptResetConfirmMessage;

  /// No description provided for @aiPromptPasted.
  ///
  /// In zh, this message translates to:
  /// **'已粘贴'**
  String get aiPromptPasted;

  /// No description provided for @aiPromptPreviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'提示词预览'**
  String get aiPromptPreviewTitle;

  /// No description provided for @aiPromptPreviewNote.
  ///
  /// In zh, this message translates to:
  /// **'以上预览使用示例数据替换变量，实际运行时会使用真实数据'**
  String get aiPromptPreviewNote;

  /// No description provided for @aiPromptVarInputSource.
  ///
  /// In zh, this message translates to:
  /// **'输入来源描述，如\"从以下支付账单文本中\"'**
  String get aiPromptVarInputSource;

  /// No description provided for @aiPromptVarCurrentTime.
  ///
  /// In zh, this message translates to:
  /// **'当前日期和时间，如\"2025-01-15 14:30\"'**
  String get aiPromptVarCurrentTime;

  /// No description provided for @aiPromptVarCurrentDate.
  ///
  /// In zh, this message translates to:
  /// **'当前日期，如\"2025-01-15\"'**
  String get aiPromptVarCurrentDate;

  /// No description provided for @aiPromptVarOcrText.
  ///
  /// In zh, this message translates to:
  /// **'用户输入的文本内容'**
  String get aiPromptVarOcrText;

  /// No description provided for @aiPromptVarCategories.
  ///
  /// In zh, this message translates to:
  /// **'支出和收入分类列表'**
  String get aiPromptVarCategories;

  /// No description provided for @aiPromptVarAccounts.
  ///
  /// In zh, this message translates to:
  /// **'用户的账户列表（可能为空）'**
  String get aiPromptVarAccounts;

  /// No description provided for @aiModelTitle.
  ///
  /// In zh, this message translates to:
  /// **'文本推理模型'**
  String get aiModelTitle;

  /// No description provided for @aiVisionModelTitle.
  ///
  /// In zh, this message translates to:
  /// **'视觉模型'**
  String get aiVisionModelTitle;

  /// No description provided for @aiVisionConcurrency.
  ///
  /// In zh, this message translates to:
  /// **'并发数'**
  String get aiVisionConcurrency;

  /// No description provided for @aiVisionConcurrencyHelper.
  ///
  /// In zh, this message translates to:
  /// **'文字识别与图片识别同时进行的最大任务数(1-32)'**
  String get aiVisionConcurrencyHelper;

  /// No description provided for @aiModelFast.
  ///
  /// In zh, this message translates to:
  /// **'快速'**
  String get aiModelFast;

  /// No description provided for @aiModelAccurate.
  ///
  /// In zh, this message translates to:
  /// **'准确'**
  String get aiModelAccurate;

  /// No description provided for @aiModelSwitched.
  ///
  /// In zh, this message translates to:
  /// **'已切换到 {modelName}'**
  String aiModelSwitched(String modelName);

  /// No description provided for @aiCustomBaseUrlHelper.
  ///
  /// In zh, this message translates to:
  /// **'标准聊天补全API地址，例如 https://api.example.com/v1'**
  String get aiCustomBaseUrlHelper;

  /// No description provided for @aiTextModelTitle.
  ///
  /// In zh, this message translates to:
  /// **'文本模型'**
  String get aiTextModelTitle;

  /// No description provided for @aiAudioModelTitle.
  ///
  /// In zh, this message translates to:
  /// **'语音模型'**
  String get aiAudioModelTitle;

  /// No description provided for @tagManageTitle.
  ///
  /// In zh, this message translates to:
  /// **'标签管理'**
  String get tagManageTitle;

  /// No description provided for @tagManageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'管理交易标签'**
  String get tagManageSubtitle;

  /// No description provided for @tagManageEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无标签'**
  String get tagManageEmpty;

  /// No description provided for @tagManageEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'点击右上角添加标签'**
  String get tagManageEmptyHint;

  /// No description provided for @tagManageGenerateDefault.
  ///
  /// In zh, this message translates to:
  /// **'生成默认标签'**
  String get tagManageGenerateDefault;

  /// No description provided for @tagManageGenerateDefaultConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要生成默认标签吗？已有同名标签不会被覆盖。'**
  String get tagManageGenerateDefaultConfirm;

  /// No description provided for @tagManageGenerateDefaultSuccess.
  ///
  /// In zh, this message translates to:
  /// **'默认标签已生成'**
  String get tagManageGenerateDefaultSuccess;

  /// No description provided for @tagEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑标签'**
  String get tagEditTitle;

  /// No description provided for @tagAddTitle.
  ///
  /// In zh, this message translates to:
  /// **'新增标签'**
  String get tagAddTitle;

  /// No description provided for @tagNameLabel.
  ///
  /// In zh, this message translates to:
  /// **'标签名称'**
  String get tagNameLabel;

  /// No description provided for @tagNameHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入标签名称'**
  String get tagNameHint;

  /// No description provided for @tagNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'标签名称不能为空'**
  String get tagNameRequired;

  /// No description provided for @tagNameDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'标签名称已存在'**
  String get tagNameDuplicate;

  /// No description provided for @tagColorLabel.
  ///
  /// In zh, this message translates to:
  /// **'标签颜色'**
  String get tagColorLabel;

  /// No description provided for @tagCreateSuccess.
  ///
  /// In zh, this message translates to:
  /// **'标签创建成功'**
  String get tagCreateSuccess;

  /// No description provided for @tagUpdateSuccess.
  ///
  /// In zh, this message translates to:
  /// **'标签更新成功'**
  String get tagUpdateSuccess;

  /// No description provided for @tagDeleteConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除标签'**
  String get tagDeleteConfirmTitle;

  /// No description provided for @tagDeleteConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除标签「{name}」吗？此操作不会影响已关联的交易记录。'**
  String tagDeleteConfirmMessage(String name);

  /// No description provided for @tagDeleteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'标签已删除'**
  String get tagDeleteSuccess;

  /// No description provided for @tagSelectTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择标签'**
  String get tagSelectTitle;

  /// No description provided for @tagSelectHint.
  ///
  /// In zh, this message translates to:
  /// **'可多选'**
  String get tagSelectHint;

  /// No description provided for @tagSelectCreateNew.
  ///
  /// In zh, this message translates to:
  /// **'新建标签'**
  String get tagSelectCreateNew;

  /// No description provided for @tagSelectOwnerManaged.
  ///
  /// In zh, this message translates to:
  /// **'共享账本标签由所有者管理'**
  String get tagSelectOwnerManaged;

  /// No description provided for @tagSelectRecentlyUsed.
  ///
  /// In zh, this message translates to:
  /// **'最近使用'**
  String get tagSelectRecentlyUsed;

  /// No description provided for @tagSelectAllTags.
  ///
  /// In zh, this message translates to:
  /// **'全部标签'**
  String get tagSelectAllTags;

  /// No description provided for @tagTransactionCount.
  ///
  /// In zh, this message translates to:
  /// **'{count}笔'**
  String tagTransactionCount(int count);

  /// No description provided for @tagDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'标签详情'**
  String get tagDetailTitle;

  /// No description provided for @tagDetailTotalCount.
  ///
  /// In zh, this message translates to:
  /// **'交易笔数'**
  String get tagDetailTotalCount;

  /// No description provided for @tagDetailTotalExpense.
  ///
  /// In zh, this message translates to:
  /// **'总支出'**
  String get tagDetailTotalExpense;

  /// No description provided for @tagDetailTotalIncome.
  ///
  /// In zh, this message translates to:
  /// **'总收入'**
  String get tagDetailTotalIncome;

  /// No description provided for @tagDetailTransactionList.
  ///
  /// In zh, this message translates to:
  /// **'关联交易'**
  String get tagDetailTransactionList;

  /// No description provided for @tagDetailNoTransactions.
  ///
  /// In zh, this message translates to:
  /// **'暂无关联交易'**
  String get tagDetailNoTransactions;

  /// No description provided for @tagDetailNoTransactionsHint.
  ///
  /// In zh, this message translates to:
  /// **'使用此标签的交易将在此显示'**
  String get tagDetailNoTransactionsHint;

  /// No description provided for @tagNotFound.
  ///
  /// In zh, this message translates to:
  /// **'标签不存在'**
  String get tagNotFound;

  /// No description provided for @tagDefaultMeituan.
  ///
  /// In zh, this message translates to:
  /// **'美团'**
  String get tagDefaultMeituan;

  /// No description provided for @tagDefaultEleme.
  ///
  /// In zh, this message translates to:
  /// **'饿了么'**
  String get tagDefaultEleme;

  /// No description provided for @tagDefaultTaobao.
  ///
  /// In zh, this message translates to:
  /// **'淘宝'**
  String get tagDefaultTaobao;

  /// No description provided for @tagDefaultJD.
  ///
  /// In zh, this message translates to:
  /// **'京东'**
  String get tagDefaultJD;

  /// No description provided for @tagDefaultPDD.
  ///
  /// In zh, this message translates to:
  /// **'拼多多'**
  String get tagDefaultPDD;

  /// No description provided for @tagDefaultStarbucks.
  ///
  /// In zh, this message translates to:
  /// **'星巴克'**
  String get tagDefaultStarbucks;

  /// No description provided for @tagDefaultLuckin.
  ///
  /// In zh, this message translates to:
  /// **'瑞幸咖啡'**
  String get tagDefaultLuckin;

  /// No description provided for @tagDefaultMcDonalds.
  ///
  /// In zh, this message translates to:
  /// **'麦当劳'**
  String get tagDefaultMcDonalds;

  /// No description provided for @tagDefaultKFC.
  ///
  /// In zh, this message translates to:
  /// **'肯德基'**
  String get tagDefaultKFC;

  /// No description provided for @tagDefaultHema.
  ///
  /// In zh, this message translates to:
  /// **'盒马'**
  String get tagDefaultHema;

  /// No description provided for @tagDefaultSams.
  ///
  /// In zh, this message translates to:
  /// **'山姆'**
  String get tagDefaultSams;

  /// No description provided for @tagDefaultCostco.
  ///
  /// In zh, this message translates to:
  /// **'Costco'**
  String get tagDefaultCostco;

  /// No description provided for @tagDefaultBusinessTrip.
  ///
  /// In zh, this message translates to:
  /// **'出差'**
  String get tagDefaultBusinessTrip;

  /// No description provided for @tagDefaultTravel.
  ///
  /// In zh, this message translates to:
  /// **'旅行'**
  String get tagDefaultTravel;

  /// No description provided for @tagDefaultDining.
  ///
  /// In zh, this message translates to:
  /// **'聚餐'**
  String get tagDefaultDining;

  /// No description provided for @tagDefaultOnlineShopping.
  ///
  /// In zh, this message translates to:
  /// **'网购'**
  String get tagDefaultOnlineShopping;

  /// No description provided for @tagDefaultDaily.
  ///
  /// In zh, this message translates to:
  /// **'日常'**
  String get tagDefaultDaily;

  /// No description provided for @tagDefaultReimbursement.
  ///
  /// In zh, this message translates to:
  /// **'报销'**
  String get tagDefaultReimbursement;

  /// No description provided for @tagDefaultRefundable.
  ///
  /// In zh, this message translates to:
  /// **'可退款'**
  String get tagDefaultRefundable;

  /// No description provided for @tagDefaultRefunded.
  ///
  /// In zh, this message translates to:
  /// **'已退款'**
  String get tagDefaultRefunded;

  /// No description provided for @tagDefaultVoiceBilling.
  ///
  /// In zh, this message translates to:
  /// **'语音记账'**
  String get tagDefaultVoiceBilling;

  /// No description provided for @tagDefaultImageBilling.
  ///
  /// In zh, this message translates to:
  /// **'图片记账'**
  String get tagDefaultImageBilling;

  /// No description provided for @tagDefaultCameraBilling.
  ///
  /// In zh, this message translates to:
  /// **'拍照记账'**
  String get tagDefaultCameraBilling;

  /// No description provided for @tagDefaultAiBilling.
  ///
  /// In zh, this message translates to:
  /// **'AI记账'**
  String get tagDefaultAiBilling;

  /// No description provided for @tagDefaultSmsBilling.
  ///
  /// In zh, this message translates to:
  /// **'短信'**
  String get tagDefaultSmsBilling;

  /// No description provided for @tagDefaultNotificationBilling.
  ///
  /// In zh, this message translates to:
  /// **'通知'**
  String get tagDefaultNotificationBilling;

  /// No description provided for @tagDefaultScreenBilling.
  ///
  /// In zh, this message translates to:
  /// **'屏幕'**
  String get tagDefaultScreenBilling;

  /// No description provided for @tagShare.
  ///
  /// In zh, this message translates to:
  /// **'分享标签'**
  String get tagShare;

  /// No description provided for @tagImport.
  ///
  /// In zh, this message translates to:
  /// **'导入标签'**
  String get tagImport;

  /// No description provided for @tagClearUnused.
  ///
  /// In zh, this message translates to:
  /// **'清理未使用'**
  String get tagClearUnused;

  /// No description provided for @tagShareSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已保存到 {path}'**
  String tagShareSuccess(String path);

  /// No description provided for @tagShareSubject.
  ///
  /// In zh, this message translates to:
  /// **'智记 标签配置'**
  String get tagShareSubject;

  /// No description provided for @tagShareFailed.
  ///
  /// In zh, this message translates to:
  /// **'分享失败'**
  String get tagShareFailed;

  /// No description provided for @tagImportInvalidFile.
  ///
  /// In zh, this message translates to:
  /// **'请选择 YAML 配置文件'**
  String get tagImportInvalidFile;

  /// No description provided for @tagImportNoTags.
  ///
  /// In zh, this message translates to:
  /// **'文件中没有标签数据'**
  String get tagImportNoTags;

  /// No description provided for @tagImportModeTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择导入模式'**
  String get tagImportModeTitle;

  /// No description provided for @tagImportModeMerge.
  ///
  /// In zh, this message translates to:
  /// **'合并'**
  String get tagImportModeMerge;

  /// No description provided for @tagImportModeMergeDesc.
  ///
  /// In zh, this message translates to:
  /// **'保留现有标签，新增不存在的'**
  String get tagImportModeMergeDesc;

  /// No description provided for @tagImportModeOverwrite.
  ///
  /// In zh, this message translates to:
  /// **'覆盖'**
  String get tagImportModeOverwrite;

  /// No description provided for @tagImportModeOverwriteDesc.
  ///
  /// In zh, this message translates to:
  /// **'清空未使用标签后导入'**
  String get tagImportModeOverwriteDesc;

  /// No description provided for @tagImportSuccess.
  ///
  /// In zh, this message translates to:
  /// **'导入成功'**
  String get tagImportSuccess;

  /// No description provided for @tagImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导入失败'**
  String get tagImportFailed;

  /// No description provided for @tagClearUnusedEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有未使用的标签'**
  String get tagClearUnusedEmpty;

  /// No description provided for @tagClearUnusedTitle.
  ///
  /// In zh, this message translates to:
  /// **'清理未使用标签'**
  String get tagClearUnusedTitle;

  /// No description provided for @tagClearUnusedMessage.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除 {count} 个未使用的标签吗？'**
  String tagClearUnusedMessage(int count);

  /// No description provided for @tagClearUnusedSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已删除 {count} 个标签'**
  String tagClearUnusedSuccess(int count);

  /// No description provided for @tagClearUnusedFailed.
  ///
  /// In zh, this message translates to:
  /// **'清理失败'**
  String get tagClearUnusedFailed;

  /// No description provided for @homeSwitchLedger.
  ///
  /// In zh, this message translates to:
  /// **'选择账本'**
  String get homeSwitchLedger;

  /// No description provided for @homeManageLedgers.
  ///
  /// In zh, this message translates to:
  /// **'管理账本'**
  String get homeManageLedgers;

  /// No description provided for @budgetTitle.
  ///
  /// In zh, this message translates to:
  /// **'预算管理'**
  String get budgetTitle;

  /// No description provided for @budgetShowOnHome.
  ///
  /// In zh, this message translates to:
  /// **'在首页显示预算'**
  String get budgetShowOnHome;

  /// No description provided for @budgetEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'还没有设置预算'**
  String get budgetEmptyHint;

  /// No description provided for @budgetAddTotal.
  ///
  /// In zh, this message translates to:
  /// **'添加总预算'**
  String get budgetAddTotal;

  /// No description provided for @budgetMonthlyBudget.
  ///
  /// In zh, this message translates to:
  /// **'本月预算'**
  String get budgetMonthlyBudget;

  /// No description provided for @budgetUsed.
  ///
  /// In zh, this message translates to:
  /// **'已用'**
  String get budgetUsed;

  /// No description provided for @budgetRemaining.
  ///
  /// In zh, this message translates to:
  /// **'剩余'**
  String get budgetRemaining;

  /// No description provided for @budgetDaysRemaining.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {days} 天'**
  String budgetDaysRemaining(int days);

  /// No description provided for @budgetDailyAvailable.
  ///
  /// In zh, this message translates to:
  /// **'日均可用 {amount}'**
  String budgetDailyAvailable(String amount);

  /// No description provided for @budgetCategoryBudgets.
  ///
  /// In zh, this message translates to:
  /// **'分类预算'**
  String get budgetCategoryBudgets;

  /// No description provided for @budgetEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑预算'**
  String get budgetEditTitle;

  /// No description provided for @budgetAddTitle.
  ///
  /// In zh, this message translates to:
  /// **'添加预算'**
  String get budgetAddTitle;

  /// No description provided for @budgetTypeTotalLabel.
  ///
  /// In zh, this message translates to:
  /// **'总预算'**
  String get budgetTypeTotalLabel;

  /// No description provided for @budgetTypeCategoryLabel.
  ///
  /// In zh, this message translates to:
  /// **'分类预算'**
  String get budgetTypeCategoryLabel;

  /// No description provided for @budgetAmountLabel.
  ///
  /// In zh, this message translates to:
  /// **'预算金额'**
  String get budgetAmountLabel;

  /// No description provided for @budgetAmountHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入预算金额'**
  String get budgetAmountHint;

  /// No description provided for @budgetCategoryLabel.
  ///
  /// In zh, this message translates to:
  /// **'选择分类'**
  String get budgetCategoryLabel;

  /// No description provided for @budgetCategoryHint.
  ///
  /// In zh, this message translates to:
  /// **'请选择预算分类'**
  String get budgetCategoryHint;

  /// No description provided for @budgetStartDayLabel.
  ///
  /// In zh, this message translates to:
  /// **'起始日'**
  String get budgetStartDayLabel;

  /// No description provided for @budgetPeriodLabel.
  ///
  /// In zh, this message translates to:
  /// **'周期'**
  String get budgetPeriodLabel;

  /// No description provided for @budgetSaveSuccess.
  ///
  /// In zh, this message translates to:
  /// **'预算保存成功'**
  String get budgetSaveSuccess;

  /// No description provided for @budgetDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定删除此预算？'**
  String get budgetDeleteConfirm;

  /// No description provided for @budgetDeleteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'预算已删除'**
  String get budgetDeleteSuccess;

  /// No description provided for @attachmentAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加图片'**
  String get attachmentAdd;

  /// No description provided for @attachmentTakePhoto.
  ///
  /// In zh, this message translates to:
  /// **'拍照'**
  String get attachmentTakePhoto;

  /// No description provided for @attachmentChooseFromGallery.
  ///
  /// In zh, this message translates to:
  /// **'从相册选择'**
  String get attachmentChooseFromGallery;

  /// No description provided for @attachmentMaxReached.
  ///
  /// In zh, this message translates to:
  /// **'已达到最大附件数量'**
  String get attachmentMaxReached;

  /// No description provided for @attachmentDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定删除此附件？'**
  String get attachmentDeleteConfirm;

  /// No description provided for @attachmentCount.
  ///
  /// In zh, this message translates to:
  /// **'{count}张图片'**
  String attachmentCount(int count);

  /// No description provided for @commonDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get commonDeleted;

  /// No description provided for @attachmentExportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出附件'**
  String get attachmentExportTitle;

  /// No description provided for @attachmentExportSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'将所有附件打包导出为压缩文件'**
  String get attachmentExportSubtitle;

  /// No description provided for @attachmentImportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入附件'**
  String get attachmentImportTitle;

  /// No description provided for @attachmentImportSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'从压缩文件导入附件'**
  String get attachmentImportSubtitle;

  /// No description provided for @attachmentExportEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有附件需要导出'**
  String get attachmentExportEmpty;

  /// No description provided for @attachmentExportProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在导出附件 ({current}/{total})'**
  String attachmentExportProgress(int current, int total);

  /// No description provided for @attachmentExportProgressDetail.
  ///
  /// In zh, this message translates to:
  /// **'正在导出 {attachmentCount} 个附件 + {iconCount} 个图标 ({current}/{total})'**
  String attachmentExportProgressDetail(int attachmentCount, int iconCount, int current, int total);

  /// No description provided for @attachmentExportSuccess.
  ///
  /// In zh, this message translates to:
  /// **'附件导出成功'**
  String get attachmentExportSuccess;

  /// No description provided for @attachmentExportSavedTo.
  ///
  /// In zh, this message translates to:
  /// **'已保存到: {path}'**
  String attachmentExportSavedTo(String path);

  /// No description provided for @attachmentImportConflictStrategy.
  ///
  /// In zh, this message translates to:
  /// **'冲突处理策略'**
  String get attachmentImportConflictStrategy;

  /// No description provided for @attachmentImportConflictSkip.
  ///
  /// In zh, this message translates to:
  /// **'跳过已存在的附件'**
  String get attachmentImportConflictSkip;

  /// No description provided for @attachmentImportConflictOverwrite.
  ///
  /// In zh, this message translates to:
  /// **'覆盖已存在的附件'**
  String get attachmentImportConflictOverwrite;

  /// No description provided for @attachmentImportProgress.
  ///
  /// In zh, this message translates to:
  /// **'正在导入附件 ({current}/{total})'**
  String attachmentImportProgress(int current, int total);

  /// No description provided for @attachmentImportResult.
  ///
  /// In zh, this message translates to:
  /// **'导入 {imported} 张，跳过 {skipped} 张，覆盖 {overwritten} 张，失败 {failed} 张'**
  String attachmentImportResult(int imported, int skipped, int overwritten, int failed);

  /// No description provided for @attachmentImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'附件导入失败'**
  String get attachmentImportFailed;

  /// No description provided for @attachmentArchiveInfo.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个附件，导出于 {date}'**
  String attachmentArchiveInfo(int count, String date);

  /// No description provided for @attachmentStartImport.
  ///
  /// In zh, this message translates to:
  /// **'开始导入'**
  String get attachmentStartImport;

  /// No description provided for @attachmentPreview.
  ///
  /// In zh, this message translates to:
  /// **'预览附件'**
  String get attachmentPreview;

  /// No description provided for @attachmentPreviewSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 张图片'**
  String attachmentPreviewSubtitle(int count);

  /// No description provided for @attachmentPreviewEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无附件'**
  String get attachmentPreviewEmpty;

  /// No description provided for @attachmentExportPreviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出预览'**
  String get attachmentExportPreviewTitle;

  /// No description provided for @attachmentImportPreviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入预览'**
  String get attachmentImportPreviewTitle;

  /// No description provided for @shortcutsGuide.
  ///
  /// In zh, this message translates to:
  /// **'快捷指令'**
  String get shortcutsGuide;

  /// No description provided for @shortcutsGuideDesc.
  ///
  /// In zh, this message translates to:
  /// **'快速打开语音、拍照等记账方式'**
  String get shortcutsGuideDesc;

  /// No description provided for @shortcutsIntroTitle.
  ///
  /// In zh, this message translates to:
  /// **'快速记账'**
  String get shortcutsIntroTitle;

  /// No description provided for @shortcutsIntroDesc.
  ///
  /// In zh, this message translates to:
  /// **'使用快捷指令，可以在桌面直接打开语音记账、拍照记账等功能，无需先打开 App。'**
  String get shortcutsIntroDesc;

  /// No description provided for @availableShortcuts.
  ///
  /// In zh, this message translates to:
  /// **'可用快捷指令'**
  String get availableShortcuts;

  /// No description provided for @shortcutVoice.
  ///
  /// In zh, this message translates to:
  /// **'语音记账'**
  String get shortcutVoice;

  /// No description provided for @shortcutVoiceDesc.
  ///
  /// In zh, this message translates to:
  /// **'通过语音快速记录账单'**
  String get shortcutVoiceDesc;

  /// No description provided for @shortcutImage.
  ///
  /// In zh, this message translates to:
  /// **'图片记账'**
  String get shortcutImage;

  /// No description provided for @shortcutImageDesc.
  ///
  /// In zh, this message translates to:
  /// **'从相册选择图片识别账单'**
  String get shortcutImageDesc;

  /// No description provided for @shortcutCamera.
  ///
  /// In zh, this message translates to:
  /// **'拍照记账'**
  String get shortcutCamera;

  /// No description provided for @shortcutCameraDesc.
  ///
  /// In zh, this message translates to:
  /// **'拍照识别账单'**
  String get shortcutCameraDesc;

  /// No description provided for @shortcutNewExpense.
  ///
  /// In zh, this message translates to:
  /// **'快捷记支出'**
  String get shortcutNewExpense;

  /// No description provided for @shortcutNewExpenseDesc.
  ///
  /// In zh, this message translates to:
  /// **'直接打开支出记账页面'**
  String get shortcutNewExpenseDesc;

  /// No description provided for @shortcutNewIncome.
  ///
  /// In zh, this message translates to:
  /// **'快捷记收入'**
  String get shortcutNewIncome;

  /// No description provided for @shortcutNewIncomeDesc.
  ///
  /// In zh, this message translates to:
  /// **'直接打开收入记账页面'**
  String get shortcutNewIncomeDesc;

  /// No description provided for @shortcutNewTransfer.
  ///
  /// In zh, this message translates to:
  /// **'快捷记转账'**
  String get shortcutNewTransfer;

  /// No description provided for @shortcutNewTransferDesc.
  ///
  /// In zh, this message translates to:
  /// **'直接打开转账记账页面'**
  String get shortcutNewTransferDesc;

  /// No description provided for @shortcutUrlCopied.
  ///
  /// In zh, this message translates to:
  /// **'链接已复制到剪贴板'**
  String get shortcutUrlCopied;

  /// No description provided for @howToAddShortcut.
  ///
  /// In zh, this message translates to:
  /// **'如何添加快捷指令'**
  String get howToAddShortcut;

  /// No description provided for @iosShortcutStep1.
  ///
  /// In zh, this message translates to:
  /// **'打开「快捷指令」App'**
  String get iosShortcutStep1;

  /// No description provided for @iosShortcutStep2.
  ///
  /// In zh, this message translates to:
  /// **'点击右上角「+」新建快捷指令'**
  String get iosShortcutStep2;

  /// No description provided for @iosShortcutStep3.
  ///
  /// In zh, this message translates to:
  /// **'添加「打开 URL」操作'**
  String get iosShortcutStep3;

  /// No description provided for @iosShortcutStep4.
  ///
  /// In zh, this message translates to:
  /// **'粘贴上方复制的链接（如 smartbook://voice）'**
  String get iosShortcutStep4;

  /// No description provided for @iosShortcutStep5.
  ///
  /// In zh, this message translates to:
  /// **'保存后，可添加到桌面使用'**
  String get iosShortcutStep5;

  /// No description provided for @androidShortcutStep1.
  ///
  /// In zh, this message translates to:
  /// **'下载支持创建快捷方式的应用（如 Shortcut Maker）'**
  String get androidShortcutStep1;

  /// No description provided for @androidShortcutStep2.
  ///
  /// In zh, this message translates to:
  /// **'选择「URL 快捷方式」'**
  String get androidShortcutStep2;

  /// No description provided for @androidShortcutStep3.
  ///
  /// In zh, this message translates to:
  /// **'粘贴上方复制的链接（如 smartbook://voice）'**
  String get androidShortcutStep3;

  /// No description provided for @androidShortcutStep4.
  ///
  /// In zh, this message translates to:
  /// **'设置图标和名称后添加到桌面'**
  String get androidShortcutStep4;

  /// No description provided for @shortcutsTip.
  ///
  /// In zh, this message translates to:
  /// **'小贴士'**
  String get shortcutsTip;

  /// No description provided for @shortcutsTipDesc.
  ///
  /// In zh, this message translates to:
  /// **'快捷指令需要配合 AI 功能使用。请确保已开启智能识别并配置好 API Key。'**
  String get shortcutsTipDesc;

  /// No description provided for @shortcutOpenShortcutsApp.
  ///
  /// In zh, this message translates to:
  /// **'打开快捷指令 App'**
  String get shortcutOpenShortcutsApp;

  /// No description provided for @shortcutAutoAdd.
  ///
  /// In zh, this message translates to:
  /// **'自动记账接口'**
  String get shortcutAutoAdd;

  /// No description provided for @shortcutAutoAddDesc.
  ///
  /// In zh, this message translates to:
  /// **'通过 URL 参数自动创建账单，适合与快捷指令、自动化工具配合使用。'**
  String get shortcutAutoAddDesc;

  /// No description provided for @shortcutAutoAddExample.
  ///
  /// In zh, this message translates to:
  /// **'示例链接：'**
  String get shortcutAutoAddExample;

  /// No description provided for @shortcutAutoAddParams.
  ///
  /// In zh, this message translates to:
  /// **'支持的参数：'**
  String get shortcutAutoAddParams;

  /// No description provided for @shortcutParamAmount.
  ///
  /// In zh, this message translates to:
  /// **'金额（必填）'**
  String get shortcutParamAmount;

  /// No description provided for @shortcutParamType.
  ///
  /// In zh, this message translates to:
  /// **'类型：expense（支出）/ income（收入）/ transfer（转账）'**
  String get shortcutParamType;

  /// No description provided for @shortcutParamCategory.
  ///
  /// In zh, this message translates to:
  /// **'分类名称（需与App中已有分类匹配）'**
  String get shortcutParamCategory;

  /// No description provided for @shortcutParamNote.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get shortcutParamNote;

  /// No description provided for @shortcutParamAccount.
  ///
  /// In zh, this message translates to:
  /// **'账户名称（需与App中已有账户匹配）'**
  String get shortcutParamAccount;

  /// No description provided for @shortcutParamTags.
  ///
  /// In zh, this message translates to:
  /// **'标签（多个用逗号分隔）'**
  String get shortcutParamTags;

  /// No description provided for @shortcutParamDate.
  ///
  /// In zh, this message translates to:
  /// **'日期（ISO格式，如 2024-01-15）'**
  String get shortcutParamDate;

  /// No description provided for @quickActionImage.
  ///
  /// In zh, this message translates to:
  /// **'图片记账'**
  String get quickActionImage;

  /// No description provided for @quickActionCamera.
  ///
  /// In zh, this message translates to:
  /// **'拍照记账'**
  String get quickActionCamera;

  /// No description provided for @quickActionVoice.
  ///
  /// In zh, this message translates to:
  /// **'语音记账'**
  String get quickActionVoice;

  /// No description provided for @quickActionAiChat.
  ///
  /// In zh, this message translates to:
  /// **'AI 小助手'**
  String get quickActionAiChat;

  /// No description provided for @calendarTitle.
  ///
  /// In zh, this message translates to:
  /// **'日历'**
  String get calendarTitle;

  /// No description provided for @calendarToday.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get calendarToday;

  /// No description provided for @calendarNoTransactions.
  ///
  /// In zh, this message translates to:
  /// **'当天无交易'**
  String get calendarNoTransactions;

  /// No description provided for @calendarAddTransaction.
  ///
  /// In zh, this message translates to:
  /// **'在该日记账'**
  String get calendarAddTransaction;

  /// No description provided for @calendarAddTransactionTooltip.
  ///
  /// In zh, this message translates to:
  /// **'添加该日记账'**
  String get calendarAddTransactionTooltip;

  /// No description provided for @commonUncategorized.
  ///
  /// In zh, this message translates to:
  /// **'未分类'**
  String get commonUncategorized;

  /// No description provided for @commonSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get commonSaved;

  /// No description provided for @aiProviderManageTitle.
  ///
  /// In zh, this message translates to:
  /// **'服务商管理'**
  String get aiProviderManageTitle;

  /// No description provided for @aiProviderManageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'管理AI服务商配置'**
  String get aiProviderManageSubtitle;

  /// No description provided for @aiProviderAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加服务商'**
  String get aiProviderAdd;

  /// No description provided for @aiProviderBuiltIn.
  ///
  /// In zh, this message translates to:
  /// **'内置'**
  String get aiProviderBuiltIn;

  /// No description provided for @aiProviderEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无服务商配置'**
  String get aiProviderEmpty;

  /// No description provided for @aiProviderNoApiKey.
  ///
  /// In zh, this message translates to:
  /// **'未配置 API Key'**
  String get aiProviderNoApiKey;

  /// No description provided for @aiProviderApiKeyKeepHint.
  ///
  /// In zh, this message translates to:
  /// **'留空保持现有 Key 不变'**
  String get aiProviderApiKeyKeepHint;

  /// No description provided for @automationDraftsDiscarded.
  ///
  /// In zh, this message translates to:
  /// **'草稿已丢弃'**
  String get automationDraftsDiscarded;

  /// No description provided for @automationDraftsImageGone.
  ///
  /// In zh, this message translates to:
  /// **'原图已被系统清理，无法重试'**
  String get automationDraftsImageGone;

  /// No description provided for @automationDraftsRetryQueued.
  ///
  /// In zh, this message translates to:
  /// **'已重新提交识别'**
  String get automationDraftsRetryQueued;

  /// No description provided for @automationDraftsDiscard.
  ///
  /// In zh, this message translates to:
  /// **'丢弃草稿'**
  String get automationDraftsDiscard;

  /// No description provided for @automationDraftsRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试识别'**
  String get automationDraftsRetry;

  /// No description provided for @automationDraftsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无离线识别草稿'**
  String get automationDraftsEmpty;

  /// No description provided for @automationDraftsTitle.
  ///
  /// In zh, this message translates to:
  /// **'草稿'**
  String get automationDraftsTitle;

  /// No description provided for @aiProviderTapToEdit.
  ///
  /// In zh, this message translates to:
  /// **'点击编辑'**
  String get aiProviderTapToEdit;

  /// No description provided for @aiProviderDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除服务商'**
  String get aiProviderDeleteTitle;

  /// No description provided for @aiProviderDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定删除服务商「{name}」吗？使用该服务商的能力将自动切换到默认服务商。'**
  String aiProviderDeleteConfirm(String name);

  /// No description provided for @aiProviderDeleted.
  ///
  /// In zh, this message translates to:
  /// **'服务商已删除'**
  String get aiProviderDeleted;

  /// No description provided for @aiProviderEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑服务商'**
  String get aiProviderEditTitle;

  /// No description provided for @aiProviderAddTitle.
  ///
  /// In zh, this message translates to:
  /// **'添加服务商'**
  String get aiProviderAddTitle;

  /// No description provided for @aiProviderBasicInfo.
  ///
  /// In zh, this message translates to:
  /// **'基本信息'**
  String get aiProviderBasicInfo;

  /// No description provided for @aiProviderName.
  ///
  /// In zh, this message translates to:
  /// **'服务商名称'**
  String get aiProviderName;

  /// No description provided for @aiProviderProtocol.
  ///
  /// In zh, this message translates to:
  /// **'接口协议'**
  String get aiProviderProtocol;

  /// No description provided for @aiProviderProtocolHint.
  ///
  /// In zh, this message translates to:
  /// **'Anthropic 协议不支持语音转文字'**
  String get aiProviderProtocolHint;

  /// No description provided for @aiProviderNameHint.
  ///
  /// In zh, this message translates to:
  /// **'如：硅基流动、DeepSeek'**
  String get aiProviderNameHint;

  /// No description provided for @aiProviderNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入服务商名称'**
  String get aiProviderNameRequired;

  /// No description provided for @aiProviderBaseUrlRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入 Base URL'**
  String get aiProviderBaseUrlRequired;

  /// No description provided for @aiProviderModels.
  ///
  /// In zh, this message translates to:
  /// **'模型配置'**
  String get aiProviderModels;

  /// No description provided for @aiProviderModelsHint.
  ///
  /// In zh, this message translates to:
  /// **'留空的能力将无法使用该服务商'**
  String get aiProviderModelsHint;

  /// No description provided for @aiCapabilityText.
  ///
  /// In zh, this message translates to:
  /// **'文本'**
  String get aiCapabilityText;

  /// No description provided for @aiCapabilityVision.
  ///
  /// In zh, this message translates to:
  /// **'视觉'**
  String get aiCapabilityVision;

  /// No description provided for @aiCapabilitySpeech.
  ///
  /// In zh, this message translates to:
  /// **'语音'**
  String get aiCapabilitySpeech;

  /// No description provided for @aiCapabilitySelectTitle.
  ///
  /// In zh, this message translates to:
  /// **'能力绑定'**
  String get aiCapabilitySelectTitle;

  /// No description provided for @aiCapabilitySelectSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'为每个AI能力选择服务商'**
  String get aiCapabilitySelectSubtitle;

  /// No description provided for @aiCapabilityTextChat.
  ///
  /// In zh, this message translates to:
  /// **'文本对话'**
  String get aiCapabilityTextChat;

  /// No description provided for @aiCapabilityTextChatDesc.
  ///
  /// In zh, this message translates to:
  /// **'用于AI对话和文本账单提取'**
  String get aiCapabilityTextChatDesc;

  /// No description provided for @aiCapabilityImageUnderstand.
  ///
  /// In zh, this message translates to:
  /// **'图片理解'**
  String get aiCapabilityImageUnderstand;

  /// No description provided for @aiCapabilityImageUnderstandDesc.
  ///
  /// In zh, this message translates to:
  /// **'用于图片账单识别'**
  String get aiCapabilityImageUnderstandDesc;

  /// No description provided for @aiCapabilitySpeechToText.
  ///
  /// In zh, this message translates to:
  /// **'语音转文字'**
  String get aiCapabilitySpeechToText;

  /// No description provided for @aiCapabilitySpeechToTextDesc.
  ///
  /// In zh, this message translates to:
  /// **'用于语音记账'**
  String get aiCapabilitySpeechToTextDesc;

  /// No description provided for @aiProviderTestRun.
  ///
  /// In zh, this message translates to:
  /// **'点击测试'**
  String get aiProviderTestRun;

  /// No description provided for @aiProviderTestRunning.
  ///
  /// In zh, this message translates to:
  /// **'测试中...'**
  String get aiProviderTestRunning;

  /// No description provided for @aiProviderTestSuccess.
  ///
  /// In zh, this message translates to:
  /// **'测试通过'**
  String get aiProviderTestSuccess;

  /// No description provided for @aiProviderTestFailed.
  ///
  /// In zh, this message translates to:
  /// **'测试失败'**
  String get aiProviderTestFailed;

  /// No description provided for @aiProviderTestAll.
  ///
  /// In zh, this message translates to:
  /// **'一键测试全部'**
  String get aiProviderTestAll;

  /// No description provided for @aiProviderTestAllRetry.
  ///
  /// In zh, this message translates to:
  /// **'重新测试'**
  String get aiProviderTestAllRetry;

  /// No description provided for @aiModelInputHelper.
  ///
  /// In zh, this message translates to:
  /// **'留空则使用默认模型'**
  String get aiModelInputHelper;

  /// No description provided for @syncPreviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'同步预览'**
  String get syncPreviewTitle;

  /// No description provided for @syncPreviewSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get syncPreviewSelectAll;

  /// No description provided for @syncPreviewDeselectAll.
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get syncPreviewDeselectAll;

  /// No description provided for @syncPreviewAdded.
  ///
  /// In zh, this message translates to:
  /// **'新增'**
  String get syncPreviewAdded;

  /// No description provided for @syncPreviewModified.
  ///
  /// In zh, this message translates to:
  /// **'修改'**
  String get syncPreviewModified;

  /// No description provided for @syncPreviewDeleted.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get syncPreviewDeleted;

  /// No description provided for @syncPreviewAddedCount.
  ///
  /// In zh, this message translates to:
  /// **'新增 {count} 条'**
  String syncPreviewAddedCount(int count);

  /// No description provided for @syncPreviewModifiedCount.
  ///
  /// In zh, this message translates to:
  /// **'修改 {count} 条'**
  String syncPreviewModifiedCount(int count);

  /// No description provided for @syncPreviewDeletedCount.
  ///
  /// In zh, this message translates to:
  /// **'删除 {count} 条'**
  String syncPreviewDeletedCount(int count);

  /// No description provided for @syncPreviewApply.
  ///
  /// In zh, this message translates to:
  /// **'应用 {count} 项'**
  String syncPreviewApply(int count);

  /// No description provided for @syncPreviewEmpty.
  ///
  /// In zh, this message translates to:
  /// **'云端数据与本地一致，无需同步'**
  String get syncPreviewEmpty;

  /// No description provided for @syncPreviewOldFormat.
  ///
  /// In zh, this message translates to:
  /// **'云端数据格式较旧，将执行全量替换'**
  String get syncPreviewOldFormat;

  /// No description provided for @syncPreviewOldFormatMessage.
  ///
  /// In zh, this message translates to:
  /// **'云端数据不包含同步标识，无法逐条对比。将清空当前账本数据并从云端重新导入。'**
  String get syncPreviewOldFormatMessage;

  /// No description provided for @syncPreviewApplied.
  ///
  /// In zh, this message translates to:
  /// **'已应用 {count} 项变更'**
  String syncPreviewApplied(int count);

  /// No description provided for @cloudSyncGuideTitle.
  ///
  /// In zh, this message translates to:
  /// **'云同步使用指南'**
  String get cloudSyncGuideTitle;

  /// No description provided for @cloudSyncGuideGotIt.
  ///
  /// In zh, this message translates to:
  /// **'我知道了'**
  String get cloudSyncGuideGotIt;

  /// No description provided for @cloudSyncGuideHowItWorks.
  ///
  /// In zh, this message translates to:
  /// **'工作原理'**
  String get cloudSyncGuideHowItWorks;

  /// No description provided for @cloudSyncGuideHowItem1.
  ///
  /// In zh, this message translates to:
  /// **'上传：将当前账本的全部数据打包上传到云端，覆盖云端旧数据'**
  String get cloudSyncGuideHowItem1;

  /// No description provided for @cloudSyncGuideHowItem2.
  ///
  /// In zh, this message translates to:
  /// **'下载：从云端拉取数据，与本地逐条对比差异，你可以选择要同步哪些变更'**
  String get cloudSyncGuideHowItem2;

  /// No description provided for @cloudSyncGuideHowItem3.
  ///
  /// In zh, this message translates to:
  /// **'云端始终只保存最后一次上传的完整快照，不保留历史版本'**
  String get cloudSyncGuideHowItem3;

  /// No description provided for @cloudSyncGuideCorrect.
  ///
  /// In zh, this message translates to:
  /// **'正确的使用方式'**
  String get cloudSyncGuideCorrect;

  /// No description provided for @cloudSyncGuideCorrectItem1.
  ///
  /// In zh, this message translates to:
  /// **'同一时间只在一台设备上记账，完成后上传'**
  String get cloudSyncGuideCorrectItem1;

  /// No description provided for @cloudSyncGuideCorrectItem2.
  ///
  /// In zh, this message translates to:
  /// **'切换设备前，先在新设备上下载同步'**
  String get cloudSyncGuideCorrectItem2;

  /// No description provided for @cloudSyncGuideCorrectItem3.
  ///
  /// In zh, this message translates to:
  /// **'下载时仔细查看预览，确认每条变更再应用'**
  String get cloudSyncGuideCorrectItem3;

  /// No description provided for @cloudSyncGuideCorrectItem4.
  ///
  /// In zh, this message translates to:
  /// **'养成「编辑→上传→切换设备→下载→编辑」的习惯'**
  String get cloudSyncGuideCorrectItem4;

  /// No description provided for @cloudSyncGuideWrong.
  ///
  /// In zh, this message translates to:
  /// **'应避免的用法'**
  String get cloudSyncGuideWrong;

  /// No description provided for @cloudSyncGuideWrongItem1.
  ///
  /// In zh, this message translates to:
  /// **'两台设备同时编辑同一个账本，后上传的会覆盖先上传的改动'**
  String get cloudSyncGuideWrongItem1;

  /// No description provided for @cloudSyncGuideWrongItem2.
  ///
  /// In zh, this message translates to:
  /// **'上传后立刻在另一台设备下载，文件服务可能有几秒到几分钟的同步延迟，等一会再试'**
  String get cloudSyncGuideWrongItem2;

  /// No description provided for @cloudSyncGuideWrongItem3.
  ///
  /// In zh, this message translates to:
  /// **'长时间不同步后一次性下载大量变更，容易遗漏需要处理的差异'**
  String get cloudSyncGuideWrongItem3;

  /// No description provided for @cloudSyncGuideLimitations.
  ///
  /// In zh, this message translates to:
  /// **'已知限制'**
  String get cloudSyncGuideLimitations;

  /// No description provided for @cloudSyncGuideLimitItem1.
  ///
  /// In zh, this message translates to:
  /// **'非实时同步：需要手动点击上传和下载'**
  String get cloudSyncGuideLimitItem1;

  /// No description provided for @cloudSyncGuideLimitItem2.
  ///
  /// In zh, this message translates to:
  /// **'无冲突合并：不会自动合并两端的修改，以最后上传的为准'**
  String get cloudSyncGuideLimitItem2;

  /// No description provided for @cloudSyncGuideLimitItem3.
  ///
  /// In zh, this message translates to:
  /// **'文件服务延迟：上传后云端文件可能需要几秒到几分钟才能被其他设备读取，取决于你使用的云服务'**
  String get cloudSyncGuideLimitItem3;

  /// No description provided for @cloudSyncGuideLimitItem4.
  ///
  /// In zh, this message translates to:
  /// **'不含附件：交易的图片附件不参与同步，需通过数据管理单独导出'**
  String get cloudSyncGuideLimitItem4;

  /// No description provided for @mineMultiDeviceSyncTitle.
  ///
  /// In zh, this message translates to:
  /// **'多设备同步'**
  String get mineMultiDeviceSyncTitle;

  /// No description provided for @mineMultiDeviceSyncSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'进入页面时自动检查云端变更'**
  String get mineMultiDeviceSyncSubtitle;

  /// No description provided for @appLockTitle.
  ///
  /// In zh, this message translates to:
  /// **'应用锁'**
  String get appLockTitle;

  /// No description provided for @appLockDesc.
  ///
  /// In zh, this message translates to:
  /// **'PIN码与生物识别保护隐私'**
  String get appLockDesc;

  /// No description provided for @appLockEnable.
  ///
  /// In zh, this message translates to:
  /// **'启用应用锁'**
  String get appLockEnable;

  /// No description provided for @appLockEnableDesc.
  ///
  /// In zh, this message translates to:
  /// **'启动和切回应用时需要验证身份'**
  String get appLockEnableDesc;

  /// No description provided for @appLockSetPin.
  ///
  /// In zh, this message translates to:
  /// **'设置密码'**
  String get appLockSetPin;

  /// No description provided for @appLockChangePin.
  ///
  /// In zh, this message translates to:
  /// **'修改密码'**
  String get appLockChangePin;

  /// No description provided for @appLockVerifyPin.
  ///
  /// In zh, this message translates to:
  /// **'验证密码'**
  String get appLockVerifyPin;

  /// No description provided for @appLockVerifyCurrentPin.
  ///
  /// In zh, this message translates to:
  /// **'请输入当前密码'**
  String get appLockVerifyCurrentPin;

  /// No description provided for @appLockSetNewPin.
  ///
  /// In zh, this message translates to:
  /// **'请设置新密码'**
  String get appLockSetNewPin;

  /// No description provided for @appLockConfirmPin.
  ///
  /// In zh, this message translates to:
  /// **'请再次输入密码'**
  String get appLockConfirmPin;

  /// No description provided for @appLockEnterPin.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码'**
  String get appLockEnterPin;

  /// No description provided for @appLockPinSetSuccess.
  ///
  /// In zh, this message translates to:
  /// **'密码设置成功'**
  String get appLockPinSetSuccess;

  /// No description provided for @appLockDisabled.
  ///
  /// In zh, this message translates to:
  /// **'应用锁已关闭'**
  String get appLockDisabled;

  /// No description provided for @appLockBiometric.
  ///
  /// In zh, this message translates to:
  /// **'生物识别解锁'**
  String get appLockBiometric;

  /// No description provided for @appLockBiometricDesc.
  ///
  /// In zh, this message translates to:
  /// **'使用Face ID或指纹快速解锁'**
  String get appLockBiometricDesc;

  /// No description provided for @appLockBiometricReason.
  ///
  /// In zh, this message translates to:
  /// **'请验证身份以解锁智记'**
  String get appLockBiometricReason;

  /// No description provided for @appLockTimeout.
  ///
  /// In zh, this message translates to:
  /// **'自动锁定时间'**
  String get appLockTimeout;

  /// No description provided for @appLockTimeoutImmediate.
  ///
  /// In zh, this message translates to:
  /// **'立即'**
  String get appLockTimeoutImmediate;

  /// No description provided for @appLockTimeout1Min.
  ///
  /// In zh, this message translates to:
  /// **'1分钟后'**
  String get appLockTimeout1Min;

  /// No description provided for @appLockTimeout5Min.
  ///
  /// In zh, this message translates to:
  /// **'5分钟后'**
  String get appLockTimeout5Min;

  /// No description provided for @appLockTimeout15Min.
  ///
  /// In zh, this message translates to:
  /// **'15分钟后'**
  String get appLockTimeout15Min;

  /// No description provided for @creditCardSettings.
  ///
  /// In zh, this message translates to:
  /// **'信用卡设置'**
  String get creditCardSettings;

  /// No description provided for @accountTabValuation.
  ///
  /// In zh, this message translates to:
  /// **'估值账户'**
  String get accountTabValuation;

  /// No description provided for @creditCardDaysRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择账单日和还款日'**
  String get creditCardDaysRequired;

  /// No description provided for @creditLimit.
  ///
  /// In zh, this message translates to:
  /// **'信用额度'**
  String get creditLimit;

  /// No description provided for @creditLimitHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入信用额度'**
  String get creditLimitHint;

  /// No description provided for @billingDay.
  ///
  /// In zh, this message translates to:
  /// **'账单日'**
  String get billingDay;

  /// No description provided for @paymentDueDay.
  ///
  /// In zh, this message translates to:
  /// **'还款日'**
  String get paymentDueDay;

  /// No description provided for @creditUsed.
  ///
  /// In zh, this message translates to:
  /// **'已用额度'**
  String get creditUsed;

  /// No description provided for @creditAvailable.
  ///
  /// In zh, this message translates to:
  /// **'可用额度'**
  String get creditAvailable;

  /// No description provided for @creditCardOwed.
  ///
  /// In zh, this message translates to:
  /// **'待还款'**
  String get creditCardOwed;

  /// No description provided for @dayOfMonth.
  ///
  /// In zh, this message translates to:
  /// **'每月{day}日'**
  String dayOfMonth(int day);

  /// No description provided for @creditCardReminderTitle.
  ///
  /// In zh, this message translates to:
  /// **'还款提醒'**
  String get creditCardReminderTitle;

  /// No description provided for @creditCardReminderDesc.
  ///
  /// In zh, this message translates to:
  /// **'在还款日前提醒还款'**
  String get creditCardReminderDesc;

  /// No description provided for @creditCardReminderDaysBefore.
  ///
  /// In zh, this message translates to:
  /// **'提前{days}天提醒'**
  String creditCardReminderDaysBefore(int days);

  /// No description provided for @creditCardInitialBalanceHint.
  ///
  /// In zh, this message translates to:
  /// **'当前欠款（填负数）'**
  String get creditCardInitialBalanceHint;

  /// No description provided for @selectDay.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get selectDay;

  /// No description provided for @accountBankName.
  ///
  /// In zh, this message translates to:
  /// **'开户行'**
  String get accountBankName;

  /// No description provided for @accountBankNameHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：工商银行'**
  String get accountBankNameHint;

  /// No description provided for @accountCardLastFour.
  ///
  /// In zh, this message translates to:
  /// **'卡号后四位'**
  String get accountCardLastFour;

  /// No description provided for @accountCardLastFourHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：1234'**
  String get accountCardLastFourHint;

  /// No description provided for @accountNote.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get accountNote;

  /// No description provided for @accountNoteHint.
  ///
  /// In zh, this message translates to:
  /// **'添加备注信息'**
  String get accountNoteHint;

  /// No description provided for @accountMetaInfo.
  ///
  /// In zh, this message translates to:
  /// **'账户信息'**
  String get accountMetaInfo;

  /// No description provided for @accountBalanceTrend.
  ///
  /// In zh, this message translates to:
  /// **'余额趋势'**
  String get accountBalanceTrend;

  /// No description provided for @accountCategoryBreakdown.
  ///
  /// In zh, this message translates to:
  /// **'分类统计'**
  String get accountCategoryBreakdown;

  /// No description provided for @accountCategoryExpense.
  ///
  /// In zh, this message translates to:
  /// **'支出'**
  String get accountCategoryExpense;

  /// No description provided for @accountCategoryIncome.
  ///
  /// In zh, this message translates to:
  /// **'收入'**
  String get accountCategoryIncome;

  /// No description provided for @accountNoMoreData.
  ///
  /// In zh, this message translates to:
  /// **'没有更多数据了'**
  String get accountNoMoreData;

  /// No description provided for @totalAssets.
  ///
  /// In zh, this message translates to:
  /// **'总资产'**
  String get totalAssets;

  /// No description provided for @totalLiabilities.
  ///
  /// In zh, this message translates to:
  /// **'总负债'**
  String get totalLiabilities;

  /// No description provided for @assetAccounts.
  ///
  /// In zh, this message translates to:
  /// **'资产账户'**
  String get assetAccounts;

  /// No description provided for @liabilityAccounts.
  ///
  /// In zh, this message translates to:
  /// **'负债账户'**
  String get liabilityAccounts;

  /// No description provided for @assetComposition.
  ///
  /// In zh, this message translates to:
  /// **'资产构成'**
  String get assetComposition;

  /// No description provided for @accountTypeInvestment.
  ///
  /// In zh, this message translates to:
  /// **'投资理财'**
  String get accountTypeInvestment;

  /// No description provided for @accountTypeLoan.
  ///
  /// In zh, this message translates to:
  /// **'贷款'**
  String get accountTypeLoan;

  /// No description provided for @accountTypeReceivable.
  ///
  /// In zh, this message translates to:
  /// **'应收款'**
  String get accountTypeReceivable;

  /// No description provided for @accountTypeRealEstate.
  ///
  /// In zh, this message translates to:
  /// **'不动产'**
  String get accountTypeRealEstate;

  /// No description provided for @accountTypeVehicle.
  ///
  /// In zh, this message translates to:
  /// **'车辆'**
  String get accountTypeVehicle;

  /// No description provided for @accountTypeInsurance.
  ///
  /// In zh, this message translates to:
  /// **'保险'**
  String get accountTypeInsurance;

  /// No description provided for @accountTypeSocialFund.
  ///
  /// In zh, this message translates to:
  /// **'公积金/社保'**
  String get accountTypeSocialFund;

  /// No description provided for @valuationCurrentValue.
  ///
  /// In zh, this message translates to:
  /// **'当前估值'**
  String get valuationCurrentValue;

  /// No description provided for @valuationCurrentDebt.
  ///
  /// In zh, this message translates to:
  /// **'当前欠款'**
  String get valuationCurrentDebt;

  /// No description provided for @valuationUpdateValue.
  ///
  /// In zh, this message translates to:
  /// **'更新估值'**
  String get valuationUpdateValue;

  /// No description provided for @valuationUpdateDebt.
  ///
  /// In zh, this message translates to:
  /// **'更新欠款'**
  String get valuationUpdateDebt;

  /// No description provided for @valuationLastUpdated.
  ///
  /// In zh, this message translates to:
  /// **'上次更新: {date}'**
  String valuationLastUpdated(String date);

  /// No description provided for @valuationAccountHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入当前估值'**
  String get valuationAccountHint;

  /// No description provided for @valuationDebtHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入当前欠款金额'**
  String get valuationDebtHint;

  /// No description provided for @accountGroupTradable.
  ///
  /// In zh, this message translates to:
  /// **'日常账户'**
  String get accountGroupTradable;

  /// No description provided for @accountGroupValuation.
  ///
  /// In zh, this message translates to:
  /// **'资产/负债'**
  String get accountGroupValuation;

  /// No description provided for @adjustmentTransaction.
  ///
  /// In zh, this message translates to:
  /// **'估值调整'**
  String get adjustmentTransaction;

  /// No description provided for @creditCardBillingInfo.
  ///
  /// In zh, this message translates to:
  /// **'每月{billingDay}日出账 · {paymentDueDay}日还款'**
  String creditCardBillingInfo(int billingDay, int paymentDueDay);

  /// No description provided for @creditCardDaysUntilPayment.
  ///
  /// In zh, this message translates to:
  /// **'距还款日还有{days}天'**
  String creditCardDaysUntilPayment(int days);

  /// No description provided for @creditCardPaymentDueToday.
  ///
  /// In zh, this message translates to:
  /// **'今天是还款日'**
  String get creditCardPaymentDueToday;

  /// No description provided for @creditCardQuickRepay.
  ///
  /// In zh, this message translates to:
  /// **'记一笔还款'**
  String get creditCardQuickRepay;

  /// No description provided for @budgetManagement.
  ///
  /// In zh, this message translates to:
  /// **'预算管理'**
  String get budgetManagement;

  /// No description provided for @budgetManagementDesc.
  ///
  /// In zh, this message translates to:
  /// **'设置月度预算，控制支出'**
  String get budgetManagementDesc;

  /// No description provided for @budgetSetupHint.
  ///
  /// In zh, this message translates to:
  /// **'设置预算，轻松掌控每月开支'**
  String get budgetSetupHint;

  /// No description provided for @budgetSetupAction.
  ///
  /// In zh, this message translates to:
  /// **'去设置'**
  String get budgetSetupAction;

  /// No description provided for @cloudCollabDevicesPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'设备会话'**
  String get cloudCollabDevicesPageTitle;

  /// No description provided for @cloudCollabDevicesPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'管理当前账号活跃设备'**
  String get cloudCollabDevicesPageSubtitle;

  /// No description provided for @cloudCollabDevicesViewAllSessions.
  ///
  /// In zh, this message translates to:
  /// **'显示全部会话'**
  String get cloudCollabDevicesViewAllSessions;

  /// No description provided for @cloudCollabDevicesViewModeHint.
  ///
  /// In zh, this message translates to:
  /// **'默认展示近 30 天去重设备，可切换查看全部会话。'**
  String get cloudCollabDevicesViewModeHint;

  /// No description provided for @cloudCollabNoDevices.
  ///
  /// In zh, this message translates to:
  /// **'当前没有活跃设备'**
  String get cloudCollabNoDevices;

  /// No description provided for @cloudCollabUnknownDeviceName.
  ///
  /// In zh, this message translates to:
  /// **'未知设备'**
  String get cloudCollabUnknownDeviceName;

  /// No description provided for @cloudCollabDeviceCurrentTag.
  ///
  /// In zh, this message translates to:
  /// **'当前设备'**
  String get cloudCollabDeviceCurrentTag;

  /// No description provided for @cloudCollabCurrentDeviceCannotRevoke.
  ///
  /// In zh, this message translates to:
  /// **'当前设备不能远程下线。'**
  String get cloudCollabCurrentDeviceCannotRevoke;

  /// No description provided for @cloudCollabDeviceAppVersion.
  ///
  /// In zh, this message translates to:
  /// **'应用：{version}'**
  String cloudCollabDeviceAppVersion(String version);

  /// No description provided for @cloudCollabDeviceOsVersion.
  ///
  /// In zh, this message translates to:
  /// **'系统：{version}'**
  String cloudCollabDeviceOsVersion(String version);

  /// No description provided for @cloudCollabDeviceModel.
  ///
  /// In zh, this message translates to:
  /// **'型号：{model}'**
  String cloudCollabDeviceModel(String model);

  /// No description provided for @cloudCollabDeviceLastIp.
  ///
  /// In zh, this message translates to:
  /// **'IP：{ip}'**
  String cloudCollabDeviceLastIp(String ip);

  /// No description provided for @cloudCollabDeviceSessionCount.
  ///
  /// In zh, this message translates to:
  /// **'会话数：{count}'**
  String cloudCollabDeviceSessionCount(String count);

  /// No description provided for @cloudCollabDeviceLastSeen.
  ///
  /// In zh, this message translates to:
  /// **'最近活跃：{time}'**
  String cloudCollabDeviceLastSeen(String time);

  /// No description provided for @cloudCollabDeviceCreatedAt.
  ///
  /// In zh, this message translates to:
  /// **'创建时间：{time}'**
  String cloudCollabDeviceCreatedAt(String time);

  /// No description provided for @cloudCollabDeviceRevokeTitle.
  ///
  /// In zh, this message translates to:
  /// **'远程下线设备'**
  String get cloudCollabDeviceRevokeTitle;

  /// No description provided for @cloudCollabDeviceRevokeMessage.
  ///
  /// In zh, this message translates to:
  /// **'确认下线设备 {name}（{id}）吗？'**
  String cloudCollabDeviceRevokeMessage(String name, String id);

  /// No description provided for @cloudCollabDeviceRevokeMultipleMessage.
  ///
  /// In zh, this message translates to:
  /// **'确认下线设备 {name} 的 {count} 个会话吗？'**
  String cloudCollabDeviceRevokeMultipleMessage(String name, String count);

  /// No description provided for @cloudCollabDeviceRevoked.
  ///
  /// In zh, this message translates to:
  /// **'设备已下线'**
  String get cloudCollabDeviceRevoked;

  /// No description provided for @cloudCollabUnavailableMessage.
  ///
  /// In zh, this message translates to:
  /// **'云同步功能暂不可用。'**
  String get cloudCollabUnavailableMessage;

  /// No description provided for @cloudCollabScopeDeniedHint.
  ///
  /// In zh, this message translates to:
  /// **'服务端尚未开启 ALLOW_APP_RW_SCOPES，当前设备会话不可用。'**
  String get cloudCollabScopeDeniedHint;

  /// No description provided for @cloudCollabScopeDeniedAction.
  ///
  /// In zh, this message translates to:
  /// **'请在服务端 .env 或部署环境中设置 ALLOW_APP_RW_SCOPES=true，重启服务后重新登录 App。'**
  String get cloudCollabScopeDeniedAction;

  /// No description provided for @syncHealthTitle.
  ///
  /// In zh, this message translates to:
  /// **'同步状态'**
  String get syncHealthTitle;

  /// No description provided for @cloudSyncHelpTitle.
  ///
  /// In zh, this message translates to:
  /// **'同步说明 · 为什么有时同步不动？'**
  String get cloudSyncHelpTitle;

  /// No description provided for @cloudSyncHelpModesTitle.
  ///
  /// In zh, this message translates to:
  /// **'三种同步方式'**
  String get cloudSyncHelpModesTitle;

  /// No description provided for @cloudSyncHelpModesBody.
  ///
  /// In zh, this message translates to:
  /// **'• 增量同步（日常自动）：记一笔 / 改一笔后，只把这条变化自动上传下载，快、无需手动操作 —— 平时一直在跑的就是它。\n• 全量上传：首次开启云同步、或云端还没有这个账本的数据时，把本地全部数据一次性推上云。\n• 全量下载：换新设备、重装、或本地为空时，从云端把全部数据拉下来。'**
  String get cloudSyncHelpModesBody;

  /// No description provided for @cloudSyncHelpWhenFullTitle.
  ///
  /// In zh, this message translates to:
  /// **'什么时候才会走全量？'**
  String get cloudSyncHelpWhenFullTitle;

  /// No description provided for @cloudSyncHelpWhenFullBody.
  ///
  /// In zh, this message translates to:
  /// **'全量只在某一端数据为空时才会自动触发（首次开启云同步 / 换新设备 / 重装 / 清空了本地或云端数据）。只要两端都有数据，之后一直走增量，不会无故重来。想强制重新全量同步，得先清空对应端的数据。'**
  String get cloudSyncHelpWhenFullBody;

  /// No description provided for @cloudSyncHelpStuckTitle.
  ///
  /// In zh, this message translates to:
  /// **'为什么有时同步不动 / 卡住'**
  String get cloudSyncHelpStuckTitle;

  /// No description provided for @cloudSyncHelpStuckBody.
  ///
  /// In zh, this message translates to:
  /// **'• 全量上传 / 下载不支持断点续传：中途断网、或 App 被切到后台被系统杀掉，会从头重来，不会接着传。数据多时请用稳定网络（建议 Wi-Fi）耐心等它跑完，别中途切走。\n• 增量同步是断点安全的，日常同步不受影响。'**
  String get cloudSyncHelpStuckBody;

  /// No description provided for @cloudSyncHelpTroubleshootTitle.
  ///
  /// In zh, this message translates to:
  /// **'排查办法'**
  String get cloudSyncHelpTroubleshootTitle;

  /// No description provided for @cloudSyncHelpTroubleshootBody.
  ///
  /// In zh, this message translates to:
  /// **'• 先在本页下拉做一次「深度检测」，对比本地与云端差异。\n• 仍有问题，去「日志中心」查看同步日志（含失败原因），方便反馈。'**
  String get cloudSyncHelpTroubleshootBody;

  /// No description provided for @cloudSyncHelpOpenLogCenter.
  ///
  /// In zh, this message translates to:
  /// **'打开日志中心'**
  String get cloudSyncHelpOpenLogCenter;

  /// No description provided for @syncHealthCheckFailed.
  ///
  /// In zh, this message translates to:
  /// **'检测失败：{msg}'**
  String syncHealthCheckFailed(String msg);

  /// No description provided for @syncHealthHasDiff.
  ///
  /// In zh, this message translates to:
  /// **'检测到差异，已自动同步'**
  String get syncHealthHasDiff;

  /// No description provided for @syncHealthInSync.
  ///
  /// In zh, this message translates to:
  /// **'本地与云端一致'**
  String get syncHealthInSync;

  /// No description provided for @syncHealthGroupCurrentLedger.
  ///
  /// In zh, this message translates to:
  /// **'当前账本'**
  String get syncHealthGroupCurrentLedger;

  /// No description provided for @syncHealthGroupAll.
  ///
  /// In zh, this message translates to:
  /// **'全部账本'**
  String get syncHealthGroupAll;

  /// No description provided for @syncHealthRowTx.
  ///
  /// In zh, this message translates to:
  /// **'交易'**
  String get syncHealthRowTx;

  /// No description provided for @syncHealthRowAttachment.
  ///
  /// In zh, this message translates to:
  /// **'附件'**
  String get syncHealthRowAttachment;

  /// No description provided for @syncHealthRowCategoryIcon.
  ///
  /// In zh, this message translates to:
  /// **'分类图标'**
  String get syncHealthRowCategoryIcon;

  /// No description provided for @syncHealthRowBudget.
  ///
  /// In zh, this message translates to:
  /// **'预算'**
  String get syncHealthRowBudget;

  /// No description provided for @syncHealthRowAccount.
  ///
  /// In zh, this message translates to:
  /// **'账户'**
  String get syncHealthRowAccount;

  /// No description provided for @syncHealthRowCategory.
  ///
  /// In zh, this message translates to:
  /// **'分类'**
  String get syncHealthRowCategory;

  /// No description provided for @syncHealthRowTag.
  ///
  /// In zh, this message translates to:
  /// **'标签'**
  String get syncHealthRowTag;

  /// No description provided for @syncHealthRowUnpushed.
  ///
  /// In zh, this message translates to:
  /// **'未推送变更'**
  String get syncHealthRowUnpushed;

  /// No description provided for @syncHealthValue.
  ///
  /// In zh, this message translates to:
  /// **'本地 {local} · 云端 {remote}'**
  String syncHealthValue(int local, int remote);

  /// No description provided for @syncHealthValueRemoteMissing.
  ///
  /// In zh, this message translates to:
  /// **'本地 {local} · 云端 —'**
  String syncHealthValueRemoteMissing(int local);

  /// No description provided for @syncForceRestoreTitle.
  ///
  /// In zh, this message translates to:
  /// **'以服务端为准'**
  String get syncForceRestoreTitle;

  /// No description provided for @syncForceRestoreConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'以服务端为准恢复？'**
  String get syncForceRestoreConfirmTitle;

  /// No description provided for @syncForceRestoreConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'将清空当前账本的本地交易与预算，并用服务端数据覆盖账户、分类与标签（本地多出的条目会被删除，且影响所有账本共用的数据）。此操作不可撤销。'**
  String get syncForceRestoreConfirmBody;

  /// No description provided for @syncForceRestoreSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已按服务端恢复：交易 {tx} 笔、预算 {budget} 笔、账户 {accounts} 个、分类 {categories} 个、标签 {tags} 个'**
  String syncForceRestoreSuccess(int tx, int budget, int accounts, int categories, int tags);

  /// No description provided for @syncForceRestoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'恢复失败'**
  String get syncForceRestoreFailed;

  /// No description provided for @sharedRoleOwner.
  ///
  /// In zh, this message translates to:
  /// **'所有者'**
  String get sharedRoleOwner;

  /// No description provided for @sharedRoleEditor.
  ///
  /// In zh, this message translates to:
  /// **'编辑者'**
  String get sharedRoleEditor;

  /// No description provided for @sharedRoleViewer.
  ///
  /// In zh, this message translates to:
  /// **'查看者'**
  String get sharedRoleViewer;

  /// No description provided for @commonCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制'**
  String get commonCopied;

  /// No description provided for @commonRemove.
  ///
  /// In zh, this message translates to:
  /// **'移除'**
  String get commonRemove;

  /// No description provided for @sharedJoinPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'加入共享账本'**
  String get sharedJoinPageTitle;

  /// No description provided for @sharedJoinPageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'输入邀请码或点击对方分享的链接'**
  String get sharedJoinPageSubtitle;

  /// No description provided for @sharedJoinEnterCode.
  ///
  /// In zh, this message translates to:
  /// **'输入邀请码'**
  String get sharedJoinEnterCode;

  /// No description provided for @sharedJoinEnterCodeHint.
  ///
  /// In zh, this message translates to:
  /// **'邀请码 6 位,全大写字母数字。也可直接点击邀请方分享的短链跳过此步。'**
  String get sharedJoinEnterCodeHint;

  /// No description provided for @sharedJoinPreviewButton.
  ///
  /// In zh, this message translates to:
  /// **'验证邀请码'**
  String get sharedJoinPreviewButton;

  /// No description provided for @sharedJoinAcceptButton.
  ///
  /// In zh, this message translates to:
  /// **'加入账本'**
  String get sharedJoinAcceptButton;

  /// No description provided for @sharedJoinInvitedBy.
  ///
  /// In zh, this message translates to:
  /// **'{name} 邀请你加入'**
  String sharedJoinInvitedBy(String name);

  /// No description provided for @sharedJoinRoleLine.
  ///
  /// In zh, this message translates to:
  /// **'角色:{role}'**
  String sharedJoinRoleLine(String role);

  /// No description provided for @sharedJoinExpiresInMinutes.
  ///
  /// In zh, this message translates to:
  /// **'有效期还剩 {n} 分钟'**
  String sharedJoinExpiresInMinutes(int n);

  /// No description provided for @sharedJoinExpiresInHours.
  ///
  /// In zh, this message translates to:
  /// **'有效期还剩 {n} 小时'**
  String sharedJoinExpiresInHours(int n);

  /// No description provided for @sharedJoinExpiresInDays.
  ///
  /// In zh, this message translates to:
  /// **'有效期还剩 {n} 天'**
  String sharedJoinExpiresInDays(int n);

  /// No description provided for @sharedJoinSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已加入「{name}」'**
  String sharedJoinSuccess(String name);

  /// No description provided for @sharedJoinCodeFormatError.
  ///
  /// In zh, this message translates to:
  /// **'邀请码格式不对,请输入 6 位字母数字'**
  String get sharedJoinCodeFormatError;

  /// No description provided for @sharedJoinInvalidOrExpired.
  ///
  /// In zh, this message translates to:
  /// **'邀请码无效或已过期,请向邀请人索取新码'**
  String get sharedJoinInvalidOrExpired;

  /// No description provided for @sharedJoinAlreadyMember.
  ///
  /// In zh, this message translates to:
  /// **'你已经是该账本成员'**
  String get sharedJoinAlreadyMember;

  /// No description provided for @sharedJoinMemberLimit.
  ///
  /// In zh, this message translates to:
  /// **'该账本成员已满,请联系账本所有者'**
  String get sharedJoinMemberLimit;

  /// No description provided for @sharedInvitePageTitle.
  ///
  /// In zh, this message translates to:
  /// **'邀请新成员'**
  String get sharedInvitePageTitle;

  /// No description provided for @sharedInviteFormRole.
  ///
  /// In zh, this message translates to:
  /// **'角色'**
  String get sharedInviteFormRole;

  /// No description provided for @sharedInviteFormExpiry.
  ///
  /// In zh, this message translates to:
  /// **'有效期'**
  String get sharedInviteFormExpiry;

  /// No description provided for @sharedInviteExpiryHours.
  ///
  /// In zh, this message translates to:
  /// **'{n} 小时'**
  String sharedInviteExpiryHours(int n);

  /// No description provided for @sharedInviteExpiryDays.
  ///
  /// In zh, this message translates to:
  /// **'{n} 天'**
  String sharedInviteExpiryDays(int n);

  /// No description provided for @sharedInviteGenerate.
  ///
  /// In zh, this message translates to:
  /// **'生成邀请码'**
  String get sharedInviteGenerate;

  /// No description provided for @sharedInviteGenerateAnother.
  ///
  /// In zh, this message translates to:
  /// **'生成另一个邀请码'**
  String get sharedInviteGenerateAnother;

  /// No description provided for @sharedInviteCopyCode.
  ///
  /// In zh, this message translates to:
  /// **'复制邀请码'**
  String get sharedInviteCopyCode;

  /// No description provided for @sharedInviteCopyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get sharedInviteCopyLink;

  /// No description provided for @sharedInviteShareLink.
  ///
  /// In zh, this message translates to:
  /// **'分享给好友'**
  String get sharedInviteShareLink;

  /// No description provided for @sharedInviteExpiresAt.
  ///
  /// In zh, this message translates to:
  /// **'邀请将在 {dt} 失效'**
  String sharedInviteExpiresAt(String dt);

  /// No description provided for @sharedInviteWarning.
  ///
  /// In zh, this message translates to:
  /// **'⚠️ 不要把邀请码发到公开群 / 朋友圈。拿到码的任何人都可加入账本;泄露后请到成员管理页撤销并重新生成。'**
  String get sharedInviteWarning;

  /// No description provided for @sharedInviteInstruction.
  ///
  /// In zh, this message translates to:
  /// **'把邀请码或短链发给对方。对方装上智记 后,点击链接或在「我的 → 加入共享账本」输入码即可加入。'**
  String get sharedInviteInstruction;

  /// No description provided for @sharedInviteShareText.
  ///
  /// In zh, this message translates to:
  /// **'邀请你加入智记 共享账本「{ledger}」\n\n邀请码:{code}\n链接:{url}\n\n点击链接或在智记 → 我的 → 加入共享账本输入此码即可。'**
  String sharedInviteShareText(String ledger, String code, String url);

  /// No description provided for @sharedMembersPageTitle.
  ///
  /// In zh, this message translates to:
  /// **'成员管理'**
  String get sharedMembersPageTitle;

  /// No description provided for @sharedMembersYou.
  ///
  /// In zh, this message translates to:
  /// **'你'**
  String get sharedMembersYou;

  /// No description provided for @sharedMembersInviteCta.
  ///
  /// In zh, this message translates to:
  /// **'邀请新成员'**
  String get sharedMembersInviteCta;

  /// No description provided for @sharedMembersLeaveCta.
  ///
  /// In zh, this message translates to:
  /// **'退出账本'**
  String get sharedMembersLeaveCta;

  /// No description provided for @sharedMembersLeaveTitle.
  ///
  /// In zh, this message translates to:
  /// **'退出账本'**
  String get sharedMembersLeaveTitle;

  /// No description provided for @sharedMembersLeaveConfirm.
  ///
  /// In zh, this message translates to:
  /// **'退出「{name}」后将无法再访问其中的交易。确定继续吗?'**
  String sharedMembersLeaveConfirm(String name);

  /// No description provided for @sharedMembersLeaveDone.
  ///
  /// In zh, this message translates to:
  /// **'已退出账本'**
  String get sharedMembersLeaveDone;

  /// No description provided for @sharedMembersRemoveTitle.
  ///
  /// In zh, this message translates to:
  /// **'移除成员'**
  String get sharedMembersRemoveTitle;

  /// No description provided for @sharedMembersRemoveCta.
  ///
  /// In zh, this message translates to:
  /// **'移除该成员'**
  String get sharedMembersRemoveCta;

  /// No description provided for @sharedMembersRemoveConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定移除 {name}?ta 将立即失去对该账本的访问。'**
  String sharedMembersRemoveConfirm(String name);

  /// No description provided for @sharedMembersRemoved.
  ///
  /// In zh, this message translates to:
  /// **'已移除成员'**
  String get sharedMembersRemoved;

  /// No description provided for @sharedMembersTransferTitle.
  ///
  /// In zh, this message translates to:
  /// **'转让所有权'**
  String get sharedMembersTransferTitle;

  /// No description provided for @sharedMembersTransferTo.
  ///
  /// In zh, this message translates to:
  /// **'转让给该成员'**
  String get sharedMembersTransferTo;

  /// No description provided for @sharedMembersTransferConfirm.
  ///
  /// In zh, this message translates to:
  /// **'把账本所有权转给 {name}?你将变为编辑者,无法再邀请人 / 改账本名 / 删账本。'**
  String sharedMembersTransferConfirm(String name);

  /// No description provided for @sharedMembersTransferConfirmCta.
  ///
  /// In zh, this message translates to:
  /// **'确认转让'**
  String get sharedMembersTransferConfirmCta;

  /// No description provided for @sharedMembersTransferDone.
  ///
  /// In zh, this message translates to:
  /// **'已转让所有权'**
  String get sharedMembersTransferDone;

  /// No description provided for @sharedTxRecordedBy.
  ///
  /// In zh, this message translates to:
  /// **'{name} 记的'**
  String sharedTxRecordedBy(String name);

  /// No description provided for @sharedTxCreatedBy.
  ///
  /// In zh, this message translates to:
  /// **'{name} 创建'**
  String sharedTxCreatedBy(String name);

  /// No description provided for @sharedTxEditedBy.
  ///
  /// In zh, this message translates to:
  /// **'{name} 最后编辑'**
  String sharedTxEditedBy(String name);

  /// No description provided for @sharedTxCreatedAndEditedBy.
  ///
  /// In zh, this message translates to:
  /// **'{name} 创建并编辑'**
  String sharedTxCreatedAndEditedBy(String name);

  /// No description provided for @sharedRequiresCloudSync.
  ///
  /// In zh, this message translates to:
  /// **'请先启用云同步'**
  String get sharedRequiresCloudSync;

  /// No description provided for @sharedMembersStatsTitle.
  ///
  /// In zh, this message translates to:
  /// **'成员收支'**
  String get sharedMembersStatsTitle;

  /// No description provided for @sharedMembersStatsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'本期暂无记账'**
  String get sharedMembersStatsEmpty;

  /// No description provided for @sharedMembersStatsLoading.
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get sharedMembersStatsLoading;

  /// No description provided for @sharedMembersStatsIncome.
  ///
  /// In zh, this message translates to:
  /// **'总收入'**
  String get sharedMembersStatsIncome;

  /// No description provided for @sharedMembersStatsExpense.
  ///
  /// In zh, this message translates to:
  /// **'总支出'**
  String get sharedMembersStatsExpense;

  /// No description provided for @sharedMembersStatsTxCount.
  ///
  /// In zh, this message translates to:
  /// **'{count}笔'**
  String sharedMembersStatsTxCount(int count);

  /// No description provided for @maintenanceOrphanCleanupTitle.
  ///
  /// In zh, this message translates to:
  /// **'数据清理'**
  String get maintenanceOrphanCleanupTitle;

  /// No description provided for @maintenanceOrphanCleanupSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'检查并清理本地孤儿数据'**
  String get maintenanceOrphanCleanupSubtitle;

  /// No description provided for @maintenanceOrphanRescan.
  ///
  /// In zh, this message translates to:
  /// **'重新扫描'**
  String get maintenanceOrphanRescan;

  /// No description provided for @maintenanceOrphanEmpty.
  ///
  /// In zh, this message translates to:
  /// **'本地数据干净,未发现孤儿数据'**
  String get maintenanceOrphanEmpty;

  /// No description provided for @maintenanceOrphanGroupDb.
  ///
  /// In zh, this message translates to:
  /// **'数据库孤儿'**
  String get maintenanceOrphanGroupDb;

  /// No description provided for @maintenanceOrphanGroupFile.
  ///
  /// In zh, this message translates to:
  /// **'磁盘文件孤儿'**
  String get maintenanceOrphanGroupFile;

  /// No description provided for @maintenanceOrphanGroupSync.
  ///
  /// In zh, this message translates to:
  /// **'同步状态孤儿'**
  String get maintenanceOrphanGroupSync;

  /// No description provided for @maintenanceOrphanSummary.
  ///
  /// In zh, this message translates to:
  /// **'发现 {count} 项异常'**
  String maintenanceOrphanSummary(int count);

  /// No description provided for @maintenanceOrphanSummarySize.
  ///
  /// In zh, this message translates to:
  /// **'可释放空间约 {size}'**
  String maintenanceOrphanSummarySize(String size);

  /// No description provided for @maintenanceOrphanSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get maintenanceOrphanSelectAll;

  /// No description provided for @maintenanceOrphanDeselectAll.
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get maintenanceOrphanDeselectAll;

  /// No description provided for @maintenanceOrphanDeleteOne.
  ///
  /// In zh, this message translates to:
  /// **'删除此项'**
  String get maintenanceOrphanDeleteOne;

  /// No description provided for @maintenanceOrphanSelectedHint.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 项'**
  String maintenanceOrphanSelectedHint(int count);

  /// No description provided for @maintenanceOrphanCleanSelected.
  ///
  /// In zh, this message translates to:
  /// **'清理已选'**
  String get maintenanceOrphanCleanSelected;

  /// No description provided for @maintenanceOrphanConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认清理'**
  String get maintenanceOrphanConfirmTitle;

  /// No description provided for @maintenanceOrphanConfirmDeleteOne.
  ///
  /// In zh, this message translates to:
  /// **'确定清理「{title}」吗？操作不可撤销。'**
  String maintenanceOrphanConfirmDeleteOne(String title);

  /// No description provided for @maintenanceOrphanConfirmDeleteBatch.
  ///
  /// In zh, this message translates to:
  /// **'确定清理选中的 {count} 项吗？操作不可撤销。'**
  String maintenanceOrphanConfirmDeleteBatch(int count);

  /// No description provided for @maintenanceOrphanCleanSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已清理 {count} 项'**
  String maintenanceOrphanCleanSuccess(int count);

  /// No description provided for @maintenanceOrphanCleanPartial.
  ///
  /// In zh, this message translates to:
  /// **'成功 {ok} 项,失败 {fail} 项'**
  String maintenanceOrphanCleanPartial(int ok, int fail);

  /// No description provided for @syncProgressTitle.
  ///
  /// In zh, this message translates to:
  /// **'正在同步'**
  String get syncProgressTitle;

  /// No description provided for @syncProgressCount.
  ///
  /// In zh, this message translates to:
  /// **'{applied} / {total} 条'**
  String syncProgressCount(int applied, int total);

  /// No description provided for @exchangeRatePageTitle.
  ///
  /// In zh, this message translates to:
  /// **'汇率管理'**
  String get exchangeRatePageTitle;

  /// No description provided for @exchangeRateEntrySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'自动获取汇率，支持手动修正'**
  String get exchangeRateEntrySubtitle;

  /// No description provided for @baseCurrencyLabel.
  ///
  /// In zh, this message translates to:
  /// **'主币种'**
  String get baseCurrencyLabel;

  /// No description provided for @rateSourceAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get rateSourceAuto;

  /// No description provided for @rateSourceManual.
  ///
  /// In zh, this message translates to:
  /// **'手动'**
  String get rateSourceManual;

  /// No description provided for @rateUpdatedAt.
  ///
  /// In zh, this message translates to:
  /// **'{date} 更新'**
  String rateUpdatedAt(Object date);

  /// No description provided for @rateNotFetched.
  ///
  /// In zh, this message translates to:
  /// **'未获取'**
  String get rateNotFetched;

  /// No description provided for @rateTapToSet.
  ///
  /// In zh, this message translates to:
  /// **'点击手动设置'**
  String get rateTapToSet;

  /// No description provided for @rateEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑汇率'**
  String get rateEditTitle;

  /// No description provided for @rateInverseHint.
  ///
  /// In zh, this message translates to:
  /// **'反向参考:1 {base} ≈ {rate} {quote}'**
  String rateInverseHint(Object base, Object quote, Object rate);

  /// No description provided for @rateResetToAuto.
  ///
  /// In zh, this message translates to:
  /// **'恢复自动'**
  String get rateResetToAuto;

  /// No description provided for @rateRefreshSuccess.
  ///
  /// In zh, this message translates to:
  /// **'汇率已更新'**
  String get rateRefreshSuccess;

  /// No description provided for @rateRefreshFailed.
  ///
  /// In zh, this message translates to:
  /// **'获取失败,可手动设置汇率'**
  String get rateRefreshFailed;

  /// No description provided for @ratesEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'给账户设置不同币种后,这里会出现可管理的汇率'**
  String get ratesEmptyHint;

  /// No description provided for @rateDisclaimer.
  ///
  /// In zh, this message translates to:
  /// **'数据来源:开源汇率数据,每日更新;折算仅供参考,可能与银行实际牌价有差异。'**
  String get rateDisclaimer;

  /// No description provided for @convertedNetWorth.
  ///
  /// In zh, this message translates to:
  /// **'净资产(折{currency})'**
  String convertedNetWorth(Object currency);

  /// No description provided for @convertedFootnote.
  ///
  /// In zh, this message translates to:
  /// **'按 {date} 汇率折算,点击管理汇率'**
  String convertedFootnote(Object date);

  /// No description provided for @convertedPartialWarning.
  ///
  /// In zh, this message translates to:
  /// **'{currencies} 未折算,点击设置汇率'**
  String convertedPartialWarning(Object currencies);

  /// No description provided for @unconvertedBadge.
  ///
  /// In zh, this message translates to:
  /// **'未折算'**
  String get unconvertedBadge;

  /// No description provided for @commonDetail.
  ///
  /// In zh, this message translates to:
  /// **'详情'**
  String get commonDetail;

  /// No description provided for @conversionDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'折算详情'**
  String get conversionDetailTitle;

  /// No description provided for @assetConversionToggle.
  ///
  /// In zh, this message translates to:
  /// **'按主币种折算'**
  String get assetConversionToggle;

  /// No description provided for @rateManualApplied.
  ///
  /// In zh, this message translates to:
  /// **'已应用 {count} 条手动汇率'**
  String rateManualApplied(Object count);

  /// No description provided for @netWorthTrendTitle.
  ///
  /// In zh, this message translates to:
  /// **'净值趋势'**
  String get netWorthTrendTitle;

  /// No description provided for @netWorthTrend3M.
  ///
  /// In zh, this message translates to:
  /// **'3个月'**
  String get netWorthTrend3M;

  /// No description provided for @netWorthTrend6M.
  ///
  /// In zh, this message translates to:
  /// **'6个月'**
  String get netWorthTrend6M;

  /// No description provided for @netWorthTrend12M.
  ///
  /// In zh, this message translates to:
  /// **'12个月'**
  String get netWorthTrend12M;

  /// No description provided for @netWorthTrendAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get netWorthTrendAll;

  /// No description provided for @netWorthTrendLineNet.
  ///
  /// In zh, this message translates to:
  /// **'净资产'**
  String get netWorthTrendLineNet;

  /// No description provided for @netWorthTrendLineAssets.
  ///
  /// In zh, this message translates to:
  /// **'总资产'**
  String get netWorthTrendLineAssets;

  /// No description provided for @netWorthTrendLineLiabilities.
  ///
  /// In zh, this message translates to:
  /// **'总负债'**
  String get netWorthTrendLineLiabilities;

  /// No description provided for @netWorthTrendMultiCurrencyNote.
  ///
  /// In zh, this message translates to:
  /// **'历史净值为各币种原值相加,未折算'**
  String get netWorthTrendMultiCurrencyNote;

  /// No description provided for @txFlagExcludeFromStats.
  ///
  /// In zh, this message translates to:
  /// **'不计入收支'**
  String get txFlagExcludeFromStats;

  /// No description provided for @txFlagExcludeFromBudget.
  ///
  /// In zh, this message translates to:
  /// **'不计入预算'**
  String get txFlagExcludeFromBudget;

  /// No description provided for @txFlagMoreOptions.
  ///
  /// In zh, this message translates to:
  /// **'更多选项'**
  String get txFlagMoreOptions;

  /// No description provided for @txFlagDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'账单标记'**
  String get txFlagDialogTitle;

  /// No description provided for @txFlagExcludeFromStatsHint.
  ///
  /// In zh, this message translates to:
  /// **'不计入收支统计,但仍计入账户余额'**
  String get txFlagExcludeFromStatsHint;

  /// No description provided for @txFlagExcludeFromBudgetHint.
  ///
  /// In zh, this message translates to:
  /// **'不占用预算额度'**
  String get txFlagExcludeFromBudgetHint;

  /// No description provided for @txFlagExcludedTag.
  ///
  /// In zh, this message translates to:
  /// **'不计收支'**
  String get txFlagExcludedTag;

  /// No description provided for @txFlagBudgetExcludedTag.
  ///
  /// In zh, this message translates to:
  /// **'不计预算'**
  String get txFlagBudgetExcludedTag;

  /// No description provided for @txCurrencyLabel.
  ///
  /// In zh, this message translates to:
  /// **'币种'**
  String get txCurrencyLabel;

  /// No description provided for @txRateLabel.
  ///
  /// In zh, this message translates to:
  /// **'汇率'**
  String get txRateLabel;

  /// No description provided for @txConvertedPreview.
  ///
  /// In zh, this message translates to:
  /// **'≈ {amount} {currency}'**
  String txConvertedPreview(Object amount, Object currency);

  /// No description provided for @txRateMissingHint.
  ///
  /// In zh, this message translates to:
  /// **'请手动填写本笔汇率后保存'**
  String get txRateMissingHint;

  /// No description provided for @txCrossCurrencyTransferBlocked.
  ///
  /// In zh, this message translates to:
  /// **'暂不支持跨币种转账,请分别记两笔或使用同币种账户'**
  String get txCrossCurrencyTransferBlocked;

  /// No description provided for @ledgerBaseCurrencyLabel.
  ///
  /// In zh, this message translates to:
  /// **'主币种'**
  String get ledgerBaseCurrencyLabel;

  /// No description provided for @statsConvertedFootnote.
  ///
  /// In zh, this message translates to:
  /// **'含外币,已按各笔记账时汇率折算为 {currency}'**
  String statsConvertedFootnote(Object currency);

  /// No description provided for @ledgerCurrencyChangeRecalcHint.
  ///
  /// In zh, this message translates to:
  /// **'修改本位币将按当前汇率重算全部历史交易的折算值'**
  String get ledgerCurrencyChangeRecalcHint;

  /// No description provided for @recalcForeignTxBanner.
  ///
  /// In zh, this message translates to:
  /// **'检测到该账本有未折算的外币交易'**
  String get recalcForeignTxBanner;

  /// No description provided for @recalcForeignTxAction.
  ///
  /// In zh, this message translates to:
  /// **'按当前汇率重算折算'**
  String get recalcForeignTxAction;

  /// No description provided for @recalcForeignTxDone.
  ///
  /// In zh, this message translates to:
  /// **'已重算 {count} 笔外币交易的折算值'**
  String recalcForeignTxDone(Object count);

  /// No description provided for @txCurrencyPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择币种'**
  String get txCurrencyPickerTitle;

  /// No description provided for @recalcSyncCountHint.
  ///
  /// In zh, this message translates to:
  /// **'将重算并同步 {count} 笔交易'**
  String recalcSyncCountHint(Object count);

  /// No description provided for @exportCsvHeaderCurrency.
  ///
  /// In zh, this message translates to:
  /// **'币种'**
  String get exportCsvHeaderCurrency;

  /// No description provided for @importFieldCurrency.
  ///
  /// In zh, this message translates to:
  /// **'币种'**
  String get importFieldCurrency;

  /// No description provided for @currencyMOP.
  ///
  /// In zh, this message translates to:
  /// **'澳门元'**
  String get currencyMOP;

  /// No description provided for @currencyMNT.
  ///
  /// In zh, this message translates to:
  /// **'蒙古图格里克'**
  String get currencyMNT;

  /// No description provided for @currencyKPW.
  ///
  /// In zh, this message translates to:
  /// **'朝鲜元'**
  String get currencyKPW;

  /// No description provided for @currencyKHR.
  ///
  /// In zh, this message translates to:
  /// **'柬埔寨瑞尔'**
  String get currencyKHR;

  /// No description provided for @currencyLAK.
  ///
  /// In zh, this message translates to:
  /// **'老挝基普'**
  String get currencyLAK;

  /// No description provided for @currencyBND.
  ///
  /// In zh, this message translates to:
  /// **'文莱元'**
  String get currencyBND;

  /// No description provided for @currencyNPR.
  ///
  /// In zh, this message translates to:
  /// **'尼泊尔卢比'**
  String get currencyNPR;

  /// No description provided for @currencyBTN.
  ///
  /// In zh, this message translates to:
  /// **'不丹努尔特鲁姆'**
  String get currencyBTN;

  /// No description provided for @currencyMVR.
  ///
  /// In zh, this message translates to:
  /// **'马尔代夫拉菲亚'**
  String get currencyMVR;

  /// No description provided for @currencyAFN.
  ///
  /// In zh, this message translates to:
  /// **'阿富汗尼'**
  String get currencyAFN;

  /// No description provided for @currencyUZS.
  ///
  /// In zh, this message translates to:
  /// **'乌兹别克斯坦索姆'**
  String get currencyUZS;

  /// No description provided for @currencyTJS.
  ///
  /// In zh, this message translates to:
  /// **'塔吉克斯坦索莫尼'**
  String get currencyTJS;

  /// No description provided for @currencyTMT.
  ///
  /// In zh, this message translates to:
  /// **'土库曼斯坦马纳特'**
  String get currencyTMT;

  /// No description provided for @currencyKGS.
  ///
  /// In zh, this message translates to:
  /// **'吉尔吉斯斯坦索姆'**
  String get currencyKGS;

  /// No description provided for @currencyQAR.
  ///
  /// In zh, this message translates to:
  /// **'卡塔尔里亚尔'**
  String get currencyQAR;

  /// No description provided for @currencyKWD.
  ///
  /// In zh, this message translates to:
  /// **'科威特第纳尔'**
  String get currencyKWD;

  /// No description provided for @currencyBHD.
  ///
  /// In zh, this message translates to:
  /// **'巴林第纳尔'**
  String get currencyBHD;

  /// No description provided for @currencyOMR.
  ///
  /// In zh, this message translates to:
  /// **'阿曼里亚尔'**
  String get currencyOMR;

  /// No description provided for @currencyJOD.
  ///
  /// In zh, this message translates to:
  /// **'约旦第纳尔'**
  String get currencyJOD;

  /// No description provided for @currencyLBP.
  ///
  /// In zh, this message translates to:
  /// **'黎巴嫩镑'**
  String get currencyLBP;

  /// No description provided for @currencyIQD.
  ///
  /// In zh, this message translates to:
  /// **'伊拉克第纳尔'**
  String get currencyIQD;

  /// No description provided for @currencyIRR.
  ///
  /// In zh, this message translates to:
  /// **'伊朗里亚尔'**
  String get currencyIRR;

  /// No description provided for @currencyYER.
  ///
  /// In zh, this message translates to:
  /// **'也门里亚尔'**
  String get currencyYER;

  /// No description provided for @currencySYP.
  ///
  /// In zh, this message translates to:
  /// **'叙利亚镑'**
  String get currencySYP;

  /// No description provided for @currencyGEL.
  ///
  /// In zh, this message translates to:
  /// **'格鲁吉亚拉里'**
  String get currencyGEL;

  /// No description provided for @currencyAMD.
  ///
  /// In zh, this message translates to:
  /// **'亚美尼亚德拉姆'**
  String get currencyAMD;

  /// No description provided for @currencyAZN.
  ///
  /// In zh, this message translates to:
  /// **'阿塞拜疆马纳特'**
  String get currencyAZN;

  /// No description provided for @currencyRON.
  ///
  /// In zh, this message translates to:
  /// **'罗马尼亚列伊'**
  String get currencyRON;

  /// No description provided for @currencyBGN.
  ///
  /// In zh, this message translates to:
  /// **'保加利亚列弗'**
  String get currencyBGN;

  /// No description provided for @currencyRSD.
  ///
  /// In zh, this message translates to:
  /// **'塞尔维亚第纳尔'**
  String get currencyRSD;

  /// No description provided for @currencyISK.
  ///
  /// In zh, this message translates to:
  /// **'冰岛克朗'**
  String get currencyISK;

  /// No description provided for @currencyMDL.
  ///
  /// In zh, this message translates to:
  /// **'摩尔多瓦列伊'**
  String get currencyMDL;

  /// No description provided for @currencyALL.
  ///
  /// In zh, this message translates to:
  /// **'阿尔巴尼亚列克'**
  String get currencyALL;

  /// No description provided for @currencyMKD.
  ///
  /// In zh, this message translates to:
  /// **'北马其顿第纳尔'**
  String get currencyMKD;

  /// No description provided for @currencyBAM.
  ///
  /// In zh, this message translates to:
  /// **'波黑可兑换马克'**
  String get currencyBAM;

  /// No description provided for @currencyGIP.
  ///
  /// In zh, this message translates to:
  /// **'直布罗陀镑'**
  String get currencyGIP;

  /// No description provided for @currencyGTQ.
  ///
  /// In zh, this message translates to:
  /// **'危地马拉格查尔'**
  String get currencyGTQ;

  /// No description provided for @currencyHNL.
  ///
  /// In zh, this message translates to:
  /// **'洪都拉斯伦皮拉'**
  String get currencyHNL;

  /// No description provided for @currencyNIO.
  ///
  /// In zh, this message translates to:
  /// **'尼加拉瓜科多巴'**
  String get currencyNIO;

  /// No description provided for @currencyCRC.
  ///
  /// In zh, this message translates to:
  /// **'哥斯达黎加科朗'**
  String get currencyCRC;

  /// No description provided for @currencyPAB.
  ///
  /// In zh, this message translates to:
  /// **'巴拿马巴波亚'**
  String get currencyPAB;

  /// No description provided for @currencyDOP.
  ///
  /// In zh, this message translates to:
  /// **'多米尼加比索'**
  String get currencyDOP;

  /// No description provided for @currencyCUP.
  ///
  /// In zh, this message translates to:
  /// **'古巴比索'**
  String get currencyCUP;

  /// No description provided for @currencyJMD.
  ///
  /// In zh, this message translates to:
  /// **'牙买加元'**
  String get currencyJMD;

  /// No description provided for @currencyTTD.
  ///
  /// In zh, this message translates to:
  /// **'特立尼达和多巴哥元'**
  String get currencyTTD;

  /// No description provided for @currencyBSD.
  ///
  /// In zh, this message translates to:
  /// **'巴哈马元'**
  String get currencyBSD;

  /// No description provided for @currencyBBD.
  ///
  /// In zh, this message translates to:
  /// **'巴巴多斯元'**
  String get currencyBBD;

  /// No description provided for @currencyBZD.
  ///
  /// In zh, this message translates to:
  /// **'伯利兹元'**
  String get currencyBZD;

  /// No description provided for @currencyHTG.
  ///
  /// In zh, this message translates to:
  /// **'海地古德'**
  String get currencyHTG;

  /// No description provided for @currencyXCD.
  ///
  /// In zh, this message translates to:
  /// **'东加勒比元'**
  String get currencyXCD;

  /// No description provided for @currencyKYD.
  ///
  /// In zh, this message translates to:
  /// **'开曼群岛元'**
  String get currencyKYD;

  /// No description provided for @currencyAWG.
  ///
  /// In zh, this message translates to:
  /// **'阿鲁巴弗罗林'**
  String get currencyAWG;

  /// No description provided for @currencyANG.
  ///
  /// In zh, this message translates to:
  /// **'荷属安的列斯盾'**
  String get currencyANG;

  /// No description provided for @currencyBMD.
  ///
  /// In zh, this message translates to:
  /// **'百慕大元'**
  String get currencyBMD;

  /// No description provided for @currencyUYU.
  ///
  /// In zh, this message translates to:
  /// **'乌拉圭比索'**
  String get currencyUYU;

  /// No description provided for @currencyPYG.
  ///
  /// In zh, this message translates to:
  /// **'巴拉圭瓜拉尼'**
  String get currencyPYG;

  /// No description provided for @currencyBOB.
  ///
  /// In zh, this message translates to:
  /// **'玻利维亚诺'**
  String get currencyBOB;

  /// No description provided for @currencyVES.
  ///
  /// In zh, this message translates to:
  /// **'委内瑞拉玻利瓦尔'**
  String get currencyVES;

  /// No description provided for @currencyGYD.
  ///
  /// In zh, this message translates to:
  /// **'圭亚那元'**
  String get currencyGYD;

  /// No description provided for @currencySRD.
  ///
  /// In zh, this message translates to:
  /// **'苏里南元'**
  String get currencySRD;

  /// No description provided for @currencyFJD.
  ///
  /// In zh, this message translates to:
  /// **'斐济元'**
  String get currencyFJD;

  /// No description provided for @currencyPGK.
  ///
  /// In zh, this message translates to:
  /// **'巴布亚新几内亚基那'**
  String get currencyPGK;

  /// No description provided for @currencySBD.
  ///
  /// In zh, this message translates to:
  /// **'所罗门群岛元'**
  String get currencySBD;

  /// No description provided for @currencyTOP.
  ///
  /// In zh, this message translates to:
  /// **'汤加潘加'**
  String get currencyTOP;

  /// No description provided for @currencyVUV.
  ///
  /// In zh, this message translates to:
  /// **'瓦努阿图瓦图'**
  String get currencyVUV;

  /// No description provided for @currencyWST.
  ///
  /// In zh, this message translates to:
  /// **'萨摩亚塔拉'**
  String get currencyWST;

  /// No description provided for @currencyXPF.
  ///
  /// In zh, this message translates to:
  /// **'太平洋法郎'**
  String get currencyXPF;

  /// No description provided for @currencyKES.
  ///
  /// In zh, this message translates to:
  /// **'肯尼亚先令'**
  String get currencyKES;

  /// No description provided for @currencyGHS.
  ///
  /// In zh, this message translates to:
  /// **'加纳塞地'**
  String get currencyGHS;

  /// No description provided for @currencyMAD.
  ///
  /// In zh, this message translates to:
  /// **'摩洛哥迪拉姆'**
  String get currencyMAD;

  /// No description provided for @currencyDZD.
  ///
  /// In zh, this message translates to:
  /// **'阿尔及利亚第纳尔'**
  String get currencyDZD;

  /// No description provided for @currencyTND.
  ///
  /// In zh, this message translates to:
  /// **'突尼斯第纳尔'**
  String get currencyTND;

  /// No description provided for @currencyLYD.
  ///
  /// In zh, this message translates to:
  /// **'利比亚第纳尔'**
  String get currencyLYD;

  /// No description provided for @currencyETB.
  ///
  /// In zh, this message translates to:
  /// **'埃塞俄比亚比尔'**
  String get currencyETB;

  /// No description provided for @currencyUGX.
  ///
  /// In zh, this message translates to:
  /// **'乌干达先令'**
  String get currencyUGX;

  /// No description provided for @currencyTZS.
  ///
  /// In zh, this message translates to:
  /// **'坦桑尼亚先令'**
  String get currencyTZS;

  /// No description provided for @currencyRWF.
  ///
  /// In zh, this message translates to:
  /// **'卢旺达法郎'**
  String get currencyRWF;

  /// No description provided for @currencyXAF.
  ///
  /// In zh, this message translates to:
  /// **'中非法郎'**
  String get currencyXAF;

  /// No description provided for @currencyXOF.
  ///
  /// In zh, this message translates to:
  /// **'西非法郎'**
  String get currencyXOF;

  /// No description provided for @currencyMUR.
  ///
  /// In zh, this message translates to:
  /// **'毛里求斯卢比'**
  String get currencyMUR;

  /// No description provided for @currencyBWP.
  ///
  /// In zh, this message translates to:
  /// **'博茨瓦纳普拉'**
  String get currencyBWP;

  /// No description provided for @currencyNAD.
  ///
  /// In zh, this message translates to:
  /// **'纳米比亚元'**
  String get currencyNAD;

  /// No description provided for @currencyZMW.
  ///
  /// In zh, this message translates to:
  /// **'赞比亚克瓦查'**
  String get currencyZMW;

  /// No description provided for @currencyMWK.
  ///
  /// In zh, this message translates to:
  /// **'马拉维克瓦查'**
  String get currencyMWK;

  /// No description provided for @currencyMZN.
  ///
  /// In zh, this message translates to:
  /// **'莫桑比克梅蒂卡尔'**
  String get currencyMZN;

  /// No description provided for @currencyAOA.
  ///
  /// In zh, this message translates to:
  /// **'安哥拉宽扎'**
  String get currencyAOA;

  /// No description provided for @currencyCDF.
  ///
  /// In zh, this message translates to:
  /// **'刚果法郎'**
  String get currencyCDF;

  /// No description provided for @currencyGMD.
  ///
  /// In zh, this message translates to:
  /// **'冈比亚达拉西'**
  String get currencyGMD;

  /// No description provided for @currencyGNF.
  ///
  /// In zh, this message translates to:
  /// **'几内亚法郎'**
  String get currencyGNF;

  /// No description provided for @currencyLRD.
  ///
  /// In zh, this message translates to:
  /// **'利比里亚元'**
  String get currencyLRD;

  /// No description provided for @currencySLE.
  ///
  /// In zh, this message translates to:
  /// **'塞拉利昂利昂'**
  String get currencySLE;

  /// No description provided for @currencySDG.
  ///
  /// In zh, this message translates to:
  /// **'苏丹镑'**
  String get currencySDG;

  /// No description provided for @currencySSP.
  ///
  /// In zh, this message translates to:
  /// **'南苏丹镑'**
  String get currencySSP;

  /// No description provided for @currencySOS.
  ///
  /// In zh, this message translates to:
  /// **'索马里先令'**
  String get currencySOS;

  /// No description provided for @currencyDJF.
  ///
  /// In zh, this message translates to:
  /// **'吉布提法郎'**
  String get currencyDJF;

  /// No description provided for @currencyERN.
  ///
  /// In zh, this message translates to:
  /// **'厄立特里亚纳克法'**
  String get currencyERN;

  /// No description provided for @currencyBIF.
  ///
  /// In zh, this message translates to:
  /// **'布隆迪法郎'**
  String get currencyBIF;

  /// No description provided for @currencyCVE.
  ///
  /// In zh, this message translates to:
  /// **'佛得角埃斯库多'**
  String get currencyCVE;

  /// No description provided for @currencySTN.
  ///
  /// In zh, this message translates to:
  /// **'圣多美多布拉'**
  String get currencySTN;

  /// No description provided for @currencySCR.
  ///
  /// In zh, this message translates to:
  /// **'塞舌尔卢比'**
  String get currencySCR;

  /// No description provided for @currencyKMF.
  ///
  /// In zh, this message translates to:
  /// **'科摩罗法郎'**
  String get currencyKMF;

  /// No description provided for @currencyLSL.
  ///
  /// In zh, this message translates to:
  /// **'莱索托洛蒂'**
  String get currencyLSL;

  /// No description provided for @currencySZL.
  ///
  /// In zh, this message translates to:
  /// **'斯威士兰里兰吉尼'**
  String get currencySZL;

  /// No description provided for @currencyMGA.
  ///
  /// In zh, this message translates to:
  /// **'马达加斯加阿里亚里'**
  String get currencyMGA;

  /// No description provided for @currencyMRU.
  ///
  /// In zh, this message translates to:
  /// **'毛里塔尼亚乌吉亚'**
  String get currencyMRU;

  /// No description provided for @trashTitle.
  ///
  /// In zh, this message translates to:
  /// **'最近删除'**
  String get trashTitle;

  /// No description provided for @trashEntryDesc.
  ///
  /// In zh, this message translates to:
  /// **'删除的交易保留 30 天,可恢复'**
  String get trashEntryDesc;

  /// No description provided for @trashEmpty.
  ///
  /// In zh, this message translates to:
  /// **'回收站是空的'**
  String get trashEmpty;

  /// No description provided for @trashRetentionHint.
  ///
  /// In zh, this message translates to:
  /// **'删除的交易保留 30 天后自动清理'**
  String get trashRetentionHint;

  /// No description provided for @trashRestored.
  ///
  /// In zh, this message translates to:
  /// **'已恢复'**
  String get trashRestored;

  /// No description provided for @trashRestoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'恢复失败'**
  String get trashRestoreFailed;

  /// No description provided for @trashRestore.
  ///
  /// In zh, this message translates to:
  /// **'恢复'**
  String get trashRestore;

  /// No description provided for @trashPurgeTitle.
  ///
  /// In zh, this message translates to:
  /// **'彻底删除'**
  String get trashPurgeTitle;

  /// No description provided for @trashPurgeAsk.
  ///
  /// In zh, this message translates to:
  /// **'将永久删除 {sign}{amount},且无法恢复。确定继续吗?'**
  String trashPurgeAsk(Object amount, Object sign);

  /// No description provided for @trashPurgeConfirm.
  ///
  /// In zh, this message translates to:
  /// **'彻底删除'**
  String get trashPurgeConfirm;

  /// No description provided for @trashDeletedAt.
  ///
  /// In zh, this message translates to:
  /// **'删除于'**
  String get trashDeletedAt;

  /// No description provided for @trashDaysLeft.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {count} 天'**
  String trashDaysLeft(Object count);

  /// No description provided for @trashTypeIncome.
  ///
  /// In zh, this message translates to:
  /// **'收入'**
  String get trashTypeIncome;

  /// No description provided for @trashTypeExpense.
  ///
  /// In zh, this message translates to:
  /// **'支出'**
  String get trashTypeExpense;

  /// No description provided for @trashTypeTransfer.
  ///
  /// In zh, this message translates to:
  /// **'转账'**
  String get trashTypeTransfer;

  /// No description provided for @pendingCandidateReasonSettlementUnknown.
  ///
  /// In zh, this message translates to:
  /// **'结算状态不明确,请核对是否已支付'**
  String get pendingCandidateReasonSettlementUnknown;

  /// No description provided for @pendingCandidateReasonTransferAccountMissing.
  ///
  /// In zh, this message translates to:
  /// **'转账/还款缺少账户,请补充'**
  String get pendingCandidateReasonTransferAccountMissing;

  /// No description provided for @pendingCandidateReasonAlreadyProcessed.
  ///
  /// In zh, this message translates to:
  /// **'同一账单已处理过'**
  String get pendingCandidateReasonAlreadyProcessed;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'zh': return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
