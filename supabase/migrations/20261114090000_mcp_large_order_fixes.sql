/*============================================================================
  20261114090000_mcp_large_order_fixes.sql
  Purpose: fixes found staging a 195-line distributor PO (Sports South
           215647) through the Rep Portal MCP order tools. Follows
           20261113090000_inside_sales_and_order_documents.

  Deploy: through etl/deploy_migrations.py only, BEFORE the edge function
  that uses the new fields. Runs under lock_timeout 10s: a timeout means
  NOTHING was applied; re-run it outside the ETL windows.

  Each numbered section below is one fix. Restated function bodies are the
  latest deployed ones with only the changes named in their section.
============================================================================*/

set local lock_timeout = '10s';

--------------------------------------------------------------------------
-- 1. resolve: PO lines -> parts (order_resolve_parts)
--    * "permission denied for table dim_part": the description fallback
--      selected dim_part.* under SECURITY INVOKER, which includes the cost
--      columns revoked from authenticated (20260901190300). It now names
--      its columns.
--    * UPC: an item may carry the PO's UPC/EAN/GTIN (`upc`), and a 12-14
--      digit `ref` is read as one. Match kind 'upc'; per item upc_check
--      (agrees / disagrees / upc_only / not_found / invalid). A UPC that
--      names a different part than the item number makes the item
--      ambiguous (check_reasons ["upc_disagrees"]).
--    * Descriptions: a new tokenizer splits run-together distributor text
--      (EVOKE7MMRM22, RAM-CORE300BO, 30816.25) and folds calibre aliases
--      (65PRC, 300BO, 338L, 350L, 7MMRM ...). A strong number/UPC match is
--      check_description only when the description actively CONFLICTS
--      (chambering, barrel length, material, model line), no longer on low
--      word overlap. mcp_order_apply flags description_mismatch by the same
--      rule, so the draft agrees with resolve.
--    * The description fallback searches the first 20 items that nothing
--      else matched; the rest come back 'not_searched' (the 8 s statement
--      timeout).
--------------------------------------------------------------------------

-- Vocabulary for the tokenizer below, which splits hyphens and letter/digit
-- runs BEFORE order_search_normalize: "22-250" arrives as "22 250", "30-06
-- SPRG" as "30 06 sprg". Distributor abbreviations too. Shared with
-- order_product_search, where both the query and the part text go through
-- the same rewrite (each canonical is one token).
insert into public.order_product_synonyms (term, canonical) values
  ('22 250', '22250'), ('22 250 rem', '22250'), ('22-250', '22250'), ('22-250 rem', '22250'),
  ('25 06', '2506'), ('25 06 rem', '2506'), ('25-06', '2506'), ('25-06 rem', '2506'),
  ('7 08', '7mm08'), ('7mm 08', '7mm08'), ('7mm 08 rem', '7mm08'),
  ('30 06 springfield', '3006'), ('30 06 sprg', '3006'), ('30 06 spfd', '3006'),
  ('6.5 284', '6.5-284'), ('6.5 284 norma', '6.5-284'),
  ('9 x 19', '9mm'), ('5.56 x 45', '556'),
  ('65 prc', '6.5prc'), ('65 crd', '6.5cm'), ('65 creed', '6.5cm'), ('65 cm', '6.5cm'),
  ('350 legend', '350legend'), ('350 lgnd', '350legend'),
  ('6 arc', '6arc'), ('7 bc', '7bc'), ('6 cm', '6cm'), ('338 arc', '338arc'),
  ('6.8 w', '6.8western'), ('280 ackley', '280ai'), ('280 ai', '280ai'), ('260 rem', '260rem'),
  ('300 norma', '300norma'), ('8.6 blk', '8.6blk'), ('8.6 blackout', '8.6blk'), ('6mm gt', '6gt'),
  ('modern pre', 'mpr'), ('modern precision', 'mpr'),
  ('rdgl', 'ridgeline'), ('elt', 'elite'), ('stl', 'steel'), ('crb', 'carbon'),
  ('saf', 'safari'), ('rch', 'ranch'), ('vntg', 'vantage'), ('trvrs', 'traverse'),
  ('tung', 'tungsten'), ('bcam', 'brushcamo'), ('brush camo', 'brushcamo'),
  ('smk bz', 'smokebronze')
on conflict (term) do nothing;

-- Distributor text split into words: letters from digits ("evoke7mmrm22"
-- -> "evoke 7mmrm 22"), a calibre suffix kept on its number ("300bo",
-- "6.5prc", "338l"), model numbers kept ("ram-15", "ca-10"), our part
-- numbers dropped ("CHR801-15025-01"), a calibre run into a length split
-- ("30816.25" -> "308 16.25"), "10 RD" joined, CBTI read as carbon titanium.
create or replace function public.order_desc_presplit(p text)
returns text
language sql immutable parallel safe
as $$
  select regexp_replace(regexp_replace(
           coalesce((select string_agg(m[1], ' ')
                       from regexp_matches(
                              regexp_replace(regexp_replace(lower(coalesce(p, '')),
                                '\d{3}-\d{4,6}-\d{2}(-[a-z]+)?', ' ', 'g'),
                                '(\d)\s*(rds|rd|rnds|rnd|rounds|round)\M', '\1rd', 'g'),
                              '([a-z]+-\d+|\d+(?:\.\d+)?(?:mm)?(?:prc|pr|creedmoor|creed|crd|cr|cm|remmag|rem|rm|winmag|win|wm|wsm|rum|bc|arc|nosler|nos|blk|bo|aac|bm|wylde|lr|lapua|lm|legend|lgnd|l|rnds|rnd|rds|rd|r)?|[a-z]+)',
                              'g') m), ''),
           '\m(223|243|270|308|338|350|450|556)([12]\d(?:\.\d+)?)\M', '\1 \2', 'g'),
         '\mcbti\M', 'carbon titanium', 'g');
$$;

-- A description as distinct words (restated from 20261112120000): the
-- presplit, then order_search_normalize, calibre spellings folded to one
-- (6.5cm, 6.5prc, 7rm, 300wm, 300blk, 338lapua, 350legend, 28nos, 308win),
-- less stop words, round counts and long digit runs (the PO's own item
-- number, which no part text carries).
create or replace function public.order_desc_tokens(p text)
returns text[]
language sql stable set search_path = public
as $$
  select coalesce(array_agg(distinct x), '{}')
  from (
    select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(t,
             '^(\d+(?:\.\d+)?)(?:mm)?(?:creedmoor|creed|crd|cr|cm)$', '\1cm'),
             '^(\d+(?:\.\d+)?)(?:mm)?(?:prc|pr)$', '\1prc'),
             '^(\d+)(?:mm)?(bc|arc)$', '\1\2'),
             '^(\d)(?:mm)?(?:remmag|rem|rm)$', '\1rm'),
             '^223(?:rem|rm)$', '223rem'),
             '^300(?:win|winmag|wm)$', '300wm'),
             '^(\d+)(?:bo|aac|blk)$', '\1blk'),
             '^338(?:l|lm|lapua)$', '338lapua'),
             '^350(?:l|lgnd|legend)$', '350legend'),
             '^(\d+)(?:nos|nosler)$', '\1nos'),
             '^(243|270|308)(?:win)?$', '\1win'),
             '^65(cm|prc)$', '6.5\1') as x
    from unnest(string_to_array(public.order_search_normalize(public.order_desc_presplit(p)), ' ')) t
    where t <> '' and not (t = any (array['christensen','chris','chr','arms','ca','rifle','rifles','rd','rnd',
                                          'round','rounds','in','inch','the','and','with','w','each','ea',
                                          'x','mag']))
  ) s
  where x !~ '^\d+(r|rd|rds|rnd|rnds)$' and x !~ '^\d{6,}$';
$$;

-- A barrel length word ("16.25", "22"): 10 to 34, else null.
create or replace function public.order_desc_len(x text)
returns numeric
language sql immutable parallel safe
as $$
  select case when x ~ '^\d{2}(\.\d+)?$' then (case when x::numeric between 10 and 34 then x::numeric end) end;
$$;

-- A chambering word: a number followed by letters (6.5cm, 300wm, 9mm), or
-- one of the all-digit ones.
create or replace function public.order_desc_is_cal(x text)
returns boolean
language sql immutable parallel safe
as $$
  select x ~ '^\d+(\.\d+)?[a-z]' or x in ('556', '223', '3006', '22250', '2506', '6.5-284');
$$;

-- Two chambering words that agree: the same; the 223 / 5.56 family; or a
-- bare "7mm" / "6mm" against any 7 / 6 mm chambering.
create or replace function public.order_desc_cal_eq(t text, u text)
returns boolean
language sql immutable parallel safe
as $$
  select u = t
      or (t in ('556', '223', '223rem', '223wylde') and u in ('556', '223', '223rem', '223wylde'))
      or (t ~ '^\d+mm$' and u ~ ('^' || rtrim(t, 'm') || '(mm)?[a-z]'))
      or (u ~ '^\d+mm$' and t ~ ('^' || rtrim(u, 'm') || '(mm)?[a-z]'));
$$;

-- A PO word found in a part word: equal; a 4+ letter prefix; a bare
-- 3-digit calibre ("300") of a suffixed one ("300wm"); agreeing
-- chamberings; lengths within half an inch (16 / 16.25).
create or replace function public.order_desc_match(t text, u text)
returns boolean
language sql immutable parallel safe
as $$
  select u = t
      or (length(t) >= 4 and starts_with(u, t))
      or (t ~ '^\d{3}$' and u ~ ('^' || t || '[a-z]'))
      or public.order_desc_cal_eq(t, u)
      or coalesce(abs(public.order_desc_len(t) - public.order_desc_len(u)) <= 0.5, false);
$$;

-- What actively disagrees between a PO description and a part, as a list
-- (empty when nothing does):
--   chambering  the PO names one the part does not have, and the part names one
--   length      both give a barrel length and none is within half an inch
--   material    steel vs carbon, or titanium on one side only
--   model       the PO names a model line the part is not, and the part names one
-- Missing words (a colour, a stock) are not conflicts.
create or replace function public.order_desc_conflicts(p_po text[], p_part text[])
returns text[]
language sql immutable parallel safe
as $$
  with l(w) as (
    select unnest(array['ridgeline','mesa','evoke','traverse','vantage','summit','ranger','mpr','mhr','mcr',
                        'msr','mlr','msp','mpp','elr','tfm','ba','ca-15','ca-10','ram-15','ram-10'])
  )
  select array_remove(array[
    case when exists (select 1 from unnest(p_po) t
                      where public.order_desc_is_cal(t)
                        and not exists (select 1 from unnest(p_part) u where public.order_desc_cal_eq(t, u)))
          and exists (select 1 from unnest(p_part) u where public.order_desc_is_cal(u))
         then 'chambering' end,
    case when exists (select 1 from unnest(p_po) t where public.order_desc_len(t) is not null)
          and exists (select 1 from unnest(p_part) u where public.order_desc_len(u) is not null)
          and not exists (select 1 from unnest(p_po) t, unnest(p_part) u
                          where abs(public.order_desc_len(t) - public.order_desc_len(u)) <= 0.5)
         then 'length' end,
    case when ('steel' = any (p_po) and 'carbon' = any (p_part) and not 'steel' = any (p_part))
           or ('carbon' = any (p_po) and 'steel' = any (p_part) and not 'carbon' = any (p_part))
           or ('titanium' = any (p_po) and not 'titanium' = any (p_part))
           or ('titanium' = any (p_part) and not 'titanium' = any (p_po)
               and ('carbon' = any (p_po) or 'steel' = any (p_po)))
         then 'material' end,
    case when exists (select 1 from unnest(p_po) t join l on l.w = t where not t = any (p_part))
          and exists (select 1 from unnest(p_part) u join l on l.w = u)
         then 'model' end], null);
$$;

-- The share of a PO's words order_desc_match finds in a part (exact
-- membership first: most words are). Null for no PO words.
create or replace function public.order_desc_overlap(p_po text[], p_part text[])
returns numeric
language sql immutable parallel safe
as $$
  select case when cardinality(p_po) = 0 then null
    else round((select count(*) from unnest(p_po) t
                 where t = any (p_part)
                    or exists (select 1 from unnest(p_part) u where public.order_desc_match(t, u)))::numeric
               / cardinality(p_po), 3) end;
$$;

-- How well a PO description agrees with a part (restated from
-- 20261112120000): 0 on a chambering conflict, else order_desc_overlap.
create or replace function public.order_desc_score(p_po text[], p_part text[])
returns numeric
language sql immutable parallel safe
as $$
  select case
    when cardinality(p_po) = 0 then null
    when 'chambering' = any (public.order_desc_conflicts(p_po, coalesce(p_part, '{}'))) then 0
    else public.order_desc_overlap(p_po, coalesce(p_part, '{}'))
  end;
$$;

-- A UPC/EAN/GTIN for comparing: digits only, leading zeros off (UPC-A,
-- EAN-13 with a leading 0 and GTIN-14 compare equal); null unless 8, 12, 13
-- or 14 digits.
create or replace function public.order_upc_norm(p text)
returns text
language sql immutable parallel safe
as $$
  select case when length(d) in (8, 12, 13, 14) then nullif(ltrim(d, '0'), '') end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) s;
$$;

revoke execute on function public.order_desc_presplit(text) from public, anon;
revoke execute on function public.order_desc_len(text) from public, anon;
revoke execute on function public.order_desc_is_cal(text) from public, anon;
revoke execute on function public.order_desc_cal_eq(text, text) from public, anon;
revoke execute on function public.order_desc_match(text, text) from public, anon;
revoke execute on function public.order_desc_conflicts(text[], text[]) from public, anon;
revoke execute on function public.order_desc_score(text[], text[]) from public, anon;
revoke execute on function public.order_desc_overlap(text[], text[]) from public, anon;
revoke execute on function public.order_desc_tokens(text) from public, anon;
revoke execute on function public.order_upc_norm(text) from public, anon;
grant execute on function public.order_desc_presplit(text) to authenticated;
grant execute on function public.order_desc_len(text) to authenticated;
grant execute on function public.order_desc_is_cal(text) to authenticated;
grant execute on function public.order_desc_cal_eq(text, text) to authenticated;
grant execute on function public.order_desc_match(text, text) to authenticated;
grant execute on function public.order_desc_conflicts(text[], text[]) to authenticated;
grant execute on function public.order_desc_score(text[], text[]) to authenticated;
grant execute on function public.order_desc_overlap(text[], text[]) to authenticated;
grant execute on function public.order_desc_tokens(text) to authenticated;
grant execute on function public.order_upc_norm(text) to authenticated;

