import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { erp, isMissingDbObject, isSchemaNotExposed, supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/fetchAll'
import {
  bestContact,
  rankContacts,
  type BestContact,
  type BillingContext,
  type RankableContact,
  type RankedContact,
} from '@/lib/contacts'
import { directionsUrl, formatAddress, soldToAddress, type StreetAddress } from '@/lib/maps'

/**
 * "Who do I call, and how do I get there" for a set of accounts — one query
 * for a whole list (a call list, a day's route), or one account via
 * useAccountReach().
 *
 * Reads public.v_account_contacts for the people and erp.dim_customer for
 * the two things ranking and Directions need: invoice_email /
 * statement_email (a contact at one of those addresses is accounts payable,
 * not the buyer) and the sold-to street address. Ranking itself is
 * lib/contacts.ts; this file only fetches and assembles.
 *
 * The account page already has both rows loaded (useContacts, useAccount);
 * it can call buildAccountReach() on those instead of a second request.
 */

/** display_name (20261013100000) postdates the generated types. */
const db = supabase as unknown as SupabaseClient

/** Keys travel in the query string; same reasoning as useAccountGoalsFor. */
const KEY_CHUNK = 100

const STALE_TIME = 5 * 60_000

/**
 * Query keys. The single-account read sits under ['account', key,
 * 'contacts'] so both the account-root sweep and the contact mutations'
 * invalidation (qk.account.contacts, a prefix of it) refresh it. The
 * multi-account read has no account key; the contact mutations in
 * useContacts.ts invalidate bestContactsKeys.root() for it.
 */
export const bestContactsKeys = {
  root: () => ['contacts', 'best'] as const,
  forKeys: (sortedKeys: string[]) => ['contacts', 'best', sortedKeys] as const,
  account: (customerKey: string) => ['account', customerKey, 'contacts', 'reach'] as const,
}

/** The v_account_contacts columns ranking reads. */
export interface ReachContact extends RankableContact {
  contact_key: string
  source: 'rep' | 'erp'
  customer_key: string
  name: string | null
  /** Null on a database without 20261013100000; contactDisplayName() copes. */
  display_name: string | null
  title: string | null
  phone: string | null
  email: string | null
  is_primary: boolean
  do_not_call: boolean
  updated_at: string | null
}

/** The dim_customer columns this needs. DimCustomerRow fits. */
export interface ReachCustomer {
  customer_key: string
  invoice_email?: string | null
  statement_email?: string | null
  sold_to_address1?: string | null
  sold_to_address2?: string | null
  sold_to_city?: string | null
  sold_to_state?: string | null
  sold_to_zip_code?: string | null
}

export interface AccountReach<T extends RankableContact = ReachContact> {
  customerKey: string
  /** bestContact(): the one to put in a header or a call list row. */
  best: BestContact<T>
  /** Every contact, best to call first; billing and internal rows last. */
  ranked: RankedContact<T>[]
  address: StreetAddress
  /** formatAddress(): one printable line, or null when there is no street. */
  addressLine: string | null
  /** Google Maps link, or null when the address is not enough to drive to. */
  directionsUrl: string | null
}

const CONTACT_COLUMNS =
  'contact_key, source, customer_key, name, display_name, title, phone, email, is_primary, do_not_call, updated_at'

const CUSTOMER_COLUMNS =
  'customer_key, invoice_email, statement_email, sold_to_address1, sold_to_address2, sold_to_city, sold_to_state, sold_to_zip_code'

/**
 * Set after the first "column does not exist": every later fetch on this
 * page load goes straight to select('*') instead of failing first. A reload
 * after the migration lands re-arms it.
 */
let displayNameMissing = false

function str(value: unknown): string | null {
  return value == null ? null : String(value)
}

function toContact(r: Record<string, unknown>): ReachContact {
  return {
    contact_key: String(r.contact_key),
    source: r.source === 'rep' ? 'rep' : 'erp',
    customer_key: String(r.customer_key),
    name: str(r.name),
    display_name: str(r.display_name),
    title: str(r.title),
    phone: str(r.phone),
    email: str(r.email),
    is_primary: r.is_primary === true,
    // Missing before 034: read as false, the same default useContacts uses.
    do_not_call: r.do_not_call === true,
    updated_at: str(r.updated_at),
  }
}

async function fetchContacts(keys: string[], columns: string) {
  return fetchAllRows<Record<string, unknown>>((from, to) =>
    db
      .from('v_account_contacts')
      .select(columns)
      .in('customer_key', keys)
      // contact_key is unique across both arms: a total order for paging.
      .order('contact_key')
      .range(from, to) as unknown as PromiseLike<{
      data: Record<string, unknown>[] | null
      error: unknown
    }>,
  )
}

async function contactsFor(keys: string[]): Promise<ReachContact[]> {
  if (!displayNameMissing) {
    try {
      return (await fetchContacts(keys, CONTACT_COLUMNS)).map(toContact)
    } catch (error) {
      if (!isMissingDbObject(error)) throw error
      displayNameMissing = true
    }
  }
  // Whatever columns this database has; toContact fills the gaps.
  return (await fetchContacts(keys, '*')).map(toContact)
}

async function customersFor(keys: string[]): Promise<ReachCustomer[]> {
  const { data, error } = await erp
    .from('dim_customer')
    .select(CUSTOMER_COLUMNS)
    .in('customer_key', keys)
  if (error) {
    // `erp` not exposed yet: rank without billing addresses, no Directions.
    if (isSchemaNotExposed(error)) return []
    throw error
  }
  return (data ?? []) as unknown as ReachCustomer[]
}

/**
 * The AccountReach for one account from rows already in hand. Pure — the
 * account page can feed it useContacts() and useAccount() data and get the
 * same answer this file's queries give.
 */
export function buildAccountReach<T extends RankableContact>(
  customerKey: string,
  contacts: readonly T[],
  customer: ReachCustomer | null | undefined,
): AccountReach<T> {
  const opts: BillingContext = {
    invoiceEmail: customer?.invoice_email,
    statementEmail: customer?.statement_email,
  }
  const address = customer ? soldToAddress(customer) : {}
  return {
    customerKey,
    best: bestContact(contacts, opts),
    ranked: rankContacts(contacts, opts),
    address,
    addressLine: formatAddress(address),
    directionsUrl: directionsUrl(address),
  }
}

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))
  return out
}

