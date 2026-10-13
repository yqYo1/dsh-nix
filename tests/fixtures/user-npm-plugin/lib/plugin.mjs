import { appendFileSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { checkOdd } from './index.js'

export function apply(ctx, config) {
  mkdirSync(dirname(config.markerPath), { recursive: true })
  appendFileSync(config.markerPath, `${config.activatedMarker} odd7=${checkOdd(7)}\n`)
  const keepAlive = setInterval(() => {}, 1000)
  ctx.effect(() => () => {
    clearInterval(keepAlive)
    appendFileSync(config.markerPath, `${config.disposedMarker}\n`)
  })
}
