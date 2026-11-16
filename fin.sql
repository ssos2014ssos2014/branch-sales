-- =====================================================================
--  إضافة: الهدف الشهري + هامش الربح + التزامات الفروع + حساب التمويلات البنكية
--  شغّل هذا الملف مرة واحدة فقط من: SQL Editor > New query > Run
--  (بعد الملفات السابقة) — لا يحذف أي بيانات. كل هذه البيانات للإدارة فقط.
-- =====================================================================

-- ---------- 1) الهدف الشهري وهامش الربح لكل فرع ----------
alter table public.branches add column if not exists monthly_target numeric(14,2);  -- الهدف الشهري للمبيعات (ريال)
alter table public.branches add column if not exists profit_margin  numeric(5,2);   -- هامش الربح التقريبي (%)

-- ---------- 2) الالتزامات المالية ----------
-- البنود الرئيسية (مشتركة لكل الفروع)
create table if not exists public.commit_cats (
  id          serial primary key,
  name        text not null,
  sort_order  int  not null default 100,
  created_at  timestamptz not null default now()
);
-- مبالغ كل فرع: name فارغ = مبلغ البند الرئيسي نفسه | name مكتوب = بند فرعي داخل البند الرئيسي
create table if not exists public.commitments (
  id          serial primary key,
  branch_id   int  not null references public.branches(id) on delete cascade,
  cat_id      int  not null references public.commit_cats(id) on delete cascade,
  name        text,
  amount      numeric(14,2) not null default 0 check (amount >= 0),  -- مبلغ شهري
  created_at  timestamptz not null default now()
);
create unique index if not exists commitments_main_uq on public.commitments (branch_id, cat_id) where name is null;

-- البنود الأساسية (تُضاف مرة واحدة فقط إذا كانت القائمة فارغة)
insert into public.commit_cats (name, sort_order)
select v.name, v.ord from (values
  ('إيجار', 1), ('قسط تمويلي', 2), ('رواتب الموظفين', 3), ('الكهرباء والمياه', 4),
  ('الإنترنت والاتصالات', 5), ('مصاريف حكومية', 6), ('الصيانة', 7), ('التسويق والإعلان', 8),
  ('التأمين', 9), ('المستهلكات ومواد التنظيف', 10), ('النقل والتوصيل', 11)
) as v(name, ord)
where not exists (select 1 from public.commit_cats);

-- ---------- 3) حساب التمويلات البنكية ----------
-- أقساط الفروع الأسبوعية التي تُدفع لحساب التمويلات (weekday: 0 الأحد ... 5 الجمعة 6 السبت)
create table if not exists public.fund_sources (
  id             serial primary key,
  label          text not null,
  group_name     text,
  weekly_amount  numeric(14,2) not null check (weekly_amount >= 0),
  weekday        int  not null default 5 check (weekday between 0 and 6),
  active         boolean not null default true,
  sort_order     int  not null default 100,
  created_at     timestamptz not null default now()
);
-- الأقساط التي تم سدادها (المبلغ يُحفظ وقت السداد)
create table if not exists public.fund_payments (
  id         bigserial primary key,
  source_id  int  not null references public.fund_sources(id) on delete cascade,
  due_date   date not null,
  amount     numeric(14,2) not null check (amount >= 0),
  paid_at    timestamptz not null default now(),
  unique (source_id, due_date)
);
-- التمويلات البنكية: قسط شهري يُسدد من الحساب في يوم محدد من الشهر
create table if not exists public.loans (
  id           serial primary key,
  name         text not null,
  amount       numeric(14,2) not null check (amount >= 0),
  due_day      int  not null check (due_day between 1 and 31),
  start_month  date,                 -- أول شهر (فارغ = من الآن)
  end_month    date,                 -- آخر شهر (فارغ = مستمر)
  active       boolean not null default true,
  notes        text,
  created_at   timestamptz not null default now()
);
create table if not exists public.loan_payments (
  id        bigserial primary key,
  loan_id   int  not null references public.loans(id) on delete cascade,
  month     date not null,           -- أول يوم في الشهر
  amount    numeric(14,2) not null check (amount >= 0),
  paid_at   timestamptz not null default now(),
  unique (loan_id, month)
);

-- أقساط الفروع حسب ما طلبته (تُضاف مرة واحدة)
insert into public.fund_sources (label, group_name, weekly_amount, weekday, sort_order)
select v.label, v.g, v.amt, 5, v.ord from (values
  ('أفنون الكيك',               'أفنون الكيك',               1500, 1),
  ('حلويات مورا - البلد',        'حلويات مورا - البلد',        1500, 2),
  ('حلويات مورا - سحر آل عاصم',  'حلويات مورا - سحر آل عاصم',  1800, 3),
  ('بلانيت بيكري',              'بلانيت بيكري',              1500, 4),
  ('مصنع أفق النكهات',           'مصنع أفق النكهات',           2600, 5)
) as v(label, g, amt, ord)
where not exists (select 1 from public.fund_sources);

-- الرصيد الافتتاحي للحساب
insert into public.app_settings (key, value) values ('fund_opening', '0') on conflict (key) do nothing;

-- ---------- 4) الصلاحيات: الإدارة فقط ----------
do $$
declare t text;
begin
  foreach t in array array['commit_cats', 'commitments', 'fund_sources', 'fund_payments', 'loans', 'loan_payments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists admin_all on public.%I', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- ---------- 5) التحديث اللحظي ----------
do $$
declare t text;
begin
  foreach t in array array['commitments', 'commit_cats', 'fund_payments', 'loan_payments', 'fund_sources', 'loans'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end;
  end loop;
end $$;

-- ---------- 6) رابط الاطلاع: يرى الأهداف والهامش والالتزامات والتمويلات (قراءة فقط) ----------
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