/**
 * One entry per requested key, contacts or not. A plain object, not a Map:
 * query data must survive JSON (a persisted query cache stores it that way,
 * and a Map comes back as {}). byKey below is the Map view of it.
 */
async function fetchReach(keys: string[]): Promise<Record<string, AccountReach>> {
  const batches = await Promise.all(
    chunk(keys, KEY_CHUNK).map(async (part) => {
      const [contacts, customers] = await Promise.all([contactsFor(part), customersFor(part)])
      return { contacts, customers }
    }),
  )

  const contactsByKey = new Map<string, ReachContact[]>()
  const customerByKey = new Map<string, ReachCustomer>()
  for (const { contacts, customers } of batches) {
    for (const c of contacts) {
      const list = contactsByKey.get(c.customer_key)
      if (list) list.push(c)
      else contactsByKey.set(c.customer_key, [c])
    }
    for (const row of customers) customerByKey.set(row.customer_key, row)
  }

  return Object.fromEntries(
    keys.map((key) => [
      key,
      buildAccountReach(key, contactsByKey.get(key) ?? [], customerByKey.get(key)),
    ]),
  )
}

/**
 * Reach for every account in `keys`: data is customer_key → AccountReach,
 * with an entry for every key asked for. `byKey` is the same as a Map (empty
 * until loaded) so templates can call byKey.value.get(key).
 *
 * With no keys the query is disabled and stays pending — gate a skeleton on
 * the list having keys, not on isPending alone.
 */
export function useBestContacts(keys: MaybeRefOrGetter<string[]>) {
  const sorted = computed(() => [...new Set(toValue(keys).filter(Boolean))].sort())
  const query = useQuery({
    queryKey: computed(() => bestContactsKeys.forKeys(sorted.value)),
    enabled: computed(() => sorted.value.length > 0),
    staleTime: STALE_TIME,
    queryFn: () => fetchReach(sorted.value),
  })
  const byKey = computed(
    () => new Map<string, AccountReach>(Object.entries(query.data.value ?? {})),
  )
  return { ...query, byKey }
}

/** One account's reach — same fetch as useBestContacts, its own cache entry. */
export function useAccountReach(customerKey: MaybeRefOrGetter<string>) {
  const key = computed(() => toValue(customerKey))
  const query = useQuery({
    queryKey: computed(() => bestContactsKeys.account(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: STALE_TIME,
    queryFn: async (): Promise<AccountReach> => {
      const all = await fetchReach([key.value])
      return all[key.value] ?? buildAccountReach<ReachContact>(key.value, [], null)
    },
  })
  const reach = computed(() => query.data.value ?? null)
  return { ...query, reach }
}
