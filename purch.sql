-- =====================================================================
--  مشتريات الفروع: (1) مشتريات من معمل البازل تنعكس تلقائياً من إدخال البازل
--                  (2) مشتريات أخرى  (3) سدادات فقط دون شراء — تدخلها الإدارة
--  شغّل هذا الملف مرة واحدة (بعد split.sql) — لا يحذف أي بيانات
-- =====================================================================

-- ربط الفرع الفرعي في توزيع البازل بفرع حقيقي في البرنامج
alter table public.branch_accounts add column if not exists linked_branch_id int references public.branches(id) on delete set null;

update public.branch_accounts a set linked_branch_id = b.id
from public.branches b
where a.linked_branch_id is null
  and a.branch_id in (select id from public.branches where name like '%البازل%')
  and ((a.name = 'مورا البلد'        and b.name like '%مورا%' and b.name like '%البلد%')
    or (a.name = 'مورا سحر آل عاصم'  and b.name like '%مورا%' and b.name like '%سحر%')
    or (a.name = 'بلانيت بيكري'      and b.name like '%بلانيت%'));

-- المشتريات الأخرى والسدادات (تدخلها الإدارة)
create table if not exists public.branch_purchases (
  id bigserial primary key,
  branch_id int not null references public.branches(id) on delete cascade,
  p_date date not null,
  kind text not null check (kind in ('purchase', 'payment')),
  supplier text,
  amount numeric(12,2) not null check (amount > 0),
  method text check (method in ('cash', 'bank', 'card')),
  note text,
  created_at timestamptz not null default now()
);
create index if not exists branch_purchases_idx on public.branch_purchases (branch_id, p_date);
alter table public.branch_purchases enable row level security;
drop policy if exists branch_purchases_admin on public.branch_purchases;
create policy branch_purchases_admin on public.branch_purchases for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.branch_purchases to authenticated;
grant usage, select on sequence public.branch_purchases_id_seq to authenticated;

-- رابط الاطلاع: إضافة المشتريات
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
    'purchases', coalesce((select json_agg(row_to_json(p) order by p.p_date, p.id) from branch_purchases p where p.p_date between p_from and p_to), '[]'::json),
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
revoke execute on function public.viewer_data(uuid, date, date) from public;
grant execute on function public.viewer_data(uuid, date, date) to anon, authenticated;

notify pgrst, 'reload schema';
