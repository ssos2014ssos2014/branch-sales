-- =====================================================================
--  نقطة فواتير المبيعات بالأصناف والعملاء (مصنع أفق النكهات)
--  - العملاء = الفروع الفرعية للفرع (branch_accounts) ويضيفهم المدير
--  - الأصناف بسعر بيع وتكلفة، والبوكسات بوزن شوكولاتة (سعر الكيلو 23 وتكلفته 11 قابلة للتعديل)
--  - تخصيص أصناف لكل عميل، وكل الفواتير آجلة، والتحصيل لكل عميل لاحقاً
--  - مبيعات اليوم في البرنامج = مجموع فواتير اليوم تلقائياً (مع توزيعها على العملاء)
--  شغّل هذا الملف مرة واحدة (بعد colsrc.sql) — لا يحذف أي بيانات
-- =====================================================================

alter table public.branches add column if not exists invoice_mode boolean not null default false;
alter table public.branches add column if not exists choc_price numeric(10,2) not null default 23;
alter table public.branches add column if not exists choc_cost numeric(10,2) not null default 11;

-- ---------- الأصناف ----------
create table if not exists public.inv_items (
  id bigserial primary key,
  branch_id int not null references public.branches(id) on delete cascade,
  name text not null,
  unit text not null default 'حبة',
  price numeric(12,2) not null default 0 check (price >= 0),   -- للبوكس الموزون: سعر البوكس بدون الشوكولاتة
  cost numeric(12,2) not null default 0 check (cost >= 0),     -- للبوكس الموزون: تكلفة البوكس بدون الشوكولاتة
  weighted boolean not null default false,                      -- سعره يتغير بوزن الشوكولاتة
  weight_g numeric(10,2) not null default 0 check (weight_g >= 0),
  active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists inv_items_branch_idx on public.inv_items (branch_id, sort_order);

-- ---------- أصناف كل عميل ----------
create table if not exists public.inv_customer_items (
  account_id bigint not null references public.branch_accounts(id) on delete cascade,
  item_id bigint not null references public.inv_items(id) on delete cascade,
  primary key (account_id, item_id)
);

-- ---------- الفواتير ----------
create table if not exists public.invoices (
  id bigserial primary key,
  branch_id int not null references public.branches(id) on delete cascade,
  account_id bigint not null references public.branch_accounts(id),
  inv_no int not null,
  inv_date date not null,
  total numeric(14,2) not null default 0,
  cost_total numeric(14,2) not null default 0,
  choc_price numeric(10,2),
  choc_cost numeric(10,2),
  note text,
  entered_by text not null default 'branch' check (entered_by in ('branch', 'admin')),
  created_at timestamptz not null default now(),
  unique (branch_id, inv_no)
);
create index if not exists invoices_branch_date_idx on public.invoices (branch_id, inv_date);
create index if not exists invoices_account_idx on public.invoices (account_id);

create table if not exists public.invoice_lines (
  id bigserial primary key,
  invoice_id bigint not null references public.invoices(id) on delete cascade,
  item_id bigint references public.inv_items(id) on delete set null,
  name text not null,
  unit text,
  qty numeric(12,3) not null check (qty > 0),
  weight_g numeric(10,2),
  unit_price numeric(12,2) not null,
  unit_cost numeric(12,2) not null,
  total numeric(14,2) not null,
  cost numeric(14,2) not null
);
create index if not exists invoice_lines_inv_idx on public.invoice_lines (invoice_id);

-- ---------- الصلاحيات: الإدارة فقط (الموظف عبر الدوال) ----------
do $$ declare t text; begin
  foreach t in array array['inv_items', 'inv_customer_items', 'invoices', 'invoice_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_admin', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t || '_admin', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
grant usage, select on sequence public.inv_items_id_seq, public.invoices_id_seq, public.invoice_lines_id_seq to authenticated;

-- ---------- مبيعات اليوم = مجموع فواتير اليوم (مع التوزيع على العملاء) ----------
create or replace function public.inv_sync_day(p_branch int, p_date date) returns void
language plpgsql security definer set search_path = public as $$
declare v_tot numeric; v_split jsonb; s sales;
begin
  select coalesce(sum(t), 0), jsonb_object_agg(account_id::text, t) filter (where t > 0)
    into v_tot, v_split
  from (select account_id, sum(total) t from invoices where branch_id = p_branch and inv_date = p_date group by account_id) x;
  select * into s from sales where branch_id = p_branch and sale_date = p_date for update;
  if found then
    if v_tot = 0 and coalesce(s.collected, 0) = 0 then
      delete from sales where id = s.id;
    else
      update sales set sales_split = null where id = s.id;
      update sales set amount = v_tot, sales_split = v_split, updated_at = now() where id = s.id;
    end if;
  elsif v_tot > 0 then
    insert into sales (branch_id, sale_date, amount, collected, col_cash, col_bank, col_card, entered_by, sales_split)
    values (p_branch, p_date, v_tot, 0, 0, 0, 0, 'branch', v_split);
  end if;
end $$;

create or replace function public.invoices_sync_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then perform inv_sync_day(old.branch_id, old.inv_date); end if;
  if tg_op in ('INSERT', 'UPDATE') then perform inv_sync_day(new.branch_id, new.inv_date); end if;
  return null;
end $$;
drop trigger if exists invoices_sync on public.invoices;
create trigger invoices_sync after insert or update or delete on public.invoices for each row execute function public.invoices_sync_trg();

-- رصيد العميل (كل الفترات): الفواتير − السداد − المردود الموزع
create or replace function public.inv_balances(p_branch int) returns table (account_id bigint, invoiced numeric, paid numeric)
language sql stable security definer set search_path = public as $$
  select a.id,
    coalesce((select sum(i.total) from invoices i where i.account_id = a.id), 0)
      - coalesce((select sum(nullif(m.split ->> a.id::text, '')::numeric) from credit_moves m where m.branch_id = p_branch and m.kind = 'return'), 0),
    coalesce((select sum(nullif(s.col_split ->> a.id::text, '')::numeric) from sales s where s.branch_id = p_branch), 0)
      + coalesce((select sum(nullif(m.split ->> a.id::text, '')::numeric) from credit_moves m where m.branch_id = p_branch and m.kind = 'collect'), 0)
  from branch_accounts a where a.branch_id = p_branch
$$;

-- ---------- بيانات نقطة الفواتير (للموظف برابط الفرع) ----------
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
    'customers', coalesce((select json_agg(json_build_object('id', a.id, 'name', a.name,
        'items', coalesce((select json_agg(ci.item_id) from inv_customer_items ci join inv_items it on it.id = ci.item_id and it.active where ci.account_id = a.id), '[]'::json),
        'balance', coalesce((select round(x.invoiced - x.paid, 2) from inv_balances(b.id) x where x.account_id = a.id), 0))
      order by a.sort_order, a.id) from branch_accounts a where a.branch_id = b.id and a.active), '[]'::json),
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'price', i.price,
        'weighted', i.weighted, 'weight_g', i.weight_g) order by i.sort_order, i.id) from inv_items i where i.branch_id = b.id and i.active), '[]'::json),
    'invoices', coalesce((select json_agg(json_build_object('id', v.id, 'no', v.inv_no, 'date', v.inv_date, 'account_id', v.account_id,
        'total', v.total, 'note', v.note, 'by', v.entered_by, 'at', v.created_at, 'choc_price', v.choc_price,
        'lines', (select json_agg(json_build_object('name', l.name, 'unit', l.unit, 'qty', l.qty, 'weight_g', l.weight_g, 'unit_price', l.unit_price, 'total', l.total) order by l.id) from invoice_lines l where l.invoice_id = v.id))
      order by v.inv_no desc) from invoices v where v.branch_id = b.id and v.inv_date >= v_today - 45), '[]'::json),
    'collections', coalesce((select json_agg(json_build_object('id', m.id, 'date', m.move_date, 'amount', m.amount, 'split', m.split, 'note', m.note, 'by', m.entered_by,
        'cash', m.col_cash, 'bank', m.col_bank, 'card', m.col_card) order by m.move_date desc, m.id desc)
      from credit_moves m where m.branch_id = b.id and m.kind = 'collect' and m.move_date >= v_today - 45), '[]'::json)
  );
