import { describe, expect, it, vi } from 'vitest';

import { ApiError } from '@smartbook/api-client';

import { localizeError } from '../i18n/errors';
import en from '../i18n/en';
import zhCN from '../i18n/zh-CN';
import zhTW from '../i18n/zh-TW';
import { withMissingKeyWarnings } from '../i18n/warnMissingKeys';

/**
 * 对抗性测试 · API 错误本地化 + i18n 字典契约:
 *  1. localizeError 对畸形错误输入的健壮性(非 Error 抛出物/未知 code/缺字段)
 *  2. ERROR_KEYS 映射表的值必须在三本字典里都存在(缺 key = UI 露 raw key)
 *  3. warnMissingKeys Proxy 的探针属性与缺 key 告警
 */

function fakeT() {
  const calls: Array<{ key: string; params?: Record<string, unknown> }> = [];
  const t = (key: string, params?: Record<string, unknown>) => {
    calls.push({ key, params });
    return 'T(' + key + ')';
  };
  return { t, calls };
}

describe('[adversarial] localizeError 健壮性', () => {
  it('已知 code 映射到对应 key', () => {
    const { t, calls } = fakeT();
    const msg = localizeError(new ApiError('x', { status: 401, code: 'AUTH_INVALID_CREDENTIALS' }), t);
    expect(msg).toBe('T(error.AUTH_INVALID_CREDENTIALS)');
    expect(calls[0].key).toBe('error.AUTH_INVALID_CREDENTIALS');
  });

  it('未知 code 回落 error.default(不抛、不露 raw code)', () => {
    const { t, calls } = fakeT();
    const msg = localizeError(new ApiError('x', { status: 500, code: 'TOTALLY_NEW_CODE_2099' }), t);
    expect(msg).toBe('T(error.default)');
    expect(calls[0].key).toBe('error.default');
  });

  it('空串 code 走 message 原文分支(不是 error.default)', () => {
    // 源码:`if (!err.code) return err.message` —— 空串是 falsy,直接透传原文。
    // HARDENING:服务端若返回 code='' 且 message 为内部串,会原样展示给用户。
    const { t, calls } = fakeT();
    const msg = localizeError(new ApiError('boom-raw', { status: 500, code: '' }), t);
    expect(msg).toBe('boom-raw');
    expect(calls.length).toBe(0);
  });

  it('WRITE_CONFLICT 缺 latestChangeId/latestServerTimestamp → 占位 unknown', () => {
    const { t, calls } = fakeT();
    localizeError(new ApiError('x', { status: 409, code: 'WRITE_CONFLICT' }), t);
    expect(calls[0].params).toEqual({
      latestChangeId: 'unknown',
      latestServerTimestamp: 'unknown',
    });
  });

  it('WRITE_CONFLICT:0 保留(合法 change_id),null 时间戳回落 unknown', () => {
    const { t, calls } = fakeT();
    localizeError(
      new ApiError('x', {
        status: 409,
        code: 'WRITE_CONFLICT',
        latestChangeId: 0,
        latestServerTimestamp: null,
      }),
      t,
    );
    // 源码 `err.latestChangeId ?? 'unknown'`:0 不是 nullish → 保留;
    // null 是 nullish → 回落 'unknown'(与缺字段同款)。
    expect(calls[0].params).toEqual({
      latestChangeId: 0,
      latestServerTimestamp: 'unknown',
    });
  });

  it('HARDENING:ApiError 无 code 时把服务端 message 原文透给用户', () => {
    const { t, calls } = fakeT();
    const raw = 'IntegrityError: UNIQUE constraint failed: ledgers.external_id';
    const msg = localizeError(new ApiError(raw, { status: 500 }), t);
    expect(msg).toBe(raw);
    expect(calls.length).toBe(0);
  });

  it('普通 Error 原文透传(同上,HARDENING)', () => {
    const { t } = fakeT();
    expect(localizeError(new TypeError('x is not a function'), t)).toBe('x is not a function');
  });

  it('非 Error 抛出物(七种)全部安全回落 default,不抛', () => {
    const { t, calls } = fakeT();
    const thrown: unknown[] = ['a string', null, undefined, 42, { code: 'FAKE' }, Symbol('s'), () => 1];
    for (const x of thrown) {
      expect(localizeError(x, t)).toBe('T(error.default)');
    }
    expect(calls.length).toBe(thrown.length);
  });

  it('message 含控制字符/超长(1MB)不抛不截断(透传层职责)', () => {
    const { t } = fakeT();
    const weird = 'a\u0000b\u001b[31mred';
    expect(localizeError(new ApiError(weird, { status: 400 }), t)).toBe(weird);
    const huge = 'x'.repeat(1_000_000);
    expect(localizeError(new ApiError(huge, { status: 400 }), t)).toHaveLength(1_000_000);
  });

  it('HARDENING:duck-typed 伪 ApiError(跨 bundle 场景)不认 instanceof,走 Error 分支原文', () => {
    const { t, calls } = fakeT();
    const fake = Object.assign(new Error('x'), { status: 409, code: 'WRITE_CONFLICT' });
    expect(localizeError(fake, t)).toBe('x');
    expect(calls.length).toBe(0);
  });
});