-- order_resolve_parts (restated from 20261113090000 with the section-1
-- changes: UPC step, named dim_part columns, conflicts-only
-- check_description, the 20-item description cap).
create or replace function public.order_resolve_parts(p_customer_key text, p_items jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = public, erp
as $$
declare
  -- Items searched by description per call: tokenising the active firearm
  -- pool takes ~1.5 s, scoring each item against it more (8 s timeout).
  c_desc_cap constant int := 20;
  v_type  text;
  v_its   jsonb;   -- [{idx, ref, uref, digits, descr, upc_in, upc, ref_upc}]
  v_cand  jsonb;   -- [{idx, part_id, how, score, sources}]
  v_more  jsonb;
  v_items jsonb;
  v_desc  int[];
  v_skip  int[] := '{}';
begin
  select dc.customer_type into v_type
  from erp.dim_customer dc where dc.customer_key = p_customer_key;
  if not found then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', p_customer_key;
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'invalid_input:items: a non-empty list of {ref?, upc?, description?}';
  end if;
  if jsonb_array_length(p_items) > 300 then
    raise exception 'invalid_input:items: 300 items at most per call';
  end if;

  -- A JSON number is read as its digits (a Vendor Style or UPC sent as one).
  select jsonb_agg(jsonb_build_object(
           'idx', (e.n - 1)::int,
           'ref', left(nullif(btrim(e.v ->> 'ref'), ''), 100),
           'uref', upper(nullif(btrim(e.v ->> 'ref'), '')),
           'digits', regexp_replace(coalesce(e.v ->> 'ref', ''), '\D', '', 'g'),
           'descr', left(nullif(btrim(e.v ->> 'description'), ''), 300),
           'upc_in', left(nullif(btrim(e.v ->> 'upc'), ''), 20),
           'upc', public.order_upc_norm(e.v ->> 'upc'),
           'ref_upc', case when btrim(coalesce(e.v ->> 'ref', '')) ~ '^\d{12,14}$'
                           then public.order_upc_norm(e.v ->> 'ref') end) order by e.n)
    into v_its
  from jsonb_array_elements(p_items) with ordinality as e(v, n)
  where jsonb_typeof(e.v) = 'object';

  -- Exact part id; the UPC (the item's upc, or a 12-14 digit ref); the
  -- customer's own item number on their past ERP orders; the same digits
  -- ("CHR801-15025-01", "8011502501" -> 801-15025-01; six digits at least,
  -- so a stray "22" never matches). One row per part, with every kind that
  -- found it (sources) and the best one (how).
  with it as (
    select * from jsonb_to_recordset(coalesce(v_its, '[]'::jsonb))
      as (idx int, ref text, uref text, digits text, descr text, upc_in text, upc text, ref_upc text)
  ),
  want as (
    select distinct it.idx, w.u
    from it cross join lateral unnest(array[it.upc, it.ref_upc]) as w(u)
    where w.u is not null
  ),
  upcs as (
    select distinct dp.part_id, public.order_upc_norm(dp.upc) as u
    from erp.dim_part dp
    where dp.upc ~ '\d{8}' and exists (select 1 from want)
  ),
  raw as (
    select it.idx, p.part_id, 'exact'::text as how, 1.0::numeric as score
    from it join erp.dim_part p on upper(p.part_id) = it.uref
    union all
    select w.idx, u.part_id, 'upc', 0.97
    from want w join upcs u on u.u = w.u
    union all
    select it.idx, p.part_id, 'customer_history', 0.95
    from it
    join erp.fact_order_line f
      on f.customer_key = p_customer_key and upper(btrim(f.customer_part_id)) = it.uref
    join erp.dim_part p on p.part_key = f.part_key
    union all
    select it.idx, p.part_id, 'digits', 0.9
    from it
    join (select distinct dp.part_id, regexp_replace(dp.part_id, '\D', '', 'g') as d from erp.dim_part dp) p
      on p.d = it.digits
    where length(it.digits) >= 6
  ),
  best as (
    select idx, part_id, max(score) as score,
           (array_agg(how order by score desc))[1] as how,
           array_agg(distinct how order by how) as sources
    from raw group by idx, part_id
  )
  select coalesce(jsonb_agg(to_jsonb(best)), '[]'::jsonb) into v_cand from best;

  -- Description, only for items nothing above matched (the first
  -- c_desc_cap of them): active firearms sharing a word and no chambering
  -- the PO's lacks, scored by order_desc_score, without a conflict. Top 5,
  -- >= 0.5 (colour siblings tie when the PO names no colour).
  select coalesce(array_agg(s.idx order by s.idx), '{}') into v_desc
  from (select (i ->> 'idx')::int as idx
          from jsonb_array_elements(coalesce(v_its, '[]'::jsonb)) i
         where i ->> 'descr' is not null
           and not exists (select 1 from jsonb_array_elements(v_cand) c
                           where (c ->> 'idx')::int = (i ->> 'idx')::int)) s;
  v_skip := coalesce(v_desc[c_desc_cap + 1:], '{}');
  v_desc := coalesce(v_desc[1:c_desc_cap], '{}');

  if cardinality(v_desc) > 0 then
    with q as materialized (
      select (i ->> 'idx')::int as idx, public.order_desc_tokens(i ->> 'descr') as toks
      from jsonb_array_elements(v_its) i
      where (i ->> 'idx')::int = any (v_desc)
    ),
    -- Items with the same words are scored once.
    qd as materialized (
      select distinct q.toks from q where cardinality(q.toks) > 0
    ),
    -- Named columns: authenticated may not read dim_part's cost columns.
    docs as materialized (
      select x.part_id,
             public.order_desc_tokens(concat_ws(' ',
               x.part_description, nullif(upper(btrim(x.product_family)), 'N/A'),
               nullif(upper(btrim(x.chambering)), 'N/A'), nullif(upper(btrim(x.barrel_length)), 'N/A'),
               nullif(upper(btrim(x.finish)), 'N/A'), nullif(upper(btrim(x.stock_color)), 'N/A'))) as toks
      from (select distinct on (dp.part_id) dp.part_id, dp.part_description, dp.product_family,
                   dp.chambering, dp.barrel_length, dp.finish, dp.stock_color
              from erp.dim_part dp
             where dp.status = 'A' and dp.part_id ~ '^8\d\d-' and dp.part_id !~ '-M$'
             order by dp.part_id, dp.part_key) x
    ),
    -- A shared word, and every chambering the PO names (so no chambering
    -- conflict: the overlap is the score).
    scored as materialized (
      select qd.toks as qt, d.part_id, d.toks as dt, public.order_desc_overlap(qd.toks, d.toks) as score
      from qd join docs d on d.toks && qd.toks
      where not exists (select 1 from unnest(qd.toks) t
                        where public.order_desc_is_cal(t)
                          and not exists (select 1 from unnest(d.toks) u where public.order_desc_cal_eq(t, u)))
    ),
    ranked as (
      select s.qt, s.part_id, s.score,
             row_number() over (partition by s.qt order by s.score desc, s.part_id) as rn
      from scored s
      where s.score >= 0.5 and cardinality(public.order_desc_conflicts(s.qt, s.dt)) = 0
    )
    select coalesce(jsonb_agg(jsonb_build_object('idx', q.idx, 'part_id', r.part_id, 'how', 'description',
                                                 'score', r.score, 'sources', jsonb_build_array('description'))),
                    '[]'::jsonb)
      into v_more
    from q join ranked r on r.qt = q.toks and r.rn <= 5;
    v_cand := v_cand || v_more;
  end if;

  with it as (
    select r.*, case when r.descr is not null then public.order_desc_tokens(r.descr) end as po_toks
    from jsonb_to_recordset(coalesce(v_its, '[]'::jsonb))
      as r(idx int, ref text, uref text, digits text, descr text, upc_in text, upc text, ref_upc text)
  ),
  c0 as (
    select * from jsonb_to_recordset(v_cand) as (idx int, part_id text, how text, score numeric, sources text[])
  ),
  c1 as (
    select c.idx, c.part_id, c.how, c.score, c.sources, it.po_toks,
           case when it.po_toks is not null
                then public.order_desc_tokens(public.order_part_doc(c.part_id)) end as part_toks
    from c0 c join it on it.idx = c.idx
  ),
  cand as (
    select c.idx, c.part_id, c.how, c.score, c.sources,
           dp.part_description, dp.status, coalesce(dp.is_kit_flag = 'Y', false) as is_kit,
           lp.unit_price as list_price,
           hist.net_price as last_paid_price, hist.order_date as last_paid_date,
           case when c.how = 'description' then c.score
                when c.po_toks is not null then public.order_desc_score(c.po_toks, c.part_toks) end
             as agreement,
           case when c.po_toks is null then '{}'::text[]
                else public.order_desc_conflicts(c.po_toks, c.part_toks) end as conflicts,
           -- Strong kinds first, then an active part over an obsolete / -M
           -- twin, then the part more kinds found (number AND UPC).
           row_number() over (partition by c.idx
                              order by (c.how <> 'description') desc, (dp.status = 'A') desc,
                                       (c.part_id ~ '-M$'), cardinality(c.sources) desc,
                                       c.score desc, c.part_id) as rn
    from c1 c
    left join lateral (
      select p.part_description, p.status, p.is_kit_flag
      from erp.dim_part p where p.part_id = c.part_id order by p.part_key limit 1) dp on true
    left join lateral (
      select i.unit_price
      from public.effective_price_lists(v_type) l
      join public.price_list_items i on i.price_list_id = l.id and i.part_id = c.part_id
      where not l.is_special
      order by l.effective_from desc, l.id limit 1) lp on true
    -- Last paid: a free unit ($0, or 100% off) is not a price paid; ties
    -- break on the ERP order and line (as mcp_order_apply, 20261113090000).
    left join lateral (
      select round(f.unit_price * (1 - coalesce(f.trade_discount_pct, 0) / 100), 2) as net_price, f.order_date
      from erp.fact_order_line f
      join erp.dim_part p on p.part_key = f.part_key
      where f.customer_key = p_customer_key and p.part_id = c.part_id and f.unit_price > 0
        and coalesce(f.trade_discount_pct, 0) < 100
      order by f.order_date desc nulls last, f.order_id desc, f.line_num desc limit 1) hist on true
  ),
  per_item as (
    select it.idx, it.ref, it.descr, it.upc_in, it.upc,
           coalesce(jsonb_agg(jsonb_build_object(
             'part_id',         c.part_id,
             'erp_description', c.part_description,
             'part_status',     c.status,
             'match',           c.how,
             'match_sources',   to_jsonb(c.sources),
             'score',           c.score,
             'description_agreement', c.agreement,
             'is_kit',          c.is_kit,
             'requires_ffl',    public.part_requires_ffl(c.part_id),
             'on_price_list',   c.list_price is not null,
             'list_price',      c.list_price,
             'last_paid_price', c.last_paid_price,
             'last_paid_date',  c.last_paid_date)
             || case when cardinality(c.conflicts) > 0
                     then jsonb_build_object('description_conflicts', to_jsonb(c.conflicts))
                     else '{}'::jsonb end
             order by c.rn) filter (where c.part_id is not null and c.rn <= 5), '[]'::jsonb) as cands,
           count(*) filter (where c.how <> 'description' and c.status = 'A' and c.part_id !~ '-M$') as strong_active,
           count(*) filter (where c.how <> 'description') as strong,
           count(c.part_id) as any_cand,
           coalesce(bool_or(c.rn = 1 and c.how <> 'description' and cardinality(c.conflicts) > 0), false)
             as top_conflicts,
           (jsonb_agg(to_jsonb(c.conflicts)) filter (where c.rn = 1)) -> 0 as top_conflict_list,
           coalesce(bool_or('upc' = any (c.sources)), false) as upc_hit,
           coalesce(bool_or(c.sources && array['exact', 'customer_history', 'digits']), false) as ref_hit,
           count(*) filter (where 'upc' = any (c.sources)
                              and c.sources && array['exact', 'customer_history', 'digits']) as agree_n
    from it
    left join cand c on c.idx = it.idx
    group by it.idx, it.ref, it.descr, it.upc_in, it.upc
  ),
  judged as (
    select p.*,
           case when p.upc_in is null then null
                when p.upc is null then 'invalid'
                when not p.upc_hit then 'not_found'
                when not p.ref_hit then 'upc_only'
                when p.agree_n > 0 then 'agrees'
                else 'disagrees' end as upc_check
    from per_item p
  ),
  statused as (
    select j.*,
           case when j.idx = any (v_skip) then 'not_searched'
                when j.upc_check = 'disagrees' then 'ambiguous'
                when (j.strong_active = 1 or j.strong = 1 or j.agree_n = 1) and j.top_conflicts
                  then 'check_description'
                when j.strong_active = 1 or j.strong = 1 or j.agree_n = 1 then 'matched'
                when j.strong > 1 then 'ambiguous'
                when j.any_cand > 0 then 'description_only'
                else 'unmatched' end as status
    from judged j
  )
  select jsonb_agg(jsonb_build_object(
           'index', s.idx,
           'ref', s.ref,
           'description', s.descr,
           'status', s.status,
           'candidates', s.cands)
           || jsonb_strip_nulls(jsonb_build_object(
                'upc', s.upc_in,
                'upc_check', s.upc_check,
                'check_reasons', case when s.upc_check = 'disagrees' then '["upc_disagrees"]'::jsonb
                                      when s.status = 'check_description' then s.top_conflict_list end,
                'description_search', case when s.status = 'not_searched' then 'skipped_over_cap' end))
           order by s.idx)
    into v_items
  from statused s;

  return jsonb_build_object(
    'customer_type', v_type,
    'items', coalesce(v_items, '[]'::jsonb),
    'note', 'matched = one strong match (exact id, UPC, this customer''s own item number, or the same '
            'digits) and nothing in the PO description conflicts with it. check_description = the number '
            'matched but the PO description names a different chambering, barrel length, material or '
            'model (check_reasons): likely a typo on the PO; show the user both. ambiguous (also: the '
            'UPC is a different part than the item number) and description_only need a person''s '
            'choice; unmatched items can be staged only by an admin or inside sales, with a price; '
            'not_searched items were past the description-search cap: resend them in a smaller call.')
    || case when cardinality(v_skip) > 0 then jsonb_build_object('description_search_cap', c_desc_cap)
            else '{}'::jsonb end;
end;
$$;

revoke execute on function public.order_resolve_parts(text, jsonb) from public, anon;
grant execute on function public.order_resolve_parts(text, jsonb) to authenticated;

comment on function public.order_resolve_parts(text, jsonb) is
  'Resolve a PO''s lines [{ref?, upc?, description?}] to ERP parts across the whole catalog: exact '
  'id, UPC, the customer''s own item number on past ERP orders, same digits, then description (the '
  'first 20 unmatched items). A strong match is check_description only when the PO description '
  'conflicts (chambering, length, material, model); a UPC naming another part makes it ambiguous. '
  'Each candidate carries its list price for the account and the last price the customer paid '
  '(free lines ignored). RLS-scoped (SECURITY INVOKER; dim_part read by named columns) '
  '(20261114090000).';

-- mcp_order_apply (restated whole from 20261113090000). Section 1 changes
-- description_mismatch (order_desc_conflicts). Section 2 (dup) adds the ERP
-- duplicate probe before the line loop, and the portal probe compares POs
-- by order_po_norm and no longer lets an earlier TEST draft block a real one.
-- Section 3 (shipto) takes the account's main address as a ship-to and
-- refuses a draft with no orderable ship-to up front. Section 4
-- (contact_header) matches the PO's contact, stores the PO header fields
-- (kept on update when left out) and each line's buyer_part_number / upc.
create or replace function public.mcp_order_apply(p_order_id bigint, p jsonb, p_params jsonb, p_idem_key text, p_hash text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
declare
  v_uid      uuid := auth.uid();
  v_guc      text := current_setting('app.mcp_order_write', true);
  v_admin    boolean := public.can_price_orders();   -- admin or inside sales: pricing and caps
  v_admin_list bigint := public.admin_price_list_id();
  v_max_lines int;
  v_max_units int;
  v_max_value numeric;
  v_max_day   int;
  v_window    int     := coalesce((p_params ->> 'duplicate_window_days')::int, 14);
  v_erp_window int    := coalesce((p_params ->> 'erp_duplicate_window_days')::int, 180);
  v_erp      jsonb;
  v_cur      public.orders;
  v_ck       text;
  v_cust     record;
  v_ship     erp.dim_ship_to;
  v_ship_key text;
  v_main     erp.dim_ship_to;
  v_main_found boolean := false;
  v_main_ok  boolean := false;
  v_main_why text;
  v_kind     text;
  v_n        int;
  v_po       text;
  v_date     date;
  v_contact  text;
  v_notes    text;
  v_allow    boolean := false;
  v_test     boolean := false;
  v_ref      jsonb;
  v_line     jsonb;
  v_part     text;
  v_qty      numeric;
  v_plid     bigint;
  v_exp      numeric;
  v_item     record;
  v_reason   text;
  v_price    numeric;
  v_cref     text;
  v_cdesc    text;
  v_known    boolean;
  v_has_item boolean;
  v_n_admin  int := 0;
  v_priced   jsonb := '[]'::jsonb;
  v_unconf   jsonb := '[]'::jsonb;
  v_ix       int := -1;
  v_choices  jsonb;
  v_total    numeric;
  v_set      jsonb;
  v_dup      bigint;
  v_tok      uuid;
  v_id       bigint;
  k          text;
  -- Section 4 (contact_header): the PO's contact and header, per line its
  -- buyer part number and UPC.
  v_pc_name  text;
  v_pc_email text;
  v_pc_phone text;
  v_match    jsonb;
  v_cmatch   text;
  v_po_date  date;
  v_cancel   date;
  v_terms    text;
  v_via      text;
  v_vendor   text;
  v_loc      text;
  v_loc_key  text;
  v_po_total numeric;
  v_bpn      text;
  v_upc      text;
begin
  -- An admin or inside sales stages distributor POs (20261112120000) and
  -- enters the day's orders: larger caps, the daily draft count included
  -- (its own key, so raising it never raises a rep's).
  if v_admin then
    v_max_lines := coalesce((p_params ->> 'admin_max_lines')::int, 500);
    v_max_units := coalesce((p_params ->> 'admin_max_units_per_line')::int, 5000);
    v_max_value := coalesce((p_params ->> 'admin_max_order_value')::numeric, 5000000);
    v_max_day   := coalesce((p_params ->> 'admin_max_drafts_per_user_per_day')::int, 200);
  else
    v_max_lines := coalesce((p_params ->> 'max_lines')::int, 40);
    v_max_units := coalesce((p_params ->> 'max_units_per_line')::int, 200);
    v_max_value := coalesce((p_params ->> 'max_order_value')::numeric, 250000);
    v_max_day   := coalesce((p_params ->> 'max_drafts_per_user_per_day')::int, 25);
  end if;

  if p_order_id is not null then
    select * into v_cur from public.orders where id = p_order_id;
  end if;

  -- Customer, and the caller's right to draft for it (DEFINER bypasses RLS,
  -- so the read policy is restated: admin, or the account is on my book).
  -- is_admin(), not v_admin: for inside sales my_customer_keys() is every
  -- account minus an admin's revokes, and a revoke stops drafting too.
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

  -- Several active accounts by this name: the user picks one.
  if (p -> 'customer_confirmed') is distinct from 'true'::jsonb then
    v_choices := public.order_same_name_accounts(v_ck);
    if jsonb_array_length(v_choices) > 1 then
      raise exception using
        message = format('customer_confirmation_required:%s: %s active accounts are named like %s; show them to the user, then send customer_confirmed=true with the one they pick',
                         v_ck, jsonb_array_length(v_choices), v_cust.customer_name),
        detail  = jsonb_build_object('error', 'customer_confirmation_required', 'choices', v_choices)::text;
    end if;
  end if;

  -- Ship-to (section 3, shipto). A real ship-to (CUST_ADDRESS) as before:
  -- a given one must be an orderable ship-to of this account; with more
  -- than one orderable the user must have picked it (ship_to_confirmed);
  -- with exactly one it is used. Or the account's main (sold-to) address,
  -- dim_ship_to '<ck>|CUST' (the key fact_order_line carries for an ERP
  -- order with no ship-to, so run_order_qc's ship_to_mismatch holds), when
  -- feature.order_main_address_ship_to is on: the default only when the
  -- account has no ship-to; picking it while ship-tos exist is confirmed.
  -- An omitted ship_to_key on an update means the default, as before.
  -- Section 4: the PO's Ship To Location (kept on update when left out)
  -- only points at the matching row in a confirmation refusal; it never
  -- stands in for ship_to_confirmed.
  if p ? 'ship_to_location' then
    v_loc := public.order_po_text(p -> 'ship_to_location', 'ship_to_location', 60, true);
  else
    v_loc := v_cur.po_ship_to_location;
  end if;
  v_loc_key := public.order_ship_to_for_location(v_ck, v_loc);

  select count(*), min(s.ship_to_key) into v_n, v_ship_key
  from erp.dim_ship_to s
  where s.customer_id = v_ck
    and public.order_ship_to_kind(s.ship_to_key, s.customer_id, s.address_source,
                                  s.ship_to_id, s.is_unknown_ship_to) = 'ship_to'
    and upper(coalesce(s.active_flag, 'Y')) <> 'N';
  if v_n <> 1 then
    v_ship_key := null;
  end if;

  select s.* into v_main from erp.dim_ship_to s
  where s.ship_to_key = v_ck || '|CUST' and s.customer_id = v_ck
    and s.address_source = 'CustomerMaster';
  v_main_found := found;
  v_main_ok := v_main_found
               and public.order_ship_to_orderable('customer_address', v_main.active_flag,
                                                  v_main.address1, v_main.city);
  -- Why the main address cannot take an order (null when it can).
  v_main_why := case
    when v_main_ok then null
    when not v_main_found then 'the account has no main address in the ERP'
    when upper(coalesce(v_main.active_flag, 'Y')) = 'N' then 'the account is inactive in the ERP'
    when nullif(btrim(v_main.address1), '') is null or nullif(btrim(v_main.city), '') is null
      then 'its street or city is blank in the ERP'
    else 'main-address orders are not enabled (feature.order_main_address_ship_to)' end;
  if v_n = 0 and v_main_ok then
    v_ship_key := v_main.ship_to_key;
  end if;

  if p ? 'ship_to_key' and jsonb_typeof(p -> 'ship_to_key') <> 'null' then
    if jsonb_typeof(p -> 'ship_to_key') <> 'string' then
      raise exception 'invalid_input:ship_to_key: must be a string';
    end if;
    v_ship_key := btrim(p ->> 'ship_to_key');
    -- '<ck>|MAIN' (or MAIN) is an alias of the main address.
    if upper(v_ship_key) in (upper(v_ck || '|MAIN'), 'MAIN') then
      v_ship_key := v_ck || '|CUST';
    end if;
    select s.* into v_ship from erp.dim_ship_to s
    where s.ship_to_key = v_ship_key and s.customer_id = v_ck;
    v_kind := case when found then public.order_ship_to_kind(v_ship.ship_to_key, v_ship.customer_id,
                     v_ship.address_source, v_ship.ship_to_id, v_ship.is_unknown_ship_to) end;
    if v_kind is null then
      raise exception 'ship_to_invalid:%: not one of this account''s ship-to addresses', v_ship_key;
    end if;
    if v_kind = 'ship_to' and upper(coalesce(v_ship.active_flag, 'Y')) = 'N' then
      raise exception 'ship_to_invalid:%: the ship-to % is inactive in the ERP; pick another', v_ship_key, v_ship.ship_to_id;
    end if;
    if v_kind = 'customer_address' and not v_main_ok then
      raise exception 'ship_to_invalid:%: the account''s main address cannot take an order (%); pick a ship-to',
        v_ship_key, v_main_why;
    end if;
    if (v_n > 1 or (v_kind = 'customer_address' and v_n >= 1))
       and (p -> 'ship_to_confirmed') is distinct from 'true'::jsonb then
      raise exception using
        message = format('ship_to_confirmation_required:%s: %s has %s orderable ship-to(s)%s; show them (with FFL number and expiry) to the user, then send ship_to_confirmed=true with the one they pick%s',
                         v_ck, v_ck, v_n, case when v_main_ok then ' and its main address' else '' end,
                         public.order_location_hint(v_loc, v_loc_key)),
        detail  = (jsonb_build_object('error', 'ship_to_confirmation_required',
                                      'choices', public.order_ship_to_choices(v_ck))
                   || jsonb_strip_nulls(jsonb_build_object('po_ship_to_location', v_loc,
                                                           'suggested_ship_to_key', v_loc_key)))::text;
    end if;
  elsif v_n > 1 then
    raise exception using
      message = format('ship_to_confirmation_required:%s: %s has %s orderable ship-tos; show them (with FFL number and expiry) to the user, then send ship_to_key and ship_to_confirmed=true%s',
                       v_ck, v_ck, v_n, public.order_location_hint(v_loc, v_loc_key)),
      detail  = (jsonb_build_object('error', 'ship_to_confirmation_required',
                                    'choices', public.order_ship_to_choices(v_ck))
                 || jsonb_strip_nulls(jsonb_build_object('po_ship_to_location', v_loc,
                                                         'suggested_ship_to_key', v_loc_key)))::text;
  end if;

  -- Refused up front, whatever the flag: a draft that can only fail at
  -- submit is never saved.
  if v_ship_key is null then
    raise exception using
      message = format('no_orderable_ship_to:%s: %s has no active ship-to address and its main address cannot take an order (%s). Nothing was saved: the address must be added or fixed in the ERP first',
                       v_ck, v_ck, v_main_why),
      detail  = jsonb_build_object('error', 'no_orderable_ship_to', 'customer_key', v_ck,
                                   'main_address', v_main_why)::text;
  end if;

  if p ? 'po_number' and jsonb_typeof(p -> 'po_number') <> 'null' then
    if jsonb_typeof(p -> 'po_number') not in ('string', 'number') then
      raise exception 'invalid_input:po_number: must be text';
    end if;
    -- Blank is blank whatever the whitespace (tab, line break, no-break
    -- space), as the order loader's strip() sees it.
    v_po := nullif(btrim(p ->> 'po_number', E' \t\r\n\u00A0'), '');
    if length(v_po) > 40 then
      raise exception 'invalid_input:po_number: 40 characters at most';
    end if;
    -- PORTAL-<id> is the reference submit_order gives an order with no PO.
    -- The order's own counts as none; any other is refused, so two orders
    -- never carry the same reference.
    if v_po ~* '^PORTAL-[0-9]+$' then
      if p_order_id is not null and upper(v_po) = 'PORTAL-' || p_order_id then
        v_po := null;
      else
        raise exception 'invalid_input:po_number: % is not a customer PO; that reference is assigned by the portal to an order that has none', v_po;
      end if;
    end if;
  end if;
  -- An update never drops a customer PO already on the draft: the model
  -- resends every confirmation (no_po_confirmed too), and a PO a person
  -- added in the portal would silently go. The draft's own PORTAL-<id> is
  -- not a customer PO.
  if p_order_id is not null and v_po is null
     and nullif(btrim(v_cur.po_number, E' \t\r\n\u00A0'), '') is not null
     and upper(btrim(v_cur.po_number, E' \t\r\n\u00A0')) <> 'PORTAL-' || p_order_id then
    raise exception 'po_would_be_removed: the draft has the customer PO %; send it again as po_number (a person can clear it in the portal if it really must go)',
      btrim(v_cur.po_number, E' \t\r\n\u00A0');
  end if;
  -- A PO is asked for every time, but an informal order ("Tim wants one")
  -- has none: the user says so (no_po_confirmed) and submit_order gives the
  -- order the reference PORTAL-<id>. Never invented by the model.
  if v_po is null and (p -> 'no_po_confirmed') is distinct from 'true'::jsonb then
    raise exception 'po_confirmation_required: no customer PO number was given. Ask the user for it. Only if they say the customer gave none, send no_po_confirmed=true; the order is then given the reference PORTAL-<order id> when it is submitted. Never invent one';
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
    v_cmatch := 'given';
  elsif not (p ? 'customer_contact_key') and v_cur.contact_match = 'given'
        and exists (select 1 from erp.dim_customer_contact e
                    where e.customer_contact_key = v_cur.customer_contact_key and e.customer_key = v_ck
                      and coalesce(e.contact_active_flag, 'Y') = 'Y') then
    -- Section 4: an update that leaves the key out keeps the contact the
    -- user picked (it used to clear it), so the PO contact kept below
    -- cannot silently re-match over it. An explicit null clears it.
    v_contact := v_cur.customer_contact_key;
    v_cmatch  := 'given';
  end if;

  -- Section 4 (contact_header): PO header fields. Unlike notes, a field
  -- left out of an update keeps the draft's value; an explicit null clears
  -- it. Informational, never refusing a draft, except a malformed value and
  -- a PO date in the future.
  if p ? 'contact_email' then
    v_pc_email := public.order_po_text(p -> 'contact_email', 'contact_email', 254, false);
  else
    v_pc_email := v_cur.po_contact_email;
  end if;
  if p ? 'contact_name' then
    v_pc_name := public.order_po_text(p -> 'contact_name', 'contact_name', 100, false);
  else
    v_pc_name := v_cur.po_contact_name;
  end if;
  if p ? 'contact_phone' then
    v_pc_phone := public.order_po_text(p -> 'contact_phone', 'contact_phone', 40, true);
  else
    v_pc_phone := v_cur.po_contact_phone;
  end if;
  if p ? 'po_date' then
    v_po_date := public.order_po_date(p -> 'po_date', 'po_date');
    if v_po_date > current_date + 1 then
      raise exception 'invalid_input:po_date: % is in the future; send the date printed on the PO (YYYY-MM-DD)', v_po_date;
    end if;
  else
    v_po_date := v_cur.po_date;
  end if;
  -- A past cancel date is stored (the preview flags it, submit refuses it).
  if p ? 'cancel_date' then
    v_cancel := public.order_po_date(p -> 'cancel_date', 'cancel_date');
  else
    v_cancel := v_cur.po_cancel_date;
  end if;
  if p ? 'payment_terms' then
    v_terms := public.order_po_text(p -> 'payment_terms', 'payment_terms', 100, false);
  else
    v_terms := v_cur.po_payment_terms;
  end if;
  if p ? 'ship_via' then
    v_via := public.order_po_text(p -> 'ship_via', 'ship_via', 60, false);
  else
    v_via := v_cur.po_ship_via;
  end if;
  if p ? 'vendor_number' then
    v_vendor := public.order_po_text(p -> 'vendor_number', 'vendor_number', 40, true);
  else
    v_vendor := v_cur.po_vendor_number;
  end if;
  if p ? 'po_total' then
    if jsonb_typeof(p -> 'po_total') = 'null' then
      v_po_total := null;
    elsif jsonb_typeof(p -> 'po_total') <> 'number'
          or (p ->> 'po_total')::numeric < 0 or (p ->> 'po_total')::numeric > 100000000 then
      raise exception 'invalid_input:po_total: the PO''s stated total, a number from 0 to 100,000,000';
    else
      v_po_total := round((p ->> 'po_total')::numeric, 2);
    end if;
  else
    v_po_total := v_cur.po_total;
  end if;

  -- No key given: the PO's contact matched to this account's ERP contacts
  -- (email, then name + phone; billing and internal contacts never). No
  -- match is not a refusal: the contact is staged and the preview says so.
  -- Review fix: an explicit customer_contact_key null clears the contact; the
  -- kept PO contact stays as free text and is not matched straight back.
  if v_contact is null and coalesce(v_pc_email, v_pc_name, v_pc_phone) is not null
     and not (p ? 'customer_contact_key' and jsonb_typeof(p -> 'customer_contact_key') = 'null') then
    v_match   := public.order_match_contact(v_ck, v_pc_email, v_pc_name, v_pc_phone);
    v_contact := v_match ->> 'customer_contact_key';
    v_cmatch  := case when v_contact is not null then v_match ->> 'matched_by' end;
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

  if p ? 'price_override_reason' and jsonb_typeof(p -> 'price_override_reason') <> 'null' then
    if not v_admin then
      raise exception 'price_not_allowed:price_override_reason: only an admin or inside sales can price an order by hand; the server prices it from the published list';
    end if;
    if jsonb_typeof(p -> 'price_override_reason') <> 'string' then
      raise exception 'invalid_input:price_override_reason: must be text';
    end if;
    v_reason := nullif(btrim(p ->> 'price_override_reason'), '');
    if length(v_reason) > 500 then
      raise exception 'invalid_input:price_override_reason: 500 characters at most';
    end if;
  end if;

  if p ? 'allow_duplicate' and jsonb_typeof(p -> 'allow_duplicate') <> 'null' then
    if jsonb_typeof(p -> 'allow_duplicate') <> 'boolean' then
      raise exception 'invalid_input:allow_duplicate: must be true or false';
    end if;
    v_allow := (p -> 'allow_duplicate')::boolean;
  end if;

  -- Once a test, always a test: an update can mark a draft as a test but
  -- never clear it (omitted or false keeps it), so a real order needs a new
  -- draft, as the test_order refusal says.
  v_test := coalesce(v_cur.is_test, false)
            or coalesce((p -> 'is_test') = 'true'::jsonb, false);

  -- Section 2 (dup): the PO already on an ERP order for this account
  -- (entered outside the portal: EDI, order entry). Needs only the PO, so it
  -- runs before any line is priced: a 195-line PO is refused at once, not
  -- after the whole pricing pass. Test drafts are checked too. Read-only on
  -- the mirror, so no lock.
  if not v_allow and v_po is not null then
    v_erp := public.order_erp_po_matches(v_ck, v_po, v_erp_window);
    if jsonb_array_length(v_erp) > 0 then
      raise exception using
        message = format('possible_duplicate_erp:%s: ERP order %s (%s, %s, %s lines) for this account already carries PO %s%s; ask the user, then send allow_duplicate=true to draft anyway',
                   v_erp -> 0 ->> 'erp_order_id', v_erp -> 0 ->> 'erp_order_id', v_erp -> 0 ->> 'order_date',
                   v_erp -> 0 ->> 'status', v_erp -> 0 ->> 'lines', v_erp -> 0 ->> 'po_as_entered',
                   -- Submitted once and recalled: the ERP order may be this
                   -- draft's own entry (the loader wrote it before the recall).
                   case when v_cur.recalled_at is not null
                        then ' (this draft was submitted before and recalled: that ERP order may be its own entry)'
                        else '' end),
        detail  = jsonb_build_object('error', 'possible_duplicate_erp', 'erp_orders', v_erp)::text;
    end if;
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
    raise exception 'invalid_input:lines: at least one line {part_id, qty, part_confirmed} is required';
  end if;
  if jsonb_array_length(p -> 'lines') > v_max_lines then
    raise exception 'too_many_lines: % lines; % at most', jsonb_array_length(p -> 'lines'), v_max_lines;
  end if;

  for v_line in select jsonb_array_elements(p -> 'lines') loop
    v_ix := v_ix + 1;
    if jsonb_typeof(v_line -> 'part_id') is distinct from 'string' or btrim(v_line ->> 'part_id') = '' then
      raise exception 'invalid_input:part_id: every line needs a part_id';
    end if;
    v_part := btrim(v_line ->> 'part_id');
    if length(v_part) > 100 then
      raise exception 'invalid_input:part_id: 100 characters at most';
    end if;
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
    v_exp := null;
    if v_line ? 'expected_unit_price' and jsonb_typeof(v_line -> 'expected_unit_price') <> 'null' then
      if jsonb_typeof(v_line -> 'expected_unit_price') <> 'number'
         or (v_line ->> 'expected_unit_price')::numeric <= 0
         or (v_line ->> 'expected_unit_price')::numeric >= 10000000000 then
        raise exception 'invalid_input:expected_unit_price: line % needs a positive number (the unit price the user said)', v_part;
      end if;
      v_exp := round((v_line ->> 'expected_unit_price')::numeric, 2);
    end if;
    if v_line ? 'part_confirmed' and jsonb_typeof(v_line -> 'part_confirmed') not in ('boolean', 'null') then
      raise exception 'invalid_input:part_confirmed: line % must send true or false', v_part;
    end if;

    -- Admin pricing (20261112120000): the PO's price, and the PO's own item
    -- number and description for the reviewer.
    v_price := null;
    if v_line ? 'unit_price' and jsonb_typeof(v_line -> 'unit_price') <> 'null' then
      if not v_admin then
        raise exception 'price_not_allowed:%: only an admin or inside sales can set a price; the server prices the order from the published list (send the user''s price as expected_unit_price)', v_part;
      end if;
      if jsonb_typeof(v_line -> 'unit_price') <> 'number' then
        raise exception 'invalid_input:unit_price: line % needs a number', v_part;
      end if;
      v_price := (v_line ->> 'unit_price')::numeric;
      if v_price < 0 or v_price > 1000000 or v_price <> round(v_price, 2) then
        raise exception 'invalid_input:unit_price: line % has %; use 0-1,000,000 with at most 2 decimals', v_part, v_price;
      end if;
    end if;
    v_cref := null;
    if v_line ? 'customer_part_ref' and jsonb_typeof(v_line -> 'customer_part_ref') <> 'null' then
      if jsonb_typeof(v_line -> 'customer_part_ref') not in ('string', 'number') then
        raise exception 'invalid_input:customer_part_ref: line % must be text', v_part;
      end if;
      v_cref := nullif(btrim(v_line ->> 'customer_part_ref'), '');
      if length(v_cref) > 100 then
        raise exception 'invalid_input:customer_part_ref: 100 characters at most';
      end if;
    end if;
    v_cdesc := null;
    if v_line ? 'customer_description' and jsonb_typeof(v_line -> 'customer_description') <> 'null' then
      if jsonb_typeof(v_line -> 'customer_description') <> 'string' then
        raise exception 'invalid_input:customer_description: line % must be text', v_part;
      end if;
      v_cdesc := left(nullif(btrim(v_line ->> 'customer_description'), ''), 300);
    end if;
    -- Section 4: the customer's own item number (Visual's CUSTOMER_PART_ID)
    -- and the line's UPC, stored digits only.
    v_bpn := public.order_po_text(v_line -> 'buyer_part_number', 'buyer_part_number', 100, true);
    v_upc := null;
    if v_line ? 'upc' and jsonb_typeof(v_line -> 'upc') <> 'null' then
      if jsonb_typeof(v_line -> 'upc') not in ('string', 'number') then
        raise exception 'invalid_input:upc: line % must send the UPC as text', v_part;
      end if;
      v_upc := nullif(regexp_replace(v_line ->> 'upc', '[\s-]', '', 'g'), '');
      if v_upc !~ '^\d{8,14}$' then
        raise exception 'invalid_input:upc: line % has UPC "%"; send its 8-14 digits as printed, or leave it out',
          v_part, left(v_line ->> 'upc', 30);
      end if;
    end if;

    v_known := exists (select 1 from erp.dim_part dp where dp.part_id = v_part);

    if exists (select 1 from erp.dim_part dp where dp.part_id = v_part and dp.is_kit_flag = 'Y') then
      raise exception 'kit_not_supported:%: kits cannot be ordered here', v_part;
    end if;

    v_has_item := false;
    -- Section 4: v_item is read (in a CASE) on the admin branch even when no
    -- item was found; unassigned it raised "record v_item is not assigned
    -- yet" when the FIRST line staged was an unmatched part.
    select null::bigint as list_id, null::text as list_name, null::bigint as item_id,
           null::numeric as unit_price, null::text as description
      into v_item;
    if v_known then
      select l.id as list_id, l.name as list_name, i.id as item_id, i.unit_price, i.description
        into v_item
      from public.effective_price_lists(v_cust.customer_type) l
      join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_part
      where (v_plid is null and not l.is_special) or l.id = v_plid
      order by l.effective_from desc, l.id
      limit 1;
      v_has_item := found;
    end if;

    if (v_line -> 'part_confirmed') is distinct from 'true'::jsonb then
      v_unconf := v_unconf || jsonb_build_object(
        'line', v_ix, 'part_id', v_part,
        'choices', public.order_part_choices(v_cust.customer_type, v_part, 6));
    end if;

    if v_has_item and (v_price is null or v_price = v_item.unit_price) then
      -- The published price. The ERP part master's description first (the
      -- uploaded list's column is only a fallback: the Buy Group sheet
      -- carried the UPC there).
      v_priced := v_priced || jsonb_build_object(
        'part_id', v_part, 'qty', v_qty::int, 'price_list_id', v_item.list_id,
        'item_id', v_item.item_id, 'unit_price', v_item.unit_price,
        'expected_unit_price', v_exp,
        'description', coalesce(
           (select dp.part_description from erp.dim_part dp
             where dp.part_id = v_part and nullif(btrim(dp.part_description), '') is not null
             order by coalesce(dp.is_unknown_part, false), dp.part_key limit 1),
           v_item.description, v_cdesc),
        'price_source', 'list', 'list_unit_price', v_item.unit_price,
        'customer_part_ref', v_cref, 'customer_description', v_cdesc, 'part_unresolved', false,
        'buyer_part_number', v_bpn, 'upc', v_upc);
    elsif v_price is null then
      if not v_known and v_admin then
        raise exception 'part_unknown:%: no ERP part has this id. Resolve it with resolve_order_parts, or send unit_price to stage it unmatched', v_part;
      end if;
      if v_plid is null then
        raise exception 'part_not_orderable:%: not on this account''s price list%', v_part,
          case when v_admin then '; send unit_price to order it off list' else '' end;
      end if;
      raise exception 'part_not_orderable:%: not on price list % (or that list is not effective for this account)', v_part, v_plid;
    else
      -- Admin price: off list, a different price, or an unmatched item.
      if v_admin_list is null then
        raise exception 'admin_price_list: the reserved admin price list is missing';
      end if;
      v_n_admin := v_n_admin + 1;
      v_priced := v_priced || jsonb_build_object(
        'part_id', v_part, 'qty', v_qty::int, 'price_list_id', v_admin_list,
        'item_id', null, 'unit_price', v_price,
        'expected_unit_price', v_exp,
        'description', coalesce(
           (select dp.part_description from erp.dim_part dp
             where dp.part_id = v_part and nullif(btrim(dp.part_description), '') is not null
             order by coalesce(dp.is_unknown_part, false), dp.part_key limit 1),
           case when v_has_item then v_item.description end, v_cdesc),
        'price_source', 'admin',
        'list_unit_price', case when v_has_item then v_item.unit_price
                                else (select i.unit_price
                                        from public.effective_price_lists(v_cust.customer_type) l
                                        join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_part
                                       where not l.is_special
                                       order by l.effective_from desc, l.id limit 1) end,
        'customer_part_ref', coalesce(v_cref, case when not v_known then v_part end),
        'customer_description', v_cdesc, 'part_unresolved', not v_known,
        'buyer_part_number', v_bpn, 'upc', v_upc);
    end if;

    if (select count(*) from jsonb_array_elements(v_priced) e
         where e ->> 'part_id' = v_part
           and (e ->> 'price_list_id')::bigint = (v_priced -> -1 ->> 'price_list_id')::bigint
           -- Hand-priced lines may repeat a part at DIFFERENT prices (10 paid
           -- and 1 free); the same part at the same price is one line.
           and (v_priced -> -1 ->> 'price_source' = 'list'
                or (e ->> 'unit_price')::numeric = (v_priced -> -1 ->> 'unit_price')::numeric)) > 1 then
      raise exception 'invalid_input:duplicate_line:%: the part appears twice at the same price; send one line with the total qty', v_part;
    end if;
  end loop;

  if jsonb_array_length(v_unconf) > 0 then
    raise exception using
      message = format('part_confirmation_required:%s: %s line(s) were not confirmed by the user; show the choices, then send part_confirmed=true on every line',
                       v_unconf -> 0 ->> 'part_id', jsonb_array_length(v_unconf)),
      detail  = jsonb_build_object('error', 'part_confirmation_required', 'lines', v_unconf)::text;
  end if;

  if v_n_admin > 0 and v_reason is null then
    raise exception 'invalid_input:price_override_reason: % line(s) are hand-priced or unmatched; say why in price_override_reason (e.g. "excess stock buy-in, approved by ...")', v_n_admin;
  end if;
  if v_n_admin = 0 then
    v_reason := null;
  end if;

  -- The same promo formula as submit_order (which re-runs it authoritatively).
  -- The admin list has no promo, so admin lines keep their price.
  with x as (
    select * from jsonb_to_recordset(v_priced)
      as (part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
          expected_unit_price numeric, description text,
          price_source text, list_unit_price numeric, customer_part_ref text, customer_description text,
          part_unresolved boolean, buyer_part_number text, upc text)
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

  -- One draft write per user, and per account, at a time: the cap and the
  -- duplicate probe below are check-then-insert, and models do issue
  -- parallel tool calls; the probe is per account, so two people drafting
  -- for one account queue too. Always user first, then account.
  perform pg_advisory_xact_lock(hashtextextended('mcp_order_apply|' || v_uid::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('mcp_order_apply|account|' || v_ck, 0));

  if p_order_id is null then
    select count(*) into v_n
    from public.orders o
    where o.created_by = v_uid and o.source <> 'portal'
      and o.created_at >= date_trunc('day', now());
    if v_n >= v_max_day then
      raise exception 'daily_draft_cap: % drafts today; % per day at most', v_n, v_max_day;
    end if;
  end if;

  -- Duplicate block: a model that retries usually invents a new key. Per
  -- account, not per drafter: the rep and inside sales (or two inside sales
  -- users) can both receive the same PO. Whoever may draft for the account
  -- reads its orders, so naming the other order leaks nothing.
  if not v_allow then
    select o.id into v_dup
    from public.orders o
    where o.customer_key = v_ck
      and o.status <> 'cancelled'
      and o.created_at >= now() - make_interval(days => v_window)
      and o.id is distinct from p_order_id
      -- Section 2 (dup): a test draft is checked against every order, tests
      -- included; a real draft is never blocked by an earlier rehearsal.
      and (v_test or not coalesce(o.is_test, false))
      -- PO compared as order_po_norm sees it ('PO# 0215647' = '215647'): a
      -- superset of the old upper/btrim equality.
      and (   (v_po is not null and public.order_po_norm(o.po_number) = public.order_po_norm(v_po))
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
        source_ref, mcp_token_id, client_request_id, request_hash, is_test, price_override_reason,
        po_contact_name, po_contact_email, po_contact_phone, contact_match, po_date, po_cancel_date,
        po_payment_terms, po_ship_via, po_vendor_number, po_ship_to_location, po_total)
      values (
        v_uid, v_uid, v_ck, coalesce(v_cust.customer_name, ''), v_cust.customer_type, 'draft', 'mcp',
        v_po, v_date, v_notes, v_ship_key, v_contact,
        v_ref, v_tok, p_idem_key, p_hash, v_test, v_reason,
        v_pc_name, v_pc_email, v_pc_phone, v_cmatch, v_po_date, v_cancel,
        v_terms, v_via, v_vendor, v_loc, v_po_total)
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
        source_ref           = coalesce(v_ref, source_ref),
        is_test              = v_test,
        price_override_reason = v_reason,
        po_contact_name      = v_pc_name,
        po_contact_email     = v_pc_email,
        po_contact_phone     = v_pc_phone,
        contact_match        = v_cmatch,
        po_date              = v_po_date,
        po_cancel_date       = v_cancel,
        po_payment_terms     = v_terms,
        po_ship_via          = v_via,
        po_vendor_number     = v_vendor,
        po_ship_to_location  = v_loc,
        po_total             = v_po_total
    where id = v_id;
    delete from public.order_lines where order_id = v_id;
  end if;

  insert into public.order_lines (order_id, price_list_id, price_list_item_id, part_id, description,
                                  qty, unit_price, discount_pct, effective_unit_price,
                                  mcp_expected_unit_price,
                                  price_source, list_unit_price, customer_part_ref, customer_description,
                                  part_unresolved, buyer_part_number, upc)
  select v_id, x.price_list_id, x.item_id, x.part_id, x.description,
         x.qty, x.unit_price, x.discount_pct, x.effective_unit_price, x.expected_unit_price,
         x.price_source, x.list_unit_price, x.customer_part_ref, x.customer_description,
         coalesce(x.part_unresolved, false), x.buyer_part_number, x.upc
  from jsonb_to_recordset(v_priced)
    as x(part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
         description text, discount_pct numeric, effective_unit_price numeric,
         expected_unit_price numeric,
         price_source text, list_unit_price numeric, customer_part_ref text, customer_description text,
         part_unresolved boolean, buyer_part_number text, upc text);

  -- For the reviewer: what this customer last paid for each part, and
  -- whether the PO's description looks like the part it was matched to.
  -- A free unit ($0, or 100% off) is not a price paid; ties break on the
  -- ERP order and line so the answer does not depend on scan order.
  update public.order_lines l
  set last_paid_price = h.net_price,
      last_paid_date  = h.order_date
  from (
    select distinct on (p.part_id) p.part_id,
           round(f.unit_price * (1 - coalesce(f.trade_discount_pct, 0) / 100), 2) as net_price, f.order_date
    from erp.fact_order_line f
    join erp.dim_part p on p.part_key = f.part_key
    where f.customer_key = v_ck and f.unit_price > 0
      and coalesce(f.trade_discount_pct, 0) < 100
      and p.part_id in (select ol.part_id from public.order_lines ol where ol.order_id = v_id)
    order by p.part_id, f.order_date desc nulls last, f.order_id desc, f.line_num desc
  ) h
  where l.order_id = v_id and l.part_id = h.part_id;

  -- 20261114090000: flagged only when the PO description CONFLICTS with the
  -- part (chambering, length, material, model), as order_resolve_parts
  -- decides check_description; low word overlap alone is not a mismatch.
  update public.order_lines l
  set description_mismatch = cardinality(public.order_desc_conflicts(
        public.order_desc_tokens(l.customer_description),
        public.order_desc_tokens(public.order_part_doc(l.part_id)))) > 0
  where l.order_id = v_id and l.customer_description is not null and not l.part_unresolved;

  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);
  return v_id;
end;
$$;

revoke execute on function public.mcp_order_apply(bigint, jsonb, jsonb, text, text) from public, anon, authenticated;

--------------------------------------------------------------------------
-- 2. dup: a PO already in the ERP
--    * The duplicate probe read only portal orders: Sports South PO 215647
--      was already EDI-00959 in the ERP mirror 20 minutes before the first
--      draft. mcp_order_apply (restated in section 1, edited in place) now
--      refuses a PO on an ERP order of the same account within
--      erp_duplicate_window_days (default 180; cancelled orders and POs with
--      fewer than 3 digits, e.g. WARRANTY, never match):
--      possible_duplicate_erp:<erp order id>. It runs before the line loop.
--    * POs compare by order_po_norm (upper, A-Z0-9 only, a leading PO
--      prefix before digits and leading zeros dropped), in the portal probe
--      too.
--    * Test drafts: checked by both probes; an existing TEST draft only
--      blocks another test draft, never the real order.
--    * mcp_order_preview: an erp_po_match alert, first in the warnings.
--    * submit_order: a Claude-drafted order whose PO is on an ERP order not
--      named in its stored warnings (an EDI order that loaded after the
--      draft was reviewed) is refused: erp_duplicate_unreviewed.
--------------------------------------------------------------------------

-- A PO as the duplicate probes compare it. No SET search_path (so it can be
-- inlined); it calls only pg_catalog built-ins, schema-qualified.
create or replace function public.order_po_norm(p text)
returns text language sql immutable parallel safe as $$
  select nullif(pg_catalog.ltrim(pg_catalog.regexp_replace(
           pg_catalog.regexp_replace(pg_catalog.upper(coalesce(p, '')), '[^A-Z0-9]', '', 'g'),
           '^PO(?=[0-9])', ''), '0'), '')
$$;
revoke execute on function public.order_po_norm(text) from public, anon;
grant execute on function public.order_po_norm(text) to authenticated;
comment on function public.order_po_norm(text) is
  'A customer PO for duplicate checks: upper, letters and digits only, a leading PO before digits '
  'and leading zeros dropped (''PO# 0215647'' = ''215647''); null when nothing is left. Never '
  'used to store a PO (20261114090000).';

-- ERP orders of an account carrying a PO (order_po_norm), newest first, at
-- most 3, within p_days. Cancelled orders (X) never match, cancelled lines
-- are not counted; a PO with fewer than 3 digits never probes. SECURITY
-- INVOKER: from the DEFINER order functions it reads the whole mirror (they
-- have checked the book); from authenticated, RLS limits it to the book.
create or replace function public.order_erp_po_matches(p_customer_key text, p_po text, p_days int default 180)
returns jsonb language sql stable security invoker set search_path = public, erp as $$
  select coalesce(jsonb_agg(x.m order by x.m ->> 'order_date' desc, x.m ->> 'erp_order_id' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'erp_order_id',  f.order_id,
             'order_date',    min(f.order_date),
             'status',        any_value(coalesce(f.order_status_desc, f.order_status)),
             'lines',         count(*) filter (where f.line_status is distinct from 'X'),
             'units',         trim_scale(coalesce(sum(f.order_qty) filter (where f.line_status is distinct from 'X'), 0)),
             'po_as_entered', min(btrim(f.customer_po_number))) as m
    from erp.fact_order_line f
    where f.customer_key = p_customer_key
      and f.order_date >= current_date - greatest(coalesce(p_days, 180), 1)
      and f.order_status is distinct from 'X'
      and public.order_po_norm(f.customer_po_number) = public.order_po_norm(p_po)
    group by f.order_id
    order by min(f.order_date) desc, f.order_id desc
    limit 3) x
  where public.order_po_norm(p_po) ~ '[0-9]{3}'
$$;
revoke execute on function public.order_erp_po_matches(text, text, int) from public, anon;
grant execute on function public.order_erp_po_matches(text, text, int) to authenticated;
comment on function public.order_erp_po_matches(text, text, int) is
  'ERP orders (erp.fact_order_line) of one account whose PO equals p_po by order_po_norm, within '
  'p_days, not cancelled: [{erp_order_id, order_date, status, lines, units, po_as_entered}], newest '
  'first, at most 3. POs with fewer than 3 digits never match. RLS-scoped (SECURITY INVOKER) '
  '(20261114090000).';

-- The ERP probe's window for the functions that get no params (preview,
-- submit): feature.mcp_orders params.erp_duplicate_window_days, default 180.
create or replace function public.order_erp_dup_window_days()
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select (s.params ->> 'erp_duplicate_window_days')::int
                     from public.app_settings s where s.setting_key = 'feature.mcp_orders'), 180)
