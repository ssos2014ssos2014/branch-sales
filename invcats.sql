-- =====================================================================
--  نقطة الفواتير (أفق النكهات): أقسام الأصناف + عملاء البوكسات بالوزن
--  الأقسام: بوكس شوكولاتة، شوكولاتة بالكيلو (مكشوف/مغلف)، شوكولاتة بلوك 2ك (بني/أبيض)،
--           سطول حشوات (الحشوة × 500 جم / 1 كيلو / 5 كيلو)، بوكسات خاصة بالوزن (شوكولاتة/كرانش)، أخرى (يكتبها الموظف)
--  شغّل هذا الملف مرة واحدة بعد invimg.sql — لا يحذف أي بيانات، ويمكن إعادة تشغيله بأمان
-- =====================================================================

alter table public.inv_items add column if not exists cat text not null default 'box';
alter table public.inv_items add column if not exists grp text;       -- اسم الحشوة (للسطول)
alter table public.inv_items add column if not exists variant text;   -- النوع: مكشوف/مغلف، بني/أبيض، 500 جم...، شوكولاتة/كرانش
do $$ begin
  alter table public.inv_items drop constraint if exists inv_items_cat_check;
  alter table public.inv_items add constraint inv_items_cat_check check (cat in ('box', 'kg', 'block', 'bucket', 'wbox'));
end $$;

alter table public.branch_accounts add column if not exists by_weight boolean not null default false;   -- عميل البوكسات بالوزن
alter table public.inv_customer_items add column if not exists price numeric(12,2) check (price is null or price >= 0); -- سعر خاص لهذا العميل

alter table public.invoice_lines add column if not exists cat text;
alter table public.invoice_lines add column if not exists boxes int;

-- ---------- الأصناف الأساسية لكل فرع فواتير (لا تتكرر) ----------
insert into public.inv_items (branch_id, name, unit, price, cost, cat, variant, sort_order, active)
select b.id, x.name, x.unit, x.price, x.cost, x.cat, x.variant, x.so, true
from public.branches b
cross join lateral (values
  ('شوكولاتة بالكيلو - مكشوف', 'كيلو', b.choc_price, b.choc_cost, 'kg', 'مكشوف', 1),
  ('شوكولاتة بالكيلو - مغلف', 'كيلو', b.choc_price, b.choc_cost, 'kg', 'مغلف', 2),
  ('شوكولاتة بلوك 2ك - بني', 'بلوك', 0::numeric, 0::numeric, 'block', 'بني', 1),
  ('شوكولاتة بلوك 2ك - أبيض', 'بلوك', 0::numeric, 0::numeric, 'block', 'أبيض', 2),
  ('بوكسات بالوزن - شوكولاتة', 'كيلو', 23::numeric, 11::numeric, 'wbox', 'شوكولاتة', 1),
  ('بوكسات بالوزن - كرانش', 'كيلو', 28::numeric, 0::numeric, 'wbox', 'كرانش', 2)
) as x(name, unit, price, cost, cat, variant, so)
where b.invoice_mode
  and not exists (select 1 from public.inv_items i where i.branch_id = b.id and i.cat = x.cat and i.variant = x.variant);

