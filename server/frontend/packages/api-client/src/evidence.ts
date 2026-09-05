import { authedDelete, authedGet, authedPost } from './http'

export interface RawEvidence {
  id: string
  event_key: string
  ledger_id: string | null
  source: string
  source_channel: string | null
  external_id: string | null
  content_hash: string | null
  actor: string | null
  title: string | null
  /** List responses contain a preview. Fetch detail to view the full body. */
  body: string | null
  metadata: Record<string, unknown>
  captured_at: string
  occurred_at: string | null
  expires_at: string | null
  created_at: string
  updated_at: string
}
export interface RawEvidenceList { total: number; items: RawEvidence[] }
export interface RawEvidenceFilters {
  source?: string
  ledger_id?: string
  from?: string
  to?: string
  limit?: number
  offset?: number
}

// No upload/edit/reparse method is exposed to the web viewer.
export function listRawEvidence(token: string, options: RawEvidenceFilters = {}): Promise<RawEvidenceList> {
  const query = new URLSearchParams()
  for (const [key, value] of Object.entries(options)) {
    if (value !== undefined && value !== '') query.set(key, String(value))
  }
  return authedGet<RawEvidenceList>('/evidence/raw' + (query.size ? '?' + query : ''), token)
}
export function getRawEvidence(token: string, id: string): Promise<RawEvidence> {
  return authedGet<RawEvidence>('/evidence/raw/' + encodeURIComponent(id), token)
}
export function deleteRawEvidence(token: string, id: string): Promise<{ ok: boolean }> {
  return authedDelete<{ ok: boolean }>('/evidence/raw/' + encodeURIComponent(id), token)
}
export function cleanupRawEvidence(token: string, options: { source?: string; before?: string }): Promise<{ deleted: number }> {
  return authedPost<{ deleted: number }>('/evidence/raw/cleanup', token, options)
}