$$;
revoke execute on function public.order_erp_dup_window_days() from public, anon, authenticated;

-- mcp_order_preview (restated whole from 20261113090000). Section 2 adds
-- the erp_po_match alert and its ALREADY IN THE ERP warning line, first.
-- Section 3 (shipto) reads the main address ('<ck>|CUST') as a ship-to and
-- flags it (ship_to_main_address); ship_to gains kind and zip. Section 4
-- (contact_header) adds contact_not_on_file, contact_differs_from_po,
-- cancel_date_*, terms_mismatch, po_total_mismatch,
-- ship_to_location_mismatch, upc_mismatch, buyer_part_conflict, the po and
-- po_contact blocks, and per-line buyer_part_number / upc (when set).
-- Section 5 (size) collapses the per-part Stock / inactive sentences and the
-- per-line price_mismatch alerts and sentences past 3, returns stock_short,
-- inactive_parts and part_count, scales ats_qty, and caps the alert strings.

create or replace function public.mcp_order_preview(p_order_id bigint, p_replayed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
declare
  c_ok    constant text := '__mcp_dry_run_ok__';
  o       public.orders;
  v_ok    boolean := false;
  v_err   text;
  v_lines jsonb;
  v_total numeric;
  v_ship  erp.dim_ship_to;
  v_has_ship boolean := false;
  v_kind  text;
  v_main_ok boolean := false;
  v_cust  record;
  v_needs boolean;
  v_cur   boolean := false;
  v_onf   boolean := false;
  v_contact jsonb;
  v_warn  text[] := '{}';
  v_alerts jsonb := '[]'::jsonb;
  v_head  text[] := '{}';
  v_adm   record;
  v_n_ok  int;
  v_dry   text;
  v_erp   jsonb := '[]'::jsonb;
  r       record;
  -- Section 4 (contact_header)
  v_m     jsonb;
  v_x     record;
  v_loc_key text;
  v_loc_ok  boolean;
  v_why   text;
  -- Section 5 (size): per-part and per-line lists collapse past c_each.
  c_each   constant int := 3;
  v_short  jsonb := '[]'::jsonb;   -- [{part_id, ats_qty, qty}] per part, order of first appearance
  v_inact  jsonb := '[]'::jsonb;   -- [{part_id, status}]
  v_pm     jsonb := '[]'::jsonb;   -- price mismatches, per line
  v_nparts int := 0;
  v_list   text;
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
               'effective_unit_price', l.effective_unit_price, 'line_total', l.line_total,
               'expected_unit_price', l.mcp_expected_unit_price,
               'price_source', l.price_source, 'list_unit_price', l.list_unit_price,
               'customer_part_ref', l.customer_part_ref, 'customer_description', l.customer_description,
               'part_unresolved', l.part_unresolved,
               'last_paid_price', l.last_paid_price, 'last_paid_date', l.last_paid_date,
               'description_mismatch', l.description_mismatch)
               || jsonb_strip_nulls(jsonb_build_object('buyer_part_number', l.buyer_part_number, 'upc', l.upc))
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
             'effective_unit_price', l.effective_unit_price, 'line_total', l.line_total,
             'expected_unit_price', l.mcp_expected_unit_price,
               'price_source', l.price_source, 'list_unit_price', l.list_unit_price,
               'customer_part_ref', l.customer_part_ref, 'customer_description', l.customer_description,
               'part_unresolved', l.part_unresolved,
               'last_paid_price', l.last_paid_price, 'last_paid_date', l.last_paid_date,
               'description_mismatch', l.description_mismatch)
             || jsonb_strip_nulls(jsonb_build_object('buyer_part_number', l.buyer_part_number, 'upc', l.upc))
             order by l.id),
           sum(l.line_total)
      into v_lines, v_total
    from public.order_lines l join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = p_order_id;
  end if;

  -- Stock never blocks; each line carries its part's available-to-sell
  -- (ats_qty), and the warning below compares it per part.
  -- Section 5: trim_scale (5, not 5.00000000).
  select coalesce(jsonb_agg(x.line || jsonb_build_object('ats_qty', trim_scale(x.ats)) order by x.ord), '[]'::jsonb)
    into v_lines
  from (
    select e.line, e.ord,
           (select sum(a.available_to_sell_qty)
              from erp.fact_available_to_sell a
              join erp.dim_part dp on dp.part_key = a.part_key
             where dp.part_id = e.line ->> 'part_id') as ats
    from jsonb_array_elements(coalesce(v_lines, '[]'::jsonb)) with ordinality as e(line, ord)
  ) x;

  -- Section 2 (dup), 20261114090000: the PO is already on an ERP order for
  -- this account. Recomputed on every preview (the mirror loads hourly), and
  -- FIRST in the warnings. A warning, not hard: allow_duplicate was sent, or
  -- the ERP order loaded after the draft was made; submit_order refuses the
  -- latter until the warning has been stored for the person submitting.
  if o.status = 'draft'
     and nullif(btrim(o.po_number, E' \t\r\n\u00A0'), '') is not null
     and upper(btrim(o.po_number, E' \t\r\n\u00A0')) <> 'PORTAL-' || o.id then
    v_erp := public.order_erp_po_matches(o.customer_key, o.po_number, public.order_erp_dup_window_days());
  end if;
  if jsonb_array_length(v_erp) > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'erp_po_match', 'severity', 'warning',
      'erp_orders', v_erp,
      'may_be_this_order', o.recalled_at is not null,
      'message', 'This PO is already on an order in the ERP. Submitting this draft would enter a second order.');
    v_head := v_head || format(
      'ALREADY IN THE ERP: PO %s is on ERP order %s (%s, %s, %s lines). Submitting creates a second order; '
      'confirm with the user that it is wanted.%s',
      btrim(o.po_number, E' \t\r\n\u00A0'),
      (select string_agg(m ->> 'erp_order_id', ', ') from jsonb_array_elements(v_erp) m),
      v_erp -> 0 ->> 'order_date', v_erp -> 0 ->> 'status', v_erp -> 0 ->> 'lines',
      case when o.recalled_at is not null
           then ' This draft was submitted before and recalled: the ERP order may be its own entry.'
           else '' end);
  end if;

  -- Hand pricing and unmatched parts (20261112120000): these lead the
  -- warnings, in capitals, and carry alerts of their own. The alert type
  -- and the admin_* keys keep their names; the words say "hand-priced".
  select count(*) as n,
         count(*) filter (where l.price_source = 'admin') as n_admin,
         count(*) filter (where l.price_source = 'admin' and l.list_unit_price is null and not l.part_unresolved) as n_off,
         count(*) filter (where l.price_source = 'admin' and l.list_unit_price is not null) as n_diff,
         count(*) filter (where l.part_unresolved) as n_unres,
         coalesce(sum(l.qty * l.unit_price) filter (where l.price_source = 'admin'), 0) as admin_value,
         coalesce(sum(l.qty * (l.list_unit_price - l.unit_price))
                    filter (where l.price_source = 'admin' and l.list_unit_price is not null), 0) as under_list,
         string_agg(coalesce(l.customer_part_ref, l.part_id), ', ' order by l.id)
           filter (where l.part_unresolved) as unres_refs,
         count(*) filter (where l.description_mismatch) as n_desc,
         string_agg(format('%s matched to %s', coalesce(l.customer_part_ref, l.part_id), l.part_id), '; ' order by l.id)
           filter (where l.description_mismatch) as desc_refs,
         count(*) filter (where l.price_source = 'admin' and l.last_paid_price is not null
                            and l.last_paid_price <> l.unit_price) as n_vs_paid
    into v_adm
  from public.order_lines l where l.order_id = p_order_id;
  if v_adm.n_unres > 0 then
    v_alerts := v_alerts || (jsonb_build_object('type', 'unmatched_parts', 'severity', 'hard',
      'count', v_adm.n_unres, 'refs', left(v_adm.unres_refs, 600),
      'message', 'Lines that match no ERP part: the order cannot be submitted until each is corrected or removed.')
      -- Section 4: an unmatched line whose UPC is a part's UPC names it.
      -- One pass over dim_part for all such lines (order_upc_norm is not
      -- indexable), and only when there is one.
      || case when exists (select 1 from public.order_lines l
                           where l.order_id = p_order_id and l.part_unresolved and l.upc is not null)
         then coalesce((
           select jsonb_build_object('upc_suggests', jsonb_agg(jsonb_build_object(
                    'ref', coalesce(u.customer_part_ref, u.part_id), 'upc', u.upc, 'part_id', d.part_id)
                    order by u.id, d.part_id))
           from (select l.id, l.part_id, l.customer_part_ref, l.upc, public.order_upc_norm(l.upc) as n
                   from public.order_lines l
                  where l.order_id = p_order_id and l.part_unresolved and l.upc is not null) u
           join (select distinct dp.part_id, public.order_upc_norm(dp.upc) as n
                   from erp.dim_part dp
                  where dp.upc ~ '\d{8}' and not coalesce(dp.is_unknown_part, false)) d on d.n = u.n
           having count(*) > 0), '{}'::jsonb)
         else '{}'::jsonb end);
    v_head := v_head || format(
      'UNMATCHED PARTS: %s line(s) match no part in the ERP (%s). They are staged as sent; the order '
      'cannot be submitted until each is corrected (update_order_draft with the right part_id) or removed.',
      v_adm.n_unres, left(v_adm.unres_refs, 400));
  end if;
  if v_adm.n_desc > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'description_check', 'severity', 'warning',
      'count', v_adm.n_desc, 'lines', left(v_adm.desc_refs, 600));
    v_head := v_head || format(
      'DESCRIPTION CHECK: on %s line(s) the PO''s description does not look like the part it was matched to '
      '(%s). Likely a typo in the PO''s item number: confirm each with the user.',
      v_adm.n_desc, left(v_adm.desc_refs, 600));
  end if;
  if v_adm.n_admin > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'admin_pricing', 'severity', 'warning',
      'lines', v_adm.n_admin, 'off_list', v_adm.n_off, 'differs_from_list', v_adm.n_diff,
      'unmatched', v_adm.n_unres, 'admin_value', v_adm.admin_value, 'below_list', v_adm.under_list,
      'reason', o.price_override_reason,
      'message', 'Hand-priced lines: an admin, or inside sales on their own order, submits it after reviewing each flagged line.');
    v_head := v_head || format(
      'HAND PRICING - CHECK EVERY FLAGGED LINE: %s of %s lines are not at the published price '
      '(%s on no price list for this account, %s priced differently from the list, %s unmatched). '
      'Hand-priced value %s; %s below list on the lines that have a list price. Reason: "%s". '
      'An admin, or inside sales on their own order, submits it after reviewing each flagged line.',
      v_adm.n_admin, v_adm.n, v_adm.n_off, v_adm.n_diff, v_adm.n_unres,
      '$' || to_char(v_adm.admin_value, 'FM999,999,990.00'), '$' || to_char(v_adm.under_list, 'FM999,999,990.00'),
      coalesce(o.price_override_reason, 'none given'));
    if v_adm.n_vs_paid > 0 then
      v_head := v_head || format(
        'PRICE VS LAST PAID: %s hand-priced line(s) differ from what this customer last paid for the part.',
        v_adm.n_vs_paid);
    end if;
  end if;

  -- No customer PO: blank after any whitespace, or a draft still carrying
  -- its own PORTAL-<id> (given at a submit, then recalled). The "No
  -- customer PO" prefix is what the portal looks for.
  if nullif(btrim(o.po_number, E' \t\r\n\u00A0'), '') is null
     or (o.status = 'draft' and upper(btrim(o.po_number, E' \t\r\n\u00A0')) = 'PORTAL-' || o.id) then
    v_alerts := v_alerts || jsonb_build_object('type', 'no_customer_po', 'severity', 'warning',
      'assigned_reference', 'PORTAL-' || o.id,
      'message', 'No customer PO number: the order is given the reference PORTAL-' || o.id || ' when it is submitted. Add the real PO if the customer has one.');
    v_warn := v_warn || format('No customer PO: it will be submitted as PORTAL-%s. Ask the customer for a PO number if they use them.', o.id);
  end if;

  if o.is_test then
    v_alerts := v_alerts || jsonb_build_object('type', 'test_order', 'severity', 'hard',
      'message', 'Test draft: it is labelled TEST in the portal and can never be submitted.');
    v_warn := v_warn || 'TEST ORDER: this draft was made as a test and cannot be submitted.'::text;
  end if;

  -- The user's expected price is checked per line. Section 5 (size): up to
  -- c_each mismatches keep their own alert and sentence (the text as
  -- before); more collapse into ONE alert (count, the first 10 parts,
  -- total_difference = the lines at the effective price less at the
  -- expected price) and ONE sentence. The sentences are stored in
  -- orders.mcp_warnings, so the collapse is here, not in the edge function.
  select coalesce(jsonb_agg(jsonb_build_object(
           'part_id', e.line ->> 'part_id',
           'expected', (e.line ->> 'expected_unit_price')::numeric,
           'list', (e.line ->> 'unit_price')::numeric,
           'effective', (e.line ->> 'effective_unit_price')::numeric,
           'difference', (e.line ->> 'effective_unit_price')::numeric - (e.line ->> 'expected_unit_price')::numeric,
           'price_list', e.line ->> 'price_list_name',
           'qty', (e.line ->> 'qty')::int) order by e.ord), '[]'::jsonb)
    into v_pm
  from jsonb_array_elements(v_lines) with ordinality as e(line, ord)
  where not coalesce((e.line ->> 'part_unresolved')::boolean, false)
    and e.line ->> 'expected_unit_price' is not null
    and (e.line ->> 'expected_unit_price')::numeric is distinct from (e.line ->> 'effective_unit_price')::numeric;
  if jsonb_array_length(v_pm) between 1 and c_each then
    for r in
      select m ->> 'part_id' as part_id, (m ->> 'list')::numeric as list_price,
             (m ->> 'effective')::numeric as eff_price, (m ->> 'expected')::numeric as expected,
             m ->> 'price_list' as list_name
      from jsonb_array_elements(v_pm) with ordinality t(m, n) order by n
    loop
      v_alerts := v_alerts || jsonb_build_object(
        'type', 'price_mismatch', 'severity', 'warning', 'part_id', r.part_id,
        'expected', r.expected, 'list', r.list_price, 'effective', r.eff_price,
        'difference', r.eff_price - r.expected, 'price_list', r.list_name);
      v_warn := v_warn || format('Price: the user expected $%s for %s; %s prices it at $%s (%s$%s each). The draft keeps the list price: a different price is agreed outside the portal.',
                                 to_char(r.expected, 'FM999,999,990.00'), r.part_id, r.list_name,
                                 to_char(r.eff_price, 'FM999,999,990.00'),
                                 case when r.eff_price > r.expected then '+' else '-' end,
                                 to_char(abs(r.eff_price - r.expected), 'FM999,999,990.00'));
    end loop;
  elsif jsonb_array_length(v_pm) > c_each then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'price_mismatch', 'severity', 'warning',
      'count', jsonb_array_length(v_pm),
      'parts', (select jsonb_agg(jsonb_build_object('part_id', m ->> 'part_id', 'expected', m -> 'expected',
                                                    'effective', m -> 'effective') order by n)
                  from jsonb_array_elements(v_pm) with ordinality t(m, n) where n <= 10),
      'total_difference', (select sum((m ->> 'difference')::numeric * (m ->> 'qty')::int)
                             from jsonb_array_elements(v_pm) m),
      'message', 'Lines where the user expected a different price than the server''s. The draft keeps the server prices: a different price is agreed outside the portal.');
    select string_agg(format('%s ($%s expected, $%s here)', m ->> 'part_id',
                             to_char((m ->> 'expected')::numeric, 'FM999,999,990.00'),
                             to_char((m ->> 'effective')::numeric, 'FM999,999,990.00')), ', ' order by n)
      into v_list
    from jsonb_array_elements(v_pm) with ordinality t(m, n) where n <= 10;
    v_warn := v_warn || format(
      'Price: on %s lines the user expected a different price than the draft''s: %s%s. Difference over those lines %s. '
      'The draft keeps its prices: a different price is agreed outside the portal.',
      jsonb_array_length(v_pm), v_list,
      case when jsonb_array_length(v_pm) > 10 then format(' and %s more', jsonb_array_length(v_pm) - 10) else '' end,
      (select case when s >= 0 then '+$' else '-$' end || to_char(abs(s), 'FM999,999,990.00')
         from (select sum((m ->> 'difference')::numeric * (m ->> 'qty')::int) s
                 from jsonb_array_elements(v_pm) m) z));
  end if;

  -- Stock and part status per PART, over the order's total qty, once each:
  -- free goods put one part on two lines (5 available, 5 paid + 1 free is
  -- short). Section 5 (size): collected first; up to c_each parts keep
  -- their own sentence (the text as before), more become ONE sentence that
  -- names the first 10. The full lists are returned as stock_short and
  -- inactive_parts (not stored: mcp_warnings stays a list of strings).
  for r in
    select g.part_id, g.qty, g.ats,
           (select min(dp.status) from erp.dim_part dp where dp.part_id = g.part_id) as status
    from (select e.line ->> 'part_id' as part_id,
                 sum((e.line ->> 'qty')::int) as qty,
                 max((e.line ->> 'ats_qty')::numeric) as ats,
                 min(e.ord) as ord
            from jsonb_array_elements(v_lines) with ordinality as e(line, ord)
           where not coalesce((e.line ->> 'part_unresolved')::boolean, false)
           group by e.line ->> 'part_id') g
    order by g.ord
  loop
    v_nparts := v_nparts + 1;
    if r.ats is null or r.ats < r.qty then
      v_short := v_short || jsonb_build_array(jsonb_build_object(
                   'part_id', r.part_id, 'ats_qty', trim_scale(r.ats), 'qty', r.qty));
    end if;
    if r.status is distinct from 'A' then
      v_inact := v_inact || jsonb_build_array(jsonb_build_object('part_id', r.part_id, 'status', r.status));
    end if;
  end loop;

  if jsonb_array_length(v_short) between 1 and c_each then
    v_warn := v_warn || array(
      select format('Stock: %s has %s available to sell; %s ordered in all. Stock does not block the order.',
                    s ->> 'part_id', coalesce(s ->> 'ats_qty', 'no'), s ->> 'qty')
      from jsonb_array_elements(v_short) with ordinality t(s, n) order by n);
  elsif jsonb_array_length(v_short) > c_each then
    select string_agg(format('%s (%s/%s)', s ->> 'part_id', coalesce(s ->> 'ats_qty', 'none'), s ->> 'qty'), ', ' order by n)
      into v_list
    from jsonb_array_elements(v_short) with ordinality t(s, n) where n <= 10;
    v_warn := v_warn || format(
      'Stock: %s of %s parts are short (ordered more than available to sell; shown as available/ordered): %s%s. Stock does not block the order.',
      jsonb_array_length(v_short), v_nparts, v_list,
      case when jsonb_array_length(v_short) > 10 then format(' and %s more', jsonb_array_length(v_short) - 10) else '' end);
  end if;

  if jsonb_array_length(v_inact) between 1 and c_each then
    v_warn := v_warn || array(
      select format('%s is not an active part in the ERP (status %s).', s ->> 'part_id', coalesce(s ->> 'status', 'unknown'))
      from jsonb_array_elements(v_inact) with ordinality t(s, n) order by n);
  elsif jsonb_array_length(v_inact) > c_each then
    select string_agg(format('%s (status %s)', s ->> 'part_id', coalesce(s ->> 'status', 'unknown')), ', ' order by n)
      into v_list
    from jsonb_array_elements(v_inact) with ordinality t(s, n) where n <= 10;
    v_warn := v_warn || format('%s parts are not active in the ERP: %s%s.',
      jsonb_array_length(v_inact), v_list,
      case when jsonb_array_length(v_inact) > 10 then format(' and %s more', jsonb_array_length(v_inact) - 10) else '' end);
  end if;

  select dc.customer_name, dc.credit_status, dc.active_flag, dc.ar_terms_rule_id into v_cust
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
  -- Section 3 (shipto): a real ship-to or the account's main address
  -- ('<ck>|CUST', kind customer_address).
  if o.ship_to_key is not null then
    select s.* into v_ship from erp.dim_ship_to s
    where s.ship_to_key = o.ship_to_key
      and s.customer_id = o.customer_key
      and public.order_ship_to_kind(s.ship_to_key, s.customer_id, s.address_source,
                                    s.ship_to_id, s.is_unknown_ship_to) is not null;
    v_has_ship := found;
    if v_has_ship then
      v_kind := public.order_ship_to_kind(v_ship.ship_to_key, v_ship.customer_id, v_ship.address_source,
                                          v_ship.ship_to_id, v_ship.is_unknown_ship_to);
    end if;
  end if;
  if v_has_ship then
    v_onf := length(public.ffl_normalize(v_ship.ffl_license_number)) = 15;
    v_cur := public.ffl_on_file_current(v_ship.ffl_license_number, v_ship.ffl_expiration_raw);
  else
    select count(*) into v_n_ok
    from erp.dim_ship_to s
    where s.customer_id = o.customer_key
      and public.order_ship_to_kind(s.ship_to_key, s.customer_id, s.address_source,
                                    s.ship_to_id, s.is_unknown_ship_to) = 'ship_to'
      and upper(coalesce(s.active_flag, 'Y')) <> 'N';
    select coalesce(bool_or(public.order_ship_to_orderable('customer_address', s.active_flag, s.address1, s.city)), false)
      into v_main_ok
    from erp.dim_ship_to s
    where s.ship_to_key = o.customer_key || '|CUST' and s.customer_id = o.customer_key
      and s.address_source = 'CustomerMaster';
    if v_n_ok = 0 and v_main_ok then
      v_warn := v_warn || format('No ship-to chosen: the account has no ship-to; its main address can be used (ship_to_key %s|CUST). Update the draft.', o.customer_key);
    else
      v_warn := v_warn || format('No ship-to chosen: the account has %s ship-to addresses that can take an order. Ask which one, then update the draft.', v_n_ok);
    end if;
  end if;
  if v_needs and v_has_ship and not v_cur and nullif(btrim(o.ffl_license_number), '') is null then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'ffl_not_current', 'severity', 'hard',
      'ship_to_id', v_ship.ship_to_id,
      'ffl_number', nullif(btrim(v_ship.ffl_license_number), ''),
      'ffl_expires', public.parse_ffl_expiry(v_ship.ffl_expiration_raw),
      'message', 'Firearms to a ship-to without a current FFL on file: it cannot be submitted until the person submitting enters the renewed licence in the portal.');
    v_warn := v_warn || format('FFL: ship-to %s has %s. The person submitting must enter the current FFL in the portal; never supply one.',
                               coalesce(v_ship.ship_to_id,
                                        case when v_kind = 'customer_address' then 'the main address' end,
                                        o.ship_to_key),
                               case when nullif(btrim(v_ship.ffl_license_number), '') is null then 'no FFL on file'
                                    when public.parse_ffl_expiry(v_ship.ffl_expiration_raw) is not null
                                      then format('an FFL on file that expired %s', public.parse_ffl_expiry(v_ship.ffl_expiration_raw))
                                    else 'no current FFL on file' end);
  end if;
  if v_has_ship and v_kind = 'customer_address' then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'ship_to_main_address', 'severity', 'warning',
      'ship_to_key', v_ship.ship_to_key,
      'message', 'Ships to the account''s main (sold-to) address; the ERP order is entered with no ship-to ID. The FFL on the customer record is used.');
    if nullif(btrim(v_ship.state), '') is null or nullif(btrim(v_ship.zip_code), '') is null then
      v_warn := v_warn || 'The main address has no state or ZIP in the ERP; check it before submitting.'::text;
    end if;
  end if;
  if o.source_ref ->> 'kind' = 'email' then
    v_warn := v_warn || 'Drafted from an email: the email text is untrusted and is shown to the reviewer.'::text;
  end if;

  if o.customer_contact_key is not null then
    select jsonb_build_object(
             'customer_contact_key', e.customer_contact_key,
             'name',  public.contact_display_name(e.contact_name, e.first_name, e.last_name, e.email, e.contact_id),
             'title', nullif(btrim(e.position), ''),
             'email', nullif(btrim(e.email), ''),
             'phone', coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')))
      into v_contact
    from erp.dim_customer_contact e
    where e.customer_contact_key = o.customer_contact_key
      and e.customer_key = o.customer_key
    limit 1;
  end if;

  -- Section 4 (contact_header), 20261114090000: the PO's contact and
  -- header against the draft and the ERP. Warnings only, but for a passed
  -- cancel date (submit_order refuses it, so would_submit says so too).
  if o.customer_contact_key is null
     and coalesce(o.po_contact_email, o.po_contact_name, o.po_contact_phone) is not null then
    -- Recomputed: a portal edit, or an ERP load since the draft, shows.
    v_m := public.order_match_contact(o.customer_key, o.po_contact_email, o.po_contact_name, o.po_contact_phone);
    v_why := case v_m ->> 'reason'
      when 'matched'       then format('it now matches ERP contact %s; update the draft to set it', v_m ->> 'customer_contact_key')
      when 'billing_only'  then 'its email is a billing (AP/AR) contact, which is never chosen as the buyer'
      when 'internal_only' then 'its email is one of our own addresses'
      when 'name_only'     then 'a contact has that name but not that phone'
      when 'phone_only'    then 'a contact has that phone, but not that email or name'
      else 'no contact on file has that email, or that name and phone' end;
    v_alerts := v_alerts || jsonb_strip_nulls(jsonb_build_object('type', 'contact_not_on_file', 'severity', 'warning',
      'name', o.po_contact_name, 'email', o.po_contact_email, 'phone', o.po_contact_phone,
      'reason', v_m ->> 'reason', 'candidates', v_m -> 'candidates',
      'message', format('The PO''s contact is not an ERP contact of this account (%s). It is staged on the order and '
                        'written to the ERP order as text; add them as a contact in the ERP, or pick one from '
                        'get_order_context.contacts and send customer_contact_key.', v_why)));
    v_head := v_head || format('CONTACT NOT ON FILE: the PO''s contact %s is not an ERP contact of this account (%s). '
                               'It goes to the ERP order as text unless a contact is picked.',
                               concat_ws(', ', o.po_contact_name, o.po_contact_email, o.po_contact_phone), v_why);
  elsif v_contact is not null and public.order_first_email(o.po_contact_email) is not null
        and not (public.order_first_email(o.po_contact_email)
                 = any (regexp_split_to_array(lower(coalesce(v_contact ->> 'email', '')), '[;,\s]+'))) then
    v_alerts := v_alerts || jsonb_build_object('type', 'contact_differs_from_po', 'severity', 'warning',
      'po_email', o.po_contact_email, 'contact_email', v_contact ->> 'email',
      'message', 'The order''s contact is not the email the PO names; confirm the contact with the user.');
    v_warn := v_warn || format('Contact: the PO names %s; the order''s contact is %s.',
                               o.po_contact_email, coalesce(v_contact ->> 'name', v_contact ->> 'email', o.customer_contact_key));
  end if;

  if o.po_cancel_date is not null then
    if o.po_cancel_date < current_date then
      v_alerts := v_alerts || jsonb_build_object('type', 'cancel_date_passed', 'severity', 'hard',
        'cancel_date', o.po_cancel_date,
        'message', format('The PO''s cancel date %s has passed: it cannot be submitted until the customer confirms '
                          'and the cancel date is changed or cleared.', o.po_cancel_date));
      v_head := v_head || format('CANCEL DATE PASSED: the PO says cancel after %s. Confirm with the customer, then '
                                 'update cancel_date (or send null to clear it) before it can be submitted.', o.po_cancel_date);
    elsif o.po_cancel_date <= current_date + 7 then
      v_alerts := v_alerts || jsonb_build_object('type', 'cancel_date_soon', 'severity', 'warning',
        'cancel_date', o.po_cancel_date);
      v_warn := v_warn || format('Cancel date: the PO is cancelled if not shipped by %s.', o.po_cancel_date);
    end if;
    if o.requested_ship_date > o.po_cancel_date then
      v_alerts := v_alerts || jsonb_build_object('type', 'cancel_before_ship_date', 'severity', 'warning',
        'cancel_date', o.po_cancel_date, 'requested_ship_date', o.requested_ship_date);
      v_warn := v_warn || format('The requested ship date %s is after the PO''s cancel date %s.',
                                 o.requested_ship_date, o.po_cancel_date);
    end if;
  end if;

  -- Terms are never sent to the ERP: the account's terms apply.
  if o.po_payment_terms is not null
     and public.order_terms_canon(o.po_payment_terms) is distinct from public.order_terms_canon(v_cust.ar_terms_rule_id) then
    v_alerts := v_alerts || jsonb_build_object('type', 'terms_mismatch', 'severity', 'warning',
      'po_terms', o.po_payment_terms, 'customer_terms', coalesce(v_cust.ar_terms_rule_id, 'none on file'),
      'message', 'The PO''s terms are not the account''s ERP terms. The ERP terms apply (PO terms are not sent to '
                 'the ERP); a PO stating net terms on a prepay, COD or card account is a credit question for AR.');
    v_warn := v_warn || format('Terms: the PO states %s; the account''s ERP terms are %s, and those apply.',
                               o.po_payment_terms, coalesce(v_cust.ar_terms_rule_id, 'none on file'));
  end if;

  if o.po_total is not null and abs(o.po_total - coalesce(v_total, 0)) > 0.01 then
    v_alerts := v_alerts || jsonb_build_object('type', 'po_total_mismatch', 'severity', 'warning',
      'po_total', o.po_total, 'order_total', coalesce(v_total, 0),
      'difference', coalesce(v_total, 0) - o.po_total, 'lines', v_adm.n,
      'message', 'The draft does not total what the PO states: check for missing lines or prices that differ from the PO.');
    v_head := v_head || format('PO TOTAL: the PO totals %s; this draft totals %s (%s%s over %s lines). Check for '
                               'missing lines or prices that differ from the PO.',
                               '$' || to_char(o.po_total, 'FM999,999,990.00'),
                               '$' || to_char(coalesce(v_total, 0), 'FM999,999,990.00'),
                               case when coalesce(v_total, 0) >= o.po_total then '+$' else '-$' end,
                               to_char(abs(coalesce(v_total, 0) - o.po_total), 'FM999,999,990.00'), v_adm.n);
  end if;

  if o.po_ship_to_location is not null and v_has_ship then
    v_loc_ok := case when v_kind = 'customer_address'
                     then upper(btrim(o.po_ship_to_location)) in ('MAIN', upper(o.customer_key))
                     else upper(btrim(v_ship.ship_to_id)) = upper(btrim(o.po_ship_to_location)) end;
    if not v_loc_ok then
      v_loc_key := public.order_ship_to_for_location(o.customer_key, o.po_ship_to_location);
      v_alerts := v_alerts || jsonb_strip_nulls(jsonb_build_object('type', 'ship_to_location_mismatch', 'severity', 'warning',
        'po_location', o.po_ship_to_location, 'ship_to_id', v_ship.ship_to_id,
        'matching_ship_to_key', v_loc_key));
      v_head := v_head || format('SHIP-TO CHECK: the PO''s Ship To Location is %s, but the order ships to %s%s.',
                                 o.po_ship_to_location, coalesce(v_ship.ship_to_id, 'the main address'),
                                 case when v_loc_key is not null then format(' (ship_to_key %s is %s)', v_loc_key, o.po_ship_to_location)
                                      else '' end);
    end if;
  end if;

  if nullif(btrim(o.po_ship_via), '') is not null
     and o.po_ship_via !~* '^\s*(best\s*way|bw|any|prepaid|ppd)\s*$' then
    v_warn := v_warn || format('Ship via: the PO asks for %s; the ERP default (%s) applies unless the reviewer changes it.',
                               o.po_ship_via,
                               coalesce(case when v_has_ship then nullif(btrim(v_ship.ship_via), '') end,
                                        (select nullif(btrim(s.ship_via), '') from erp.dim_ship_to s
                                          where s.ship_to_key = o.customer_key || '|CUST'),
                                        'none on file'));
  end if;

  -- UPC on the PO vs the matched part's (ERP junk like TBD never compares).
  select count(*) as n,
         string_agg(format('%s matched to %s (PO UPC %s, part UPC %s)', coalesce(l.customer_part_ref, l.part_id),
                           l.part_id, l.upc, p.upc), '; ' order by l.id) as refs,
         -- review fix: each flagged line's position in preview.lines (ordered by id),
         -- so the summary preview lists every one, not just the 600-char text.
         jsonb_agg(l.idx order by l.id) as idxs
    into v_x
  from (select l0.*, (row_number() over (order by l0.id) - 1)::int as idx
          from public.order_lines l0 where l0.order_id = p_order_id) l
  cross join lateral (select dp.upc from erp.dim_part dp
                       where dp.part_id = l.part_id and public.order_upc_norm(dp.upc) is not null
                       order by coalesce(dp.is_unknown_part, false), dp.part_key limit 1) p
  where l.order_id = p_order_id and l.upc is not null and not l.part_unresolved
    and public.order_upc_norm(l.upc) is distinct from public.order_upc_norm(p.upc);
  if v_x.n > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'upc_mismatch', 'severity', 'warning',
      'count', v_x.n, 'lines', left(v_x.refs, 600), 'line_indexes', v_x.idxs);
    v_head := v_head || format('UPC CHECK: on %s line(s) the PO''s UPC is not the part''s (%s). Confirm each with the user.',
                               v_x.n, left(v_x.refs, 600));
  end if;

  -- The customer's own item number, on their ERP history, for another part.
  -- One query (idx_fol_customer), not one per line.
  select count(*) as n,
         string_agg(format('%s: item %s was %s on ERP order %s', l.part_id, l.buyer_part_number, h.part_id, h.order_id),
                    '; ' order by l.id) as refs,
         jsonb_agg(l.idx order by l.id) as idxs   -- review fix, as upc_mismatch
    into v_x
  from (select l0.*, (row_number() over (order by l0.id) - 1)::int as idx
          from public.order_lines l0 where l0.order_id = p_order_id) l
  join (select distinct on (f.customer_part_id) f.customer_part_id, dp.part_id, f.order_id
          from erp.fact_order_line f
          join erp.dim_part dp on dp.part_key = f.part_key
         where f.customer_key = o.customer_key
           and f.customer_part_id in (select l2.buyer_part_number from public.order_lines l2
                                       where l2.order_id = p_order_id and l2.buyer_part_number is not null)
         order by f.customer_part_id, f.order_date desc nulls last, f.order_id desc, f.line_num desc) h
    on h.customer_part_id = l.buyer_part_number
  where l.order_id = p_order_id and not l.part_unresolved and h.part_id <> l.part_id;
  if v_x.n > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'buyer_part_conflict', 'severity', 'warning',
      'count', v_x.n, 'lines', left(v_x.refs, 600), 'line_indexes', v_x.idxs);
    v_head := v_head || format('CUSTOMER ITEM CHECK: on %s line(s) the customer''s item number was a different part on '
                               'their past ERP orders (%s). Confirm each with the user.', v_x.n, left(v_x.refs, 600));
  end if;

  return jsonb_build_object(
    'order_id',      o.id,
    'status',        o.status,
    'is_test',       o.is_test,
    'replayed',      coalesce(p_replayed, false),
    'source',        o.source,
    'customer_key',  o.customer_key,
    'customer_name', coalesce(v_cust.customer_name, nullif(o.customer_name, ''), o.customer_key),
    'po_number',     o.po_number,
    'requested_ship_date', o.requested_ship_date,
    'ship_to', case when v_has_ship then jsonb_build_object(
                 'ship_to_key', v_ship.ship_to_key,
                 'ship_to_id',  v_ship.ship_to_id,
                 'name',        v_ship.ship_to_name,
                 'address',     nullif(concat_ws(', ', nullif(btrim(v_ship.address1), ''),
                                  nullif(btrim(v_ship.address2), ''), nullif(btrim(v_ship.address3), '')), ''),
                 'city',        v_ship.city,
                 'state',       v_ship.state,
                 'kind',        v_kind,
                 'zip',         v_ship.zip_code)
               || case when o.po_ship_to_location is not null and v_loc_ok
                       then '{"po_location_matches": true}'::jsonb else '{}'::jsonb end end,
    'contact',       case when v_contact is not null
                          then v_contact || jsonb_strip_nulls(jsonb_build_object('matched_by', o.contact_match)) end,
    'requires_ffl',  v_needs,
    'ffl',           jsonb_build_object(
                       'on_file', v_onf, 'current', v_cur,
                       'number',  case when v_has_ship then nullif(btrim(v_ship.ffl_license_number), '') end,
                       'expires', case when v_has_ship then public.parse_ffl_expiry(v_ship.ffl_expiration_raw) end),
    'lines',         v_lines,
    'total_amount',  coalesce(v_total, 0),
    'admin_pricing', case when v_adm.n_admin > 0 then jsonb_build_object(
                       'lines', v_adm.n_admin, 'off_list', v_adm.n_off, 'differs_from_list', v_adm.n_diff,
                       'unmatched', v_adm.n_unres, 'admin_value', v_adm.admin_value,
                       'below_list', v_adm.under_list, 'reason', o.price_override_reason) end,
    'would_submit',  jsonb_build_object('ok', v_ok, 'error', v_err),
    'alerts',        v_alerts,
    'warnings',      to_jsonb(v_head || v_warn),
    'portal_path',   '/orders/' || o.id,
    -- Section 5 (size): the lists behind the collapsed sentences.
    'part_count',    v_nparts,
    'stock_short',   v_short,
    'inactive_parts', v_inact)
    -- Section 4: present only when set (the response-size budget).
    || jsonb_strip_nulls(jsonb_build_object(
    'po_contact', case when o.customer_contact_key is null
                           and coalesce(o.po_contact_email, o.po_contact_name, o.po_contact_phone) is not null
                          then jsonb_strip_nulls(jsonb_build_object('name', o.po_contact_name,
                                 'email', o.po_contact_email, 'phone', o.po_contact_phone)) end,
    'po', nullif(jsonb_strip_nulls(jsonb_build_object(
                       'date', o.po_date, 'cancel_date', o.po_cancel_date,
                       'payment_terms', o.po_payment_terms,
                       'customer_terms', case when o.po_payment_terms is not null then v_cust.ar_terms_rule_id end,
                       'ship_via', o.po_ship_via, 'vendor_number', o.po_vendor_number,
                       'ship_to_location', o.po_ship_to_location, 'total', o.po_total)), '{}'::jsonb)));
