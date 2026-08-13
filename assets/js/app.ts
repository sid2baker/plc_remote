import 'phoenix_html'
import { Socket } from 'phoenix'
import { LiveSocket } from 'phoenix_live_view'

const csrfToken = document
  .querySelector<HTMLMetaElement>('meta[name="csrf-token"]')
  ?.getAttribute('content')

const liveSocket = new LiveSocket('/live', Socket, {
  longPollFallbackMs: 2_500,
  params: { _csrf_token: csrfToken },
})

liveSocket.connect()
