/**
 * Hand-written shapes for the `erp` read models.
 *
 * The generated database.types.ts only covers `public`, because PostgREST does
 * not serve `erp` until it is added to Settings → API → Exposed schemas. Once
 * it is, regenerate types and replace these with the generated `erp` rows.
 *
 * Only the columns the UI actually selects are listed — these are not
 * column-for-column mirrors of 002_erp_read_tables.sql.
 */

export interface DimCustomerRow {
  customer_key: string
  customer_id: string
  customer_name: string | null
  sold_to_city: string | null
  sold_to_state: string | null
  assigned_sales_rep_id: string | null
  assigned_sales_rep_name: string | null
  territory: string | null
  customer_type: string | null
  active_flag: string | null
  account_open_date: string | null
  last_order_date: string | null
  yearly_sales_goal: number | null
  credit_status: string | null
  /**
   * Compliance and credit, landed since 002 and surfaced for the first time
   * on the account page's "Can we ship?" strip. useAccount() already does
   * select('*'), so these arrived in the payload long before anything read
   * them.
   *
   * ffl_expiration_raw is FREE-FORM (bi.vw_DimCustomer sources it from
   * CUSTOMER.USER_5, a user-defined field) — parse it through lib/ffl.ts,
   * which refuses anything it cannot read rather than guessing.
   */
  ffl_license_number: string | null
  ffl_expiration_raw: string | null
  credit_limit_amount: number | null
  ar_terms_rule_id: string | null
}

export interface DimSalesRepRow {
  sales_rep_key: string
  sales_rep_name: string | null
  vendor_id: string | null
  is_placeholder_rep: boolean | null
}

export interface FactInvoiceLineRow {
  invoice_id: string
  invoice_line_no: number
  customer_key: string
  part_key: string | null
  invoice_date: string | null
  invoice_qty: number | null
  revenue: number | null
  is_memo: boolean | null
}

export interface FactOrderLineRow {
  order_id: string
  line_num: number
  customer_key: string
  part_key: string | null
  order_date: string | null
  promise_date: string | null
  order_state: string | null
  order_qty: number | null
  bookings: number | null
  backlog_qty: number | null
  is_backlog_line: boolean | null
}

export interface FactShipmentLineRow {
  packlist_id: string
  line_num: number
  customer_key: string
  part_key: string | null
  ship_date: string | null
  shipped_qty: number | null
  shipped_revenue: number | null
}
