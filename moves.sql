-- =====================================================================
--  إضافة: مردود المبيعات + تحصيل تُدخله الإدارة + الإحصائيات المدمجة
--  شغّل هذا الملف مرة واحدة فقط (بعد الملفات السابقة) — لا يحذف أي بيانات
-- =====================================================================

-- ---------- 1) حركات الفروع الآجلة ----------
-- kind = 'return' مردود مبيعات (يُخصم من إجمالي المبيعات)  |  'collect' تحصيل إضافي تُدخله الإدارة
-- المبيعات المسجلة سابقاً لا تتغير، والمبلغ يُحفظ موجباً ويُعرض بالسالب للمردود
create table if not exists public.credit_moves (
  id          bigserial primary key,
  branch_id   int  not null references public.branches(id) on delete cascade,
  move_date   date not null,
  kind        text not null check (kind in ('return', 'collect')),
  amount      numeric(14,2) not null check (amount > 0),
  note        text,
  entered_by  text not null default 'branch' check (entered_by in ('branch', 'admin')),
  created_at  timestamptz not null default now()
);
create index if not exists credit_moves_date_idx   on public.credit_moves (move_date);
create index if not exists credit_moves_branch_idx on public.credit_moves (branch_id, move_date);

-- ---------- 2) الإحصائيات المدمجة (مثل: مصنع أفق النكهات + فرع التوزيع) ----------
create table if not exists public.merged_views (
  id          serial primary key,
  name        text  not null,
  branch_ids  int[] not null,
  created_at  timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['credit_moves', 'merged_views'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists admin_all on public.%I', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end;
  end loop;
end $$;

-- ---------- 3) صفحة الفرع: إدخال المردود (الفروع الآجلة فقط) ----------
create or replace function public.submit_return(p_token uuid, p_date date, p_amount numeric, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if not b.credit then raise exception 'المردود متاح للفروع الآجلة فقط'; end if;
  if p_date is null then raise exception 'اختر التاريخ'; end if;
  if p_date > riyadh_today() then raise exception 'لا يمكن الإدخال لتاريخ لم يأتِ بعد'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'اكتب مبلغ المردود رقماً أكبر من صفر'; end if;
  insert into credit_moves (branch_id, move_date, kind, amount, note, entered_by)
  values (b.id, p_date, 'return', round(p_amount, 2), nullif(btrim(coalesce(p_note, '')), ''), 'branch');
  return json_build_object('ok', true);
end $$;

-- مردود الفرع لفترة (للعرض في صفحة الفرع)
create or replace function public.branch_returns(p_token uuid, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
declare b branches;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  return coalesce((
    select json_agg(json_build_object('date', m.move_date, 'amount', m.amount, 'note', m.note, 'by', m.entered_by, 'at', m.created_at)
           order by m.move_date desc, m.id desc)
    from credit_moves m where m.branch_id = b.id and m.kind = 'return' and m.move_date between p_from and p_to), '[]'::json);
end $$;

revoke execute on function public.submit_return(uuid, date, numeric, text) from public, anon, authenticated;
revoke execute on function public.branch_returns(uuid, date, date)         from public, anon, authenticated;
grant  execute on function public.submit_return(uuid, date, numeric, text) to anon, authenticated;
grant  execute on function public.branch_returns(uuid, date, date)         to anon, authenticated;

-- ---------- 4) رابط الاطلاع: المردود والتحصيل والإحصائيات المدمجة ----------
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
               'amount', s.amount, 'collected', s.collected, 'entered_by', s.entered_by)
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
               'amount', m.amount, 'note', m.note, 'entered_by', m.entered_by, 'created_at', m.created_at) order by m.move_date, m.id)
      from credit_moves m where m.move_date between p_from and p_to), '[]'::json),
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

revoke execute on function public.viewer_data(uuid, date, date) from public, anon, authenticated;
grant  execute on function public.viewer_data(uuid, date, date) to anon, authenticated;

notify pgrst, 'reload schema';
