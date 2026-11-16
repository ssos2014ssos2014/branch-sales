-- =====================================================================
--  تقرير المبيعات اليومي على قروب واتساب لكل فرع + رابط قروب خاص للتوالف لكل فرع
--  شغّل هذا الملف مرة واحدة فقط (بعد resend.sql) — لا يحذف أي بيانات
-- =====================================================================

-- رابط قروب تقرير المبيعات (إذا كان فارغاً لا يظهر زر الإرسال للفرع)
alter table public.branches add column if not exists sales_wa_link text;
-- رابط قروب التوالف الخاص بالفرع (إذا كان فارغاً يُستخدم الرابط العام)
alter table public.branches add column if not exists waste_wa_link text;

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
                 'cash', s.col_cash, 'bank', s.col_bank, 'card', s.col_card,
                 'by', s.entered_by,
                 'pending', exists (select 1 from correction_requests c where c.sale_id = s.id and c.status = 'pending'))
               order by s.sale_date desc)
        from sales s where s.branch_id = b.id), '[]'::json)
  );
end $$;

revoke execute on function public.branch_info(uuid) from public, anon, authenticated;
grant execute on function public.branch_info(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
