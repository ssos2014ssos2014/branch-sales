-- =====================================================================
--  إضافة: البضائع التالفة + شعارات الفروع + رابط قروب الواتساب
--  شغّل هذا الملف مرة واحدة فقط من: SQL Editor > New query > Run
--  (بعد credit_collection.sql) — لا يحذف أي بيانات
-- =====================================================================

-- ---------- 1) أعمدة الفروع ----------
alter table public.branches add column if not exists waste boolean not null default false; -- يظهر له قسم التوالف
alter table public.branches add column if not exists logo  text;                            -- شعار الفرع (صورة مضغوطة)

update public.branches set waste = true
where group_name in ('حلويات مورا - البلد', 'حلويات مورا - سحر آل عاصم', 'بلانيت بيكري');

-- ---------- 2) الإعدادات (رابط قروب التوالف) ----------
create table if not exists public.app_settings (
  key   text primary key,
  value text
);
insert into public.app_settings (key, value) values ('waste_whatsapp_link', '')
on conflict (key) do nothing;

-- ---------- 3) الأصناف ----------
create table if not exists public.waste_items (
  id          serial primary key,
  name        text not null,
  unit        text not null check (unit in ('piece', 'weight')),  -- حبة / وزن
  cost        numeric(12,2) not null check (cost >= 0),           -- الحبة: تكلفة الحبة | الوزن: تكلفة 1 كيلو
  branch_ids  int[],                                               -- فارغ = كل فروع التوالف
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- 4) سجلات التوالف ----------
-- كل إرسال من الموظف = دفعة (batch_id) فيها عدة أصناف. التكلفة تُحفظ وقت الإدخال
-- فلو تغيّرت تكلفة الصنف لاحقاً لا تتغير التقارير القديمة.
create table if not exists public.waste_records (
  id          bigserial primary key,
  batch_id    uuid not null,
  branch_id   int  not null references public.branches(id) on delete cascade,
  waste_date  date not null,
  item_id     int  references public.waste_items(id) on delete set null,
  item_name   text not null,
  unit        text not null check (unit in ('piece', 'weight')),
  qty         numeric(12,3) not null check (qty > 0),             -- الحبة: العدد | الوزن: بالجرام
  unit_cost   numeric(12,2) not null,
  cost        numeric(14,2) not null,
  entered_by  text not null default 'branch' check (entered_by in ('branch','admin')),
  created_at  timestamptz not null default now()
);
create index if not exists waste_records_date_idx   on public.waste_records (waste_date);
create index if not exists waste_records_branch_idx on public.waste_records (branch_id, waste_date);

-- ---------- 5) الصلاحيات (RLS) ----------
alter table public.app_settings  enable row level security;
alter table public.waste_items   enable row level security;
alter table public.waste_records enable row level security;

