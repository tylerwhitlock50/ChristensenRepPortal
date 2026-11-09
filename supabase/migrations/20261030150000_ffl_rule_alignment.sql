/*============================================================================
  20261030150000_ffl_rule_alignment.sql
  Purpose: make the portal and the order loader agree, exactly, on the two
  FFL rules 20261030140000 introduced (review findings).

  1. part_requires_ffl(): Z_PRODUCT_DETAIL family/chambering are free text,
     so 'n/a', 'N/A ' or 'N/A' + a tab must read as "no spec", as they do
     in isGunRow()/hasSpec() and the loader's ffl.part_requires_ffl().
     Compare trimmed (all whitespace) and upper-cased.

  2. parse_ffl_expiry(): one reading of the free-form CUST_ADDRESS.USER_5
     string, shared with the loader (order_loader/app/ffl.py
     parse_expiration, same test strings in both test suites):
       - a leading label is dropped: EXP, EXPIRES, EXPIRATION, EXP DATE,
         EXPIRATION DATE, VALID UNTIL / VALID TIL; trailing punctuation too
       - 2027-01-31                 ISO
       - 01312027                   MMDDYYYY
       - Jan 31 2027, January 31, 2027, Sept. 30, 2027   month name
       - 31-Jan-2027, 31-Jan-27     DD-Mon-YY(YY)
       - 1/31/2027, 1-31-27, 1.31.2027, also inside other text
         ("1/31/2027 renewed")       M/D/Y anywhere, any of / - .
     Two-digit years < 70 are 20xx. A date more than 25 years from today
     is not an expiry (typo or another field): NULL. NULL always means
     "unknown", and unknown is never "current".
============================================================================*/

create or replace function public.part_requires_ffl(p_part_id text)
returns boolean
language sql stable security definer set search_path = public, erp
as $$
  select coalesce((
    select coalesce(p.product_code, '') !~* 'component'
       and (   coalesce(nullif(upper(regexp_replace(p.product_family, '^\s+|\s+$', '', 'g')), ''), 'N/A') <> 'N/A'
            or coalesce(nullif(upper(regexp_replace(p.chambering,     '^\s+|\s+$', '', 'g')), ''), 'N/A') <> 'N/A')
    from erp.dim_part p
    where p.part_id = p_part_id
    limit 1), true);
$$;

create or replace function public.parse_ffl_expiry(p_raw text)
returns date
language plpgsql stable
as $$
declare
  months constant text[] := array['JANUARY','FEBRUARY','MARCH','APRIL','MAY','JUNE','JULY',
                                  'AUGUST','SEPTEMBER','OCTOBER','NOVEMBER','DECEMBER'];
  v   text := upper(regexp_replace(coalesce(p_raw, ''), '^\s+|\s+$', '', 'g'));
  m   text[];
  mon int;
  y   int;
  d   date;
begin
  v := regexp_replace(v, '^(EXP(IRES|IRATION)?(\s+DATE)?|VALID\s+(UN)?TIL)\M[\s:.-]*', '');
  v := regexp_replace(v, '[\s.,;]+$', '');
  if v = '' then
    return null;
  end if;

  begin
    m := regexp_match(v, '^(\d{4})-(\d{1,2})-(\d{1,2})$');
    if m is not null then
      d := make_date(m[1]::int, m[2]::int, m[3]::int);
    end if;

    if d is null then
      m := regexp_match(v, '^(\d{2})(\d{2})(\d{4})$');
      if m is not null then
        d := make_date(m[3]::int, m[1]::int, m[2]::int);
      end if;
    end if;

    if d is null then
      m := regexp_match(v, '^([A-Z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})$');
      if m is not null then
        mon := public.ffl_month(m[1], months);
        if mon is not null then
          d := make_date(m[3]::int, mon, m[2]::int);
        end if;
      end if;
    end if;

    if d is null then
      m := regexp_match(v, '^(\d{1,2})-([A-Z]{3,9})-(\d{4}|\d{2})$');
      if m is not null then
        mon := public.ffl_month(m[2], months);
        y := m[3]::int;
        if length(m[3]) = 2 then
          y := y + case when y < 70 then 2000 else 1900 end;
        end if;
        if mon is not null then
          d := make_date(y, mon, m[1]::int);
        end if;
      end if;
    end if;

    if d is null then
      m := regexp_match(v, '(?<!\d)(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})(?!\d)');
      if m is not null then
        y := m[3]::int;
        if length(m[3]) = 2 then
          y := y + case when y < 70 then 2000 else 1900 end;
        end if;
        d := make_date(y, m[1]::int, m[2]::int);
      end if;
    end if;
  exception when others then
    return null;
  end;

  if d is null or abs(d - current_date) > 365 * 25 then
    return null;
  end if;
  return d;
end;
$$;

-- 'JAN', 'JANUARY', 'SEPT' → month number; anything else (e.g. 'JUNK') → NULL.
create or replace function public.ffl_month(p_word text, p_months text[])
returns int
language sql immutable
as $$
  select i
  from generate_subscripts(p_months, 1) as i
  where p_word = left(p_months[i], 3) or p_word = p_months[i] or (p_word = 'SEPT' and i = 9)
  limit 1;
$$;

revoke execute on function public.part_requires_ffl(text) from public, anon;
revoke execute on function public.parse_ffl_expiry(text) from public, anon;
revoke execute on function public.ffl_month(text, text[]) from public, anon;
grant execute on function public.part_requires_ffl(text) to authenticated;
grant execute on function public.parse_ffl_expiry(text) to authenticated;
grant execute on function public.ffl_month(text, text[]) to authenticated;