end;
$$;

revoke execute on function public.mcp_order_preview(bigint, boolean) from public, anon, authenticated;

-- submit_order (restated whole from 20261113090000). Section 2 adds the
-- erp_duplicate_unreviewed check. Section 3 (shipto) takes the main address
-- ('<ck>|CUST', no ship-to ID, FFL from the customer record) and stamps
-- ship_to_source. Section 4 (contact_header) refuses a passed PO cancel
-- date (cancel_date_passed), falls back to the PO's contact when there is
-- no contact key, and stamps contact_source.
create or replace function public.submit_order(p_order_id bigint, p_acknowledged boolean DEFAULT false)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
  v_cust  record;
  v_ship  erp.dim_ship_to;
  v_kind  text;
  v_bad   text;
  v_needs boolean;
  v_ffl   text;
  v_exp   date;
  v_ack   boolean := coalesce(p_acknowledged, false);
  v_guc   text := current_setting('app.mcp_order_write', true);
  v_n_admin int;
  v_cname  text;
  v_cphone text;
  v_cemail text;
  v_erp    jsonb;
  v_csrc   text;
begin
  -- A JWT outlives deactivation; the profile is the cutoff, not the token.
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;
  -- Claude never submits. An MCP session reaches this only through the
  -- draft preview's dry run (mcp_order_preview sets app.mcp_dry_run and
  -- always rolls the subtransaction back).
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp'
     and coalesce(current_setting('app.mcp_dry_run', true), '') <> 'on' then
    raise exception 'mcp_cannot_submit: Claude drafts orders; a person submits them in the portal'
      using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if not (v_order.user_id = v_uid or public.is_admin()) then
    raise exception 'only the order''s owner may submit it';
  end if;
  if v_order.status <> 'draft' then
    raise exception 'order % is %, only drafts can be submitted',
      p_order_id, v_order.status;
  end if;
  -- Claude (or any non-portal source) drafted it: a person must confirm it.
  if v_order.source <> 'portal' and not v_ack then
    raise exception 'acknowledge_required: order % was drafted by %; confirm you have reviewed it before submitting',
      p_order_id, case v_order.source when 'mcp' then 'Claude' else v_order.source end;
  end if;
  if not exists (select 1 from public.order_lines where order_id = p_order_id) then
    raise exception 'order % has no lines', p_order_id;
  end if;

  -- Section 2 (dup), 20261114090000: a Claude-drafted order whose PO is on
  -- an ERP order the person submitting was never shown. The reviewer sees
  -- only the warnings stored at create/update (orders.mcp_warnings); an EDI
  -- order that loaded after that is in none of them. Refused until the
  -- draft is cancelled or re-saved over MCP with allow_duplicate (which
  -- stores the ALREADY IN THE ERP warning). Not in the preview's dry run
  -- (the preview shows the alert itself), not for portal-typed orders.
  if v_order.source <> 'portal'
     and coalesce(current_setting('app.mcp_dry_run', true), '') <> 'on'
     and nullif(btrim(v_order.po_number, E' \t\r\n\u00A0'), '') is not null
     and upper(btrim(v_order.po_number, E' \t\r\n\u00A0')) <> 'PORTAL-' || v_order.id then
    v_erp := public.order_erp_po_matches(v_order.customer_key, v_order.po_number,
                                         public.order_erp_dup_window_days());
    select string_agg(m ->> 'erp_order_id', ', ') into v_bad
    from jsonb_array_elements(v_erp) m
    where not exists (
      select 1
      from jsonb_array_elements_text(case when jsonb_typeof(v_order.mcp_warnings) = 'array'
                                          then v_order.mcp_warnings else '[]'::jsonb end) w
      where w like 'ALREADY IN THE ERP:%' and strpos(w, m ->> 'erp_order_id') > 0);
    if v_bad is not null then
      raise exception 'erp_duplicate_unreviewed: PO % is already on ERP order % for this account, entered after this draft was reviewed. Cancel this draft if that order is the same one; if a second order is really wanted, have Claude update the draft with allow_duplicate so the warning is recorded, then submit',
        btrim(v_order.po_number, E' \t\r\n\u00A0'), v_bad;
    end if;
  end if;

  -- Unmatched items never leave draft.
  select string_agg(coalesce(l.customer_part_ref, l.part_id), ', ' order by l.id) into v_bad
  from public.order_lines l
  where l.order_id = p_order_id
    and (l.part_unresolved or not exists (select 1 from erp.dim_part dp where dp.part_id = l.part_id));
  if v_bad is not null then
    raise exception 'unmatched_parts: order % has lines that match no ERP part (%). Correct or remove them before submitting.',
      p_order_id, left(v_bad, 400);
  end if;

  -- Hand prices: an admin, or inside sales on their own order (the owner
  -- check above), submits, and only having acknowledged them.
  select count(*) into v_n_admin
  from public.order_lines l where l.order_id = p_order_id and l.price_source = 'admin';
  if v_n_admin > 0 then
    if not public.can_price_orders() then
      raise exception 'admin_price_requires_admin: order % has % line(s) priced by hand; only an admin, or inside sales on their own order, can submit it',
        p_order_id, v_n_admin;
    end if;
    if not v_ack then
      raise exception 'acknowledge_required: order % has % line(s) at admin prices; confirm you have reviewed every flagged line before submitting',
        p_order_id, v_n_admin;
    end if;
    if exists (select 1 from public.order_lines l
               where l.order_id = p_order_id and l.price_source = 'admin'
                 and l.price_list_id is distinct from public.admin_price_list_id()) then
      raise exception 'order % has an admin-priced line that is not on the admin price list', p_order_id;
    end if;
  end if;

  select c.customer_name, c.customer_type into v_cust
  from erp.dim_customer c where c.customer_key = v_order.customer_key;
  if not found then
    raise exception 'customer % not found in the ERP', v_order.customer_key;
  end if;

  -- A ship date already gone by would reach order entry as a date the ERP
  -- refuses; the person submitting fixes it first. current_date is the
  -- business date (America/Denver, 20260901190000).
  if v_order.requested_ship_date < current_date then
    raise exception 'ship_date_past: the requested ship date % has passed; change it before submitting',
      v_order.requested_ship_date;
  end if;
  -- Section 4 (contact_header): the customer's PO says not after this date.
  -- In the preview's dry run too, so would_submit shows it.
  if v_order.po_cancel_date < current_date then
    raise exception 'cancel_date_passed: the PO''s cancel date % has passed; confirm with the customer, then have Claude update the draft with a new cancel_date (or null to clear it)',
      v_order.po_cancel_date;
  end if;

  -- Ship-to: one of this account's own Visual ship-to addresses (CUST_ADDRESS,
  -- so it has a SHIPTO_ID the order can carry), and still active; or, when
  -- feature.order_main_address_ship_to is on, the account's main (sold-to)
  -- address ('<ck>|CUST': no ship-to ID, Visual ships to CUSTOMER.ADDR_*,
  -- the FFL on the customer record).
  if v_order.ship_to_key is null then
    raise exception 'pick a ship-to address for this order';
  end if;
  select s.* into v_ship from erp.dim_ship_to s where s.ship_to_key = v_order.ship_to_key;
  v_kind := case when found and v_ship.customer_id = v_order.customer_key
                 then public.order_ship_to_kind(v_ship.ship_to_key, v_ship.customer_id, v_ship.address_source,
                                                v_ship.ship_to_id, v_ship.is_unknown_ship_to) end;
  if v_kind is null then
    raise exception 'ship-to % is not one of this account''s ship-to addresses', v_order.ship_to_key;
  end if;
  if v_kind = 'ship_to' and upper(coalesce(v_ship.active_flag, 'Y')) = 'N' then
    raise exception 'ship-to % (%) is inactive in the ERP; pick another address',
      v_ship.ship_to_id, v_ship.ship_to_name;
  end if;
  if v_kind = 'customer_address'
     and not public.order_ship_to_orderable(v_kind, v_ship.active_flag, v_ship.address1, v_ship.city) then
    raise exception 'the account''s main address cannot take an order (inactive, incomplete in the ERP, or main-address orders are off); pick a ship-to';
  end if;

  -- FFL: only when a line is a firearm (part_requires_ffl). The ship-to's
  -- licence on file is used when it is complete and current; the rep enters
  -- one only when it is not (or to give a renewed licence). Whether an
  -- entered licence matches Visual is order entry's check: the loader
  -- refuses to write until the ship-to in Visual carries it.
  v_needs := exists (select 1 from public.order_lines l
                     where l.order_id = p_order_id and public.part_requires_ffl(l.part_id));
  if not v_needs then
    v_ffl := null;
    v_exp := null;
  elsif nullif(trim(v_order.ffl_license_number), '') is null
        and public.ffl_on_file_current(v_ship.ffl_license_number, v_ship.ffl_expiration_raw) then
    v_ffl := upper(trim(v_ship.ffl_license_number));
    v_exp := public.parse_ffl_expiry(v_ship.ffl_expiration_raw);
  else
    if length(public.ffl_normalize(v_order.ffl_license_number)) <> 15 then
      raise exception 'this order has firearms and ship-to % has no current FFL on file: enter the FFL '
        'number (15 characters, e.g. 1-23-456-78-9A-12345)', coalesce(v_ship.ship_to_id, 'the main address');
    end if;
    if v_order.ffl_expires_on is null then
      raise exception 'the FFL expiration date is required';
    end if;
    if v_order.ffl_expires_on < current_date then
      raise exception 'the FFL expired on %; get the renewed licence before submitting',
        v_order.ffl_expires_on;
    end if;
    v_ffl := upper(trim(v_order.ffl_license_number));
    v_exp := v_order.ffl_expires_on;
  end if;

  -- The buyer, as the ERP has them now: the order loader writes these to
  -- the Visual order (it reads the order, not erp.dim_customer_contact).
  -- Only an ACTIVE contact of this account: one deactivated since the draft,
  -- or a key pointing at another account (a portal PATCH can set one),
  -- stamps nothing, all three fields null.
  select public.contact_display_name(e.contact_name, e.first_name, e.last_name, null, null),
         coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')),
         nullif(btrim(e.email), '')
    into v_cname, v_cphone, v_cemail
  from erp.dim_customer_contact e
  where e.customer_contact_key = v_order.customer_contact_key
    and e.customer_key = v_order.customer_key
    and coalesce(e.contact_active_flag, 'Y') = 'Y'
  limit 1;
  -- Section 4 (contact_header): contact_source says where the snapshot
  -- came from. With no key at all, the PO's own contact (staged by
  -- mcp_order_apply when it matched no ERP contact) is written as text:
  -- 'po', and customer_contact_key stays null. A key that no longer
  -- resolves (inactive, another account's) stamps nothing, as before:
  -- never a PO contact next to an ERP key, never ERP and PO values mixed.
  if found then
    v_csrc := 'erp';
  elsif v_order.customer_contact_key is null
        and coalesce(v_order.po_contact_name, v_order.po_contact_email, v_order.po_contact_phone) is not null then
    v_cname  := v_order.po_contact_name;
    v_cphone := v_order.po_contact_phone;
    v_cemail := v_order.po_contact_email;
    v_csrc   := 'po';
  else
    v_cname := null; v_cphone := null; v_cemail := null;
    v_csrc  := null;
  end if;

  -- Every LIST-priced line must sit on a list effective today for this
  -- customer type, and its captured price must still be the published price.
  -- Admin lines were checked above.
  select string_agg(distinct l.part_id, ', ') into v_bad
  from public.order_lines l
  where l.order_id = p_order_id
    and l.price_source = 'list'
    and not exists (
      select 1
      from public.effective_price_lists(v_cust.customer_type) epl
      join public.price_list_items i
        on i.price_list_id = epl.id and i.part_id = l.part_id
      where epl.id = l.price_list_id
        and i.unit_price = l.unit_price
    );
  if v_bad is not null then
    raise exception 'lines no longer valid against today''s price lists: %. '
      'Re-open the draft to refresh pricing.', v_bad;
  end if;

  -- From here the server writes lines and protected columns: open the write
  -- window (order_lines_protect_pricing, orders_protect_provenance), then put
  -- the GUC back as it was.
  perform set_config('app.mcp_order_write', 'on', true);

  -- Authoritative promo pass (overwrites whatever the client previewed).
  -- The admin list has no promo: its lines keep their price.
  perform public.order_apply_promo(p_order_id);

  update public.orders o
  set status        = 'submitted',
      -- No customer PO (blank after any whitespace): the order's own
      -- reference, so the portal, the order loader and Visual's
      -- CUSTOMER_PO_REF all show the same thing. A real PO is stored trimmed.
      po_number     = coalesce(nullif(btrim(o.po_number, E' \t\r\n\u00A0'), ''), 'PORTAL-' || o.id),
      customer_name = coalesce(v_cust.customer_name, v_order.customer_key),
      customer_type = v_cust.customer_type,
      ship_to_id      = v_ship.ship_to_id,
      ship_to_addr_no = v_ship.addr_no,
      ship_to_name    = v_ship.ship_to_name,
      ship_to_address = concat_ws(', ',
                          nullif(trim(v_ship.address1), ''), nullif(trim(v_ship.address2), ''),
                          nullif(trim(v_ship.address3), ''), nullif(trim(v_ship.city), ''),
                          nullif(trim(concat_ws(' ', v_ship.state, v_ship.zip_code)), '')),
      requires_ffl               = v_needs,
      ffl_license_number         = v_ffl,
      ffl_expires_on             = v_exp,
      ffl_on_file_number         = v_ship.ffl_license_number,
      ffl_on_file_expiration_raw = v_ship.ffl_expiration_raw,
      ship_to_source = case v_kind when 'ship_to' then 'ship_to' else 'customer_address' end,
      total_amount  = (select sum(line_total) from public.order_lines
                       where order_id = p_order_id),
      -- The buyer snapshot (resolved above).
      contact_name  = v_cname,
      contact_phone = v_cphone,
      contact_email = v_cemail,
      contact_source = v_csrc,
      submitted_at  = now(),
      acknowledged_at = case when v_ack then now() else o.acknowledged_at end,
      acknowledged_by = case when v_ack then v_uid else o.acknowledged_by end
  where o.id = p_order_id
  returning * into v_order;
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);

  return v_order;
