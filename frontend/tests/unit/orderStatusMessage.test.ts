/**
 * Unit tests for lib/orderStatusMessage.ts — the "Send status" text, the
 * sms: link and the share/copy fallback.
 *
 * Run with:  npm run test:unit -- orderStatusMessage
 *
 * The text goes to a dealer, unedited, from a parking lot. What matters is
 * that it says THEIR number first, never claims a ship date the ERP does not
 * have, and never lists a parcel twice.
 */
import {
  MAX_TRACKING_LINKS,
  orderStatusMessage,
  senderName,
  shareOrCopy,
  shipmentMessage,
  smsHref,
  smsNumber,
  smsPlatform,
  trackingList,
  upsTrackUrl,
  type StatusLine,
  type StatusOrder,
} from '../../src/lib/orderStatusMessage'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(
      `FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`,
    )
  }
}

const today = new Date('2026-10-13T12:00:00')

const order: StatusOrder = {
  order_id: 'SO-88412',
  customer_po_number: 'PO-1001',
  order_date: '2026-10-08',
  order_status_desc: 'Released',
  line_count: 3,
  open_line_count: 2,
  next_promise_date: '2026-10-23',
  next_desired_ship_date: '2026-10-20',
  tracking_numbers: '1Z999AA10123456784',
  last_ship_date: '2026-10-10',
}

const line = (over: Partial<StatusLine>): StatusLine => ({
  line_num: 1,
  part_id: null,
  part_description: null,
  order_qty: 1,
  backlog_qty: 0,
  is_backlog_line: false,
  total_shipped_qty_to_date: 0,
  promise_date: null,
  desired_ship_date: null,
  ...over,
})

const lines: StatusLine[] = [
  line({ line_num: 1, part_id: 'CA-MPR-308', part_description: 'MPR 308 Win 16in', order_qty: 3, total_shipped_qty_to_date: 3, tracking_numbers: '1Z999AA10123456784' }),
  line({ line_num: 2, part_id: 'CA-RIDGE-7', part_description: 'Ridgeline 7mm PRC', order_qty: 2, backlog_qty: 2, is_backlog_line: true, promise_date: '2026-10-23' }),
  line({ line_num: 3, part_id: 'CA-556', part_description: null, order_qty: 3, backlog_qty: 2, is_backlog_line: true, total_shipped_qty_to_date: 1, desired_ship_date: '2027-01-05', tracking_numbers: '1Z999AA10123456784, 1Z999AA10123450002' }),
]

/* ---- tracking helpers ---------------------------------------------------- */

t('upsTrackUrl encodes and trims', upsTrackUrl(' 1Z 999 '), 'https://www.ups.com/track?tracknum=1Z%20999')
t('trackingList splits, trims, drops blanks and duplicates',
  trackingList(' 1ZA, ,1ZB,1ZA '), ['1ZA', '1ZB'])
t('trackingList of null is empty', trackingList(null), [])

/* ---- with lines ---------------------------------------------------------- */

t('with lines: their PO first, then shipped and open by part, tracking once per parcel, sign-off',
  orderStatusMessage(order, { lines, from: 'Riley', today }).split('\n'),
  [
    'Christensen Arms order update: your PO PO-1001 (our order SO-88412, placed Oct 8).',
    '',
    'Shipped:',
    '- MPR 308 Win 16in x 3',
    '- CA-556 x 1',
    '',
    'Still open:',
    '- Ridgeline 7mm PRC x 2, promised Oct 23',
    '- CA-556 x 2, est. production Jan 5, 2027',
    '',
    'Track them:',
    'https://www.ups.com/track?tracknum=1Z999AA10123456784',
    'https://www.ups.com/track?tracknum=1Z999AA10123450002',
    '',
    '- Riley',
  ])

t('an open line with neither date says so instead of inventing one',
  orderStatusMessage(order, {
    lines: [line({ part_description: 'Mesa 6.5 CM', backlog_qty: 1, is_backlog_line: true })],
    today,
  }).split('\n')[3],
  '- Mesa 6.5 CM x 1, no date yet')

t('lines without tracking fall back to the order\'s numbers',
  orderStatusMessage(order, {
    lines: [line({ part_description: 'Mesa 6.5 CM', total_shipped_qty_to_date: 1 })],
    today,
  }).includes('tracknum=1Z999AA10123456784'),
  true)

/* ---- header only --------------------------------------------------------- */

t('header only: open count, next promise, last shipment, tracking',
  orderStatusMessage(order, { today }).split('\n'),
  [
    'Christensen Arms order update: your PO PO-1001 (our order SO-88412, placed Oct 8).',
    '2 of 3 lines still open, next promised Oct 23.',
    'Last shipment went out Oct 10.',
    '',
    'Track it:',
    'https://www.ups.com/track?tracknum=1Z999AA10123456784',
  ])

t('header only, no promise: the est. production date',
  orderStatusMessage({ ...order, next_promise_date: null }, { today }).split('\n')[1],
  '2 of 3 lines still open, next est. production Oct 20.')

t('header only, no dates at all',
  orderStatusMessage({ ...order, next_promise_date: null, next_desired_ship_date: null, line_count: 1, open_line_count: 1, last_ship_date: null, tracking_numbers: null }, { today }).split('\n'),
  [
    'Christensen Arms order update: your PO PO-1001 (our order SO-88412, placed Oct 8).',
    '1 line still open, no ship date yet.',
  ])

