-- =====================================================================
--  نظام مبيعات الفروع  |  قاعدة البيانات (Supabase)
--  شغّل هذا الملف كاملاً مرة واحدة من: SQL Editor > New query > Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- الجداول ----------
create table if not exists public.branches (
  id          serial primary key,
  name        text not null,                 -- اسم الفرع (أو القسم الداخلي)
  group_name  text not null,                 -- الفرع الرئيسي الذي يظهر في الداشبورد
  sort_order  int  not null default 0,
  token       uuid not null unique default gen_random_uuid(),  -- مفتاح الرابط الخاص بالفرع
  active      boolean not null default true,
  unique (group_name, name)
);

create table if not exists public.sales (
  id          bigserial primary key,
  branch_id   int  not null references public.branches(id) on delete cascade,
  sale_date   date not null,
  amount      numeric(14,2) not null check (amount >= 0),
  entered_by  text not null default 'branch' check (entered_by in ('branch','admin')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (branch_id, sale_date)              -- كل تاريخ يُدخل مرة واحدة فقط لكل فرع
);

create table if not exists public.correction_requests (
  id          bigserial primary key,
  sale_id     bigint not null references public.sales(id) on delete cascade,
  branch_id   int    not null references public.branches(id) on delete cascade,
  sale_date   date   not null,
  old_amount  numeric(14,2) not null,
  new_amount  numeric(14,2) not null check (new_amount >= 0),
  note        text,
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz
);
create unique index if not exists one_pending_per_sale
  on public.correction_requests(sale_id) where status = 'pending';

create table if not exists public.admins (
  email text primary key
);

-- ---------- الفروع ----------
insert into public.branches (name, group_name, sort_order) values
  ('أفنون الكيك',                'أفنون الكيك',                1),
  ('حلويات مورا - البلد',         'حلويات مورا - البلد',         2),
  ('حلويات مورا - سحر آل عاصم',   'حلويات مورا - سحر آل عاصم',   3),
  ('بلانيت بيكري',               'بلانيت بيكري',               4),
  ('البازل الذهبي',              'البازل الذهبي',              5),
  ('المصنع',                     'مصنع أفق النكهات',           6),
  ('مندوب التوزيع',               'مصنع أفق النكهات',           7)
on conflict (group_name, name) do nothing;

-- ---------- حساب الإدارة ----------
-- ضع هنا البريد الذي ستنشئ به حساب الإدارة في Authentication > Users
insert into public.admins (email) values ('ssos2014ssos2014@gmail.com')
on conflict do nothing;

-- ---------- دوال مساعدة ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

create or replace function public.riyadh_today() returns date
language sql stable as $$
  select (now() at time zone 'Asia/Riyadh')::date;
$$;

-- ---------- صلاحيات الجداول (RLS) ----------
alter table public.branches            enable row level security;
alter table public.sales               enable row level security;
alter table public.correction_requests enable row level security;
alter table public.admins              enable row level security;

drop policy if exists admin_read_branches on public.branches;
create policy admin_read_branches on public.branches
  for select to authenticated using (public.is_admin());

drop policy if exists admin_all_sales on public.sales;
create policy admin_all_sales on public.sales
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists admin_read_corrections on public.correction_requests;
create policy admin_read_corrections on public.correction_requests
  for select to authenticated using (public.is_admin());
-- جدول admins بلا سياسات: لا يقرؤه أحد من الواجهة.

-- ---------- دوال صفحة الفرع (بدون تسجيل دخول، عبر مفتاح الرابط) ----------
create or replace function public.branch_info(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare b branches;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;

  return json_build_object(
    'name',       b.name,
    'group_name', b.group_name,
    'today',      riyadh_today(),
    'entries',    coalesce((
        select json_agg(json_build_object(
                 'date',    s.sale_date,
                 'amount',  s.amount,
                 'by',      s.entered_by,
                 'pending', exists (select 1 from correction_requests c
                                    where c.sale_id = s.id and c.status = 'pending'))
               order by s.sale_date desc)
        from sales s where s.branch_id = b.id), '[]'::json)
  );
end $$;

create or replace function public.submit_sale(p_token uuid, p_date date, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare b branches;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if p_date is null then raise exception 'اختر التاريخ أولاً'; end if;
  if p_date > riyadh_today() then raise exception 'لا يمكن إدخال مبيعات لتاريخ لم يأتِ بعد'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;
  if exists (select 1 from sales where branch_id = b.id and sale_date = p_date) then
    raise exception 'مبيعات هذا التاريخ مُدخلة من قبل. استخدم طلب التعديل إذا كان المبلغ خاطئاً.';
  end if;

  insert into sales (branch_id, sale_date, amount) values (b.id, p_date, round(p_amount, 2));
  return json_build_object('ok', true);
exception when unique_violation then
  raise exception 'مبيعات هذا التاريخ مُدخلة من قبل. استخدم طلب التعديل إذا كان المبلغ خاطئاً.';
end $$;

create or replace function public.request_correction(p_token uuid, p_date date, p_new_amount numeric, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; s sales;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if p_new_amount is null or p_new_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;

  select * into s from sales where branch_id = b.id and sale_date = p_date;
  if not found then raise exception 'لا توجد مبيعات مسجلة لهذا التاريخ'; end if;
  if round(p_new_amount, 2) = s.amount then raise exception 'المبلغ الجديد مطابق للمبلغ المسجل'; end if;
  if exists (select 1 from correction_requests where sale_id = s.id and status = 'pending') then
    raise exception 'يوجد طلب تعديل لهذا التاريخ بانتظار الإدارة';
  end if;

  insert into correction_requests (sale_id, branch_id, sale_date, old_amount, new_amount, note)
  values (s.id, b.id, p_date, s.amount, round(p_new_amount, 2), nullif(trim(p_note), ''));
  return json_build_object('ok', true);
end $$;

-- ---------- دوال الإدارة ----------
create or replace function public.approve_correction(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r correction_requests;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into r from correction_requests where id = p_id for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.status <> 'pending' then raise exception 'تمت معالجة هذا الطلب من قبل'; end if;

  update sales set amount = r.new_amount, updated_at = now() where id = r.sale_id;
  update correction_requests set status = 'approved', decided_at = now() where id = p_id;
end $$;

create or replace function public.reject_correction(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  update correction_requests set status = 'rejected', decided_at = now()
  where id = p_id and status = 'pending';
  if not found then raise exception 'تمت معالجة هذا الطلب من قبل'; end if;
end $$;

-- إدخال الإدارة: نفس القواعد (لا تاريخ مستقبلي، ولا تكرار)
create or replace function public.admin_submit_sale(p_branch_id int, p_date date, p_amount numeric) returns json
language plpgsql security definer set search_path = public as $$
declare b branches;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into b from branches where id = p_branch_id and active;
  if not found then raise exception 'اختر الفرع'; end if;
  if p_date is null then raise exception 'اختر التاريخ'; end if;
  if p_date > riyadh_today() then raise exception 'لا يمكن إدخال مبيعات لتاريخ لم يأتِ بعد'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;
  if exists (select 1 from sales where branch_id = b.id and sale_date = p_date) then
    raise exception 'مبيعات هذا الفرع لهذا التاريخ مُدخلة من قبل';
  end if;

  insert into sales (branch_id, sale_date, amount, entered_by)
  values (b.id, p_date, round(p_amount, 2), 'admin');
  return json_build_object('ok', true);
exception when unique_violation then
  raise exception 'مبيعات هذا الفرع لهذا التاريخ مُدخلة من قبل';
end $$;

-- ---------- صلاحيات تنفيذ الدوال ----------
revoke execute on function public.branch_info(uuid)                              from public, anon, authenticated;
revoke execute on function public.submit_sale(uuid, date, numeric)               from public, anon, authenticated;
revoke execute on function public.request_correction(uuid, date, numeric, text)  from public, anon, authenticated;
revoke execute on function public.approve_correction(bigint)                     from public, anon, authenticated;
revoke execute on function public.reject_correction(bigint)                      from public, anon, authenticated;
revoke execute on function public.admin_submit_sale(int, date, numeric)        from public, anon, authenticated;
revoke execute on function public.is_admin()                                     from public, anon, authenticated;

grant execute on function public.branch_info(uuid)                             to anon, authenticated;
grant execute on function public.submit_sale(uuid, date, numeric)              to anon, authenticated;
grant execute on function public.request_correction(uuid, date, numeric, text) to anon, authenticated;
grant execute on function public.approve_correction(bigint)                    to authenticated;
grant execute on function public.reject_correction(bigint)                     to authenticated;
grant execute on function public.admin_submit_sale(int, date, numeric)       to authenticated;
grant execute on function public.is_admin()                                    to authenticated;

-- ---------- التحديث اللحظي ----------
do $$ begin
  begin alter publication supabase_realtime add table public.sales;               exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.correction_requests; exception when duplicate_object then null; end;
end $$;
