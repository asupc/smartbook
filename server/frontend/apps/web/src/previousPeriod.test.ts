import { describe, expect, it } from 'vitest'

import {
  periodDaysElapsed,
  periodLengthDays,
  previousMonthRange,
  previousPeriodLabel,
  previousPeriodRangeText,
  yearDaysElapsed,
} from '@smartbook/web-features'

describe('previousPeriodLabel / previousPeriodRangeText 边界验证', () => {
  const d = (s: string) => new Date(s)

  it('自然月(startDay=1):跨年、大小月', () => {
    expect(previousPeriodLabel(d('2026-01-05'), 1)).toBe('2025-12')
    expect(previousPeriodLabel(d('2026-03-31'), 1)).toBe('2026-02')
    expect(previousPeriodLabel(d('2026-10-01'), 1)).toBe('2026-09')
  })

  it('startDay=15:月内切换日两侧', () => {
    // 10-01 尚未到 15 号 → 当前周期 2026-09,上月应为 2026-08
    expect(previousPeriodLabel(d('2026-10-01'), 15)).toBe('2026-08')
    // 10-15 起进入 2026-10 周期,上月为 2026-09
    expect(previousPeriodLabel(d('2026-10-15'), 15)).toBe('2026-09')
  })

  it('startDay=28:2月溢出场景(3-31 → new Date(y,1,31) 溢出到 3 月)', () => {
    expect(previousPeriodLabel(d('2026-03-31'), 28)).toBe('2026-02')
    expect(previousPeriodLabel(d('2026-03-27'), 28)).toBe('2026-01')
    expect(previousPeriodLabel(d('2026-03-28'), 28)).toBe('2026-02')
  })

  it('previousPeriodRangeText:startDay=1 不标注', () => {
    expect(previousPeriodRangeText(1)).toBeNull()
  })

  it('previousPeriodRangeText:startDay=15', () => {
    expect(previousPeriodRangeText(15, d('2026-09-09'))).toBe('7.15-8.14')
    expect(previousPeriodRangeText(15, d('2026-01-03'),)).toBe('11.15-12.14')
  })

  it('previousPeriodRangeText:startDay=28 覆盖 2 月(28 天)', () => {
    // 2026-03-27 仍在 2.28 起的周期内,上一周期为 1.28-2.27
    expect(previousPeriodRangeText(28, d('2026-03-27'))).toBe('1.28-2.27')
    // 2026-03-28 当天进入 3.28 起的新周期,上一周期为 2.28-3.27
    expect(previousPeriodRangeText(28, d('2026-03-28'))).toBe('2.28-3.27')
  })
})

describe('periodDaysElapsed / periodLengthDays / yearDaysElapsed 边界验证', () => {
  const d = (s: string) => new Date(s)

  it('periodDaysElapsed:自然月已过天数(含今天)', () => {
    expect(periodDaysElapsed(1, d('2026-09-01'))).toBe(1)
    expect(periodDaysElapsed(1, d('2026-09-09'))).toBe(9)
    // 8 月 31 天:9-1 已进入新周期,分母重置为 1
    expect(periodDaysElapsed(1, d('2026-08-31'))).toBe(31)
  })

  it('periodDaysElapsed:startDay=15,周期跨月', () => {
    // 周期 8.15 → 9.14:9-9 是第 26 天
    expect(periodDaysElapsed(15, d('2026-09-09'))).toBe(26)
    // 周期首日
    expect(periodDaysElapsed(15, d('2026-08-15'))).toBe(1)
  })

  it('periodLengthDays:上一周期完整天数', () => {
    // 8 月自然月 31 天
    expect(periodLengthDays(previousMonthRange(1, d('2026-09-09')))).toBe(31)
    // startDay=15 → 上周期 7.15-8.14,31 天
    expect(periodLengthDays(previousMonthRange(15, d('2026-09-09')))).toBe(31)
    // startDay=28 → 上周期 2.28-3.27(2026 平年),28 天
    expect(periodLengthDays(previousMonthRange(28, d('2026-03-28')))).toBe(28)
    // 2 月自然月:3 月的上周期是 2 月,28 天(2026 非闰年)
    expect(periodLengthDays(previousMonthRange(1, d('2026-03-10')))).toBe(28)
  })

  it('yearDaysElapsed:自然年与跨年周期', () => {
    expect(yearDaysElapsed(1, d('2026-01-01'))).toBe(1)
    // 2026-09-09:31+28+31+30+31+30+31+31+9 = 252
    expect(yearDaysElapsed(1, d('2026-09-09'))).toBe(252)
    // startDay=15 → 年起点 1.15:1.15 → 9.9 = 238 天(17+28+31+30+31+30+31+31+9)
    expect(yearDaysElapsed(15, d('2026-09-09'))).toBe(238)
  })
})