-- ---------- بيانات نقطة الفواتير ----------
create or replace function public.inv_data(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare b branches; v_today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط غير صالح'; end if;
  if not b.invoice_mode then raise exception 'نقطة الفواتير غير مفعلة لهذا الفرع'; end if;
  return json_build_object(
    'branch', json_build_object('id', b.id, 'name', b.name, 'logo', b.logo, 'choc_price', b.choc_price),
    'today', v_today,
    'customers', coalesce((select json_agg(json_build_object('id', a.id, 'name', a.name, 'by_weight', a.by_weight,
        'items', coalesce((select json_agg(ci.item_id) from inv_customer_items ci join inv_items it on it.id = ci.item_id and it.active where ci.account_id = a.id), '[]'::json),
        'prices', coalesce((select json_object_agg(ci.item_id::text, ci.price) from inv_customer_items ci where ci.account_id = a.id and ci.price is not null), '{}'::json),
        'balance', coalesce((select round(x.invoiced - x.paid, 2) from inv_balances(b.id) x where x.account_id = a.id), 0))
      order by a.sort_order, a.id) from branch_accounts a where a.branch_id = b.id and a.active), '[]'::json),
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'price', i.price,
        'weighted', i.weighted, 'weight_g', i.weight_g, 'image', i.image, 'cat', i.cat, 'grp', i.grp, 'variant', i.variant) order by i.sort_order, i.id)
      from inv_items i where i.branch_id = b.id and i.active), '[]'::json),
    'invoices', coalesce((select json_agg(json_build_object('id', v.id, 'no', v.inv_no, 'date', v.inv_date, 'account_id', v.account_id,
        'total', v.total, 'note', v.note, 'by', v.entered_by, 'at', v.created_at, 'choc_price', v.choc_price,
        'lines', (select json_agg(json_build_object('name', l.name, 'unit', l.unit, 'qty', l.qty, 'weight_g', l.weight_g, 'unit_price', l.unit_price, 'total', l.total, 'cat', l.cat, 'boxes', l.boxes) order by l.id) from invoice_lines l where l.invoice_id = v.id))
      order by v.inv_no desc) from invoices v where v.branch_id = b.id and v.inv_date >= v_today - 45), '[]'::json),
    'collections', coalesce((select json_agg(json_build_object('id', m.id, 'date', m.move_date, 'amount', m.amount, 'split', m.split, 'note', m.note, 'by', m.entered_by,
        'cash', m.col_cash, 'bank', m.col_bank, 'card', m.col_card) order by m.move_date desc, m.id desc)
      from credit_moves m where m.branch_id = b.id and m.kind = 'collect' and m.move_date >= v_today - 45), '[]'::json)
  );
end $$;

