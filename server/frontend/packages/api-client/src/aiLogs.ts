import { authedDelete, authedGet, authedGetBlob, authedPost } from './http'

export type AIAnalysisLogEntryType = 'ask' | 'parse_tx_image' | 'parse_tx_text'
export type AIAnalysisLogStatus = 'ok' | 'error'

/**
 * GET /ai/logs 列表项 —— 服务端只返截断预览(input_preview / output_preview),
 * 全文走详情 endpoint,避免列表 payload 无谓变大。
 */
export interface AIAnalysisLogItem {
  id: number
  entry_type: AIAnalysisLogEntryType
  status: AIAnalysisLogStatus
  provider_id: string | null
  model: string | null
  ledger_id: string | null
  input_preview: string | null
  output_preview: string | null
  error_message: string | null
  duration_ms: number
  prompt_tokens: number | null
  completion_tokens: number | null
  total_tokens: number | null
  client_ip: string | null
  called_at: string
}

/** GET /ai/logs/{id} —— 单条全文(写入侧已截断到 50k/100k)。
 * `has_image`:App 上报截图记账时随行传了输入原图,详情页据此渲染图片。 */
export interface AIAnalysisLogDetail {
  id: number
  entry_type: AIAnalysisLogEntryType
  status: AIAnalysisLogStatus
  provider_id: string | null
  model: string | null
  ledger_id: string | null
  input_text: string | null
  output_text: string | null
  error_message: string | null
  duration_ms: number
  prompt_tokens: number | null
  completion_tokens: number | null
  total_tokens: number | null
  client_ip: string | null
  has_image: boolean
  called_at: string
}

export interface AIAnalysisLogListResult {
  total: number
  items: AIAnalysisLogItem[]
}

export interface AIAnalysisLogListOptions {
  limit?: number
  offset?: number
  entry_type?: AIAnalysisLogEntryType
  status?: AIAnalysisLogStatus
}

/**
 * 列出当前用户的 AI 分析调用历史(called_at 倒序),支持过滤。
 * 抛 ApiError(对齐 read endpoints)。
 */
export async function listAIAnalysisLogs(
  token: string,
  options: AIAnalysisLogListOptions = {},
): Promise<AIAnalysisLogListResult> {
  const query = new URLSearchParams()
  if (options.limit !== undefined) query.set('limit', `${options.limit}`)
  if (options.offset !== undefined) query.set('offset', `${options.offset}`)
  if (options.entry_type) query.set('entry_type', options.entry_type)
  if (options.status) query.set('status', options.status)
  const suffix = query.toString() ? `?${query.toString()}` : ''
  return authedGet<AIAnalysisLogListResult>(`/ai/logs${suffix}`, token)
}

/** 单条全文;非本人或不存在 → ApiError(404,服务端不区分)。 */
export async function getAIAnalysisLog(
  token: string,
  logId: number,
): Promise<AIAnalysisLogDetail> {
  return authedGet<AIAnalysisLogDetail>(`/ai/logs/${logId}`, token)
}

/** 单条记录的输入图片(App 上报的截图原图);无图/非本人/丢失 → ApiError。 */
export async function getAIAnalysisLogImage(
  token: string,
  logId: number,
): Promise<Blob> {
  return authedGetBlob(`/ai/logs/${logId}/image`, token)
}

/**
 * 删除一条自己的 AI 调用记录(日志不设自动保留期,删除是唯一清理入口;
 * 带图记录随行删落盘图片)。非本人/不存在 → ApiError(404,服务端不区分)。
 */
export async function deleteAIAnalysisLog(
  token: string,
  logId: number,
): Promise<{ ok: boolean }> {
  return authedDelete<{ ok: boolean }>(`/ai/logs/${logId}`, token)
}

/**
 * 批量删除自己的 AI 调用记录(Web 多选删除)。服务端只删属于本人的 id,
 * 不存在/他人的跳过;返回实际删除条数。
 */
export async function batchDeleteAIAnalysisLogs(
  token: string,
  ids: number[],
): Promise<{ deleted: number }> {
  return authedPost<{ deleted: number }>('/ai/logs/batch-delete', token, { ids })
}
