-- compact_sync_changes_postgres.sql — compact_sync_changes.sh 的 PostgreSQL 版
--
-- 用途:一次性清理 SmartBook-Cloud PostgreSQL DB 里 sync_changes 表的历史重复 /
-- 已删 entity 的废弃 upsert(并发 fullPush bug 的历史数据 backfill,逻辑与
-- SQLite 版 server/scripts/compact_sync_changes.sh 完全一致):
--   1) 对已 delete 的 entity,清掉它所有 upsert(保留 delete event)
--   2) 对未 delete 的 entity,同 (user_id, entity_type, entity_sync_id) 多条
--      upsert 只保留 MAX(change_id) —— 最新一条 = 当前状态
--   3) 修复 *_projection.source_change_id 指向(被删 change 的引用归到留下的 MAX)
--
-- 适用场景:canonical PG 部署(仓库根 docker-compose.yml 的 smartbook-db)。
-- SQLite 本地库请用 compact_sync_changes.sh。
--
-- 用法(psql >= 10,需要 \if 支持):
--   # DRY-RUN(默认:只打印统计与将删除的行数,不动数据):
--   psql "postgresql://user:pass@localhost:5432/smartbook" \
--       -f scripts/compact_sync_changes_postgres.sql
--   # 真做(整个清理在一个事务里,sanity check 失败自动 ROLLBACK):
--   psql "postgresql://user:pass@localhost:5432/smartbook" \
--       -v apply=true -f scripts/compact_sync_changes_postgres.sql
--
--   注意:compose/.env 里的连接串是 SQLAlchemy 形态(postgresql+psycopg://),
--   给 psql 用时去掉 "+psycopg"。容器内:
--   docker compose exec smartbook-db psql -U smartbook -d smartbook \
--       -v apply=true -f /dev/stdin < scripts/compact_sync_changes_postgres.sql
--
-- 跑前强烈建议:停掉 smartbook-cloud 或进维护窗口(避免与正在 push 的客户端
-- race / 锁冲突),并先备份:
--   docker compose exec smartbook-db pg_dump -U smartbook -Fc smartbook \
--       > smartbook-$(date +%Y%m%d-%H%M%S).dump

\set ON_ERROR_STOP on

-- apply 变量:未传 -v apply=true 时默认 false(= dry-run)
\if :{?apply}
\else
\set apply false
\endif

\echo '=== 清理前 sync_changes 分布 ==='
SELECT entity_type, action, COUNT(*) AS cnt
FROM sync_changes
GROUP BY entity_type, action
ORDER BY cnt DESC;

\echo '=== 清理前 projection vs sync_changes 比例 ==='
SELECT t, proj, sc, round(sc / NULLIF(proj, 0), 2) AS ratio
FROM (
  SELECT 'account' AS t,
    (SELECT COUNT(*) FROM user_account_projection) AS proj,
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'account' AND action = 'upsert') AS sc
  UNION ALL
  SELECT 'category',
    (SELECT COUNT(*) FROM user_category_projection),
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'category' AND action = 'upsert')
  UNION ALL
  SELECT 'tag',
    (SELECT COUNT(*) FROM user_tag_projection),
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'tag' AND action = 'upsert')
  UNION ALL
  SELECT 'transaction',
    (SELECT COUNT(*) FROM read_tx_projection),
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'transaction' AND action = 'upsert')
  UNION ALL
  SELECT 'budget',
    (SELECT COUNT(*) FROM read_budget_projection),
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'budget' AND action = 'upsert')
) x;

\echo '=== 可清理 row 数估算(dry-run,两种模式都会跑) ==='
SELECT
  (SELECT COUNT(*) FROM sync_changes s          -- step 1: 已 delete 的 entity 上的 upsert
     WHERE s.action != 'delete'
       AND EXISTS (SELECT 1 FROM sync_changes d
                    WHERE d.action = 'delete'
                      AND d.user_id = s.user_id
                      AND d.entity_type = s.entity_type
                      AND d.entity_sync_id = s.entity_sync_id)) AS step1,
  (SELECT COUNT(*) FROM sync_changes s          -- step 2: 未 delete entity 的非最新 upsert
     WHERE s.action != 'delete'
       AND s.change_id NOT IN (SELECT MAX(change_id) FROM sync_changes
                                WHERE action != 'delete'
                                GROUP BY user_id, entity_type, entity_sync_id)
       AND NOT EXISTS (SELECT 1 FROM sync_changes d
                        WHERE d.action = 'delete'
                          AND d.user_id = s.user_id
                          AND d.entity_type = s.entity_type
                          AND d.entity_sync_id = s.entity_sync_id)) AS step2;

\if :apply

BEGIN;

-- step 1: 已 delete 的 entity,清掉其全部 upsert(保留 delete event)
DELETE FROM sync_changes s
WHERE s.action != 'delete'
  AND EXISTS (SELECT 1 FROM sync_changes d
               WHERE d.action = 'delete'
                 AND d.user_id = s.user_id
                 AND d.entity_type = s.entity_type
                 AND d.entity_sync_id = s.entity_sync_id);

