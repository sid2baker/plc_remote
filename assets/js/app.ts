import 'phoenix_html'
import { Socket } from 'phoenix'
import { LiveSocket } from 'phoenix_live_view'

type DynamicFieldsHook = {
  el: HTMLElement
  refresh: () => void
  listener: () => void
}

const DynamicFields = {
  mounted(this: DynamicFieldsHook) {
    this.refresh = () => {
      this.el.querySelectorAll<HTMLElement>('[data-visible-when]').forEach((element) => {
        const rule = element.dataset.visibleWhen
        if (!rule) return

        const [field, values] = rule.split(':', 2)
        const input = Array.from(this.el.querySelectorAll<HTMLSelectElement>('select[name]')).find(
          (select) => select.name === `settings[${field}]`,
        )

        element.hidden = !input || !values.split(',').includes(input.value)
      })
    }

    this.listener = () => this.refresh()
    this.el.addEventListener('change', this.listener)
    this.refresh()
  },
  updated(this: DynamicFieldsHook) {
    this.refresh()
  },
  destroyed(this: DynamicFieldsHook) {
    this.el.removeEventListener('change', this.listener)
  },
}

const csrfToken = document
  .querySelector<HTMLMetaElement>('meta[name="csrf-token"]')
  ?.getAttribute('content')

const liveSocket = new LiveSocket('/live', Socket, {
  hooks: { DynamicFields },
  longPollFallbackMs: 2_500,
  params: { _csrf_token: csrfToken },
})

liveSocket.connect()