end;
$$;

revoke execute on function public.submit_order(bigint, boolean) from public, anon;
grant execute on function public.submit_order(bigint, boolean) to authenticated, service_role;

comment on function public.submit_order(bigint, boolean) is
  'draft -> submitted, with the authoritative pricing/ship-to/FFL pass. An '
  'order with source <> ''portal'' needs p_acknowledged => true. Lines '
  'matching no ERP part never submit; hand-priced lines need an admin, or '
  'inside sales on their own order, as submitter and the acknowledgement. A '
  'blank PO becomes PORTAL-<id>; a requested ship date that has passed is '
  'refused (ship_date_past). A non-portal order whose PO is on an ERP order '
  'not named in its stored warnings is refused (erp_duplicate_unreviewed). '
  'The ship-to is a CUST_ADDRESS ship-to, or the account''s main address '
  '(<cust>|CUST) when feature.order_main_address_ship_to is on; '
  'ship_to_source records which. A passed PO cancel date is refused '
  '(cancel_date_passed); with no contact key the PO''s contact is the '
  'snapshot (contact_source po, else erp) (20261114090000).';

--------------------------------------------------------------------------
-- 3. shipto: the account's main (sold-to) address as a ship-to
--    * An account with no CUST_ADDRESS ship-to (TYLE WHIT; 8,946 active
--      accounts live) could not take an order at all, and an MCP draft for
--      it was SAVED with no ship-to: it only failed at submit. Now
--      mcp_order_apply refuses it up front (no_orderable_ship_to), whatever
--      the flag below.
--    * The main address is erp.dim_ship_to '<cust>|CUST' (CustomerMaster:
--      CUSTOMER.ADDR_*, FFL = CUSTOMER.USER_4/USER_5). That is the key
--      fact_order_line carries for an ERP order with no ship-to, so
--      run_order_qc's ship_to_mismatch holds unchanged. '<cust>|MAIN' is
--      accepted as an input alias only.
--    * Behind feature.order_main_address_ship_to, OFF: the order middleware
--      (outside this repo) must first learn to write NO SHIPTO_ID for a row
--      with v_orders_ready_for_erp.use_customer_address and to check the
--      FFL against CUSTOMER.USER_4/USER_5. With the flag off nothing offers
--      or accepts the main address; only the up-front refusal and the new
--      fields (false / empty) change.
--    * order_context offers it (kind customer_address; the default only
--      when the account has no ship-to; alert ship_to_main_address);
--      order_same_name_accounts and order_ship_to_choices know it;
--      submit_order stamps orders.ship_to_source; the ready view appends
--      ship_to_source and use_customer_address. mcp_order_apply,
--      mcp_order_preview and submit_order are edited in their restatements
--      above.
--------------------------------------------------------------------------
insert into public.app_settings (setting_key, enabled, params, description) values
  ('feature.order_main_address_ship_to', false, '{}'::jsonb,
   'Orders may ship to the account''s main (sold-to) address (dim_ship_to <cust>|CUST, no ship-to ID). '
   'Turn on only once the order middleware reads v_orders_ready_for_erp.use_customer_address: '
   'no SHIPTO_ID, FFL from CUSTOMER.USER_4/USER_5.')
