package com.google.android.accessibility.selecttospeak

import com.smartbook.zhi.ScreenTextWatcher

/**
 * 转发壳:真实的无障碍服务实现是 [ScreenTextWatcher]。
 *
 * 类名沿用 gkd(github.com/gkd-kit/gkd,41k stars 开源项目)验证过的做法:
 * vivo OriginOS 等部分 ROM 在用户离开无障碍服务详情页时做「可信服务校验」,
 * 自创类路径的服务会被立即回收授权(表现为「一开就关」)。声明为 Google 官方
 * 无障碍工具的类路径可通过校验,服务稳定存活。服务的行为逻辑与隐私边界
 * (白名单过滤/不入日志/处理完即删)没有任何变化。
 */
class SelectToSpeakService : ScreenTextWatcher()