-- ---------- إصدار فاتورة: الأسعار تُحسب في القاعدة ----------
-- كل سطر: {item_id, qty, weight_g?, boxes?}  أو صنف أخرى: {name, qty, unit, price}
create or replace function public.inv_create(p_token uuid, p_account bigint, p_date date, p_lines jsonb, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; acc branch_accounts; v_today date := (now() at time zone 'Asia/Riyadh')::date; e jsonb; it inv_items;
  v_qty numeric; v_w numeric; v_up numeric; v_uc numeric; v_tot numeric := 0; v_cost numeric := 0; v_no int; v_id bigint;
  v_boxrestrict boolean; v_ov numeric; v_name text; v_unit text; v_boxes int; v_cat text;
begin
  select * into b from branches where token = p_token and active for update;
  if not found then raise exception 'رابط غير صالح'; end if;
  if not b.invoice_mode then raise exception 'نقطة الفواتير غير مفعلة لهذا الفرع'; end if;
  select * into acc from branch_accounts a where a.id = p_account and a.branch_id = b.id and a.active;
  if not found then raise exception 'اختر العميل'; end if;
  if p_date is null or p_date > v_today or p_date < v_today - 30 then raise exception 'تاريخ الفاتورة يجب أن يكون خلال آخر 30 يوماً'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'أضف صنفاً واحداً على الأقل'; end if;
  if jsonb_array_length(p_lines) > 200 then raise exception 'الحد الأعلى 200 صنف في الفاتورة'; end if;
  -- العميل العادي: إذا خُصصت له بوكسات معينة تظهر له هي فقط
  v_boxrestrict := exists (select 1 from inv_customer_items ci join inv_items i on i.id = ci.item_id where ci.account_id = p_account and i.cat = 'box');
  select coalesce(max(inv_no), 0) + 1 into v_no from invoices where branch_id = b.id;
  insert into invoices (branch_id, account_id, inv_no, inv_date, note, entered_by, choc_price, choc_cost)
  values (b.id, p_account, v_no, p_date, nullif(btrim(coalesce(p_note, '')), ''), 'branch', b.choc_price, b.choc_cost) returning id into v_id;
  for e in select value from jsonb_array_elements(p_lines) loop
    v_qty := round(nullif(e ->> 'qty', '')::numeric, 3); v_w := null; v_boxes := null;
    if nullif(e ->> 'item_id', '') is null then
      -- صنف أخرى يكتبه الموظف
      v_name := left(btrim(coalesce(e ->> 'name', '')), 80); v_unit := left(coalesce(nullif(btrim(e ->> 'unit'), ''), 'حبة'), 20);
      if v_name = '' then raise exception 'اكتب اسم الصنف في "أخرى"'; end if;
      if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'كمية غير صحيحة للصنف "%"', v_name; end if;
      v_up := round(nullif(e ->> 'price', '')::numeric, 2);
      if v_up is null or v_up < 0 or v_up > 1000000 then raise exception 'اكتب سعر الصنف "%"', v_name; end if;
      v_uc := 0; v_cat := 'other';
      insert into invoice_lines (invoice_id, item_id, name, unit, qty, weight_g, unit_price, unit_cost, total, cost, cat)
      values (v_id, null, 'أخرى: ' || v_name, v_unit, v_qty, null, v_up, 0, round(v_up * v_qty, 2), 0, v_cat);
      v_tot := v_tot + round(v_up * v_qty, 2);
      continue;
    end if;
    select * into it from inv_items where id = (e ->> 'item_id')::bigint and branch_id = b.id and active;
    if not found then raise exception 'صنف غير متاح'; end if;
    if it.cat = 'wbox' then
      if not acc.by_weight then raise exception 'البوكسات بالوزن غير مفعلة لهذا العميل'; end if;
    elsif acc.by_weight then
      if not exists (select 1 from inv_customer_items where account_id = p_account and item_id = it.id) then raise exception 'الصنف "%" غير مخصص لهذا العميل', it.name; end if;
    elsif it.cat = 'box' and v_boxrestrict then
      if not exists (select 1 from inv_customer_items where account_id = p_account and item_id = it.id) then raise exception 'الصنف "%" غير مخصص لهذا العميل', it.name; end if;
    end if;
    if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'كمية غير صحيحة للصنف "%"', it.name; end if;
    select price into v_ov from inv_customer_items where account_id = p_account and item_id = it.id;
    v_up := coalesce(v_ov, it.price); v_uc := it.cost;
    if it.cat = 'box' and it.weighted then
      v_w := round(coalesce(nullif(e ->> 'weight_g', '')::numeric, it.weight_g), 2);
      if v_w is null or v_w < 0 or v_w > 100000 then raise exception 'وزن غير صحيح للصنف "%"', it.name; end if;
      v_up := v_up + v_w / 1000 * b.choc_price; v_uc := it.cost + v_w / 1000 * b.choc_cost;
    end if;
    if it.cat = 'wbox' then
      v_boxes := nullif(e ->> 'boxes', '')::numeric::int;
      if v_boxes is not null and (v_boxes < 0 or v_boxes > 100000) then raise exception 'عدد البوكسات غير صحيح للصنف "%"', it.name; end if;
    end if;
    v_up := round(v_up, 2); v_uc := round(v_uc, 2);
    insert into invoice_lines (invoice_id, item_id, name, unit, qty, weight_g, unit_price, unit_cost, total, cost, cat, boxes)
    values (v_id, it.id, it.name, it.unit, v_qty, v_w, v_up, v_uc, round(v_up * v_qty, 2), round(v_uc * v_qty, 2), it.cat, v_boxes);
    v_tot := v_tot + round(v_up * v_qty, 2); v_cost := v_cost + round(v_uc * v_qty, 2);
  end loop;
  update invoices set total = v_tot, cost_total = v_cost where id = v_id;
  return json_build_object('id', v_id, 'no', v_no, 'total', v_tot);
end $$;

revoke execute on function public.inv_data(uuid) from public;
revoke execute on function public.inv_create(uuid, bigint, date, jsonb, text) from public;
grant execute on function public.inv_data(uuid) to anon, authenticated;
grant execute on function public.inv_create(uuid, bigint, date, jsonb, text) to anon, authenticated;

notify pgrst, 'reload schema';