on conflict (setting_key) do nothing;

-- Stamped by submit_order. Not backfilled: an UPDATE would bump updated_at
-- on submitted orders (touch_updated_at); the view derives legacy rows.
alter table public.orders add column if not exists ship_to_source text;

-- Review fix: when the draft was last recalled from submitted. recall_order
-- clears acknowledged_at, so the 'the ERP order may be this draft's own entry'
-- hint needs a mark that survives the recall.
alter table public.orders add column if not exists recalled_at timestamptz;
alter table public.orders drop constraint if exists orders_ship_to_source_check;
alter table public.orders add constraint orders_ship_to_source_check
  check (ship_to_source is null or ship_to_source in ('ship_to', 'customer_address'));
comment on column public.orders.ship_to_source is
  'Stamped by submit_order (and cleared by recall_order): ship_to = a CUST_ADDRESS ship-to '
  '(ship_to_id/addr_no set); customer_address = the account''s main (sold-to) address, '
  'ship_to_key <cust>|CUST, no ship-to ID. A draft''s value means nothing (an owner can write '
  'it; submit always overwrites it, and the ready view reads submitted rows only) (20261114090000).';

-- What a dim_ship_to row is to an order: 'ship_to' (a CUST_ADDRESS ship-to
-- with a SHIPTO_ID), 'customer_address' (the account's main address,
-- '<cust>|CUST'), or null (neither: the Unknown row, a blank id). Scalars,
-- not the row type, so the ETL can rebuild erp tables freely.
create or replace function public.order_ship_to_kind(
  p_ship_to_key text, p_customer_id text, p_address_source text, p_ship_to_id text, p_unknown boolean)
returns text
language sql immutable set search_path = public
as $$
  select case
    when p_ship_to_key is null or coalesce(p_unknown, false) then null
    when p_address_source = 'ShipTo' and nullif(btrim(p_ship_to_id), '') is not null then 'ship_to'
    when p_address_source = 'CustomerMaster' and p_ship_to_key = p_customer_id || '|CUST' then 'customer_address'
  end
$$;

