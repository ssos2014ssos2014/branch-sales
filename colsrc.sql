-- =====================================================================
--  مصدر التحصيل: توزيع التحصيل فقط على فروعنا + أخرى (مصنع أفق النكهات)
--  شغّل هذا الملف مرة واحدة (بعد expenses.sql) — لا يحذف أي بيانات
-- =====================================================================
alter table public.branches add column if not exists split_mode text not null default 'both';
alter table public.branches drop constraint if exists branches_split_mode_chk;
alter table public.branches add constraint branches_split_mode_chk check (split_mode in ('both', 'col'));

-- أفق النكهات: التحصيل فقط، ومصادره = كل فروعنا (مرة واحدة إذا لم تُضف)
update public.branches set split_mode = 'col' where name like '%أفق النكهات%';
insert into public.branch_accounts (branch_id, name, sort_order)
select f.id, b.name, row_number() over (order by b.sort_order, b.id)
from public.branches f
join public.branches b on b.id <> f.id and b.active
where f.name like '%أفق النكهات%'
  and not exists (select 1 from public.branch_accounts a where a.branch_id = f.id);

create or replace function public.sales_split_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select split_mode from branches where id = new.branch_id) = 'col' then new.sales_split := null;
  else new.sales_split := split_clean(new.branch_id, new.sales_split, new.amount, 'المبيعات'); end if;
  new.col_split   := split_clean(new.branch_id, new.col_split, new.collected, 'التحصيل');
  return new;
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
    'sales_pay', coalesce(b.sales_pay, false),
    'split_mode', coalesce(b.split_mode, 'both'),
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

revoke execute on function public.branch_info(uuid) from public;
grant execute on function public.branch_info(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