drop policy if exists admin_all_settings on public.app_settings;
create policy admin_all_settings on public.app_settings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists admin_all_waste_items on public.waste_items;
create policy admin_all_waste_items on public.waste_items
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists admin_all_waste_records on public.waste_records;
create policy admin_all_waste_records on public.waste_records
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- الإدارة تعدّل الشعار وتفعيل التوالف للفروع
drop policy if exists admin_update_branches on public.branches;
create policy admin_update_branches on public.branches
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- 6) دوال صفحة الفرع ----------
create or replace function public.branch_info(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare b branches;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;

  return json_build_object(
    'name',       b.name,
    'group_name', b.group_name,
    'credit',     b.credit,
    'waste',      b.waste,
    'logo',       b.logo,
    'today',      riyadh_today(),
    'waste_link', case when b.waste then (select value from app_settings where key = 'waste_whatsapp_link') end,
    'items',      case when b.waste then coalesce((
        select json_agg(json_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost', i.cost) order by i.name)
        from waste_items i
        where i.active and (i.branch_ids is null or cardinality(i.branch_ids) = 0 or b.id = any(i.branch_ids))), '[]'::json)
      else '[]'::json end,
    'entries',    coalesce((
        select json_agg(json_build_object(
                 'date',      s.sale_date,
                 'amount',    s.amount,
                 'collected', s.collected,
                 'by',        s.entered_by,
                 'pending',   exists (select 1 from correction_requests c
                                      where c.sale_id = s.id and c.status = 'pending'))
               order by s.sale_date desc)
        from sales s where s.branch_id = b.id), '[]'::json)
  );
end $$;

-- تقرير توالف الفرع لفترة
create or replace function public.branch_waste(p_token uuid, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
declare b branches;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  return coalesce((
    select json_agg(json_build_object(
             'batch', r.batch_id, 'date', r.waste_date, 'item', r.item_name, 'unit', r.unit,
             'qty', r.qty, 'unit_cost', r.unit_cost, 'cost', r.cost, 'by', r.entered_by, 'at', r.created_at)
           order by r.waste_date, r.created_at, r.id)
    from waste_records r
    where r.branch_id = b.id and r.waste_date between p_from and p_to), '[]'::json);
end $$;

-- إرسال التوالف: p_lines = [{"item_id": 3, "qty": 5}, {"item_id": 7, "qty": 1250}]
-- (الحبة بالعدد، والوزن بالجرام)
create or replace function public.submit_waste(p_token uuid, p_date date, p_lines json) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; it waste_items; l json; q numeric; v_batch uuid := gen_random_uuid(); v_total numeric := 0; v_cost numeric;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if not b.waste then raise exception 'قسم التوالف غير مفعّل لهذا الفرع'; end if;
  if p_date is null then raise exception 'اختر التاريخ'; end if;
  if p_date > riyadh_today() then raise exception 'لا يمكن الإدخال لتاريخ لم يأتِ بعد'; end if;
  if p_lines is null or json_typeof(p_lines) <> 'array' or json_array_length(p_lines) = 0 then
    raise exception 'أضف صنفاً واحداً على الأقل';
  end if;

  for l in select value from json_array_elements(p_lines) loop
    select * into it from waste_items
    where id = (l->>'item_id')::int and active
      and (branch_ids is null or cardinality(branch_ids) = 0 or b.id = any(branch_ids));
    if not found then raise exception 'أحد الأصناف لم يعد متاحاً. حدّث الصفحة وحاول مرة أخرى.'; end if;
    q := (l->>'qty')::numeric;
    if q is null or q <= 0 then raise exception 'اكتب كمية صحيحة للصنف: %', it.name; end if;
    if q <> trunc(q) then raise exception 'الكمية يجب أن تكون رقماً صحيحاً: %', it.name; end if;
    v_cost := round(case when it.unit = 'weight' then q / 1000 * it.cost else q * it.cost end, 2);
    v_total := v_total + v_cost;
    insert into waste_records (batch_id, branch_id, waste_date, item_id, item_name, unit, qty, unit_cost, cost)
    values (v_batch, b.id, p_date, it.id, it.name, it.unit, q, it.cost, v_cost);
  end loop;

  return json_build_object('ok', true, 'batch_id', v_batch, 'total', v_total);
end $$;

-- ---------- 7) صلاحيات تنفيذ الدوال ----------
revoke execute on function public.branch_info(uuid)                from public, anon, authenticated;
revoke execute on function public.branch_waste(uuid, date, date)   from public, anon, authenticated;
revoke execute on function public.submit_waste(uuid, date, json)   from public, anon, authenticated;
grant  execute on function public.branch_info(uuid)                to anon, authenticated;
grant  execute on function public.branch_waste(uuid, date, date)   to anon, authenticated;
grant  execute on function public.submit_waste(uuid, date, json)   to anon, authenticated;

-- ---------- 8) التحديث اللحظي ----------
do $$ begin
  begin alter publication supabase_realtime add table public.waste_records; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.waste_items;   exception when duplicate_object then null; end;
end $$;

notify pgrst, 'reload schema';
