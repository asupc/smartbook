import { describe, expect, it } from 'vitest';

import { canManageLedger, canWriteTransactions } from '@smartbook/web-features';

import { APP_SECTIONS, DEFAULT_APP_SECTION, parseRoute, routePath, type AppRoute } from '../state/router';

/**
 * 对抗性测试 · state 层:
 *  1. permissions —— 角色 × 关键操作全排列,专找「未知角色默认放行」
 *  2. router —— 非法路径:`%00` / `../` / 未编码 / 超长 / 缺参 / 重复段 / 残缺百分号
 */

const ROLES = [
  'owner', 'editor', 'viewer',
  'admin', 'OWNER', 'owner ', '', 'unknown-role-typo',
  '__proto__', 'constructor', 'viewer\nadmin', 'x'.repeat(1000),
] as const;

const OPS = [
  { name: '删账本', fn: canManageLedger },
  { name: '编辑交易', fn: canWriteTransactions },
  { name: '管理成员', fn: canManageLedger },
  { name: '导出', fn: canWriteTransactions },
] as const;

describe('[adversarial] permission matrix — 角色 × 关键操作全排列', () => {
  it('12 角色 × 4 关键操作 = 48 组全部放行(单用户模式契约)', () => {
    const matrix: string[] = [];
    for (const role of ROLES) {
      for (const op of OPS) {
        if (!op.fn(role)) matrix.push(`${role.slice(0, 20)} × ${op.name}`);
      }
    }
    // 单用户 per-ledger 设计:能看见账本即 owner,角色字段只是线上兼容残留。
    expect(matrix).toEqual([]);
  });

  it('HARDENING:未知/敌意角色同样恒为 true,原型名不命中 Object.prototype', () => {
    for (const role of ROLES) {
      expect(canWriteTransactions(role)).toBe(true);
      expect(canManageLedger(role)).toBe(true);
    }
    expect(canWriteTransactions('__proto__')).toBe(true);
    expect(canManageLedger('constructor')).toBe(true);
    expect(typeof canManageLedger('toString')).toBe('boolean');
  });

  it('显式 undefined / 缺参(老客户端不发 role 字段)恒为 true', () => {
    expect(canWriteTransactions(undefined)).toBe(true);
    expect(canManageLedger(undefined)).toBe(true);
    expect(canWriteTransactions()).toBe(true);
    expect(canManageLedger()).toBe(true);
  });
});

