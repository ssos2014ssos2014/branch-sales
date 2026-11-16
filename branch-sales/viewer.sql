-- =====================================================================
--  إضافة: روابط الاطلاع فقط (عرض كل الإحصائيات بدون أي تعديل)
--  شغّل هذا الملف مرة واحدة فقط من: SQL Editor > New query > Run
-- =====================================================================

create table if not exists public.viewer_links (
  id          serial primary key,
  token       uuid not null unique default gen_random_uuid(),
  label       text not null,                 -- لمن الرابط (مثل: المدير المالي)
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

alter table public.viewer_links enable row level security;
drop policy if exists admin_all_viewer_links on public.viewer_links;
create policy admin_all_viewer_links on public.viewer_links
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- بيانات العرض فقط: قراءة لفترة محددة، بدون مفاتيح روابط الفروع، وبدون أي صلاحية كتابة
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
    'branches', coalesce((
      select json_agg(json_build_object('id', b.id, 'name', b.name, 'group_name', b.group_name, 'sort_order', b.sort_order,
               'active', b.active, 'credit', b.credit, 'waste', b.waste, 'logo', b.logo, 'is_rep', b.is_rep)
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
      from (select * from correction_requests where status <> 'pending' order by decided_at desc limit 12) c), '[]'::json)
  );
end $$;

revoke execute on function public.viewer_data(uuid, date, date) from public, anon, authenticated;
grant  execute on function public.viewer_data(uuid, date, date) to anon, authenticated;

notify pgrst, 'reload schema';
