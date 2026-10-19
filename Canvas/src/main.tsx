import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import { installApi } from './api'
import { counters } from './canvas/debug'
import { CanvasApp } from './canvas/components/CanvasApp'
import { VERSION } from './controller'
import { hasNativeHost, postToHost } from './host-bridge'
import { installTheme } from './theme'
import { installBakedShadows } from './canvas/shadows'

installTheme()
installBakedShadows()
installApi()
// Render counters for measuring a running page (`canvas/debug.ts`): read-only numbers.
Object.defineProperty(window, '__canvasCounters', { value: counters, configurable: true })

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <CanvasApp />
  </StrictMode>
)

const params = new URLSearchParams(window.location.search)
if (!hasNativeHost() && params.get('dev') === '1') {
  void import('./dev').then(m => m.startDev(params))
} else {
  performance.mark?.('canvas:ready')
  postToHost({ type: 'ready', version: VERSION })
}