-- Whether an address of that kind can take an order now: a ship-to while
-- active (submit_order's rule); the main address while the flag is on, the
-- account active, and street and city filled (a blank state or ZIP is a
-- preview warning, not a refusal).
create or replace function public.order_ship_to_orderable(
  p_kind text, p_active_flag text, p_address1 text, p_city text)
returns boolean
language sql stable set search_path = public
as $$
  select case p_kind
    when 'ship_to' then upper(coalesce(p_active_flag, 'Y')) <> 'N'
    when 'customer_address' then public.feature_enabled('feature.order_main_address_ship_to')
         and upper(coalesce(p_active_flag, 'Y')) <> 'N'
         and nullif(btrim(p_address1), '') is not null
         and nullif(btrim(p_city), '') is not null
    else false end
$$;

revoke execute on function public.order_ship_to_kind(text, text, text, text, boolean) from public, anon;
revoke execute on function public.order_ship_to_orderable(text, text, text, text) from public, anon;
grant execute on function public.order_ship_to_kind(text, text, text, text, boolean) to authenticated;
grant execute on function public.order_ship_to_orderable(text, text, text, text) to authenticated;

-- order_same_name_accounts (restated from 20261112090000): orderable_ship_tos
-- keeps its meaning (real ship-tos); main_address_orderable is new, so a
-- main-address-only account no longer reads as unorderable among the
-- choices.
create or replace function public.order_same_name_accounts(p_customer_key text)
returns jsonb
language plpgsql stable security invoker set search_path = public, erp
as $$
declare
  v_name text;
begin
  select public.customer_name_key(dc.customer_name) into v_name
  from erp.dim_customer dc where dc.customer_key = p_customer_key;
  if v_name is null then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'customer_key',  d.customer_key,
             'customer_name', d.customer_name,
             'customer_type', d.customer_type,
             'city',          nullif(btrim(d.sold_to_city), ''),
             'state',         nullif(btrim(d.sold_to_state), ''),
             'last_order_date', d.last_order_date,
             'has_price_list', exists (select 1 from public.effective_price_lists(d.customer_type) l
                                       where not l.is_special),
             'orderable_ship_tos', (select count(*) from erp.dim_ship_to s
                                    where s.customer_id = d.customer_key
                                      and public.order_ship_to_kind(s.ship_to_key, s.customer_id, s.address_source,
                                                                    s.ship_to_id, s.is_unknown_ship_to) = 'ship_to'
                                      and upper(coalesce(s.active_flag, 'Y')) <> 'N'),
             'main_address_orderable', exists (
                                    select 1 from erp.dim_ship_to s
                                    where s.ship_to_key = d.customer_key || '|CUST'
                                      and s.customer_id = d.customer_key
                                      and s.address_source = 'CustomerMaster'
                                      and public.order_ship_to_orderable('customer_address', s.active_flag,
                                                                         s.address1, s.city)),
             'this_one',      d.customer_key = p_customer_key)
             order by (d.customer_key = p_customer_key) desc, d.last_order_date desc nulls last, d.customer_key)
    from erp.dim_customer d
    where public.customer_name_key(d.customer_name) = v_name
      and upper(coalesce(d.active_flag, 'Y')) <> 'N'
      and (public.is_admin() or d.customer_key in (select public.my_customer_keys()))
    having count(*) > 1), '[]'::jsonb);
end;
$$;
revoke execute on function public.order_same_name_accounts(text) from public, anon;
grant execute on function public.order_same_name_accounts(text) to authenticated;

comment on function public.order_same_name_accounts(text) is
  'Active accounts the caller can see whose name matches this one''s '
  '(customer_name_key), this one first; [] when it is the only one. '
  'orderable_ship_tos counts real ship-tos; main_address_orderable says the '
  'main address can take an order (20261114090000).';

-- order_ship_to_choices (restated from 20261112090000): the main address too
-- (when orderable, last), with kind, zip and a label (its ship_to_id is null,
-- which the edge function's compact() drops).
create or replace function public.order_ship_to_choices(p_customer_key text)
returns jsonb
language sql stable security definer set search_path = public, erp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'ship_to_key', s.ship_to_key,
           'ship_to_id',  s.ship_to_id,
           'kind',        k.kind,
           'label',       case when k.kind = 'customer_address' then 'Main address - ' else s.ship_to_id || ' - ' end
                          || concat_ws(', ', nullif(btrim(s.ship_to_name), ''), nullif(btrim(s.city), ''),
                                       nullif(btrim(s.state), '')),
           'name',        s.ship_to_name,
           'address',     nullif(concat_ws(', ', nullif(btrim(s.address1), ''),
                            nullif(btrim(s.address2), ''), nullif(btrim(s.address3), '')), ''),
           'city',        s.city,
           'state',       s.state,
           'zip',         s.zip_code,
           'ffl_number',  nullif(btrim(s.ffl_license_number), ''),
           'ffl_expires', public.parse_ffl_expiry(s.ffl_expiration_raw),
           'ffl_current', public.ffl_on_file_current(s.ffl_license_number, s.ffl_expiration_raw))
           order by (k.kind = 'customer_address'),
                    public.ffl_on_file_current(s.ffl_license_number, s.ffl_expiration_raw) desc,
                    s.addr_no nulls last, s.ship_to_key), '[]'::jsonb)
  from erp.dim_ship_to s
  cross join lateral (select public.order_ship_to_kind(s.ship_to_key, s.customer_id, s.address_source,
                                                       s.ship_to_id, s.is_unknown_ship_to) as kind) k
  where s.customer_id = p_customer_key
    and public.order_ship_to_orderable(k.kind, s.active_flag, s.address1, s.city)
$$;
revoke execute on function public.order_ship_to_choices(text) from public, anon, authenticated;

-- order_context (restated from 20261112090000): the main address. With the
-- flag off its output is unchanged but for three new keys (false/null/[]):
-- the main row is not listed. With it on the main row is listed last (kind
-- customer_address), is the default only when the account has no orderable
-- ship-to, and then flags ship_to_main_address. orderable_ship_to_count
-- still counts real ship-tos.
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
  v_flag     boolean := public.feature_enabled('feature.order_main_address_ship_to');
  v_main_ok  boolean;
  v_main_key text;
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

  select coalesce(jsonb_agg(jsonb_build_object(
           'ship_to_key', s.ship_to_key,
           'ship_to_id',  s.ship_to_id,
           'addr_no',     s.addr_no,
           'kind',        s.kind,
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
                    'expires_on',     public.parse_ffl_expiry(s.ffl_expiration_raw),
                    'current',        public.ffl_on_file_current(s.ffl_license_number, s.ffl_expiration_raw)))
           order by s.ok desc, (s.kind = 'customer_address'), s.addr_no nulls last, s.ship_to_key), '[]'::jsonb),
         count(*) filter (where s.ok and s.kind = 'ship_to'),
         min(s.ship_to_key) filter (where s.ok and s.kind = 'ship_to'),
         coalesce(bool_or(s.ok) filter (where s.kind = 'customer_address'), false),
         min(s.ship_to_key) filter (where s.ok and s.kind = 'customer_address')
    into v_ships, v_n_ok, v_default, v_main_ok, v_main_key
  from (
    -- A ShipTo row with a blank id is listed (not orderable) as before.
    select x.*,
           coalesce(k.kind, 'ship_to') as kind,
           public.order_ship_to_orderable(k.kind, x.active_flag, x.address1, x.city) as ok
    from erp.dim_ship_to x
    cross join lateral (select public.order_ship_to_kind(x.ship_to_key, x.customer_id, x.address_source,
                                                         x.ship_to_id, x.is_unknown_ship_to) as kind) k
    where x.customer_id = c.customer_key
      and ((x.address_source = 'ShipTo' and not coalesce(x.is_unknown_ship_to, false))
           or (k.kind = 'customer_address' and v_flag))
  ) s;

  if v_n_ok = 0 and not v_main_ok then
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
    'same_name_accounts', public.order_same_name_accounts(c.customer_key),
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
    'orderable_ship_to_count', v_n_ok,
    'default_ship_to_key', case when v_n_ok = 1 then v_default
                                when v_n_ok = 0 and v_main_ok then v_main_key end,
    'main_address_orderable',   v_main_ok,
    'main_address_ship_to_key', v_main_key,
    'ship_to_alerts', case when v_n_ok = 0 and v_main_ok then '["ship_to_main_address"]'::jsonb
                           else '[]'::jsonb end,
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
                public.contact_display_name(e.contact_name, e.first_name, e.last_name, e.email, e.contact_id) as name,
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
                'source',       r.source,
                'is_test',      r.is_test)
              order by r.created_at desc, r.id desc)
       from (select o.id, o.status, o.po_number, o.created_at, o.total_amount, o.source, o.is_test
             from public.orders o
             where o.customer_key = c.customer_key
             order by o.created_at desc, o.id desc
             limit 10) r), '[]'::jsonb),
    -- The last successful load, not this row's last change (a quiet
    -- account's row is not rewritten, so its loaded_at stands still).
    'data_as_of', coalesce((select f.data_loaded_at from public.v_data_freshness f), c.loaded_at),
    'account_changed_at', c.loaded_at);
end;
$$;

revoke execute on function public.order_context(text) from public, anon;
grant execute on function public.order_context(text) to authenticated;

comment on function public.order_context(text) is
  'Account context for drafting an order: customer, blockers, same-name '
  'accounts, effective price lists, ship-tos (orderable = submit_order''s '
  'rule; kind ship_to, or customer_address = the main address <cust>|CUST '
  'when feature.order_main_address_ship_to is on) with FFL on file and '
  'expiry, contacts, recent portal orders, data_as_of = last ETL run. '
  'RLS-scoped (SECURITY INVOKER) (20261114090000).';

-- recall_order (restated from 20261113090000): back in draft the order has
-- no ship_to_source, nor (section 4) contact_source: submit stamps both.
create or replace function public.recall_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
begin
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if not (v_order.user_id = v_uid or public.is_admin()) then
    raise exception 'only the order''s owner may recall it';
  end if;
  if v_order.status <> 'submitted' then
    raise exception 'order % is %, only submitted orders can be recalled',
      p_order_id, v_order.status;
  end if;

  -- PORTAL-<id> was given at submit because the order had no customer PO:
  -- back in draft it has none again (flagged, and re-given at the next
  -- submit), so a PO that turns up can simply be typed in.
  update public.orders
  set status = 'draft', submitted_at = null, total_amount = null,
      recalled_at = now(),   -- review fix: recall clears acknowledged_at, so the ERP-duplicate hint keys on this
      po_number = case when po_number = 'PORTAL-' || id then null else po_number end,
      ship_to_source = null,
      contact_source = null   -- section 4: submit stamps it again
  where id = p_order_id
  returning * into v_order;
  return v_order;
end;
$$;

revoke execute on function public.recall_order(bigint) from public, anon;
grant execute on function public.recall_order(bigint) to authenticated;

-- v_orders_ready_for_erp: restated at the end of section 4, with this
-- section's ship_to_source and use_customer_address (it reads section 4's
-- columns too, which do not exist yet at this point of the file).

--------------------------------------------------------------------------
-- 4. contact_header: the PO's contact, and its optional header fields
--    * The only contact input was customer_contact_key: the PO's Contact
--      Email / Phone had nowhere to go (unknown_field). Now contact_email /
--      contact_name / contact_phone are matched IN SQL (on the raw inputs,
--      so the idempotency hash never depends on the hourly contact load) to
--      this account's ERP contacts: email first, then name + phone. A
--      billing (AP/AR) or internal contact is never chosen: Sports South's
--      ERP primary is its AP mailbox. A name or phone that alone matches
--      only lists candidates. No match: the contact is staged on the order
--      (po_contact_*), alert contact_not_on_file, and submit_order writes it
--      as the order's contact text (contact_source 'po').
--    * Optional PO header fields: po_date, cancel_date (a passed one blocks
--      submit), payment_terms (terms_mismatch against the account's ERP
--      terms; never sent to the ERP), ship_via, vendor_number,
--      ship_to_location (checked against the ship-to; suggested in a
--      ship-to confirmation refusal), po_total (po_total_mismatch). Per
--      line: buyer_part_number (Visual's CUSTOMER_PART_ID on EDI orders)
--      and upc (upc_mismatch; an unmatched line's UPC suggests the part).
--      Unlike notes, an update that leaves one out keeps it; null clears.
--    * An order with only part + qty drafts exactly as before.
--    * mcp_order_apply, mcp_order_preview, submit_order and recall_order are
--      edited in their restatements above; the ready view is restated below.
--------------------------------------------------------------------------
alter table public.orders
  add column if not exists po_contact_name     text,
  add column if not exists po_contact_email    text,
  add column if not exists po_contact_phone    text,
  add column if not exists contact_match       text,
  add column if not exists contact_source      text,
  add column if not exists po_date             date,
  add column if not exists po_cancel_date      date,
  add column if not exists po_payment_terms    text,
  add column if not exists po_ship_via         text,
  add column if not exists po_vendor_number    text,
  add column if not exists po_ship_to_location text,
  add column if not exists po_total            numeric(14,2);
alter table public.orders drop constraint if exists orders_contact_match_check;
alter table public.orders add constraint orders_contact_match_check
  check (contact_match is null or contact_match in ('given', 'email', 'name_phone'));
alter table public.orders drop constraint if exists orders_contact_source_check;
alter table public.orders add constraint orders_contact_source_check
  check (contact_source is null or contact_source in ('erp', 'po'));
alter table public.orders drop constraint if exists orders_po_total_check;
alter table public.orders add constraint orders_po_total_check
  check (po_total is null or po_total >= 0);
alter table public.orders drop constraint if exists orders_po_header_len_check;
alter table public.orders add constraint orders_po_header_len_check
  check (coalesce(length(po_contact_name), 0) <= 100 and coalesce(length(po_contact_email), 0) <= 254
         and coalesce(length(po_contact_phone), 0) <= 40 and coalesce(length(po_payment_terms), 0) <= 100
         and coalesce(length(po_ship_via), 0) <= 60 and coalesce(length(po_vendor_number), 0) <= 40
         and coalesce(length(po_ship_to_location), 0) <= 60);

alter table public.order_lines
  add column if not exists buyer_part_number text,
  add column if not exists upc               text;
alter table public.order_lines drop constraint if exists order_lines_upc_check;
alter table public.order_lines add constraint order_lines_upc_check
  check (upc is null or upc ~ '^\d{8,14}$');
alter table public.order_lines drop constraint if exists order_lines_buyer_part_number_check;
alter table public.order_lines add constraint order_lines_buyer_part_number_check
  check (buyer_part_number is null or length(buyer_part_number) <= 100);

comment on column public.orders.po_contact_name is
  'The buyer contact as the customer''s PO states it (with po_contact_email, po_contact_phone). '
  'When no ERP contact matched (customer_contact_key null), submit_order writes these to '
  'contact_name/phone/email (contact_source po) (20261114090000).';
comment on column public.orders.po_contact_email is 'The PO''s contact email, as stated (see po_contact_name).';
comment on column public.orders.po_contact_phone is 'The PO''s contact phone, as stated (see po_contact_name).';
comment on column public.orders.contact_match is
  'How customer_contact_key was set over MCP: given (sent by the user), email or name_phone '
  '(matched from the PO contact). Null when not set over MCP; stale after a portal edit '
  '(the preview recomputes) (20261114090000).';
comment on column public.orders.contact_source is
  'Stamped by submit_order (cleared by recall_order): erp = contact_name/phone/email are ERP '
  'contact customer_contact_key; po = they are the PO''s contact as text, customer_contact_key '
  'null; null = no contact (20261114090000).';
comment on column public.orders.po_date is 'The PO''s date, as stated. Informational (20261114090000).';
comment on column public.orders.po_cancel_date is
  'The PO''s cancel / do-not-ship-after date. Once passed, submit_order refuses the order '
  '(cancel_date_passed) until it is changed or cleared (20261114090000).';
comment on column public.orders.po_payment_terms is
  'Payment terms as the PO states them. Informational: compared with the account''s ERP terms '
  '(terms_mismatch); the ERP terms apply (20261114090000).';
comment on column public.orders.po_ship_via is 'The PO''s carrier / routing text. Free text, not a SHIP_VIA code (20261114090000).';
comment on column public.orders.po_vendor_number is 'Our vendor number at the customer, as the PO states it (20261114090000).';
comment on column public.orders.po_ship_to_location is
  'The PO''s ship-to location code (e.g. BLDG1), checked against the ship-to''s id (20261114090000).';
comment on column public.orders.po_total is
  'The PO''s stated total; the preview flags po_total_mismatch when the draft differs (20261114090000).';
comment on column public.order_lines.buyer_part_number is
  'The customer''s own item number (EDI "Buyers Catalog or Stock Keeping #"): what Visual''s EDI '
  'orders store in CUSTOMER_PART_ID (20261114090000).';
comment on column public.order_lines.upc is
  'The UPC/EAN/GTIN on the PO line, digits only; checked against the part (upc_mismatch) (20261114090000).';

-- Payment terms in one spelling, to compare a PO's with Visual's terms id:
-- '2% 10/NET 30' = '2%10 N30' = '2.0% 10 NET 30' -> '2%10N30';
-- 'NET30 FREE SHIP' = 'Net 30 days' -> 'N30'. Visual-only ids (PREPAY, DUR,
-- 10TH, CREDIT_CARD) never equal PO text: that mismatch is the point.
create or replace function public.order_terms_canon(t text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select nullif(regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(upper(coalesce(t, '')), '\mFREE\s*SHI\w*|\mDAYS?\M|\mTERMS?\M', '', 'g'),
             '\mNET\s*', 'N', 'g'),
           '(\d+)\.0+(?=\D|$)', '\1', 'g'),
         '[^A-Z0-9%]', '', 'g'), '')
$$;

