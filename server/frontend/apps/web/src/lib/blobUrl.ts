/**
 * W5:blob objectURL 竞态守卫。
 *
 * 症状(AiLogsPage 详情图片):effect 发起 fetchBlob → 用户快速关详情/切行,
 * effect cleanup 先跑 → fetch 之后 resolve → 照常 createObjectURL + setState:
 *   - objectURL 无人 revoke(泄漏,直到页面卸载)
 *   - stale setState(旧详情的图写进新详情)
 *
 * 守卫:resolve 后先看 isCancelled() —— 已取消就不 createObjectURL(从根上
 * 不产生需要回收的 URL),由调用方对「已创建」的 URL 在卸载时 revoke。
 */
export async function createObjectUrlWhenCurrent<B>(
  fetchBlob: () => Promise<B>,
  isCancelled: () => boolean,
  toUrl: (blob: B) => string = (blob) => URL.createObjectURL(blob as unknown as Blob),
): Promise<string | null> {
  let blob: B
  try {
    blob = await fetchBlob()
  } catch {
    return null
  }
  // 关键:取消发生在 resolve 之后 → 不 createObjectURL,零泄漏。
  if (isCancelled()) return null
  return toUrl(blob)
}
