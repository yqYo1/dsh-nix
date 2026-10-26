import { appendFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

// Minimal example plugin: records activation/disposal and keeps the process
// alive so the CLI's signal-owned shutdown exercises the fiber disposer.
export function apply(ctx, config) {
  mkdirSync(dirname(config.markerPath), { recursive: true })
  appendFileSync(config.markerPath, `${config.activatedMarker}\n`)
  const keepAlive = setInterval(() => {}, 1000)
  ctx.effect(() => () => {
    clearInterval(keepAlive)
    appendFileSync(config.markerPath, `${config.disposedMarker}\n`)
  })
}