-- The first email address in a field ('Name <a@x.com>; b@x.com' ->
-- 'a@x.com'), lower case; null when there is none.
create or replace function public.order_first_email(t text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select lower(substring(t from '[^\s<>;,"''()\[\]]+@[^\s<>;,"''()\[\]@]+\.[^\s<>;,"''()\[\]@]+'))
$$;

-- A name for comparing: lower-case words, sorted ('SMITH, Pat' = 'Pat Smith').
create or replace function public.order_name_canon(t text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select nullif(string_agg(w, ' ' order by w), '')
  from regexp_split_to_table(lower(coalesce(t, '')), '[^a-z0-9]+') w
  where w <> ''
$$;

-- SQL port of the billing / internal rules of supabase/functions/_shared/
-- contacts.ts (isBillingContact, isInternalContact; a byte copy of
-- frontend/src/lib/contacts.ts) plus rankAccountContacts' invoice_email /
-- statement_email rule (functions/mcp/tools.ts). A change there needs the
-- same change here; tests/20261114_mcp_large_order.sql section 4 holds the
-- parity cases of contacts.test.ts. Returns 'billing', 'internal' or null.
create or replace function public.order_contact_excluded(
  p_name text, p_title text, p_email text, p_phone text,
  p_invoice_email text, p_statement_email text)
returns text
language plpgsql immutable parallel safe set search_path = public
as $$
declare
  c_buying  constant text := '\mbuy(er|ers|ing)?\M(?!\s*group)|purchas|owner|president|proprietor|\mgm\M|general\s+manager';
  c_tokens  constant text[] := array['ap','ar','billing','statement','statements','accounting',
                                     'payable','payables','receivable','receivables'];
  v_email   text := lower(btrim(coalesce(p_email, '')));
  v_local   text;
  v_domain  text;
  v_named   boolean;
  s         text;
begin
  -- textIsBilling(s) and (it says invoic, or it names no buying role)
  foreach s in array array[p_name, p_title] loop
    if s is not null
       and (s ~* 'invoic|accounts?\s*-?\s*(payable|receivable)|acct\.?\s*(payable|receivable)'
            or exists (select 1 from regexp_split_to_table(
                          regexp_replace(regexp_replace(lower(s), '\mar-?1[05]\M', ' ', 'g'),
                                         '\ma\s*/\s*([pr])\M', 'a\1', 'g'), '[^a-z0-9]+') t
                       where t = any (c_tokens)))
       and (s ~* 'invoic' or s !~* c_buying) then
      return 'billing';
    end if;
  end loop;

  if strpos(v_email, '@') > 0 then
    v_local  := regexp_replace(v_email, '@[^@]*$', '');
    v_domain := substring(v_email from '@([^@]*)$');
  else
    v_local := ''; v_domain := '';
  end if;
  if v_local <> ''
     and (v_local ~ 'invoic|payable|receivable|billing(?!s)|statement|accounting'
          or exists (select 1 from regexp_split_to_table(v_local, '[^a-z0-9]+') t
                     where t in ('ap', 'ar', 'acctg', 'accts')))
     and (v_local ~ 'invoic'
          or not (coalesce(p_name, '') ~* c_buying or coalesce(p_title, '') ~* c_buying)) then
    return 'billing';
  end if;

  -- The account's invoice / statement address, unless a named person with a phone.
  if v_email <> ''
     and v_email = any (array(select x from regexp_split_to_table(
                                lower(concat_ws(' ', p_invoice_email, p_statement_email)), '[;,\s]+') x
                              where strpos(x, '@') > 0)) then
    s := btrim(coalesce(p_name, ''));
    v_named := s <> '' and s !~ '^[\s#-]*\d[\d\s-]*$' and strpos(s, '@') = 0
               and s !~* '^(the\s+)?(orders?|purchasing|purchase\s+orders?|buying|po|sales|info|office)(\s+(dept\.?|department|desk|team|line|mailbox))?$'
               and not (s ~* 'invoic|accounts?\s*-?\s*(payable|receivable)|acct\.?\s*(payable|receivable)'
                        or exists (select 1 from regexp_split_to_table(
                                      regexp_replace(regexp_replace(lower(s), '\mar-?1[05]\M', ' ', 'g'),
                                                     '\ma\s*/\s*([pr])\M', 'a\1', 'g'), '[^a-z0-9]+') t
                                   where t = any (c_tokens)))
               and s ~* '[a-z]{2,}';
    if not (v_named and length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 7) then
      return 'billing';
    end if;
  end if;

  if v_domain = 'christensenarms.com' or v_domain like '%.christensenarms.com' then
    return 'internal';
  end if;
  return null;
end;
$$;

-- This account's active ERP contacts as order_match_contact compares them.
create or replace function public.order_contact_rows(p_ck text)
returns table (k text, prim boolean, has_phone boolean, emails text[], nm text, fl text,
               p1 text, p2 text, ex text)
language sql stable security definer set search_path = public, erp
as $$
  select e.customer_contact_key,
         coalesce(e.primary_contact_flag = 'Y', false),
         length(regexp_replace(coalesce(nullif(btrim(e.phone), ''), e.mobile, ''), '\D', '', 'g')) >= 7,
         regexp_split_to_array(lower(btrim(coalesce(e.email, ''))), '[;,\s]+'),
         public.order_name_canon(public.contact_display_name(e.contact_name, e.first_name, e.last_name, null, null)),
         public.order_name_canon(concat_ws(' ', e.first_name, e.last_name)),
         nullif(right(regexp_replace(coalesce(e.phone, ''), '\D', '', 'g'), 10), ''),
         nullif(right(regexp_replace(coalesce(e.mobile, ''), '\D', '', 'g'), 10), ''),
         public.order_contact_excluded(
           public.contact_display_name(e.contact_name, e.first_name, e.last_name, e.email, e.contact_id),
           e.position, e.email, coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')),
           dc.invoice_email, dc.statement_email)
  from erp.dim_customer_contact e
  left join erp.dim_customer dc on dc.customer_key = e.customer_key
  where e.customer_key = p_ck
    and coalesce(e.contact_active_flag, 'Y') = 'Y'
$$;

-- The PO's contact against this account's ERP contacts. Returns
-- {customer_contact_key, matched_by: email | name_phone, reason: matched |
-- billing_only | internal_only | name_only | phone_only | no_match,
-- candidates: [keys]}. A key only on an email match, or a name AND phone
-- match, of a contact that is neither billing nor internal; ties break on
-- primary, has a phone, then the key (689 duplicated account emails live).
create or replace function public.order_match_contact(p_ck text, p_email text, p_name text, p_phone text)
returns jsonb
language plpgsql stable security definer set search_path = public, erp
as $$
declare
  v_email  text := public.order_first_email(p_email);
  v_name   text := public.order_name_canon(p_name);
  v_phone  text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  v_key    text;
  v_reason text;
  v_cands  jsonb;
begin
  if length(v_phone) < 7 then
    v_phone := null;
  end if;

  -- (a) Email.
  if v_email is not null then
    select c.k into v_key from public.order_contact_rows(p_ck) c
    where v_email = any (c.emails) and c.ex is null
    order by c.prim desc, c.has_phone desc, c.k limit 1;
    if v_key is not null then
      return jsonb_build_object('customer_contact_key', v_key, 'matched_by', 'email', 'reason', 'matched',
                                'candidates', '[]'::jsonb);
    end if;
    select case when bool_or(c.ex = 'billing') then 'billing_only' else 'internal_only' end
      into v_reason
    from public.order_contact_rows(p_ck) c where v_email = any (c.emails)
    having count(*) > 0;
  end if;

  -- (b) Name and phone, both.
  if v_name is not null and v_phone is not null then
    select c.k into v_key from public.order_contact_rows(p_ck) c
    where (c.nm = v_name or c.fl = v_name) and v_phone in (c.p1, c.p2) and c.ex is null
    order by c.prim desc, c.has_phone desc, c.k limit 1;
    if v_key is not null then
      return jsonb_build_object('customer_contact_key', v_key, 'matched_by', 'name_phone', 'reason', 'matched',
                                'candidates', '[]'::jsonb);
    end if;
  end if;

  -- (c) The name alone, (d) the phone alone: candidates, never a key.
  if v_name is not null then
    select jsonb_agg(x.k order by x.prim desc, x.k) into v_cands
    from (select c.k, c.prim from public.order_contact_rows(p_ck) c
          where (c.nm = v_name or c.fl = v_name) and c.ex is null
          order by c.prim desc, c.k limit 5) x;
    if v_cands is not null then
      return jsonb_build_object('customer_contact_key', null, 'matched_by', null, 'reason', 'name_only',
                                'candidates', v_cands);
    end if;
  end if;
  if v_phone is not null then
    select jsonb_agg(x.k order by x.prim desc, x.k) into v_cands
    from (select c.k, c.prim from public.order_contact_rows(p_ck) c
          where v_phone in (c.p1, c.p2) and c.ex is null
          order by c.prim desc, c.k limit 5) x;
    if v_cands is not null then
      return jsonb_build_object('customer_contact_key', null, 'matched_by', null, 'reason', 'phone_only',
                                'candidates', v_cands);
    end if;
  end if;

  return jsonb_build_object('customer_contact_key', null, 'matched_by', null,
                            'reason', coalesce(v_reason, 'no_match'), 'candidates', '[]'::jsonb);
end;
$$;

-- The orderable ship-to of the account whose id is the PO's Ship To
-- Location (one only), or the main address for 'MAIN' / the customer id
-- when it can take an order; null otherwise.
create or replace function public.order_ship_to_for_location(p_ck text, p_loc text)
returns text
language sql stable security definer set search_path = public, erp
as $$
  select case when count(*) = 1 then min(k) end
  from (
    select s.ship_to_key as k
    from erp.dim_ship_to s
    where s.customer_id = p_ck
      and nullif(btrim(p_loc), '') is not null
      and public.order_ship_to_kind(s.ship_to_key, s.customer_id, s.address_source,
                                    s.ship_to_id, s.is_unknown_ship_to) = 'ship_to'
      and upper(coalesce(s.active_flag, 'Y')) <> 'N'
      and upper(btrim(s.ship_to_id)) = upper(btrim(p_loc))
    union all
    select s.ship_to_key
    from erp.dim_ship_to s
    where s.ship_to_key = p_ck || '|CUST' and s.customer_id = p_ck and s.address_source = 'CustomerMaster'
      and upper(btrim(p_loc)) in ('MAIN', upper(p_ck))
      and public.order_ship_to_orderable('customer_address', s.active_flag, s.address1, s.city)
  ) m
$$;

-- What a ship-to confirmation refusal says about the PO's location.
create or replace function public.order_location_hint(p_loc text, p_key text)
returns text
language sql immutable set search_path = public
as $$
  select case when p_loc is null then ''
              when p_key is not null then format('; the PO''s Ship To Location is %s, which is ship_to_key %s', p_loc, p_key)
              else format('; the PO''s Ship To Location is %s, which matches none of them', p_loc) end
$$;

-- A PO text field: string (or number when p_number_ok), trimmed, capped.
create or replace function public.order_po_text(p_val jsonb, p_field text, p_max int, p_number_ok boolean)
returns text
language plpgsql immutable set search_path = public
as $$
declare
  v text;
begin
  if p_val is null or jsonb_typeof(p_val) = 'null' then
    return null;
  end if;
  if not (jsonb_typeof(p_val) = 'string' or (p_number_ok and jsonb_typeof(p_val) = 'number')) then
    raise exception 'invalid_input:%: must be text', p_field;
  end if;
  v := nullif(btrim(p_val #>> '{}', E' \t\r\n\u00A0'), '');
  if length(v) > p_max then
    raise exception 'invalid_input:%: % characters at most', p_field, p_max;
  end if;
  return v;
end;
$$;

-- A PO date: YYYY-MM-DD (a PO's MM/DD/YYYY is converted by the caller).
create or replace function public.order_po_date(p_val jsonb, p_field text)
returns date
language plpgsql immutable set search_path = public
as $$
declare
  v date;
begin
  if p_val is null or jsonb_typeof(p_val) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_val) <> 'string' or (p_val #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'invalid_input:%: use YYYY-MM-DD (convert the PO''s MM/DD/YYYY)', p_field;
  end if;
  begin
    v := (p_val #>> '{}')::date;
  exception when others then
    raise exception 'invalid_input:%: % is not a date', p_field, p_val #>> '{}';
  end;
  return v;
end;
$$;

revoke execute on function public.order_terms_canon(text) from public, anon;
revoke execute on function public.order_first_email(text) from public, anon;
revoke execute on function public.order_name_canon(text) from public, anon;
grant execute on function public.order_terms_canon(text) to authenticated;
grant execute on function public.order_first_email(text) to authenticated;
grant execute on function public.order_name_canon(text) to authenticated;
-- Contact classification and matching read contacts across accounts by
-- key: only the DEFINER order functions call them.
revoke execute on function public.order_contact_excluded(text, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.order_match_contact(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.order_contact_rows(text) from public, anon, authenticated;
revoke execute on function public.order_ship_to_for_location(text, text) from public, anon, authenticated;
revoke execute on function public.order_location_hint(text, text) from public, anon, authenticated;
revoke execute on function public.order_po_text(jsonb, text, int, boolean) from public, anon, authenticated;
revoke execute on function public.order_po_date(jsonb, text) from public, anon, authenticated;

-- mcp_order_check_keys (restated from 20261113090000): the new header and
-- line fields are order fields.
create or replace function public.mcp_order_check_keys(p jsonb, p_update boolean)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $$
declare
  c_top  constant text[] := array['idempotency_key','customer_key','customer_confirmed','ship_to_key',
                                  'ship_to_confirmed','po_number','requested_ship_date',
                                  'customer_contact_key','notes','allow_duplicate','source_ref',
                                  'is_test','lines','price_override_reason','no_po_confirmed',
                                  'contact_email','contact_name','contact_phone','po_date','cancel_date',
                                  'payment_terms','ship_via','vendor_number','ship_to_location','po_total'];
  c_line constant text[] := array['part_id','qty','price_list_id','part_confirmed','expected_unit_price',
                                  'unit_price','customer_part_ref','customer_description',
                                  'buyer_part_number','upc'];
  c_price constant text[] := array['price','prices','discount_pct','effective_unit_price',
                                   'line_total','total_amount','total'];
  c_ffl  constant text[] := array['ffl_license_number','ffl_expires_on','ffl','ffl_number'];
  k text;
  l jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_input:body: the request must be a JSON object';
  end if;
  for k in select jsonb_object_keys(p) loop
    if k = any (c_price) or k = 'unit_price' then
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
        raise exception 'invalid_input:lines: every line must be an object {part_id, qty, part_confirmed, price_list_id?, expected_unit_price?}';
      end if;
      for k in select jsonb_object_keys(l) loop
        if k = any (c_price) then
          raise exception 'invalid_input:%: prices are set by the server from the published price list; pass the price the user expects as expected_unit_price', k;
        elsif k = any (c_ffl) then
          raise exception 'invalid_input:%: an FFL is never supplied here', k;
        elsif not (k = any (c_line)) then
          raise exception 'invalid_input:unknown_field:%: not a line field (part_id, qty, part_confirmed, price_list_id, expected_unit_price, unit_price, customer_part_ref, customer_description, buyer_part_number, upc)', k;
        end if;
      end loop;
    end loop;
  end if;
  foreach k in array array['customer_confirmed', 'ship_to_confirmed', 'is_test', 'no_po_confirmed'] loop
    if p ? k and jsonb_typeof(p -> k) not in ('boolean', 'null') then
      raise exception 'invalid_input:%: must be true or false', k;
    end if;
  end loop;
end;
$$;

revoke execute on function public.mcp_order_check_keys(jsonb, boolean) from public, anon, authenticated;

comment on function public.mcp_create_order_draft(jsonb) is
  'MCP only (mcp_orders_gate). Creates a DRAFT from {idempotency_key, customer_key, '
  'customer_confirmed?, ship_to_key, ship_to_confirmed, po_number | no_po_confirmed, '
  'requested_ship_date?, customer_contact_key? | contact_email? contact_name? contact_phone? '
  '(matched to an ERP contact, else staged), po_date?, cancel_date?, payment_terms?, ship_via?, '
  'vendor_number?, ship_to_location?, po_total?, notes?, allow_duplicate?, is_test?, '
  'source_ref?, price_override_reason?, lines:[{part_id, qty, part_confirmed, '
  'price_list_id?, expected_unit_price?, unit_price?, customer_part_ref?, '
  'customer_description?, buyer_part_number?, upc?}]}. unit_price and price_override_reason: '
  'admin or inside sales only. Prices otherwise on the server; dry-runs submit_order; never '
  'submits (20261114090000).';
comment on function public.mcp_update_order_draft(bigint, jsonb) is
  'MCP only. Replaces the header and lines of the caller''s MCP draft; returns the preview. '
  'The PO header fields (contact_email/name/phone, po_date, cancel_date, payment_terms, '
  'ship_via, vendor_number, ship_to_location, po_total) are kept when left out and cleared by '
  'null; a customer_contact_key the user gave is kept when left out (20261114090000).';

-- v_orders_ready_for_erp (restated from 20261113090000; moved here from
-- section 3): section 3's ship_to_source and use_customer_address, then
-- section 4's contact_source and PO header columns, appended (a view's
-- existing columns cannot move). lines[] gains buyer_part_number and upc.
-- use_customer_address = ship to the account's main address: ship_to_id and
-- ship_to_addr_no are null, write NO SHIPTO_ID, check the FFL against
-- CUSTOMER.USER_4/USER_5. A loader that does not know this must refuse such
-- a row. Legacy rows (submitted before the column) derive from ship_to_id.
create or replace view public.v_orders_ready_for_erp
with (security_invoker = true) as
select
  o.id                         as order_id,
  o.status,
  o.source,
  o.user_id,
  o.created_by,
  o.created_at,
  o.submitted_at,
  o.acknowledged_at,
  o.acknowledged_by,
  o.customer_key,
  o.customer_name,
  o.customer_type,
  o.po_number,
  o.requested_ship_date,
  o.notes,
  o.customer_contact_key,
  o.ship_to_key,
  o.ship_to_id,
  o.ship_to_addr_no,
  o.ship_to_name,
  o.ship_to_address,
  o.requires_ffl,
  o.ffl_license_number,
  o.ffl_expires_on,
  o.ffl_on_file_number,
  o.ffl_on_file_expiration_raw,
  o.total_amount,
  o.mcp_token_id,
  o.client_request_id,
  o.source_ref,
  o.mcp_warnings,
  o.updated_at,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'line_id',              l.id,
             'part_id',              l.part_id,
             'description',          l.description,
             'qty',                  l.qty,
             'price_list_id',        l.price_list_id,
             'price_list_name',      pl.name,
             'unit_price',           l.unit_price,
             'discount_pct',         l.discount_pct,
             'effective_unit_price', l.effective_unit_price,
             'line_total',           l.line_total,
             'price_source',         l.price_source,
             'list_unit_price',      l.list_unit_price,
             'customer_part_ref',    l.customer_part_ref,
             'customer_description', l.customer_description,
             'buyer_part_number',    l.buyer_part_number,
             'upc',                  l.upc)
           order by l.id)
    from public.order_lines l
    join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = o.id), '[]'::jsonb) as lines,
  o.price_override_reason,
  o.contact_name,
  o.contact_phone,
  o.contact_email,
  coalesce(o.ship_to_source, case when o.ship_to_id is not null then 'ship_to' end) as ship_to_source,
  (coalesce(o.ship_to_source, '') = 'customer_address')                           as use_customer_address,
  o.contact_source,
  o.po_contact_name,
  o.po_contact_email,
  o.po_contact_phone,
  o.contact_match,
  o.po_date,
  o.po_cancel_date,
  o.po_payment_terms,
  o.po_ship_via,
  o.po_vendor_number,
  o.po_ship_to_location,
  o.po_total
from public.orders o
where o.status = 'submitted'
  and (o.source = 'portal'
       or (o.acknowledged_at is not null and o.acknowledged_at >= o.submitted_at));

revoke all on public.v_orders_ready_for_erp from anon, public;
grant select on public.v_orders_ready_for_erp to authenticated, service_role;

comment on view public.v_orders_ready_for_erp is
  'Submitted portal orders with lines, ship-to/FFL snapshot, acknowledgement and source: the '
  'stable read for the ERP middleware. Nothing here writes the ERP. contact_source: erp = '
  'contact_name/phone/email are ERP contact customer_contact_key; po = they are free text from '
  'the customer''s PO (customer_contact_key null): write them to the order''s contact text and '
  'set no contact ID. lines[].buyer_part_number is the customer''s own item number, what '
  'Visual''s EDI orders store in CUSTOMER_PART_ID: prefer it there, falling back to '
  'customer_part_ref (the PO''s item number as printed) when null (a portal line edit drops '
  'both). po_payment_terms and po_ship_via are informational (terms come from the customer '
  'record; ship via is free text, not a SHIP_VIA code); po_cancel_date may go to a UDF or the '
  'notes. use_customer_address: write no SHIPTO_ID (20261114090000).';

--------------------------------------------------------------------------
-- 5. size: a 195-line draft's preview and stored warnings
--    A 195-line EDI PO came back as ~122K characters from create_order_draft:
--    one "Stock:" sentence per short part (192 of them, 18K, and stored in
--    orders.mcp_warnings, so the portal reviewer and the ERP middleware saw
--    them too), one price_mismatch alert + sentence per line, and 19 keys on
--    every line. mcp_order_preview (restated in section 2, edited there):
--    * Stock, inactive-part and price_mismatch: up to 3 keep their own
--      sentence (and alert) with today's text; more become ONE sentence
--      naming the first 10 ("... and N more") and, for prices, ONE alert
--      (count, parts, total_difference).
--    * New keys stock_short [{part_id, ats_qty, qty}], inactive_parts
--      [{part_id, status}] and part_count carry the full lists; every
--      existing key keeps its name and meaning.
--    * ats_qty is trim_scale'd; alert strings are capped at 600 characters
--      (the count keys keep the totals).
--    The edge function shapes the rest (summary preview, trimmed lines).
--    CONTRACT CHANGE for the ERP middleware / order entry:
--    v_orders_ready_for_erp.mcp_warnings now carries one Stock sentence
--    naming up to 10 parts, not one sentence per part.
--    Drafts stored before this keep their per-part sentences until updated;
--    the one-off update below collapses them (order 672 today).
--------------------------------------------------------------------------

-- Per-part "Stock: X has N available to sell; Q ordered in all." sentences
-- (the pre-section-5 text) past 3 -> one sentence at the first one's place.
-- Anything else keeps its order. The edge function does the same for
-- previews made before this migration (collapseStockWarnings).
create or replace function public.order_collapse_stock_warnings(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with w as (
    select e.v, e.n,
           jsonb_typeof(e.v) = 'string'
             and (e.v #>> '{}') ~ '^Stock: .+ has \S+ available to sell; \d+ ordered in all\.' as is_stock
    from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end)
           with ordinality as e(v, n)
  ), s as (
    select count(*) as c, min(z.n) as first_n,
           string_agg(regexp_replace(z.v #>> '{}',
                        '^Stock: (.+) has (\S+) available to sell; (\d+) ordered in all\..*$', '\1 (\2/\3)'),
                      ', ' order by z.n) filter (where z.k <= 10) as listed
    from (select w.*, row_number() over (order by w.n) as k from w where w.is_stock) z
  )
  select case
    when jsonb_typeof(p) is distinct from 'array' then p
    when (select s.c from s) <= 3 then p
    else (select coalesce(jsonb_agg(x.v order by x.n), '[]'::jsonb)
          from (select w.v, w.n from w where not w.is_stock
                union all
                select to_jsonb(format(
                         'Stock: %s parts are short (ordered more than available to sell; shown as available/ordered): %s%s. Stock does not block the order.',
                         s.c, s.listed, case when s.c > 10 then format(' and %s more', s.c - 10) else '' end)),
                       s.first_n
                from s) x)
  end
$$;
revoke execute on function public.order_collapse_stock_warnings(jsonb) from public, anon, authenticated;

-- One-off: drafts already holding more than 3 per-part Stock sentences.
-- The provenance guard lets this through only under the write GUC (a
-- migration has no auth.uid() either way).
do $$
declare
  v_guc text := current_setting('app.mcp_order_write', true);
begin
  perform set_config('app.mcp_order_write', 'on', true);
  update public.orders o
     set mcp_warnings = public.order_collapse_stock_warnings(o.mcp_warnings)
   where o.status = 'draft'
     and jsonb_typeof(o.mcp_warnings) = 'array'
     and jsonb_array_length(o.mcp_warnings) > 3
     and o.mcp_warnings is distinct from public.order_collapse_stock_warnings(o.mcp_warnings);
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);
end
$$;

comment on column public.v_orders_ready_for_erp.mcp_warnings is
  'Warnings stored at the last MCP create/update (strings). Since 20261114090000 more than 3 '
  'per-part Stock or inactive-part sentences, or per-line Price sentences, are ONE sentence each '
  'naming up to 10 parts ("... and N more").';