end $$;

-- ---------- إصدار فاتورة: الأسعار تُحسب في القاعدة ----------
create or replace function public.inv_create(p_token uuid, p_account bigint, p_date date, p_lines jsonb, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; v_today date := (now() at time zone 'Asia/Riyadh')::date; e jsonb; it inv_items;
  v_qty numeric; v_w numeric; v_up numeric; v_uc numeric; v_tot numeric := 0; v_cost numeric := 0; v_no int; v_id bigint; n int := 0;
  v_restrict boolean;
begin
  select * into b from branches where token = p_token and active for update;
  if not found then raise exception 'رابط غير صالح'; end if;
  if not b.invoice_mode then raise exception 'نقطة الفواتير غير مفعلة لهذا الفرع'; end if;
  if not exists (select 1 from branch_accounts a where a.id = p_account and a.branch_id = b.id and a.active) then raise exception 'اختر العميل'; end if;
  if p_date is null or p_date > v_today or p_date < v_today - 30 then raise exception 'تاريخ الفاتورة يجب أن يكون خلال آخر 30 يوماً'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'أضف صنفاً واحداً على الأقل'; end if;
  if jsonb_array_length(p_lines) > 200 then raise exception 'الحد الأعلى 200 صنف في الفاتورة'; end if;
  v_restrict := exists (select 1 from inv_customer_items where account_id = p_account);
  select coalesce(max(inv_no), 0) + 1 into v_no from invoices where branch_id = b.id;
  insert into invoices (branch_id, account_id, inv_no, inv_date, note, entered_by, choc_price, choc_cost)
  values (b.id, p_account, v_no, p_date, nullif(btrim(coalesce(p_note, '')), ''), 'branch', b.choc_price, b.choc_cost) returning id into v_id;
  for e in select value from jsonb_array_elements(p_lines) loop
    select * into it from inv_items where id = (e ->> 'item_id')::bigint and branch_id = b.id and active;
    if not found then raise exception 'صنف غير متاح'; end if;
    if v_restrict and not exists (select 1 from inv_customer_items where account_id = p_account and item_id = it.id) then raise exception 'الصنف "%" غير مخصص لهذا العميل', it.name; end if;
    v_qty := round(nullif(e ->> 'qty', '')::numeric, 3);
    if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'كمية غير صحيحة للصنف "%"', it.name; end if;
    v_w := null; v_up := it.price; v_uc := it.cost;
    if it.weighted then
      v_w := round(coalesce(nullif(e ->> 'weight_g', '')::numeric, it.weight_g), 2);
      if v_w is null or v_w < 0 or v_w > 100000 then raise exception 'وزن غير صحيح للصنف "%"', it.name; end if;
      v_up := it.price + v_w / 1000 * b.choc_price; v_uc := it.cost + v_w / 1000 * b.choc_cost;
    end if;
    v_up := round(v_up, 2); v_uc := round(v_uc, 2);
    insert into invoice_lines (invoice_id, item_id, name, unit, qty, weight_g, unit_price, unit_cost, total, cost)
    values (v_id, it.id, it.name, it.unit, v_qty, v_w, v_up, v_uc, round(v_up * v_qty, 2), round(v_uc * v_qty, 2));
    v_tot := v_tot + round(v_up * v_qty, 2); v_cost := v_cost + round(v_uc * v_qty, 2); n := n + 1;
  end loop;
  update invoices set total = v_tot, cost_total = v_cost where id = v_id;
  return json_build_object('id', v_id, 'no', v_no, 'total', v_tot);
end $$;

-- ---------- حذف فاتورة من الموظف (فواتيره خلال 24 ساعة فقط) ----------
create or replace function public.inv_delete(p_token uuid, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; v invoices;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط غير صالح'; end if;
  select * into v from invoices where id = p_id and branch_id = b.id;
  if not found then raise exception 'الفاتورة غير موجودة'; end if;
  if v.entered_by <> 'branch' or v.created_at < now() - interval '24 hours' then raise exception 'لا يمكن حذف الفاتورة بعد 24 ساعة، اطلب من الإدارة'; end if;
  delete from invoices where id = v.id;
  return json_build_object('ok', true);
end $$;

-- ---------- سند تحصيل من عميل (من الموظف) ----------
create or replace function public.inv_collect(p_token uuid, p_account bigint, p_date date,
    p_cash numeric default 0, p_bank numeric default 0, p_card numeric default 0, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; v_today date := (now() at time zone 'Asia/Riyadh')::date; v_c numeric; v_b numeric; v_k numeric; v_t numeric; v_id bigint;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط غير صالح'; end if;
  if not b.invoice_mode then raise exception 'نقطة الفواتير غير مفعلة لهذا الفرع'; end if;
  if not exists (select 1 from branch_accounts a where a.id = p_account and a.branch_id = b.id and a.active) then raise exception 'اختر العميل'; end if;
  if p_date is null or p_date > v_today or p_date < v_today - 30 then raise exception 'تاريخ التحصيل يجب أن يكون خلال آخر 30 يوماً'; end if;
  v_c := round(coalesce(p_cash, 0), 2); v_b := round(coalesce(p_bank, 0), 2); v_k := round(coalesce(p_card, 0), 2);
  if v_c < 0 or v_b < 0 or v_k < 0 then raise exception 'المبالغ لا تكون بالسالب'; end if;
  v_t := v_c + v_b + v_k; if v_t <= 0 then raise exception 'اكتب مبلغ التحصيل'; end if;
  insert into credit_moves (branch_id, move_date, kind, amount, col_cash, col_bank, col_card, note, entered_by, split)
  values (b.id, p_date, 'collect', v_t, v_c, v_b, v_k, nullif(btrim(coalesce(p_note, '')), ''), 'branch', jsonb_build_object(p_account::text, v_t))
  returning id into v_id;
  return json_build_object('id', v_id, 'amount', v_t);
end $$;

-- ---------- branch_info: إضافة invoice_mode (يحوّل رابط الفرع لنقطة الفواتير) ----------
create or replace function public.branch_info(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare b branches; v_late json;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  select json_build_object('missing', missing, 'count', late_count) into v_late from late_rows() where branch_id = b.id;
  return json_build_object(
    'name', b.name, 'group_name', b.group_name, 'credit', b.credit, 'waste', b.waste, 'logo', b.logo,
    'today', riyadh_today(),
    'late', coalesce(v_late, json_build_object('missing', '[]'::json, 'count', 0)),
    'waste_link', case when b.waste then coalesce(nullif(btrim(b.waste_wa_link), ''), (select value from app_settings where key = 'waste_whatsapp_link')) end,
    'sales_link', nullif(btrim(b.sales_wa_link), ''),
    'sales_pay', coalesce(b.sales_pay, false),
    'split_mode', coalesce(b.split_mode, 'both'),
    'invoice_mode', coalesce(b.invoice_mode, false),
    'accounts', coalesce((select json_agg(json_build_object('id', a.id, 'name', a.name) order by a.sort_order, a.id) from branch_accounts a where a.branch_id = b.id and a.active), '[]'::json),
    'items', case when b.waste then coalesce((
        select json_agg(json_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost', i.cost, 'category', i.category, 'sort_order', i.sort_order) order by i.category, i.name)
        from waste_items i
        where i.active and (i.branch_ids is null or cardinality(i.branch_ids) = 0 or b.id = any(i.branch_ids))), '[]'::json)
      else '[]'::json end,
    'cats', case when b.waste then coalesce((select json_agg(c.name order by c.sort_order, c.id) from waste_cats c), '[]'::json) else '[]'::json end,
    'resend', coalesce((select json_agg(json_build_object('id', q.id, 'kind', q.kind, 'date', q.req_date, 'note', q.note, 'at', q.created_at)
        order by q.req_date) from resend_requests q where q.branch_id = b.id and q.status = 'open'), '[]'::json),
    'entries', coalesce((
        select json_agg(json_build_object(
                 'date', s.sale_date, 'amount', s.amount, 'collected', s.collected,
                 'cash', s.col_cash, 'bank', s.col_bank, 'card', s.col_card, 'split', s.sales_split, 'col_split', s.col_split, 'amt_cash', s.amt_cash, 'amt_bank', s.amt_bank, 'expenses', s.expenses,
                 'by', s.entered_by,
                 'pending', exists (select 1 from correction_requests c where c.sale_id = s.id and c.status = 'pending'))
               order by s.sale_date desc)
        from sales s where s.branch_id = b.id), '[]'::json)
  );
end $$;

-- ---------- الصلاحيات ----------
revoke execute on function public.inv_data(uuid) from public;
revoke execute on function public.inv_create(uuid, bigint, date, jsonb, text) from public;
revoke execute on function public.inv_delete(uuid, bigint) from public;
revoke execute on function public.inv_collect(uuid, bigint, date, numeric, numeric, numeric, text) from public;
revoke execute on function public.inv_sync_day(int, date) from public, anon, authenticated;
revoke execute on function public.inv_balances(int) from public, anon;
revoke execute on function public.branch_info(uuid) from public;
grant execute on function public.inv_data(uuid) to anon, authenticated;
grant execute on function public.inv_create(uuid, bigint, date, jsonb, text) to anon, authenticated;
grant execute on function public.inv_delete(uuid, bigint) to anon, authenticated;
grant execute on function public.inv_collect(uuid, bigint, date, numeric, numeric, numeric, text) to anon, authenticated;
grant execute on function public.inv_balances(int) to authenticated;
grant execute on function public.branch_info(uuid) to anon, authenticated;

-- ---------- تفعيل أفق النكهات: نقطة فواتير، والتوزيع على العملاء للمبيعات والتحصيل، ومستثنى من تنبيهات التأخير ----------
update public.branches set invoice_mode = true, split_mode = 'both', late_exempt = true where name like '%أفق النكهات%';

notify pgrst, 'reload schema';
