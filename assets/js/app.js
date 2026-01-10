// SPDX-License-Identifier: MPL-2.0
// HAR - Hybrid Automation Router
// Phoenix LiveView JavaScript

import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken }
})

// Connect if there are any LiveViews on the page
liveSocket.connect()

// Expose liveSocket on window for debugging
window.liveSocket = liveSocket