describe('[adversarial] router 非法路径解析', () => {
  it('残缺百分号编码不得抛异常(URIError 会白屏)', () => {
    // ADVERSE FINDING: parseRoute 内 decodeURIComponent('%') 抛 URIError;
    // AdminLayout 在 render 期调用 parseRoute(location.pathname),全仓无
    // ErrorBoundary → 地址栏出现 /app/% 路径即整页崩溃。
    expect(() => parseRoute('/app/%/transactions')).not.toThrow();
  });

  it('截断的多字节 UTF-8 序列(%E0%A4%A)不得抛异常', () => {
    // ADVERSE FINDING: 同上 —— 粘贴一半的编码串会抛 URIError
    expect(() => parseRoute('/app/%E0%A4%A/transactions')).not.toThrow();
  });

  it('残缺编码兜底结果必须是合法 AppRoute(不能返回 undefined)', () => {
    let route: AppRoute | undefined;
    try {
      route = parseRoute('/app/%/transactions');
    } catch {
      route = undefined;
    }
    expect(route).toBeDefined();
    expect(route!.kind).toBe('app');
  });

  it('合法百分号编码正常解码(对照组)', () => {
    expect(parseRoute('/app/%E4%B8%AD/transactions')).toEqual({
      kind: 'app', ledgerId: '中', section: 'transactions',
    });
    expect(parseRoute('/app/%25/transactions')).toEqual({
      kind: 'app', ledgerId: '%', section: 'transactions',
    });
  });

  it('%00 注入:原样进 ledgerId(不抛;下游 encodeURIComponent 保护)', () => {
    const r = parseRoute('/app/%00/transactions');
    expect(r.kind).toBe('app');
    if (r.kind === 'app') {
      expect(r.ledgerId.length).toBe(1);
      expect(encodeURIComponent(r.ledgerId)).toBe('%00');
    }
  });

  it('HARDENING:编码后的 ../ 解码后进 ledgerId,section 落白名单兜底', () => {
    // 实际实现是「整路径先 decodeURIComponent 再按 / 切段」:
    // '..%2F..%2Fadmin' 解码成 '../../admin' 后被再切成段,ledgerId='..'、
    // section='..' 不在白名单 → 落 default。安全属性成立(不劫持 section),
    // 原「整串进 ledgerId」的断言按 split-then-decode 假设写错,改为钉住
    // 真实且安全的行为。
    const r = parseRoute('/app/..%2F..%2Fadmin/users');
    expect(r.kind).toBe('app');
    if (r.kind === 'app') {
      expect(APP_SECTIONS).toContain(r.section);
      expect(r.section.startsWith('admin')).toBe(false);
    }
    expect(encodeURIComponent('../../admin')).toBe('..%2F..%2Fadmin');
  });

  it('未编码的非 ASCII 账本名直接透传', () => {
    expect(parseRoute('/app/家庭账本/transactions')).toEqual({
      kind: 'app', ledgerId: '家庭账本', section: 'transactions',
    });
  });

  it('超长路径(10k 字符)不抛、可解析', () => {
    const big = 'a'.repeat(10_000);
    const r = parseRoute(`/app/${big}/transactions`);
    expect(r.kind).toBe('app');
    expect(r.kind === 'app' && r.ledgerId).toBe(big);
  });

  it('重复/多余路径段回退默认 section,不抛', () => {
    expect(parseRoute('/app/L1/transactions/extra/deep')).toEqual({
      kind: 'app', ledgerId: 'L1', section: 'transactions',
    });
    expect(parseRoute('/app/workspace/bogus/bogus')).toEqual({
      kind: 'app', ledgerId: '', section: DEFAULT_APP_SECTION,
    });
  });

  it('workspace 下的 ../ 无法穿越到 admin 分区', () => {
    const r = parseRoute('/app/workspace/../../admin/users');
    expect(r).toEqual({ kind: 'app', ledgerId: '', section: DEFAULT_APP_SECTION });
    expect(r.kind === 'app' && r.section.startsWith('admin')).toBe(false);
  });

  it('大小写敏感:/APP/ 不进 app(保持 login)', () => {
    expect(parseRoute('/APP/L1/transactions')).toEqual({ kind: 'login' });
  });

  it('缺参/斜杠变体全部收敛为合法 AppRoute', () => {
    const variants = [
      '/app', '/app/', '/app///', '//app//L1//transactions//',
      '/app/L1', '/app/workspace', '/app/settings', '/app/admin',
      '/app/%', '/app/%E0%A4%A', '', '/login/', '///',
    ];
    for (const p of variants) {
      let r: AppRoute | undefined;
      try {
        r = parseRoute(p);
      } catch (e) {
        throw new Error(`parseRoute(${JSON.stringify(p)}) threw: ${String(e)}`);
      }
      expect(['login', 'app']).toContain(r.kind);
      if (r.kind === 'app') expect(typeof r.section).toBe('string');
    }
  });
});

describe('[adversarial] routePath ↔ parseRoute 往返一致', () => {
  it('全部 APP_SECTIONS 往返稳定', () => {
    for (const section of APP_SECTIONS) {
      const path = routePath({ kind: 'app', ledgerId: '', section });
      expect(typeof path).toBe('string');
      expect(path!.startsWith('/app/')).toBe(true);
      expect(parseRoute(path!)).toEqual({ kind: 'app', ledgerId: '', section });
    }
  });

  it('login 路由往返', () => {
    expect(routePath({ kind: 'login' })).toBe('/login');
    expect(parseRoute(routePath({ kind: 'login' }))).toEqual({ kind: 'login' });
  });

  it('section 白名单:routePath 造出的值都可被 parseRoute 认回', () => {
    const produced = new Set<string>();
    for (const s of APP_SECTIONS) {
      const back = parseRoute(routePath({ kind: 'app', ledgerId: '', section: s })!);
      if (back.kind === 'app') produced.add(back.section);
    }
    expect([...produced].sort()).toEqual([...APP_SECTIONS].sort());
  });
});
