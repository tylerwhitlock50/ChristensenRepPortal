/*============================================================================
  20261111100100_mcp_order_rpcs.sql
  Purpose: the RPCs the MCP order tools call (follows 20261111100000).

  Reads (SECURITY INVOKER: RLS on dim_customer / dim_ship_to limits a rep to
  their own book; an admin sees every account):
    order_context(customer)                  account, ship-tos, FFL, lists, contacts
    order_product_search(customer, text)     free-text product match, priced for the account

  Writes (SECURITY DEFINER, search_path pinned; each calls mcp_orders_gate()
  first, so a portal session can never reach them):
    mcp_create_order_draft(p jsonb)           idempotent create, returns a preview
    mcp_update_order_draft(id, p jsonb)       replace header + lines of an MCP draft
    mcp_cancel_order_draft(id)                cancel an MCP draft

  The server sets every price (no price or FFL inputs exist). The preview's
  would_submit comes from a DRY RUN of the real submit_order() inside a
  subtransaction that is always rolled back, so the screen, the preview and
  the submit can never disagree, and the order stays a draft. A person
  submits in the portal.

  Errors are RAISEd as '<code>[:<detail>]: <human text>' - split on the first
  ': ' (colon + space) to get the code.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Product vocabulary: what reps say -> one canonical token
--------------------------------------------------------------------------
create table if not exists public.order_product_synonyms (
    term      text primary key check (term = lower(btrim(term)) and term <> ''),
    canonical text not null check (canonical <> '')
);
alter table public.order_product_synonyms enable row level security;

comment on table public.order_product_synonyms is
  'Firearm shorthand for order_product_search: a phrase (lower case, as '
  'order_search_normalize leaves it) and the single token both the query and '
  'the part text are rewritten to. Admins extend it with SQL.';

drop policy if exists "read order product synonyms" on public.order_product_synonyms;
create policy "read order product synonyms" on public.order_product_synonyms
  for select to authenticated using (true);
drop policy if exists "admin manages order product synonyms" on public.order_product_synonyms;
create policy "admin manages order product synonyms" on public.order_product_synonyms
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

revoke all on public.order_product_synonyms from anon, public;
grant select, insert, update, delete on public.order_product_synonyms to authenticated;

-- Every RLS table is read-only while an admin is viewing as a rep (20260901190200).
drop trigger if exists trg_order_product_synonyms_no_write_while_viewing_as on public.order_product_synonyms;
create trigger trg_order_product_synonyms_no_write_while_viewing_as
  before insert or update or delete on public.order_product_synonyms
  for each row execute function public.block_writes_while_impersonating();

-- Seeded from the live erp.dim_part family / chambering / finish /
-- stock_color vocabulary and the abbreviations in part descriptions
-- ("RL FFT 6.5 CRD 24IN 1/8 CBNW/GRY").
insert into public.order_product_synonyms (term, canonical) values
  -- chamberings
  ('6.5 creedmoor', '6.5cm'), ('6.5 creedmore', '6.5cm'), ('6.5 creed', '6.5cm'),
  ('6.5 crd', '6.5cm'), ('6.5crd', '6.5cm'), ('6.5 cm', '6.5cm'), ('6.5mm creedmoor', '6.5cm'),
  ('65 creedmoor', '6.5cm'), ('6.5mm cm', '6.5cm'),
  ('6.5 prc', '6.5prc'),
  ('6.5-284 norma', '6.5-284'),
  ('6.8 western', '6.8western'), ('6.8 wst', '6.8western'), ('6.8w', '6.8western'),
  ('7mm prc', '7prc'), ('7 prc', '7prc'), ('7mmprc', '7prc'),
  ('7mm rem mag', '7rm'), ('7mm remington magnum', '7rm'), ('7mm rem', '7rm'),
  ('7 rem mag', '7rm'), ('7mm mag', '7rm'), ('7mm rm', '7rm'),
  ('7mm backcountry', '7bc'), ('7 backcountry', '7bc'), ('7mm bc', '7bc'),
  ('7mm-08 rem', '7mm08'), ('7mm-08', '7mm08'), ('7-08', '7mm08'),
  ('300 win mag', '300wm'), ('300 winchester magnum', '300wm'), ('300 win', '300wm'),
  ('300 wm', '300wm'), ('300 winmag', '300wm'), ('300 mag', '300wm'),
  ('300 prc', '300prc'),
  ('300 rum', '300rum'), ('300 ultra mag', '300rum'),
  ('300 wsm', '300wsm'),
  ('300 aac', '300blk'), ('300 aac blackout', '300blk'), ('300 blackout', '300blk'), ('300 blk', '300blk'),
  ('308 win', '308win'), ('308 winchester', '308win'), ('308', '308win'),
  ('243 win', '243win'), ('243', '243win'),
  ('270 win', '270win'), ('270', '270win'), ('270 wsm', '270wsm'),
  ('28 nosler', '28nos'), ('28 nos', '28nos'), ('26 nosler', '26nos'),
  ('30 nosler', '30nos'), ('33 nosler', '33nos'),
  ('22 creedmoor', '22cm'), ('22 crd', '22cm'), ('22 cm', '22cm'),
  ('25 creedmoor', '25cm'), ('25 crd', '25cm'), ('25 cm', '25cm'),
  ('6mm creedmoor', '6cm'), ('6mm crd', '6cm'), ('6mm cm', '6cm'),
  ('223 wylde', '223wylde'), ('223 wyld', '223wylde'),
  ('223 rem', '223rem'), ('223 remington', '223rem'),
  ('556 nato', '556'), ('5.56 nato', '556'), ('5.56', '556'), ('5.56x45', '556'),
  ('30-06 springfield', '3006'), ('30-06 sprg', '3006'), ('30-06 spfd', '3006'),
  ('30-06', '3006'), ('30 06', '3006'),
  ('338 lapua', '338lapua'), ('338 lapua mag', '338lapua'), ('338 lm', '338lapua'),
  ('375 h h', '375hh'),
  ('450 bushmaster', '450bm'), ('450 bm', '450bm'),
  ('6mm arc', '6arc'), ('22 arc', '22arc'),
  ('9 mm', '9mm'), ('9x19', '9mm'),
  ('45 acp', '45acp'), ('45 auto', '45acp'),
  ('22 lr', '22lr'), ('22 long rifle', '22lr'), ('17 hmr', '17hmr'), ('22 wmr', '22wmr'),
  -- product lines
  ('flash forged technology', 'fft'), ('flash forged', 'fft'),
  ('rl', 'ridgeline'), ('ridge line', 'ridgeline'),
  ('modern precision rifle', 'mpr'),
  ('ti', 'titanium'),
  ('ca 15', 'ca-15'), ('ca15', 'ca-15'), ('ca 10', 'ca-10'), ('ca10', 'ca-10'),
  -- finishes and colours
  ('grey', 'gray'), ('gry', 'gray'), ('blk', 'black'), ('grn', 'green'), ('brn', 'brown'),
  ('cbn', 'carbon'), ('cbnw', 'carbon'), ('carbon fiber', 'carbon'), ('carbon fibre', 'carbon'),
  ('burnt bronze', 'burntbronze'), ('bbz', 'burntbronze'), ('bb', 'burntbronze'),
  ('smoke bronze', 'smokebronze'), ('midnight bronze', 'midnightbronze'),
  ('flat dark earth', 'fde'),
  ('od green', 'odgreen'), ('olive drab', 'odgreen'),
  ('stealth grey', 'stealthgray'), ('stealth gray', 'stealthgray'),
  -- handedness (dim_part.handedness LEFT/RIGHT is indexed as lh/rh)
  ('left hand', 'lh'), ('left handed', 'lh'), ('left-handed', 'lh'), ('lefty', 'lh'), ('left', 'lh'),
  ('right hand', 'rh'), ('right handed', 'rh'), ('right-handed', 'rh'), ('right', 'rh')
on conflict (term) do nothing;

-- One reading of free text, for the query AND the part text: lower case,
-- separators to spaces, "24in" -> "24", stray leading/trailing punctuation
-- off each word (".308" -> "308"), then every synonym phrase (longest
-- first) to its canonical token.
create or replace function public.order_search_normalize(p text)
returns text
language plpgsql stable set search_path = public
as $$
declare
  v text;
  s record;
begin
  v := lower(coalesce(p, ''));
  v := regexp_replace(v, '[,/&()+;:!?"*{}|<>=~`@$%^\[\]\\]', ' ', 'g');
  v := regexp_replace(v, '(\d)(in|inch|inches)\M', '\1', 'g');
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := regexp_replace(v, '(^| )[.''#-]+', '\1', 'g');
  v := regexp_replace(v, '[.''#-]+( |$)', '\1', 'g');
  v := ' ' || btrim(v) || ' ';
  for s in
    select y.term, y.canonical
    from public.order_product_synonyms y
    where strpos(v, ' ' || y.term || ' ') > 0
    order by length(y.term) desc, y.term
  loop
    -- Twice: adjacent repeats share the space between them.
    v := replace(v, ' ' || s.term || ' ', ' ' || s.canonical || ' ');
    v := replace(v, ' ' || s.term || ' ', ' ' || s.canonical || ' ');
  end loop;
  return btrim(regexp_replace(v, '\s+', ' ', 'g'));
end;
$$;

revoke execute on function public.order_search_normalize(text) from public, anon;
grant execute on function public.order_search_normalize(text) to authenticated;

--------------------------------------------------------------------------
-- 2. order_context: everything Claude needs before drafting for an account
--------------------------------------------------------------------------
create or replace function public.order_context(p_customer_key text)
returns jsonb
language plpgsql stable security invoker set search_path = public, erp
as $$
declare
  c          record;
  v_blockers text[] := '{}';
  v_ships    jsonb;
  v_n_ok     int;
  v_default  text;
begin
  select dc.customer_key, dc.customer_name, dc.customer_type, dc.credit_status,
         dc.active_flag, dc.loaded_at
    into c
  from erp.dim_customer dc
  where dc.customer_key = p_customer_key;
  if not found then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', p_customer_key;
  end if;

  if upper(coalesce(c.active_flag, 'Y')) = 'N' then
    v_blockers := v_blockers || 'inactive'::text;
  end if;
  if upper(coalesce(c.credit_status, '')) like 'HOLD%' then
    v_blockers := v_blockers || 'credit_hold'::text;
  end if;
  if not exists (select 1 from public.effective_price_lists(c.customer_type) l where not l.is_special) then
    v_blockers := v_blockers || 'no_price_list_for_type'::text;
  end if;

  -- The account's own ship-to addresses (CUST_ADDRESS); orderable is
  -- exactly submit_order()'s rule.
  select coalesce(jsonb_agg(jsonb_build_object(
           'ship_to_key', s.ship_to_key,
           'ship_to_id',  s.ship_to_id,
           'addr_no',     s.addr_no,
           'name',        s.ship_to_name,
           'address',     nullif(concat_ws(', ', nullif(btrim(s.address1), ''),
                                 nullif(btrim(s.address2), ''), nullif(btrim(s.address3), '')), ''),
           'city',        s.city,
           'state',       s.state,
           'zip',         s.zip_code,
           'active',      upper(coalesce(s.active_flag, 'Y')) <> 'N',
           'orderable',   s.ok,
           'ffl', jsonb_build_object(
                    'number_on_file', nullif(btrim(s.ffl_license_number), ''),
                    'expires_raw',    nullif(btrim(s.ffl_expiration_raw), ''),
                    'current',        public.ffl_on_file_current(s.ffl_license_number, s.ffl_expiration_raw)))
           order by s.ok desc, s.addr_no nulls last, s.ship_to_key), '[]'::jsonb),
         count(*) filter (where s.ok),
         min(s.ship_to_key) filter (where s.ok)
    into v_ships, v_n_ok, v_default
  from (
    select x.*,
           (nullif(btrim(x.ship_to_id), '') is not null
            and upper(coalesce(x.active_flag, 'Y')) <> 'N') as ok
    from erp.dim_ship_to x
    where x.customer_id = c.customer_key
      and x.address_source = 'ShipTo'
      and not coalesce(x.is_unknown_ship_to, false)
  ) s;

  if v_n_ok = 0 then
    v_blockers := v_blockers || 'no_orderable_ship_to'::text;
  end if;

  return jsonb_build_object(
    'customer', jsonb_build_object(
       'customer_key',  c.customer_key,
       'customer_name', c.customer_name,
       'customer_type', c.customer_type,
       'credit_status', c.credit_status,
       'active',        upper(coalesce(c.active_flag, 'Y')) <> 'N'),
    'orderable', cardinality(v_blockers) = 0,
    'blockers',  to_jsonb(v_blockers),
    'price_lists', coalesce((
       select jsonb_agg(jsonb_build_object(
                'price_list_id', l.id,
                'name',          l.name,
                'is_special',    l.is_special,
                'promo_buy_qty', l.promo_buy_qty,
                'promo_get_qty', l.promo_get_qty)
              order by l.is_special, l.effective_from desc, l.id)
       from public.effective_price_lists(c.customer_type) l), '[]'::jsonb),
    'ship_tos', v_ships,
    'default_ship_to_key', case when v_n_ok = 1 then v_default end,
    'contacts', coalesce((
       select jsonb_agg(jsonb_build_object(
                'customer_contact_key', k.customer_contact_key,
                'name',       k.name,
                'title',      k.title,
                'email',      k.email,
                'phone',      k.phone,
                'is_primary', k.is_primary)
              order by k.is_primary desc, k.name, k.customer_contact_key)
       from (
         select e.customer_contact_key,
                coalesce(nullif(btrim(e.contact_name), ''),
                         nullif(btrim(concat_ws(' ', btrim(e.first_name), btrim(e.last_name))), ''),
                         e.contact_id) as name,
                nullif(btrim(e.position), '') as title,
                nullif(btrim(e.email), '') as email,
                coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')) as phone,
                coalesce(e.primary_contact_flag = 'Y', false) as is_primary
         from erp.dim_customer_contact e
         where e.customer_key = c.customer_key
           and coalesce(e.contact_active_flag, 'Y') = 'Y'
         order by coalesce(e.primary_contact_flag = 'Y', false) desc, e.customer_contact_key
         limit 25) k), '[]'::jsonb),
    'recent_orders', coalesce((
       select jsonb_agg(jsonb_build_object(
                'order_id',     r.id,
                'status',       r.status,
                'po_number',    r.po_number,
                'created_at',   r.created_at,
                'total_amount', r.total_amount,
                'source',       r.source)
              order by r.created_at desc, r.id desc)
       from (select o.id, o.status, o.po_number, o.created_at, o.total_amount, o.source
             from public.orders o
             where o.customer_key = c.customer_key
             order by o.created_at desc, o.id desc
             limit 10) r), '[]'::jsonb),
    'data_as_of', c.loaded_at);
end;
$$;

revoke execute on function public.order_context(text) from public, anon;
grant execute on function public.order_context(text) to authenticated;

comment on function public.order_context(text) is
  'Account context for drafting an order: customer, blockers, effective price '
  'lists, ship-tos (orderable = submit_order''s rule) with FFL on file, '
  'contacts, recent portal orders. RLS-scoped (SECURITY INVOKER).';

--------------------------------------------------------------------------
-- 3. order_product_search: free text -> priced, ranked candidates
--------------------------------------------------------------------------
create or replace function public.order_product_search(
  p_customer_key text,
  p_query        text,
  p_limit        int default 10
)
returns jsonb
language plpgsql stable security invoker set search_path = public, erp
as $$
declare
  c_stop constant text[] := array[
    'a','an','the','one','two','three','four','five','six','seven','eight','nine','ten',
    'dozen','of','in','inch','inches','and','with','for','to','x','qty','pcs','pc','ea',
    'each','please','order','need','needs','want','some','rifle','rifles','gun','guns',
    'firearm','firearms','unit','units','i','we','would','like','get','me','us','send','ship',
    'color','colour','finish','barrel'];
  v_type     text;
  v_cham_map jsonb;     -- upper(chambering) -> its normalised tokens
  v_fam_map  jsonb;     -- upper(product_family) -> its normalised tokens
  v_cham_all text[];
  v_fam_all  text[];
  v_raw      text[];
  v_tok      text;
  v_alt      text;
  v_pfx      text;
  v_re       text;
  v_is_cham  boolean;
  v_is_fam   boolean;
  v_first    boolean := true;
  v_q        text[] := '{}';
  v_alts     text[] := '{}';
  v_pfxs     text[] := '{}';
  v_res      text[] := '{}';
  v_ws       int[] := '{}';
  v_qc       boolean[] := '{}';
  v_qf       boolean[] := '{}';
  v_has_cham boolean := false;
  v_has_fam  boolean := false;
  v_wsum     int;
  v_items    jsonb;
  v_top      numeric;
  v_ties     int;
  v_fits     boolean;
  v_lim      int := greatest(1, least(coalesce(p_limit, 10), 25));
begin
  select dc.customer_type into v_type
  from erp.dim_customer dc where dc.customer_key = p_customer_key;
  if not found then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', p_customer_key;
  end if;

  -- The account's priced chambering and family vocabulary, normalised once
  -- per distinct value (a few dozen), not once per part.
  select coalesce(jsonb_object_agg(x.k, to_jsonb(string_to_array(public.order_search_normalize(x.k), ' '))), '{}'::jsonb)
    into v_cham_map
  from (select distinct upper(btrim(p.chambering)) as k
          from public.effective_price_lists(v_type) l
          join public.price_list_items i on i.price_list_id = l.id
          join erp.dim_part p on p.part_id = i.part_id
         where btrim(coalesce(p.chambering, '')) not in ('', 'N/A', 'n/a')) x;
  select coalesce(jsonb_object_agg(x.k, to_jsonb(string_to_array(public.order_search_normalize(x.k), ' '))), '{}'::jsonb)
    into v_fam_map
  from (select distinct upper(btrim(p.product_family)) as k
          from public.effective_price_lists(v_type) l
          join public.price_list_items i on i.price_list_id = l.id
          join erp.dim_part p on p.part_id = i.part_id
         where btrim(coalesce(p.product_family, '')) not in ('', 'N/A', 'n/a')) x;
  v_cham_all := array(select distinct t from jsonb_each(v_cham_map) e, jsonb_array_elements_text(e.value) t where t <> '');
  v_fam_all  := array(select distinct t from jsonb_each(v_fam_map) e, jsonb_array_elements_text(e.value) t where t <> '');

  v_raw := array(
    select u.t
    from unnest(string_to_array(public.order_search_normalize(p_query), ' ')) with ordinality as u(t, n)
    where u.t <> '' and not (u.t = any (c_stop))
    order by u.n);

  -- Each query word matches a part word that equals it, its singular
  -- ("ridgelines"), or starts with it: words of 4+ letters, and partial
  -- calibers ("6.5" -> 6.5cm / 6.5prc, "300" -> 300wm / 300prc, "7mm" ->
  -- 7prc / 7rm, but "6mm" never 6.5cm). A word that names a chambering or a
  -- family on this account's lists weighs 3; colour, finish, length 1.
  foreach v_tok in array coalesce(v_raw, '{}') loop
    if v_tok = any (v_q) then
      v_first := false;
      continue;
    end if;
    v_alt := case when length(v_tok) >= 5 and v_tok ~ '[a-z]s$' then left(v_tok, -1) end;
    v_pfx := case when length(v_tok) >= 4 or (v_tok ~ '^\d' and (v_tok ~ '\.' or length(v_tok) >= 3))
                  then v_tok end;
    v_re  := case when v_tok ~ '^\d+mm$'
                  then '^' || substring(v_tok from '^\d+') || '(mm|[a-z]|$)' end;
    v_is_cham := exists (select 1 from unnest(v_cham_all) c
                         where c = v_tok or c = v_alt or starts_with(c, v_pfx) or c ~ v_re);
    v_is_fam  := exists (select 1 from unnest(v_fam_all) f
                         where f = v_tok or f = v_alt or starts_with(f, v_pfx) or f ~ v_re);
    -- A bare number is a quantity ("10 ridgelines", "20 mesas") or a twist
    -- rate unless it is a chambering ("mesa 300") or a barrel length after
    -- the product words ("mpr 26").
    if v_tok ~ '^\d+x?$' and not v_is_cham then
      if v_tok ~ 'x$' or v_first or length(v_tok) > 6
         or substring(v_tok from '^\d+')::numeric < 16 then
        v_first := false;
        continue;
      end if;
    end if;
    v_first := false;
    v_q    := v_q    || v_tok;
    v_alts := v_alts || v_alt;
    v_pfxs := v_pfxs || v_pfx;
    v_res  := v_res  || v_re;
    v_ws   := v_ws   || case when v_is_cham or v_is_fam then 3 else 1 end;
    v_qc   := v_qc   || v_is_cham;
    v_qf   := v_qf   || v_is_fam;
    v_has_cham := v_has_cham or v_is_cham;
    v_has_fam  := v_has_fam or v_is_fam;
  end loop;

  if cardinality(v_q) = 0 then
    return jsonb_build_object('customer_type', v_type, 'items', '[]'::jsonb, 'ties', 0,
      'note', 'The query has no product words to match. Ask for the model, chambering, barrel length or colour.');
  end if;
  select sum(w) into v_wsum from unnest(v_ws) w;

  with qt as (
    select * from unnest(v_q, v_alts, v_pfxs, v_res, v_ws, v_qc, v_qf)
      as q(tok, alt, pfx, re, w, is_cham, is_fam)
  ),
  priced as (
    select i.part_id,
           jsonb_agg(jsonb_build_object(
             'price_list_id',   l.id,
             'price_list_name', l.name,
             'is_special',      l.is_special,
             'unit_price',      i.unit_price,
             'promo_buy_qty',   l.promo_buy_qty,
             'promo_get_qty',   l.promo_get_qty)
             order by l.is_special, l.effective_from desc, l.id) as options,
           min(i.description) as list_description
    from public.effective_price_lists(v_type) l
    join public.price_list_items i on i.price_list_id = l.id
    group by i.part_id
  ),
  docs as (
    select pr.part_id, pr.options, pr.list_description, dp.*,
           string_to_array(public.order_search_normalize(concat_ws(' ',
             pr.part_id, coalesce(dp.part_description, pr.list_description),
             nullif(upper(btrim(dp.product_family)), 'N/A'), dp.product_code,
             nullif(upper(btrim(dp.chambering)), 'N/A'), nullif(upper(btrim(dp.barrel_length)), 'N/A'),
             nullif(upper(btrim(dp.finish)), 'N/A'), nullif(upper(btrim(dp.stock_color)), 'N/A'),
             nullif(upper(btrim(dp.stock_style)), 'N/A'), nullif(upper(btrim(dp.handguard)), 'N/A'),
             case upper(btrim(dp.handedness)) when 'LEFT' then 'lh' when 'RIGHT' then 'rh' end)), ' ') as toks,
           array(select jsonb_array_elements_text(coalesce(v_fam_map -> upper(btrim(dp.product_family)), '[]'::jsonb))) as fam,
           array(select jsonb_array_elements_text(coalesce(v_cham_map -> upper(btrim(dp.chambering)), '[]'::jsonb))) as cham
    from priced pr
    left join lateral (
      select p.part_key, p.part_description, p.product_family, p.product_code, p.chambering,
             p.barrel_length, p.finish, p.stock_color, p.stock_style, p.handguard, p.handedness,
             p.status, p.is_kit_flag
      from erp.dim_part p
      where p.part_id = pr.part_id
      order by p.part_key
      limit 1) dp on true
  ),
  scored as (
    select d.*, m.matched, m.weighted,
           -- The request names a chambering / family: a part in another one
           -- is not a candidate for the tie, whatever else it matches.
           (not v_has_cham or m.cham_hit) as cham_ok,
           (not v_has_fam  or m.fam_hit)  as fam_ok,
           (cardinality(d.fam) > 0
            and not exists (select 1 from unnest(d.fam) f
                            where not exists (select 1 from qt
                                              where f = qt.tok or f = qt.alt
                                                 or starts_with(f, qt.pfx) or f ~ qt.re))) as family_hit
    from docs d
    cross join lateral (
      select count(*) filter (where h.hit) as matched,
             coalesce(sum(h.w) filter (where h.hit), 0) as weighted,
             coalesce(bool_or(h.cham_hit), false) as cham_hit,
             coalesce(bool_or(h.fam_hit), false)  as fam_hit
      from (
        select qt.w,
               exists (select 1 from unnest(d.toks) t
                       where t = qt.tok or t = qt.alt or starts_with(t, qt.pfx) or t ~ qt.re) as hit,
               qt.is_cham and exists (select 1 from unnest(d.cham) t
                       where t = qt.tok or t = qt.alt or starts_with(t, qt.pfx) or t ~ qt.re) as cham_hit,
               qt.is_fam and exists (select 1 from unnest(d.fam) t
                       where t = qt.tok or t = qt.alt or starts_with(t, qt.pfx) or t ~ qt.re) as fam_hit
        from qt) h
    ) m
  ),
  ranked as (
    select s.*,
           (s.cham_ok and s.fam_ok) as fits,
           round(s.weighted::numeric / v_wsum, 3) as match_score,
           max(s.weighted) filter (where s.cham_ok and s.fam_ok) over () as top_weighted,
           row_number() over (order by (s.cham_ok and s.fam_ok) desc, s.weighted desc, s.family_hit desc,
                                       (coalesce(s.status, '') = 'A') desc, s.part_id) as rn
    from scored s
    where s.matched > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'part_id',       r.part_id,
           'description',   coalesce(r.part_description, r.list_description),
           'family',        r.product_family,
           'chambering',    r.chambering,
           'barrel_length', r.barrel_length,
           'finish',        r.finish,
           'stock_color',   r.stock_color,
           'handedness',    r.handedness,
           'status',        r.status,
           'is_kit',        coalesce(r.is_kit_flag = 'Y', false),
           'requires_ffl',  public.part_requires_ffl(r.part_id),
           'match_score',   r.match_score,
           'fits_request',  r.fits,
           'options',       r.options,
           'stock', jsonb_build_object(
              'ats_qty',   (select sum(a.available_to_sell_qty) from erp.fact_available_to_sell a
                            where a.part_key = r.part_key),
              'warehouse', (select min(a.shippable_warehouse_id) from erp.fact_available_to_sell a
                            where a.part_key = r.part_key)))
           order by r.rn), '[]'::jsonb),
         max(r.match_score) filter (where r.rn = 1),
         count(*) filter (where r.fits and r.weighted = r.top_weighted),
         coalesce(bool_or(r.fits) filter (where r.rn = 1), false)
    into v_items, v_top, v_ties, v_fits
  from ranked r
  where r.rn <= v_lim;

  return jsonb_build_object(
    'customer_type', v_type,
    'items', v_items,
    'ties', coalesce(v_ties, 0),
    'note', case
      when jsonb_array_length(v_items) = 0 then
        'No product priced for this account matches. Try other words, or check the account''s price list.'
      when not v_fits then
        'Nothing priced for this account is in the chambering or model asked for; these are only the closest. Tell the user and ask before drafting.'
      when v_ties > 1 then
        format('%s products match equally well (score %s). Ask the user one short question to pick (e.g. barrel length, handedness, colour).', v_ties, v_top)
      when v_top < 1 then
        'The best match does not cover every word in the request. Confirm it with the user before drafting.'
      else 'One clear best match.'
    end);
end;
$$;

revoke execute on function public.order_product_search(text, text, int) from public, anon;
grant execute on function public.order_product_search(text, text, int) to authenticated;

comment on function public.order_product_search(text, text, int) is
  'Free-text product match ("one 6.5 Creedmoor Ridgeline FFT in black and grey") '
  'over the parts priced on a list effective for this account. Query and part '
  'text go through order_search_normalize (order_product_synonyms). Chambering '
  'and family words weigh 3, other words 1; a part in another chambering or '
  'family than the one named never ties (fits_request=false). match_score = '
  'weighted share of query words matched; ties = equally good fitting parts. '
  'RLS-scoped (SECURITY INVOKER).';

--------------------------------------------------------------------------
-- 4. Internal helpers for the write RPCs (not callable by clients)
--------------------------------------------------------------------------

-- Shape check: only known keys; price and FFL inputs do not exist.
create or replace function public.mcp_order_check_keys(p jsonb, p_update boolean)
returns void
language plpgsql immutable set search_path = public
as $$
declare
  c_top  constant text[] := array['idempotency_key','customer_key','ship_to_key','po_number',
                                  'requested_ship_date','customer_contact_key','notes',
                                  'allow_duplicate','source_ref','lines'];
  c_line constant text[] := array['part_id','qty','price_list_id'];
  c_price constant text[] := array['unit_price','price','prices','discount_pct','effective_unit_price',
                                   'line_total','total_amount','total'];
  c_ffl  constant text[] := array['ffl_license_number','ffl_expires_on','ffl','ffl_number'];
  k text;
  l jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_input:body: the request must be a JSON object';
  end if;
  for k in select jsonb_object_keys(p) loop
    if k = any (c_price) then
      raise exception 'invalid_input:%: prices are set by the server from the published price list', k;
    elsif k = any (c_ffl) then
      raise exception 'invalid_input:%: an FFL is never supplied here; the licence on file is used, or the person submitting enters one in the portal', k;
    elsif not (k = any (c_top)) then
      raise exception 'invalid_input:unknown_field:%: not an order field', k;
    end if;
  end loop;
  if jsonb_typeof(p -> 'lines') = 'array' then
    for l in select jsonb_array_elements(p -> 'lines') loop
      if jsonb_typeof(l) <> 'object' then
        raise exception 'invalid_input:lines: every line must be an object {part_id, qty, price_list_id?}';
      end if;
      for k in select jsonb_object_keys(l) loop
        if k = any (c_price) then
          raise exception 'invalid_input:%: prices are set by the server from the published price list', k;
        elsif k = any (c_ffl) then
          raise exception 'invalid_input:%: an FFL is never supplied here', k;
        elsif not (k = any (c_line)) then
          raise exception 'invalid_input:unknown_field:%: not a line field (part_id, qty, price_list_id)', k;
        end if;
      end loop;
    end loop;
  end if;
end;
$$;

-- Build the draft preview: re-read the order, dry-run submit_order inside a
-- subtransaction that is always rolled back, and collect warnings.
create or replace function public.mcp_order_preview(p_order_id bigint, p_replayed boolean)
returns jsonb
language plpgsql security definer set search_path = public, erp
as $$
declare
  c_ok    constant text := '__mcp_dry_run_ok__';
  o       public.orders;
  v_ok    boolean := false;
  v_err   text;
  v_lines jsonb;
  v_total numeric;
  v_ship  erp.dim_ship_to;
  v_has_ship boolean := false;
  v_cust  record;
  v_needs boolean;
  v_cur   boolean := false;
  v_onf   boolean := false;
  v_contact jsonb;
  v_warn  text[] := '{}';
  v_n_ok  int;
  v_dry   text;
  r       record;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    raise exception 'order_not_found: order % not found', p_order_id;
  end if;

  if o.status = 'draft' then
    -- submit_order refuses an MCP session unless this dry-run flag is on.
    -- Set OUTSIDE the subtransaction (so the sentinel rollback cannot undo
    -- it) and put back right after it.
    v_dry := current_setting('app.mcp_dry_run', true);
    perform set_config('app.mcp_dry_run', 'on', true);
    begin
      perform public.submit_order(p_order_id, true);
      select jsonb_agg(jsonb_build_object(
               'part_id', l.part_id, 'description', l.description, 'qty', l.qty,
               'price_list_id', l.price_list_id, 'price_list_name', pl.name,
               'unit_price', l.unit_price, 'discount_pct', l.discount_pct,
               'effective_unit_price', l.effective_unit_price, 'line_total', l.line_total)
               order by l.id),
             sum(l.line_total)
        into v_lines, v_total
      from public.order_lines l join public.price_lists pl on pl.id = l.price_list_id
      where l.order_id = p_order_id;
      raise exception using message = c_ok;
    exception when others then
      if sqlerrm = c_ok then
        v_ok := true;
      else
        v_ok := false;
        v_err := sqlerrm;
        v_lines := null;
        v_total := null;
      end if;
    end;
    perform set_config('app.mcp_dry_run', coalesce(v_dry, ''), true);
  else
    v_err := format('order %s is %s; only drafts can be submitted', p_order_id, o.status);
  end if;

  if v_lines is null then
    select jsonb_agg(jsonb_build_object(
             'part_id', l.part_id, 'description', l.description, 'qty', l.qty,
             'price_list_id', l.price_list_id, 'price_list_name', pl.name,
             'unit_price', l.unit_price, 'discount_pct', l.discount_pct,
             'effective_unit_price', l.effective_unit_price, 'line_total', l.line_total)
             order by l.id),
           sum(l.line_total)
      into v_lines, v_total
    from public.order_lines l join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = p_order_id;
  end if;

  -- Stock never blocks; it is reported per line.
  select coalesce(jsonb_agg(x.line || jsonb_build_object('ats_qty', x.ats) order by x.ord), '[]'::jsonb)
    into v_lines
  from (
    select e.line, e.ord,
           (select sum(a.available_to_sell_qty)
              from erp.fact_available_to_sell a
              join erp.dim_part dp on dp.part_key = a.part_key
             where dp.part_id = e.line ->> 'part_id') as ats
    from jsonb_array_elements(coalesce(v_lines, '[]'::jsonb)) with ordinality as e(line, ord)
  ) x;

  for r in
    select e.line ->> 'part_id' as part_id, (e.line ->> 'qty')::int as qty,
           (e.line ->> 'ats_qty')::numeric as ats,
           (select min(dp.status) from erp.dim_part dp where dp.part_id = e.line ->> 'part_id') as status
    from jsonb_array_elements(v_lines) as e(line)
  loop
    if r.ats is null or r.ats < r.qty then
      v_warn := v_warn || format('Stock: %s has %s available to sell; %s ordered. Stock does not block the order.',
                                 r.part_id, coalesce(trim_scale(r.ats)::text, 'no'), r.qty);
    end if;
    if r.status is distinct from 'A' then
      v_warn := v_warn || format('%s is not an active part in the ERP (status %s).', r.part_id, coalesce(r.status, 'unknown'));
    end if;
  end loop;

  select dc.customer_name, dc.credit_status, dc.active_flag into v_cust
  from erp.dim_customer dc where dc.customer_key = o.customer_key;
  if upper(coalesce(v_cust.active_flag, 'Y')) = 'N' then
    v_warn := v_warn || 'The account is inactive in the ERP.'::text;
  end if;
  if upper(coalesce(v_cust.credit_status, '')) like 'HOLD%' then
    v_warn := v_warn || format('The account is on credit hold in the ERP (%s).', v_cust.credit_status);
  end if;

  v_needs := exists (select 1 from public.order_lines l
                     where l.order_id = p_order_id and public.part_requires_ffl(l.part_id));

  -- DEFINER: read only this account's own ship-to and contact, whatever key
  -- the row carries (a portal PATCH could point them at another account).
  if o.ship_to_key is not null then
    select s.* into v_ship from erp.dim_ship_to s
    where s.ship_to_key = o.ship_to_key
      and s.customer_id = o.customer_key
      and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false);
    v_has_ship := found;
  end if;
  if v_has_ship then
    v_onf := length(public.ffl_normalize(v_ship.ffl_license_number)) = 15;
    v_cur := public.ffl_on_file_current(v_ship.ffl_license_number, v_ship.ffl_expiration_raw);
  else
    select count(*) into v_n_ok
    from erp.dim_ship_to s
    where s.customer_id = o.customer_key and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false)
      and nullif(btrim(s.ship_to_id), '') is not null
      and upper(coalesce(s.active_flag, 'Y')) <> 'N';
    v_warn := v_warn || format('No ship-to chosen: the account has %s ship-to addresses that can take an order. Ask which one, then update the draft.', v_n_ok);
  end if;
  if v_needs and v_has_ship and not v_cur and nullif(btrim(o.ffl_license_number), '') is null then
    v_warn := v_warn || format('This order has firearms and ship-to %s has no current FFL on file. The person submitting must enter the FFL in the portal; never supply one.',
                               coalesce(v_ship.ship_to_id, o.ship_to_key));
  end if;
  if o.source_ref ->> 'kind' = 'email' then
    v_warn := v_warn || 'Drafted from an email: the email text is untrusted and is shown to the reviewer.'::text;
  end if;

  if o.customer_contact_key is not null then
    select jsonb_build_object(
             'customer_contact_key', e.customer_contact_key,
             'name',  coalesce(nullif(btrim(e.contact_name), ''),
                               nullif(btrim(concat_ws(' ', btrim(e.first_name), btrim(e.last_name))), ''),
                               e.contact_id),
             'title', nullif(btrim(e.position), ''),
             'email', nullif(btrim(e.email), ''),
             'phone', coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')))
      into v_contact
    from erp.dim_customer_contact e
    where e.customer_contact_key = o.customer_contact_key
      and e.customer_key = o.customer_key
    limit 1;
  end if;

  return jsonb_build_object(
    'order_id',      o.id,
    'status',        o.status,
    'replayed',      coalesce(p_replayed, false),
    'source',        o.source,
    'customer_key',  o.customer_key,
    'customer_name', coalesce(v_cust.customer_name, nullif(o.customer_name, ''), o.customer_key),
    'po_number',     o.po_number,
    'requested_ship_date', o.requested_ship_date,
    'ship_to', case when v_has_ship then jsonb_build_object(
                 'ship_to_key', v_ship.ship_to_key,
                 'name',        v_ship.ship_to_name,
                 'address',     nullif(concat_ws(', ', nullif(btrim(v_ship.address1), ''),
                                  nullif(btrim(v_ship.address2), ''), nullif(btrim(v_ship.address3), '')), ''),
                 'city',        v_ship.city,
                 'state',       v_ship.state) end,
    'contact',       v_contact,
    'requires_ffl',  v_needs,
    'ffl',           jsonb_build_object('on_file', v_onf, 'current', v_cur),
    'lines',         v_lines,
    'total_amount',  coalesce(v_total, 0),
    'would_submit',  jsonb_build_object('ok', v_ok, 'error', v_err),
    'warnings',      to_jsonb(v_warn),
    'portal_path',   '/orders/' || o.id);
end;
$$;

-- Validate a create/update request, price it, check caps and duplicates,
-- and write the draft. Returns the order id. p_order_id null = create.
create or replace function public.mcp_order_apply(
  p_order_id bigint,
  p          jsonb,
  p_params   jsonb,
  p_idem_key text,
  p_hash     text
)
returns bigint
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_uid      uuid := auth.uid();
  v_guc      text := current_setting('app.mcp_order_write', true);
  v_max_lines int     := coalesce((p_params ->> 'max_lines')::int, 40);
  v_max_units int     := coalesce((p_params ->> 'max_units_per_line')::int, 200);
  v_max_value numeric := coalesce((p_params ->> 'max_order_value')::numeric, 250000);
  v_max_day   int     := coalesce((p_params ->> 'max_drafts_per_user_per_day')::int, 25);
  v_window    int     := coalesce((p_params ->> 'duplicate_window_days')::int, 14);
  v_cur      public.orders;
  v_ck       text;
  v_cust     record;
  v_ship     erp.dim_ship_to;
  v_ship_key text;
  v_n        int;
  v_po       text;
  v_date     date;
  v_contact  text;
  v_notes    text;
  v_allow    boolean := false;
  v_ref      jsonb;
  v_line     jsonb;
  v_part     text;
  v_qty      numeric;
  v_plid     bigint;
  v_item     record;
  v_priced   jsonb := '[]'::jsonb;
  v_total    numeric;
  v_set      jsonb;
  v_dup      bigint;
  v_tok      uuid;
  v_id       bigint;
  k          text;
begin
  if p_order_id is not null then
    select * into v_cur from public.orders where id = p_order_id;
  end if;

  -- Customer, and the caller's right to draft for it (DEFINER bypasses RLS,
  -- so the read policy is restated: admin, or the account is on my book).
  if p ? 'customer_key' and jsonb_typeof(p -> 'customer_key') <> 'null' then
    if jsonb_typeof(p -> 'customer_key') <> 'string' or btrim(p ->> 'customer_key') = '' then
      raise exception 'invalid_input:customer_key: a customer_key string is required';
    end if;
    v_ck := btrim(p ->> 'customer_key');
  else
    v_ck := v_cur.customer_key;
  end if;
  if v_ck is null then
    raise exception 'invalid_input:customer_key: a customer_key is required';
  end if;
  select dc.customer_key, dc.customer_name, dc.customer_type into v_cust
  from erp.dim_customer dc where dc.customer_key = v_ck;
  if not found
     or not (public.is_admin() or v_ck in (select public.my_customer_keys())) then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', v_ck;
  end if;

  -- Ship-to: a given one must be an orderable ship-to of this account;
  -- none given and exactly one orderable = that one; otherwise the draft
  -- has no ship-to and the preview says so.
  if p ? 'ship_to_key' and jsonb_typeof(p -> 'ship_to_key') <> 'null' then
    if jsonb_typeof(p -> 'ship_to_key') <> 'string' then
      raise exception 'invalid_input:ship_to_key: must be a string';
    end if;
    v_ship_key := btrim(p ->> 'ship_to_key');
    select s.* into v_ship from erp.dim_ship_to s
    where s.ship_to_key = v_ship_key
      and s.customer_id = v_ck
      and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false)
      and nullif(btrim(s.ship_to_id), '') is not null;
    if not found then
      raise exception 'ship_to_invalid:%: not one of this account''s ship-to addresses', v_ship_key;
    end if;
    if upper(coalesce(v_ship.active_flag, 'Y')) = 'N' then
      raise exception 'ship_to_invalid:%: the ship-to % is inactive in the ERP; pick another', v_ship_key, v_ship.ship_to_id;
    end if;
  else
    select count(*), min(s.ship_to_key) into v_n, v_ship_key
    from erp.dim_ship_to s
    where s.customer_id = v_ck and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false)
      and nullif(btrim(s.ship_to_id), '') is not null
      and upper(coalesce(s.active_flag, 'Y')) <> 'N';
    if v_n <> 1 then
      v_ship_key := null;
    end if;
  end if;

  if p ? 'po_number' and jsonb_typeof(p -> 'po_number') <> 'null' then
    if jsonb_typeof(p -> 'po_number') not in ('string', 'number') then
      raise exception 'invalid_input:po_number: must be text';
    end if;
    v_po := nullif(btrim(p ->> 'po_number'), '');
    if length(v_po) > 40 then
      raise exception 'invalid_input:po_number: 40 characters at most';
    end if;
  end if;

  if p ? 'requested_ship_date' and jsonb_typeof(p -> 'requested_ship_date') <> 'null' then
    begin
      if jsonb_typeof(p -> 'requested_ship_date') <> 'string'
         or (p ->> 'requested_ship_date') !~ '^\d{4}-\d{2}-\d{2}$' then
        raise exception 'bad';
      end if;
      v_date := (p ->> 'requested_ship_date')::date;
    exception when others then
      raise exception 'invalid_input:requested_ship_date: use YYYY-MM-DD';
    end;
    if v_date < current_date then
      raise exception 'invalid_input:requested_ship_date: % is in the past', v_date;
    end if;
  end if;

  if p ? 'customer_contact_key' and jsonb_typeof(p -> 'customer_contact_key') <> 'null' then
    v_contact := btrim(p ->> 'customer_contact_key');
    if jsonb_typeof(p -> 'customer_contact_key') <> 'string'
       or not exists (select 1 from erp.dim_customer_contact e
                      where e.customer_contact_key = v_contact and e.customer_key = v_ck
                        and coalesce(e.contact_active_flag, 'Y') = 'Y') then
      raise exception 'invalid_input:customer_contact_key: not an active contact on this account';
    end if;
  end if;

  if p ? 'notes' and jsonb_typeof(p -> 'notes') <> 'null' then
    if jsonb_typeof(p -> 'notes') <> 'string' then
      raise exception 'invalid_input:notes: must be text';
    end if;
    v_notes := nullif(btrim(p ->> 'notes'), '');
    if length(v_notes) > 1000 then
      raise exception 'invalid_input:notes: 1000 characters at most';
    end if;
  end if;

  if p ? 'allow_duplicate' and jsonb_typeof(p -> 'allow_duplicate') <> 'null' then
    if jsonb_typeof(p -> 'allow_duplicate') <> 'boolean' then
      raise exception 'invalid_input:allow_duplicate: must be true or false';
    end if;
    v_allow := (p -> 'allow_duplicate')::boolean;
  end if;

  if p ? 'source_ref' and jsonb_typeof(p -> 'source_ref') <> 'null' then
    v_ref := p -> 'source_ref';
    if jsonb_typeof(v_ref) <> 'object' or v_ref ->> 'kind' is distinct from 'email' then
      raise exception 'invalid_input:source_ref: must be {kind:"email", sender, subject, received_at, excerpt}';
    end if;
    for k in select jsonb_object_keys(v_ref) loop
      if not (k = any (array['kind','sender','subject','received_at','excerpt','message_id']))
         or jsonb_typeof(v_ref -> k) not in ('string', 'null') then
        raise exception 'invalid_input:source_ref: field % is not allowed or not text', k;
      end if;
    end loop;
    if length(v_ref ->> 'excerpt') > 4000 then
      raise exception 'invalid_input:source_ref: excerpt is 4000 characters at most';
    end if;
    if greatest(length(v_ref ->> 'sender'), length(v_ref ->> 'subject'),
                length(v_ref ->> 'received_at'), length(v_ref ->> 'message_id')) > 500 then
      raise exception 'invalid_input:source_ref: sender, subject, received_at and message_id are 500 characters at most';
    end if;
  end if;

  -- Lines: price every one on the server.
  if jsonb_typeof(p -> 'lines') is distinct from 'array' or jsonb_array_length(p -> 'lines') = 0 then
    raise exception 'invalid_input:lines: at least one line {part_id, qty} is required';
  end if;
  if jsonb_array_length(p -> 'lines') > v_max_lines then
    raise exception 'too_many_lines: % lines; % at most', jsonb_array_length(p -> 'lines'), v_max_lines;
  end if;

  for v_line in select jsonb_array_elements(p -> 'lines') loop
    if jsonb_typeof(v_line -> 'part_id') is distinct from 'string' or btrim(v_line ->> 'part_id') = '' then
      raise exception 'invalid_input:part_id: every line needs a part_id';
    end if;
    v_part := btrim(v_line ->> 'part_id');
    if jsonb_typeof(v_line -> 'qty') is distinct from 'number' then
      raise exception 'invalid_input:qty: line % needs a whole-number qty', v_part;
    end if;
    v_qty := (v_line ->> 'qty')::numeric;
    if v_qty <> trunc(v_qty) then
      raise exception 'invalid_input:qty: line % needs a whole-number qty', v_part;
    end if;
    if v_qty < 1 or v_qty > v_max_units then
      raise exception 'qty_out_of_range:%: qty % is outside 1-%', v_part, v_qty, v_max_units;
    end if;
    v_plid := null;
    if v_line ? 'price_list_id' and jsonb_typeof(v_line -> 'price_list_id') <> 'null' then
      if jsonb_typeof(v_line -> 'price_list_id') <> 'number'
         or (v_line ->> 'price_list_id')::numeric <> trunc((v_line ->> 'price_list_id')::numeric) then
        raise exception 'invalid_input:price_list_id: line % has a price_list_id that is not a whole number', v_part;
      end if;
      v_plid := (v_line ->> 'price_list_id')::bigint;
    end if;

    if exists (select 1 from erp.dim_part dp where dp.part_id = v_part and dp.is_kit_flag = 'Y') then
      raise exception 'kit_not_supported:%: kits cannot be ordered here', v_part;
    end if;

    select l.id as list_id, l.name as list_name, i.id as item_id, i.unit_price, i.description
      into v_item
    from public.effective_price_lists(v_cust.customer_type) l
    join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_part
    where (v_plid is null and not l.is_special) or l.id = v_plid
    order by l.effective_from desc, l.id
    limit 1;
    if not found then
      if v_plid is null then
        raise exception 'part_not_orderable:%: not on this account''s price list', v_part;
      end if;
      raise exception 'part_not_orderable:%: not on price list % (or that list is not effective for this account)', v_part, v_plid;
    end if;

    if exists (select 1 from jsonb_array_elements(v_priced) e
               where e ->> 'part_id' = v_part and (e ->> 'price_list_id')::bigint = v_item.list_id) then
      raise exception 'invalid_input:duplicate_line:%: the part appears twice on the same price list; send one line with the total qty', v_part;
    end if;

    v_priced := v_priced || jsonb_build_object(
      'part_id', v_part, 'qty', v_qty::int, 'price_list_id', v_item.list_id,
      'item_id', v_item.item_id, 'unit_price', v_item.unit_price,
      'description', coalesce(v_item.description,
                              (select min(dp.part_description) from erp.dim_part dp where dp.part_id = v_part)));
  end loop;

  -- The same promo formula as submit_order (which re-runs it authoritatively).
  with x as (
    select * from jsonb_to_recordset(v_priced)
      as (part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric, description text)
  ),
  pct as (
    select x.price_list_id,
           case when pl.promo_buy_qty is null then 0::numeric
                else round(100 * (floor(sum(x.qty)::numeric / (pl.promo_buy_qty + pl.promo_get_qty))
                                  * pl.promo_get_qty) / sum(x.qty)::numeric, 4)
           end as discount_pct
    from x join public.price_lists pl on pl.id = x.price_list_id
    group by x.price_list_id, pl.promo_buy_qty, pl.promo_get_qty
  )
  select jsonb_agg(to_jsonb(x) || jsonb_build_object(
           'discount_pct', pct.discount_pct,
           'effective_unit_price', round(x.unit_price * (1 - pct.discount_pct / 100), 2))),
         sum(x.qty * round(x.unit_price * (1 - pct.discount_pct / 100), 2)),
         (select jsonb_agg(jsonb_build_array(s.part_id, s.q) order by s.part_id)
            from (select x2.part_id, sum(x2.qty) as q from x x2 group by x2.part_id) s)
    into v_priced, v_total, v_set
  from x join pct using (price_list_id);

  if v_total > v_max_value then
    raise exception 'order_value_cap: the order totals %; drafts over MCP are capped at %', v_total, v_max_value;
  end if;

  -- One draft write per user at a time: the cap and the duplicate probe
  -- below are check-then-insert, and models do issue parallel tool calls.
  perform pg_advisory_xact_lock(hashtextextended('mcp_order_apply|' || v_uid::text, 0));

  if p_order_id is null then
    select count(*) into v_n
    from public.orders o
    where o.created_by = v_uid and o.source <> 'portal'
      and o.created_at >= date_trunc('day', now());
    if v_n >= v_max_day then
      raise exception 'daily_draft_cap: % drafts today; % per day at most', v_n, v_max_day;
    end if;
  end if;

  -- Duplicate block: a model that retries usually invents a new key.
  if not v_allow then
    select o.id into v_dup
    from public.orders o
    where o.user_id = coalesce(v_cur.user_id, v_uid)
      and o.customer_key = v_ck
      and o.status <> 'cancelled'
      and o.created_at >= now() - make_interval(days => v_window)
      and o.id is distinct from p_order_id
      and (   (v_po is not null and upper(btrim(o.po_number)) = upper(v_po))
           or v_set = (select jsonb_agg(jsonb_build_array(s.part_id, s.q) order by s.part_id)
                       from (select l.part_id, sum(l.qty) as q from public.order_lines l
                             where l.order_id = o.id group by l.part_id) s))
    order by o.created_at desc, o.id desc
    limit 1;
    if v_dup is not null then
      raise exception 'possible_duplicate:%: order % for this account has the same PO or the same lines; ask the user, then send allow_duplicate=true to draft anyway', v_dup, v_dup;
    end if;
  end if;

  perform set_config('app.mcp_order_write', 'on', true);

  if p_order_id is null then
    if (auth.jwt() -> 'app_metadata' ->> 'mcp_token_id')
         ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_tok := (auth.jwt() -> 'app_metadata' ->> 'mcp_token_id')::uuid;
    end if;
    begin
      insert into public.orders (
        user_id, created_by, customer_key, customer_name, customer_type, status, source,
        po_number, requested_ship_date, notes, ship_to_key, customer_contact_key,
        source_ref, mcp_token_id, client_request_id, request_hash)
      values (
        v_uid, v_uid, v_ck, coalesce(v_cust.customer_name, ''), v_cust.customer_type, 'draft', 'mcp',
        v_po, v_date, v_notes, v_ship_key, v_contact,
        v_ref, v_tok, p_idem_key, p_hash)
      returning id into v_id;
    exception when unique_violation then
      raise exception 'idempotency_conflict: a request with this idempotency_key is already being processed; retry';
    end;
  else
    v_id := p_order_id;
    update public.orders
    set customer_key         = v_ck,
        customer_name        = coalesce(v_cust.customer_name, ''),
        customer_type        = v_cust.customer_type,
        po_number            = v_po,
        requested_ship_date  = v_date,
        notes                = v_notes,
        ship_to_key          = v_ship_key,
        customer_contact_key = v_contact,
        source_ref           = coalesce(v_ref, source_ref)
    where id = v_id;
    delete from public.order_lines where order_id = v_id;
  end if;

  insert into public.order_lines (order_id, price_list_id, price_list_item_id, part_id, description,
                                  qty, unit_price, discount_pct, effective_unit_price)
  select v_id, x.price_list_id, x.item_id, x.part_id, x.description,
         x.qty, x.unit_price, x.discount_pct, x.effective_unit_price
  from jsonb_to_recordset(v_priced)
    as x(part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
         description text, discount_pct numeric, effective_unit_price numeric);

  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);
  return v_id;
end;
$$;

-- Store the preview's warnings on the order for the reviewer.
create or replace function public.mcp_order_store_warnings(p_order_id bigint, p_preview jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_guc text := current_setting('app.mcp_order_write', true);
begin
  perform set_config('app.mcp_order_write', 'on', true);
  update public.orders set mcp_warnings = coalesce(p_preview -> 'warnings', '[]'::jsonb)
  where id = p_order_id;
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);
end;
$$;

revoke execute on function public.mcp_order_check_keys(jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.mcp_order_preview(bigint, boolean) from public, anon, authenticated;
revoke execute on function public.mcp_order_apply(bigint, jsonb, jsonb, text, text) from public, anon, authenticated;
revoke execute on function public.mcp_order_store_warnings(bigint, jsonb) from public, anon, authenticated;

--------------------------------------------------------------------------
-- 5. The write RPCs
--------------------------------------------------------------------------
create or replace function public.mcp_create_order_draft(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_params  jsonb;
  v_key     text;
  v_hash    text;
  v_old     record;
  v_id      bigint;
  v_preview jsonb;
begin
  v_params := public.mcp_orders_gate();
  perform public.mcp_order_check_keys(p, false);

  if jsonb_typeof(p -> 'idempotency_key') is distinct from 'string'
     or (p ->> 'idempotency_key') !~ '^[!-~]{8,100}$' then
    raise exception 'invalid_input:idempotency_key: 8-100 printable characters, no spaces; reuse it when retrying the same request';
  end if;
  v_key  := p ->> 'idempotency_key';
  v_hash := encode(sha256(convert_to((p - 'idempotency_key')::text, 'UTF8')), 'hex');

  select o.id, o.request_hash into v_old
  from public.orders o
  where o.user_id = auth.uid() and o.client_request_id = v_key;
  if found then
    if v_old.request_hash is distinct from v_hash then
      raise exception 'idempotency_conflict: idempotency_key % was already used for a different request (order %); use a new key for a new order', v_key, v_old.id;
    end if;
    return public.mcp_order_preview(v_old.id, true);
  end if;

  v_id := public.mcp_order_apply(null, p, v_params, v_key, v_hash);
  v_preview := public.mcp_order_preview(v_id, false);
  perform public.mcp_order_store_warnings(v_id, v_preview);
  return v_preview;
end;
$$;

create or replace function public.mcp_update_order_draft(p_order_id bigint, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_params  jsonb;
  v_order   public.orders;
  v_preview jsonb;
begin
  v_params := public.mcp_orders_gate();
  perform public.mcp_order_check_keys(p, true);

  select * into v_order from public.orders where id = p_order_id for update;
  -- Own drafts only, admin or not: a prompt-injected session should not
  -- reach anyone else's drafts. An admin manages others' in the portal.
  if not found or v_order.user_id is distinct from auth.uid() then
    raise exception 'order_not_found: order % not found', p_order_id;
  end if;
  if v_order.source = 'portal' then
    raise exception 'order_not_mcp: order % was typed in the portal; change it there', p_order_id;
  end if;
  if v_order.status <> 'draft' then
    raise exception 'order_not_draft: order % is %; only drafts can be changed', p_order_id, v_order.status;
  end if;

  perform public.mcp_order_apply(p_order_id, p - 'idempotency_key', v_params, null, null);
  v_preview := public.mcp_order_preview(p_order_id, false);
  perform public.mcp_order_store_warnings(p_order_id, v_preview);
  return v_preview;
end;
$$;

create or replace function public.mcp_cancel_order_draft(p_order_id bigint)
returns jsonb
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_order public.orders;
  v_guc   text;
begin
  perform public.mcp_orders_gate();

  select * into v_order from public.orders where id = p_order_id for update;
  -- Own drafts only, admin or not: a prompt-injected session should not
  -- reach anyone else's drafts. An admin manages others' in the portal.
  if not found or v_order.user_id is distinct from auth.uid() then
    raise exception 'order_not_found: order % not found', p_order_id;
  end if;
  if v_order.source = 'portal' then
    raise exception 'order_not_mcp: order % was typed in the portal; cancel it there', p_order_id;
  end if;
  if v_order.status <> 'draft' then
    raise exception 'order_not_draft: order % is %; only drafts can be cancelled over MCP', p_order_id, v_order.status;
  end if;

  v_guc := current_setting('app.mcp_order_write', true);
  perform set_config('app.mcp_order_write', 'on', true);
  update public.orders set status = 'cancelled' where id = p_order_id;
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);
  return jsonb_build_object('order_id', p_order_id, 'status', 'cancelled');
end;
$$;

revoke execute on function public.mcp_create_order_draft(jsonb) from public, anon;
revoke execute on function public.mcp_update_order_draft(bigint, jsonb) from public, anon;
revoke execute on function public.mcp_cancel_order_draft(bigint) from public, anon;
grant execute on function public.mcp_create_order_draft(jsonb) to authenticated;
grant execute on function public.mcp_update_order_draft(bigint, jsonb) to authenticated;
grant execute on function public.mcp_cancel_order_draft(bigint) to authenticated;

comment on function public.mcp_create_order_draft(jsonb) is
  'MCP only (mcp_orders_gate). Creates a DRAFT from {idempotency_key, customer_key, '
  'ship_to_key?, po_number?, requested_ship_date?, customer_contact_key?, notes?, '
  'allow_duplicate?, source_ref?, lines:[{part_id, qty, price_list_id?}]}; prices '
  'on the server; dry-runs submit_order; returns the preview. Never submits.';
comment on function public.mcp_update_order_draft(bigint, jsonb) is
  'MCP only. Replaces header and lines of the caller''s MCP draft; returns the preview.';
comment on function public.mcp_cancel_order_draft(bigint) is
  'MCP only. Cancels the caller''s MCP draft (drafts only).';