t('shipped complete',
  orderStatusMessage({ ...order, open_line_count: 0, tracking_numbers: null }, { today }).split('\n')[1],
  'Shipped complete, last on Oct 10.')

t('no PO: our order number leads, capitalised',
  orderStatusMessage({ ...order, customer_po_number: null }, { today }).split('\n')[0],
  'Christensen Arms order update: Our order SO-88412, placed Oct 8.')

t('cancelled says so and nothing about open lines or dates',
  orderStatusMessage({ ...order, order_status_desc: 'Canceled', tracking_numbers: null }, { today }).split('\n'),
  [
    'Christensen Arms order update: your PO PO-1001 (our order SO-88412, placed Oct 8).',
    'This order is cancelled.',
  ])
t('cancelled after a partial shipment still links what did ship',
  orderStatusMessage({ ...order, order_status_desc: 'Canceled' }, { lines, today }).split('\n').slice(1, 4),
  ['This order is cancelled.', '', 'Track them:'])

t(`more than ${MAX_TRACKING_LINKS} parcels: the first ${MAX_TRACKING_LINKS} and a count`,
  orderStatusMessage({ ...order, tracking_numbers: 'A1,A2,A3,A4,A5' }, { today }).split('\n').slice(-2),
  ['https://www.ups.com/track?tracknum=A3', '+2 more parcels'])

/* ---- shipment (activity feed) -------------------------------------------- */

t('shipmentMessage with PO and order',
  shipmentMessage({ order_id: 'SO-1', customer_po_number: 'PO-9', ship_date: '2026-10-12', tracking_numbers: '1ZX' }, { from: 'Riley', today }).split('\n'),
  [
    'Christensen Arms shipping update: your PO PO-9 (our order SO-1) shipped Oct 12.',
    '',
    'Track it:',
    'https://www.ups.com/track?tracknum=1ZX',
    '',
    '- Riley',
  ])
t('shipmentMessage with no tracking and no PO',
  shipmentMessage({ order_id: 'SO-1', ship_date: null, tracking_numbers: null }, { today }),
  'Christensen Arms shipping update: your order SO-1 shipped.')

t('senderName: first name only', senderName('Riley Rep'), 'Riley')
t('senderName: never an email', senderName('riley@x.test'), null)
t('senderName: blank', senderName('  '), null)

/* ---- sms ----------------------------------------------------------------- */

t('smsNumber strips formatting', smsNumber('(406) 555-0142'), '4065550142')
t('smsNumber keeps a leading +', smsNumber('+1 406 555 0142'), '+14065550142')
t('smsNumber drops an extension', smsNumber('406-555-0142 x204'), '4065550142')
t('smsNumber drops "ext."', smsNumber('406.555.0142 ext. 9'), '4065550142')
t('smsNumber refuses a short number', smsNumber('555-01'), null)
t('smsNumber of null', smsNumber(null), null)

t('iOS body after &', smsHref('(406) 555-0142', 'Hi there\nPO 1', 'ios'), 'sms:4065550142&body=Hi%20there%0APO%201')
t('Android body after ?', smsHref('(406) 555-0142', 'Hi', 'other'), 'sms:4065550142?body=Hi')
t('no usable number, no link', smsHref('n/a', 'Hi', 'ios'), null)

t('iPhone is ios', smsPlatform('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)', 5), 'ios')
t('iPadOS (a touch Mac) is ios', smsPlatform('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 5), 'ios')
t('a real Mac is not', smsPlatform('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)', 0), 'other')
t('Android is other', smsPlatform('Mozilla/5.0 (Linux; Android 14; Pixel 8)', 5), 'other')

/* ---- share / copy -------------------------------------------------------- */

async function shareCases() {
  const shared: string[] = []
  t('share sheet when there is one',
    await shareOrCopy('hello', { share: async (d) => void shared.push(d.text ?? '') }, null),
    'shared')
  t('…with the text', shared, ['hello'])

  t('a dismissed share sheet is cancelled, not copied',
    await shareOrCopy('x', {
      share: async () => { throw Object.assign(new Error('x'), { name: 'AbortError' }) },
      clipboard: { writeText: async () => { throw new Error('should not copy') } },
    }, null),
    'cancelled')

  const copied: string[] = []
  t('a refused share falls back to the clipboard',
    await shareOrCopy('y', {
      share: async () => { throw Object.assign(new Error('no'), { name: 'NotAllowedError' }) },
      clipboard: { writeText: async (s) => void copied.push(s) },
    }, null),
    'copied')
  t('no share API: clipboard', await shareOrCopy('z', { clipboard: { writeText: async (s) => void copied.push(s) } }, null), 'copied')
  t('…both copies carried the text', copied, ['y', 'z'])
  t('canShare false: clipboard, not share',
    await shareOrCopy('w', {
      share: async () => { throw new Error('should not share') },
      canShare: () => false,
      clipboard: { writeText: async () => {} },
    }, null),
    'copied')
  t('nothing works and no document: failed', await shareOrCopy('v', {}, null), 'failed')
}

await shareCases()

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
