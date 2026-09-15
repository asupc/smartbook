import { Modal } from 'antd'

/**
 * W2:编辑表单脏检查 —— ESC / 遮罩 / X / 取消按钮统一拦截,有未保存修改时
 * 弹二次确认(antd Modal.confirm),不再静默丢弃输入(交易长表单误触即丢)。
 *
 * 快照口径:dialog 打开时对 form 序列化(JSON.stringify;form 都是从
 * defaults / edit 构造后 spread 派生,字段顺序稳定),关闭时浅比较字符串。
 * 保存成功路径直接调外层 setOpen(false),不走这里 —— 不会误弹确认。
 */
export type DirtyCloseTexts = {
  title: string
  description: string
  confirm: string
  cancel: string
}

/** 表单快照序列化(独立出来方便单测口径)。 */
export function serializeFormSnapshot(form: unknown): string {
  return JSON.stringify(form)
}

/** 快照与当前值是否不一致(null 快照 = 无基线,视为不脏)。 */
export function isFormDirty(snapshot: string | null, current: unknown): boolean {
  return snapshot !== null && snapshot !== serializeFormSnapshot(current)
}

/**
 * 请求关闭:脏 → Modal.confirm,确认放弃才 close;不脏 → 直接 close。
 * close 里做调用方自己的收尾(onReset / 清错误提示等)。
 */
export function requestDirtyClose(options: {
  snapshot: string | null
  current: unknown
  texts: DirtyCloseTexts
  close: () => void
}): void {
  const dirty = isFormDirty(options.snapshot, options.current)
  if (!dirty) {
    options.close()
    return
  }
  Modal.confirm({
    title: options.texts.title,
    content: options.texts.description,
    okText: options.texts.confirm,
    cancelText: options.texts.cancel,
    okButtonProps: { danger: true },
    onOk: options.close,
  })
}
