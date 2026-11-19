-- =====================================================================
--  توزيع فواتير الفرع وتحصيله على فروع فرعية (مثل البازل الذهبي: مورا البلد، مورا سحر آل عاصم، بلانيت بيكري، نكهة بيت، أخرى)
--  شغّل هذا الملف مرة واحدة فقط (بعد studiobg.sql) — لا يحذف أي بيانات
--  "أخرى" لا تُخزَّن: هي دائماً الإجمالي − مجموع الفروع. المبيعات القديمة تُحسب كلها في "أخرى" حتى تعدّلها الإدارة
-- =====================================================================

-- ---------- 1) الفروع الفرعية لكل فرع ----------
create table if not exists public.branch_accounts (
  id bigserial primary key,
  branch_id int not null references public.branches(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists branch_accounts_branch_idx on public.branch_accounts (branch_id, sort_order);
alter table public.branch_accounts enable row level security;
drop policy if exists branch_accounts_admin on public.branch_accounts;
create policy branch_accounts_admin on public.branch_accounts for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.branch_accounts to authenticated;
grant usage, select on sequence public.branch_accounts_id_seq to authenticated;

-- ---------- 2) أعمدة التوزيع ({"رقم الفرع الفرعي": المبلغ}) ----------
alter table public.sales               add column if not exists sales_split jsonb;
alter table public.sales               add column if not exists col_split jsonb;
alter table public.credit_moves        add column if not exists split jsonb;
alter table public.correction_requests add column if not exists split_given boolean not null default false;
alter table public.correction_requests add column if not exists old_split jsonb;
alter table public.correction_requests add column if not exists old_col_split jsonb;
alter table public.correction_requests add column if not exists new_split jsonb;
alter table public.correction_requests add column if not exists new_col_split jsonb;

-- ---------- 3) التحقق: مجموع الفروع لا يتجاوز الإجمالي ----------
create or replace function public.split_sum(p jsonb) returns numeric
language sql immutable as $$
  select coalesce(sum((e.value #>> '{}')::numeric), 0) from jsonb_each(case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end) e
$$;

create or replace function public.split_clean(p_branch int, p_split jsonb, p_total numeric, p_what text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e record; v numeric; r jsonb := '{}'::jsonb; s numeric := 0; t numeric := round(coalesce(p_total, 0), 2);
begin
  if p_split is null or jsonb_typeof(p_split) <> 'object' then return null; end if;
  for e in select key, value #>> '{}' as val from jsonb_each(p_split) loop
    begin v := round(e.val::numeric, 2); exception when others then raise exception 'مبلغ غير صحيح في توزيع %', p_what; end;
    if v is null or v = 0 then continue; end if;
    if v < 0 then raise exception 'مبالغ الفروع لا تكون بالسالب'; end if;
    if e.key !~ '^\d+$' or not exists (select 1 from branch_accounts a where a.id = e.key::bigint and a.branch_id = p_branch) then
      raise exception 'فرع غير معروف في توزيع %', p_what;
    end if;
    s := s + v; r := r || jsonb_build_object(e.key, v);
  end loop;
  if s > t then
    raise exception 'مجموع مبالغ الفروع في % (%) أكبر من الإجمالي (%). الحد الأقصى هو % ريال', p_what, s, t, t;
  end if;
  return case when r = '{}'::jsonb then null else r end;
end $$;

create or replace function public.sales_split_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.sales_split := split_clean(new.branch_id, new.sales_split, new.amount, 'المبيعات');
  new.col_split   := split_clean(new.branch_id, new.col_split, new.collected, 'التحصيل');
  return new;
end $$;
drop trigger if exists sales_split_check on public.sales;
create trigger sales_split_check before insert or update on public.sales for each row execute function public.sales_split_check();

create or replace function public.moves_split_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.split := split_clean(new.branch_id, new.split, new.amount, case when new.kind = 'return' then 'المردود' else 'التحصيل' end);
  return new;
end $$;
drop trigger if exists moves_split_check on public.credit_moves;
create trigger moves_split_check before insert or update on public.credit_moves for each row execute function public.moves_split_check();

-- ---------- 4) الدوال: إضافة التوزيع ----------
drop function if exists public.submit_sale(uuid, date, numeric, numeric, numeric, numeric, numeric);
drop function if exists public.request_correction(uuid, date, numeric, text, numeric, numeric, numeric, numeric);
drop function if exists public.admin_submit_sale(int, date, numeric, numeric, numeric, numeric, numeric);

create or replace function public.submit_sale(p_token uuid, p_date date, p_amount numeric, p_collected numeric default 0,
    p_cash numeric default null, p_bank numeric default null, p_card numeric default null,
    p_split jsonb default null, p_col_split jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; v_cash numeric := 0; v_bank numeric := 0; v_card numeric := 0; v_col numeric;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if p_date is null then raise exception 'اختر التاريخ أولاً'; end if;
  if p_date > riyadh_today() then raise exception 'لا يمكن إدخال مبيعات لتاريخ لم يأتِ بعد'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;
  if b.credit then
    if p_cash is not null or p_bank is not null or p_card is not null then
      v_cash := round(coalesce(p_cash, 0), 2); v_bank := round(coalesce(p_bank, 0), 2); v_card := round(coalesce(p_card, 0), 2);
      if v_cash < 0 or v_bank < 0 or v_card < 0 then raise exception 'أدخل مبالغ تحصيل صحيحة'; end if;
      v_col := v_cash + v_bank + v_card;
    else
      v_col := round(coalesce(p_collected, 0), 2);
      if v_col < 0 then raise exception 'أدخل مبلغ تحصيل صحيحاً'; end if;
    end if;
  else v_col := 0; end if;
  if exists (select 1 from sales where branch_id = b.id and sale_date = p_date) then
    raise exception 'مبيعات هذا التاريخ مُدخلة من قبل. استخدم طلب التعديل إذا كان المبلغ خاطئاً.';
  end if;
  insert into sales (branch_id, sale_date, amount, collected, col_cash, col_bank, col_card, sales_split, col_split)
  values (b.id, p_date, round(p_amount, 2), v_col, v_cash, v_bank, v_card, p_split, case when b.credit then p_col_split end);
  return json_build_object('ok', true);
exception when unique_violation then
  raise exception 'مبيعات هذا التاريخ مُدخلة من قبل. استخدم طلب التعديل إذا كان المبلغ خاطئاً.';
end $$;

create or replace function public.request_correction(p_token uuid, p_date date, p_new_amount numeric,
    p_note text default null, p_new_collected numeric default null,
    p_new_cash numeric default null, p_new_bank numeric default null, p_new_card numeric default null,
    p_new_split jsonb default null, p_new_col_split jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; s sales; v_col numeric; v_split boolean := false; v_cash numeric; v_bank numeric; v_card numeric;
  v_given boolean := p_new_split is not null or p_new_col_split is not null; v_ns jsonb; v_nc jsonb; v_same_split boolean := true;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if p_new_amount is null or p_new_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;
  select * into s from sales where branch_id = b.id and sale_date = p_date;
  if not found then raise exception 'لا توجد مبيعات مسجلة لهذا التاريخ'; end if;

  if v_given then
    v_ns := split_clean(b.id, p_new_split, round(p_new_amount, 2), 'المبيعات');
    v_same_split := coalesce(v_ns, '{}'::jsonb) = coalesce(s.sales_split, '{}'::jsonb);
  end if;
  if b.credit then
    if p_new_cash is not null or p_new_bank is not null or p_new_card is not null then
      v_split := true;
      v_cash := round(coalesce(p_new_cash, 0), 2); v_bank := round(coalesce(p_new_bank, 0), 2); v_card := round(coalesce(p_new_card, 0), 2);
      if v_cash < 0 or v_bank < 0 or v_card < 0 then raise exception 'أدخل مبالغ تحصيل صحيحة'; end if;
      v_col := v_cash + v_bank + v_card;
      if v_given then
        v_nc := split_clean(b.id, p_new_col_split, v_col, 'التحصيل');
        v_same_split := v_same_split and coalesce(v_nc, '{}'::jsonb) = coalesce(s.col_split, '{}'::jsonb);
      end if;
      if v_same_split and round(p_new_amount, 2) = s.amount and v_cash = s.col_cash and v_bank = s.col_bank and v_card = s.col_card and v_col = s.collected then
        raise exception 'المبالغ الجديدة مطابقة للمبالغ المسجلة';
      end if;
    else
      v_col := round(coalesce(p_new_collected, s.collected), 2);
      if v_col < 0 then raise exception 'أدخل مبلغ تحصيل صحيحاً'; end if;
      if v_same_split and round(p_new_amount, 2) = s.amount and v_col = s.collected then raise exception 'المبالغ الجديدة مطابقة للمبالغ المسجلة'; end if;
    end if;
  else
    v_col := null;
    if v_same_split and round(p_new_amount, 2) = s.amount then raise exception 'المبلغ الجديد مطابق للمبلغ المسجل'; end if;
  end if;

  if exists (select 1 from correction_requests where sale_id = s.id and status = 'pending') then
    raise exception 'يوجد طلب تعديل لهذا التاريخ بانتظار الإدارة';
  end if;

  insert into correction_requests (sale_id, branch_id, sale_date, old_amount, new_amount, old_collected, new_collected, note,
                                   old_cash, old_bank, old_card, new_cash, new_bank, new_card,
                                   split_given, old_split, old_col_split, new_split, new_col_split)
  values (s.id, b.id, p_date, s.amount, round(p_new_amount, 2), case when b.credit then s.collected end, v_col, nullif(trim(p_note), ''),
          case when b.credit then s.col_cash end, case when b.credit then s.col_bank end, case when b.credit then s.col_card end,
          case when v_split then v_cash end, case when v_split then v_bank end, case when v_split then v_card end,
          v_given, s.sales_split, s.col_split, v_ns, v_nc);
  return json_build_object('ok', true);
end $$;

create or replace function public.approve_correction(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r correction_requests;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into r from correction_requests where id = p_id for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.status <> 'pending' then raise exception 'تمت معالجة هذا الطلب من قبل'; end if;
  -- يُفرَّغ التوزيع مؤقتاً حتى لا يتعارض مع المبالغ الجديدة ثم يُعاد ضبطه بالأسفل
  update sales set sales_split = case when r.split_given or split_sum(sales_split) > r.new_amount then null else sales_split end,
                   col_split = case when r.split_given or split_sum(col_split) > coalesce(r.new_collected, collected) then null else col_split end
  where id = r.sale_id;
  if r.new_cash is not null then
    update sales set amount = r.new_amount, collected = r.new_collected,
                     col_cash = r.new_cash, col_bank = r.new_bank, col_card = r.new_card, updated_at = now()
    where id = r.sale_id;
  else
    -- طلب بدون تفصيل: يتغير المجموع فقط، ويُلغى التفصيل إذا تغيّر المجموع
    update sales set amount = r.new_amount,
                     collected = coalesce(r.new_collected, collected),
                     col_cash = case when r.new_collected is null or r.new_collected = collected then col_cash else 0 end,
                     col_bank = case when r.new_collected is null or r.new_collected = collected then col_bank else 0 end,
                     col_card = case when r.new_collected is null or r.new_collected = collected then col_card else 0 end,
                     updated_at = now()
    where id = r.sale_id;
  end if;
  -- توزيع الفواتير على الفروع
  if r.split_given then
    update sales set sales_split = r.new_split, col_split = r.new_col_split where id = r.sale_id;
  else
    update sales set sales_split = case when split_sum(sales_split) <= amount then sales_split end,
                     col_split   = case when split_sum(col_split) <= collected then col_split end
    where id = r.sale_id;
  end if;
  update correction_requests set status = 'approved', decided_at = now() where id = p_id;
end $$;

create or replace function public.admin_submit_sale(p_branch_id int, p_date date, p_amount numeric, p_collected numeric default 0,
    p_cash numeric default null, p_bank numeric default null, p_card numeric default null,
    p_split jsonb default null, p_col_split jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; v_cash numeric := 0; v_bank numeric := 0; v_card numeric := 0; v_col numeric;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into b from branches where id = p_branch_id and active;
  if not found then raise exception 'اختر الفرع'; end if;
  if p_date is null then raise exception 'اختر التاريخ'; end if;
  if p_date > riyadh_today() then raise exception 'لا يمكن إدخال مبيعات لتاريخ لم يأتِ بعد'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;
  if b.credit then
    if p_cash is not null or p_bank is not null or p_card is not null then
      v_cash := round(coalesce(p_cash, 0), 2); v_bank := round(coalesce(p_bank, 0), 2); v_card := round(coalesce(p_card, 0), 2);
      if v_cash < 0 or v_bank < 0 or v_card < 0 then raise exception 'أدخل مبالغ تحصيل صحيحة'; end if;
      v_col := v_cash + v_bank + v_card;
    else
      v_col := round(coalesce(p_collected, 0), 2);
      if v_col < 0 then raise exception 'أدخل مبلغ تحصيل صحيحاً'; end if;
    end if;
  else v_col := 0; end if;
  if exists (select 1 from sales where branch_id = b.id and sale_date = p_date) then
    raise exception 'مبيعات هذا الفرع لهذا التاريخ مُدخلة من قبل';
  end if;
  insert into sales (branch_id, sale_date, amount, collected, col_cash, col_bank, col_card, entered_by, sales_split, col_split)
  values (b.id, p_date, round(p_amount, 2), v_col, v_cash, v_bank, v_card, 'admin', p_split, case when b.credit then p_col_split end);
  return json_build_object('ok', true);
exception when unique_violation then
  raise exception 'مبيعات هذا الفرع لهذا التاريخ مُدخلة من قبل';
end $$;

-- تعديل الإدارة لأي يوم سابق: المبيعات + التحصيل وتفصيله + التوزيع على الفروع
create or replace function public.admin_edit_sale(p_id bigint, p_amount numeric,
    p_cash numeric default null, p_bank numeric default null, p_card numeric default null,
    p_split jsonb default null, p_col_split jsonb default null) returns json
language plpgsql security definer set search_path = public as $$
declare s sales; b branches; v_cash numeric := 0; v_bank numeric := 0; v_card numeric := 0;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into s from sales where id = p_id for update;
  if not found then raise exception 'المبيعات غير موجودة'; end if;
  select * into b from branches where id = s.branch_id;
  if p_amount is null or p_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;
  if b.credit then
    v_cash := round(coalesce(p_cash, s.col_cash), 2); v_bank := round(coalesce(p_bank, s.col_bank), 2); v_card := round(coalesce(p_card, s.col_card), 2);
    if v_cash < 0 or v_bank < 0 or v_card < 0 then raise exception 'أدخل مبالغ تحصيل صحيحة'; end if;
  end if;
  update sales set sales_split = null, col_split = null where id = p_id;
  update sales set amount = round(p_amount, 2),
                   collected = case when b.credit then v_cash + v_bank + v_card else 0 end,
                   col_cash = v_cash, col_bank = v_bank, col_card = v_card,
                   sales_split = p_split, col_split = case when b.credit then p_col_split end,
                   updated_at = now()
  where id = p_id;
  return json_build_object('ok', true);
end $$;

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
                 'cash', s.col_cash, 'bank', s.col_bank, 'card', s.col_card, 'split', s.sales_split, 'col_split', s.col_split,
                 'by', s.entered_by,
                 'pending', exists (select 1 from correction_requests c where c.sale_id = s.id and c.status = 'pending'))
               order by s.sale_date desc)
        from sales s where s.branch_id = b.id), '[]'::json)
  );
end $$;

create or replace function public.viewer_data(p_token uuid, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
declare v viewer_links;
begin
  select * into v from viewer_links where token = p_token and active;
  if not found then raise exception 'رابط الاطلاع غير صحيح أو تم إيقافه. اطلب رابطاً جديداً من الإدارة.'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'الفترة غير صحيحة'; end if;
  if p_to - p_from > 800 then raise exception 'الفترة طويلة جداً. اختر فترة أقصر.'; end if;

  return json_build_object(
    'label', v.label,
    'today', riyadh_today(),
    'late',  late_json(),
    'branches', coalesce((
      select json_agg(json_build_object('id', b.id, 'name', b.name, 'group_name', b.group_name, 'sort_order', b.sort_order,
               'active', b.active, 'credit', b.credit, 'waste', b.waste, 'logo', b.logo, 'is_rep', b.is_rep, 'whatsapp', b.whatsapp,
               'late_exempt', b.late_exempt, 'monthly_target', b.monthly_target, 'profit_margin', b.profit_margin)
             order by b.sort_order, b.id)
      from branches b), '[]'::json),
    'sales', coalesce((
      select json_agg(json_build_object('id', s.id, 'branch_id', s.branch_id, 'sale_date', s.sale_date,
               'amount', s.amount, 'collected', s.collected, 'col_cash', s.col_cash, 'col_bank', s.col_bank, 'col_card', s.col_card, 'entered_by', s.entered_by, 'sales_split', s.sales_split, 'col_split', s.col_split)
             order by s.sale_date, s.id)
      from sales s where s.sale_date between p_from and p_to), '[]'::json),
    'waste', coalesce((
      select json_agg(json_build_object('id', r.id, 'batch_id', r.batch_id, 'branch_id', r.branch_id, 'waste_date', r.waste_date,
               'item_name', r.item_name, 'unit', r.unit, 'qty', r.qty, 'unit_cost', r.unit_cost, 'cost', r.cost,
               'entered_by', r.entered_by, 'created_at', r.created_at)
             order by r.waste_date, r.id)
      from waste_records r where r.waste_date between p_from and p_to), '[]'::json),
    'pending', coalesce((
      select json_agg(row_to_json(c) order by c.created_at)
      from correction_requests c where c.status = 'pending'), '[]'::json),
    'recent', coalesce((
      select json_agg(row_to_json(c) order by c.decided_at desc)
      from (select * from correction_requests where status <> 'pending' order by decided_at desc limit 12) c), '[]'::json),
    'moves', coalesce((
      select json_agg(json_build_object('id', m.id, 'branch_id', m.branch_id, 'move_date', m.move_date, 'kind', m.kind,
               'amount', m.amount, 'col_cash', m.col_cash, 'col_bank', m.col_bank, 'col_card', m.col_card, 'note', m.note, 'entered_by', m.entered_by, 'created_at', m.created_at, 'split', m.split) order by m.move_date, m.id)
      from credit_moves m where m.move_date between p_from and p_to), '[]'::json),
    'accounts', coalesce((select json_agg(row_to_json(a) order by a.branch_id, a.sort_order, a.id) from branch_accounts a), '[]'::json),
    'merges', coalesce((select json_agg(row_to_json(x) order by x.id) from merged_views x), '[]'::json),
    'fin', json_build_object(
      'cats',          coalesce((select json_agg(row_to_json(x) order by x.sort_order, x.id) from commit_cats x), '[]'::json),
      'commitments',   coalesce((select json_agg(row_to_json(x) order by x.id) from commitments x), '[]'::json),
      'sources',       coalesce((select json_agg(row_to_json(x) order by x.sort_order, x.id) from fund_sources x), '[]'::json),
      'payments',      coalesce((select json_agg(row_to_json(x)) from fund_payments x), '[]'::json),
      'loans',         coalesce((select json_agg(row_to_json(x) order by x.due_day, x.id) from loans x), '[]'::json),
      'loan_payments', coalesce((select json_agg(row_to_json(x)) from loan_payments x), '[]'::json),
      'opening',       (select value from app_settings where key = 'fund_opening')
    )
  );
end $$;

-- ---------- 5) الصلاحيات ----------
revoke execute on function public.submit_sale(uuid, date, numeric, numeric, numeric, numeric, numeric, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.request_correction(uuid, date, numeric, text, numeric, numeric, numeric, numeric, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.admin_submit_sale(int, date, numeric, numeric, numeric, numeric, numeric, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.admin_edit_sale(bigint, numeric, numeric, numeric, numeric, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.approve_correction(bigint) from public, anon, authenticated;
revoke execute on function public.branch_info(uuid) from public, anon, authenticated;
revoke execute on function public.viewer_data(uuid, date, date) from public, anon, authenticated;
revoke execute on function public.split_clean(int, jsonb, numeric, text) from public, anon, authenticated;
grant execute on function public.submit_sale(uuid, date, numeric, numeric, numeric, numeric, numeric, jsonb, jsonb) to anon, authenticated;
grant execute on function public.request_correction(uuid, date, numeric, text, numeric, numeric, numeric, numeric, jsonb, jsonb) to anon, authenticated;
grant execute on function public.branch_info(uuid) to anon, authenticated;
grant execute on function public.viewer_data(uuid, date, date) to anon, authenticated;
grant execute on function public.admin_submit_sale(int, date, numeric, numeric, numeric, numeric, numeric, jsonb, jsonb) to authenticated;
grant execute on function public.admin_edit_sale(bigint, numeric, numeric, numeric, numeric, jsonb, jsonb) to authenticated;
grant execute on function public.approve_correction(bigint) to authenticated;

-- ---------- 6) فروع البازل الذهبي (مرة واحدة فقط إذا لم تُضف) ----------
insert into public.branch_accounts (branch_id, name, sort_order)
select b.id, x.name, x.ord
from public.branches b
cross join (values ('مورا البلد', 1), ('مورا سحر آل عاصم', 2), ('بلانيت بيكري', 3), ('نكهة بيت', 4)) as x(name, ord)
where b.name like '%البازل%'
  and not exists (select 1 from public.branch_accounts a where a.branch_id = b.id);

notify pgrst, 'reload schema';
