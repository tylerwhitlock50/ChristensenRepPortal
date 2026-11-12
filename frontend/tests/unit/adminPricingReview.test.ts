/**
 * Unit tests for components/orders/AdminPricingReview.vue — which lines the
 * review block lists, and which controls each one gets.
 *
 * Run with:  npm run test:unit -- adminPricingReview
 *
 * Rendered with Vue's own server renderer (see asyncState.test.ts).
 *
 * The case this exists for: a rep who owns a hand-priced Claude draft cannot
 * price it and cannot open it in the writer, so the review block is the only
 * place they can take a line off. It must list EVERY line for them, the
 * list-priced ones too, with Remove line and no price controls.
 */
import { createSSRApp, h } from 'vue'
import { renderToString } from 'vue/server-renderer'
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query'
import AdminPricingReview from '../../src/components/orders/AdminPricingReview.vue'
import type { OrderLineRow } from '../../src/composables/useOrders'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(`FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`)
  }
}

function line(id: number, partId: string, over: Partial<OrderLineRow> = {}): OrderLineRow {
  return {
    id,
    order_id: 8123,
    price_list_id: 1,
    price_list_item_id: null,
    part_id: partId,
    description: `Part ${partId}`,
    qty: 2,
    unit_price: 100,
    discount_pct: 0,
    effective_unit_price: 100,
    line_total: 200,
    mcp_expected_unit_price: null,
    price_source: 'list',
    list_unit_price: 100,
    customer_part_ref: null,
    customer_description: null,
    part_unresolved: false,
    last_paid_price: null,
    last_paid_date: null,
    description_mismatch: false,
    ...over,
  }
}

// 10 paid + 1 free on the same part, priced by hand, and one line at list.
const lines = [
  line(1, 'HAND-PAID', { price_source: 'admin', unit_price: 90 }),
  line(2, 'HAND-PAID', { price_source: 'admin', unit_price: 0, qty: 1 }),
  line(3, 'AT-LIST'),
]

async function render(props: Record<string, unknown>) {
  const app = createSSRApp({ render: () => h(AdminPricingReview, { lines, reason: 'free goods', ...props }) })
  app.use(VueQueryPlugin, { queryClient: new QueryClient() })
  const html = await renderToString(app)
  const count = (s: string) => html.split(s).length - 1
  return {
    listsAtListLine: html.includes('AT-LIST'),
    removeButtons: count('Remove line'),
    setPriceButtons: count('Set price'),
  }
}

t(
  'a rep who owns the draft (may remove, may not price): every line, each with Remove line, no prices',
  await render({ editable: false, canRemove: true }),
  { listsAtListLine: true, removeButtons: 3, setPriceButtons: 0 },
)
t(
  'whoever may price it: every line, with prices and Remove line',
  await render({ editable: true, canRemove: true }),
  { listsAtListLine: true, removeButtons: 3, setPriceButtons: 3 },
)
t(
  'a reader who can do neither: only the flagged lines, no controls',
  await render({ editable: false, canRemove: false }),
  { listsAtListLine: false, removeButtons: 0, setPriceButtons: 0 },
)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