-- step 2: 未 delete 的 entity,只保留每 (user_id, entity_type, entity_sync_id) 的
-- 最新一条 upsert(MAX(change_id)),其余删除
DELETE FROM sync_changes s
WHERE s.action != 'delete'
  AND NOT EXISTS (
      SELECT 1 FROM (
          SELECT user_id, entity_type, entity_sync_id, MAX(change_id) AS max_cid
          FROM sync_changes
          WHERE action != 'delete'
          GROUP BY user_id, entity_type, entity_sync_id
      ) m
      WHERE m.user_id = s.user_id
        AND m.entity_type = s.entity_type
        AND m.entity_sync_id = s.entity_sync_id
        AND s.change_id = m.max_cid)
  AND NOT EXISTS (SELECT 1 FROM sync_changes d
                   WHERE d.action = 'delete'
                     AND d.user_id = s.user_id
                     AND d.entity_type = s.entity_type
                     AND d.entity_sync_id = s.entity_sync_id);

-- step 3: 修复 projection.source_change_id(被删 change 的引用归到留下的 MAX)
UPDATE user_account_projection p
SET source_change_id = COALESCE((
  SELECT MAX(sc.change_id) FROM sync_changes sc
  WHERE sc.user_id = p.user_id AND sc.entity_type = 'account'
    AND sc.entity_sync_id = p.sync_id), p.source_change_id);

UPDATE user_category_projection p
SET source_change_id = COALESCE((
  SELECT MAX(sc.change_id) FROM sync_changes sc
  WHERE sc.user_id = p.user_id AND sc.entity_type = 'category'
    AND sc.entity_sync_id = p.sync_id), p.source_change_id);

UPDATE user_tag_projection p
SET source_change_id = COALESCE((
  SELECT MAX(sc.change_id) FROM sync_changes sc
  WHERE sc.user_id = p.user_id AND sc.entity_type = 'tag'
    AND sc.entity_sync_id = p.sync_id), p.source_change_id);

UPDATE read_tx_projection p
SET source_change_id = COALESCE((
  SELECT MAX(sc.change_id) FROM sync_changes sc
  WHERE sc.user_id = p.user_id AND sc.entity_type = 'transaction'
    AND sc.entity_sync_id = p.sync_id), p.source_change_id);

UPDATE read_budget_projection p
SET source_change_id = COALESCE((
  SELECT MAX(sc.change_id) FROM sync_changes sc
  WHERE sc.user_id = p.user_id AND sc.entity_type = 'budget'
    AND sc.entity_sync_id = p.sync_id), p.source_change_id);

-- sanity check: projection.source_change_id 不应有 dangling —— 有则整体回滚
SELECT (
  (SELECT COUNT(*) FROM user_account_projection p
     LEFT JOIN sync_changes sc ON sc.change_id = p.source_change_id AND sc.user_id = p.user_id
     WHERE sc.change_id IS NULL)
+ (SELECT COUNT(*) FROM user_category_projection p
     LEFT JOIN sync_changes sc ON sc.change_id = p.source_change_id AND sc.user_id = p.user_id
     WHERE sc.change_id IS NULL)
+ (SELECT COUNT(*) FROM user_tag_projection p
     LEFT JOIN sync_changes sc ON sc.change_id = p.source_change_id AND sc.user_id = p.user_id
     WHERE sc.change_id IS NULL)
+ (SELECT COUNT(*) FROM read_tx_projection p
     LEFT JOIN sync_changes sc ON sc.change_id = p.source_change_id AND sc.user_id = p.user_id
     WHERE sc.change_id IS NULL)
+ (SELECT COUNT(*) FROM read_budget_projection p
     LEFT JOIN sync_changes sc ON sc.change_id = p.source_change_id AND sc.user_id = p.user_id
     WHERE sc.change_id IS NULL)
) AS dangling \gset

\if :dangling
\echo '!!! sanity check 失败: 存在 dangling projection 引用(见上方 dangling 计数),已 ROLLBACK,未做任何改动。请人工核查后重试。'
ROLLBACK;
\else
COMMIT;
\echo '=== 清理已提交。清理后分布 ==='
SELECT entity_type, action, COUNT(*) AS cnt
FROM sync_changes
GROUP BY entity_type, action
ORDER BY cnt DESC;
\echo '=== 清理后 projection vs sync_changes 比例(应全部 ≈ 1.00) ==='
SELECT t, proj, sc, round(sc / NULLIF(proj, 0), 2) AS ratio
FROM (
  SELECT 'account' AS t,
    (SELECT COUNT(*) FROM user_account_projection) AS proj,
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'account' AND action = 'upsert') AS sc
  UNION ALL
  SELECT 'category',
    (SELECT COUNT(*) FROM user_category_projection),
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'category' AND action = 'upsert')
  UNION ALL
  SELECT 'tag',
    (SELECT COUNT(*) FROM user_tag_projection),
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'tag' AND action = 'upsert')
  UNION ALL
  SELECT 'transaction',
    (SELECT COUNT(*) FROM read_tx_projection),
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'transaction' AND action = 'upsert')
  UNION ALL
  SELECT 'budget',
    (SELECT COUNT(*) FROM read_budget_projection),
    (SELECT COUNT(*) FROM sync_changes WHERE entity_type = 'budget' AND action = 'upsert')
) x;
\endif

\else

\echo 'DRY-RUN 模式(未传 -v apply=true),数据库未做任何改动。'

\endif
