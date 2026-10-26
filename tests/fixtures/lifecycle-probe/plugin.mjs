import { appendFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

export function apply(ctx, config) {
  mkdirSync(dirname(config.markerPath), { recursive: true })
  appendFileSync(config.markerPath, `${config.activatedMarker}\n`)
  // Keep the real CLI alive until its signal-owned shutdown path invokes the
  // fiber disposer; without a live handle, this fixture would exit naturally
  // after activation and never exercise SIGTERM -> dispose.
  const keepAlive = setInterval(() => {}, 1000)
  ctx.effect(() => () => {
    clearInterval(keepAlive)
    appendFileSync(config.markerPath, `${config.disposedMarker}\n`)
  })
}
