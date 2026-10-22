import { useEffect, useState } from 'react'
import { Link, Navigate, useParams } from 'react-router'
import { encode } from 'uqr'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Tables } from './types/database'

const l = t.assetDetail.label

// The scan target [Z7]: login and RLS on the detail page are the gate, so the id alone is enough.
export const scanUrl = (id: string) => `${window.location.origin}/q/${id}`

// Module grid as SVG rects, no innerHTML [Z9]. ecc M survives a scuffed label.
export function QrCode({ value }: { value: string }) {
  const { data, size } = encode(value, { ecc: 'M' })
  return (
    <svg viewBox={`0 0 ${size} ${size}`} shapeRendering="crispEdges" role="img" aria-label={l.qr}>
      <rect width={size} height={size} fill="#fff" />
      {data.flatMap((row, y) => row.flatMap((on, x) => (on ? [<rect key={`${x}.${y}`} x={x} y={y} width={1} height={1} />] : [])))}
    </svg>
  )
}

// /q/:id → the detail page, which shows the same not-found for an unknown id and another tenant's.
export function ScanPage() {
  const { assetId = '' } = useParams()
  return <Navigate to={`/assets/${assetId}`} replace />
}

// One 50 × 25 mm label, printed with the browser [Z8]. shortcut: one asset; bulk labels from the list come later.
export function AssetLabelPage() {
  const { assetId = '' } = useParams()
  const [asset, setAsset] = useState<Pick<Tables<'asset_view'>, 'id' | 'tag' | 'name'> | null>()

  useEffect(() => {
    let live = true
    void supabase
      .from('asset_view')
      .select('id, tag, name')
      .eq('id', assetId)
      .then(({ data }) => live && setAsset(data?.[0] ?? null))
    return () => {
      live = false
    }
  }, [assetId])

  if (asset === undefined) return <p className="muted" role="status">{t.assetDetail.loading}</p>
  if (asset === null) return <p className="muted">{t.assetDetail.notFound}</p>

  return (
    <>
      <title>{`${l.title} · ${asset.tag} · ${t.app.name}`}</title>
      <style>{'@page { size: 50mm 25mm; margin: 0; }'}</style>
      <div className="page-head">
        <h1>{l.title}</h1>
        <div className="spacer" />
        <Link className="btn" to={`/assets/${assetId}`}>
          {l.back}
        </Link>
        <button className="btn btn-main" type="button" onClick={() => window.print()}>
          {l.print}
        </button>
      </div>
      <p className="muted">{l.hint}</p>
      <div className="qr-label">
        <QrCode value={scanUrl(assetId)} />
        <div>
          <b>{asset.tag}</b>
          <span>{asset.name}</span>
        </div>
      </div>
    </>
  )
}