describe('[adversarial] ERROR_KEYS ↔ 三语字典契约', () => {
  const ERROR_KEY_VALUES = [
    'error.AUTH_INVALID_CREDENTIALS', 'error.INTERNAL_ERROR', 'error.WRITE_CONFLICT',
    'error.WRITE_ROLE_FORBIDDEN', 'error.SHARE_ROLE_FORBIDDEN',
    'error.SYNC_VIEWER_WRITE_FORBIDDEN', 'error.SYNC_LEDGER_WRITE_FORBIDDEN',
    'error.AUTH_INSUFFICIENT_SCOPE', 'error.ADMIN_FORBIDDEN', 'error.RATE_LIMITED',
    'error.LEDGER_ALREADY_EXISTS', 'error.ENTITY_NOT_FOUND', 'error.WRITE_VALIDATION_FAILED',
    'error.USER_EMAIL_EXISTS', 'error.USER_PASSWORD_TOO_SHORT',
    'error.SHARE_MEMBER_USER_NOT_FOUND', 'error.ADMIN_USER_DELETE_SELF_FORBIDDEN',
    'error.ADMIN_USER_DELETE_LAST_ADMIN_FORBIDDEN', 'error.default',
  ];

  it('每个 ERROR_KEYS 值在 en 里存在', () => {
    // ADVERSE FINDING: errors.ts 的 ERROR_KEYS 引用了 error.SHARE_ROLE_FORBIDDEN /
    // error.SHARE_MEMBER_USER_NOT_FOUND,但三本字典(en/zh-CN/zh-TW)都没有这两个
    // key → 共享账本权限被拒时,UI 显示裸 key 字符串而非可读提示。
    const missing = ERROR_KEY_VALUES.filter((k) => !(k in en));
    expect(missing, `en 缺 key: ${missing.join(',')}`).toEqual([]);
  });

  it('每个 ERROR_KEYS 值在 zh-CN 里存在', () => {
    const missing = ERROR_KEY_VALUES.filter((k) => !(k in zhCN));
    expect(missing, `zh-CN 缺 key: ${missing.join(',')}`).toEqual([]);
  });

  it('每个 ERROR_KEYS 值在 zh-TW 里存在', () => {
    const missing = ERROR_KEY_VALUES.filter((k) => !(k in zhTW));
    expect(missing, `zh-TW 缺 key: ${missing.join(',')}`).toEqual([]);
  });

  it('WRITE_CONFLICT 的占位符在三语模板里都声明了', () => {
    for (const [name, dict] of [['en', en], ['zh-CN', zhCN], ['zh-TW', zhTW]] as const) {
      const tpl = (dict as Record<string, string>)['error.WRITE_CONFLICT'];
      expect(tpl, `${name} 缺 error.WRITE_CONFLICT`).toBeTruthy();
      expect(tpl, `${name} 模板缺 latestChangeId 占位`).toContain('{latestChangeId}');
      expect(tpl, `${name} 模板缺 latestServerTimestamp 占位`).toContain('{latestServerTimestamp}');
    }
  });

  it('三语字典的 key 集合一致(防单语漏键)', () => {
    const enKeys = Object.keys(en).sort();
    const zhKeys = Object.keys(zhCN).sort();
    const twKeys = Object.keys(zhTW).sort();
    const onlyEn = enKeys.filter((k) => !zhKeys.includes(k));
    const onlyZh = zhKeys.filter((k) => !enKeys.includes(k));
    expect(onlyEn, `en 有而 zh-CN 无: ${onlyEn.slice(0, 5).join(',')}`).toEqual([]);
    expect(onlyZh, `zh-CN 有而 en 无: ${onlyZh.slice(0, 5).join(',')}`).toEqual([]);
    expect(twKeys.sort()).toEqual(enKeys);
  });

  it('无空值翻译(空串等价于缺 key,t() 回落时会露 key)', () => {
    for (const [name, dict] of [['en', en], ['zh-CN', zhCN], ['zh-TW', zhTW]] as const) {
      const empties = Object.entries(dict as Record<string, string>)
        .filter(([, v]) => typeof v !== 'string' || v.trim() === '')
        .map(([k]) => k);
      expect(empties, `${name} 空值 key: ${empties.slice(0, 5).join(',')}`).toEqual([]);
    }
  });
});

describe('[adversarial] warnMissingKeys Proxy', () => {
  it('缺 key 访问打 console.warn 并返回 undefined', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const proxy = withMissingKeyWarnings('test', { a: 'A' });
    expect((proxy as Record<string, string>)['nonexistent.key']).toBeUndefined();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('nonexistent.key'));
    warn.mockRestore();
  });

  it('探针属性(__esModule/then/$x)不打告警(防误报刷屏)', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const proxy = withMissingKeyWarnings('test', { a: 'A' });
    const p = proxy as Record<string, unknown>;
    void p.__esModule;
    void p.then;
    void p.catch;
    void p.$router;
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
  });

  it('已存在的 key 正常返回且不告警', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const proxy = withMissingKeyWarnings('test', { a: 'A' });
    expect((proxy as Record<string, string>).a).toBe('A');
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
  });

  it('原型名访问(constructor)不告警,且写操作不污染 Object.prototype', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const proxy = withMissingKeyWarnings('test', { a: 'A' }) as unknown as Record<string, unknown>;
    expect(typeof proxy.constructor).toBe('function');
    expect(warn).not.toHaveBeenCalled();
    proxy['polluted'] = 'x';
    expect(({} as Record<string, unknown>)['polluted']).toBeUndefined();
    warn.mockRestore();
  });

  it('空字符串 key 不告警(isProbeProp 之外的 length>0 条件)', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const proxy = withMissingKeyWarnings('test', { a: 'A' }) as unknown as Record<string, unknown>;
    void proxy[''];
    expect(warn).not.toHaveBeenCalled();
    warn.mockRestore();
  });
});
