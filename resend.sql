-- =====================================================================
--  حذف وتعديل التوالف من الإدارة + حذف تقرير يوم كامل (مبيعات أو توالف)
--  مع طلب إعادة الإرسال من الفرع
--  شغّل هذا الملف مرة واحدة فقط (بعد wcats.sql) — لا يحذف أي بيانات بنفسه
-- =====================================================================

-- ---------- 1) طلبات إعادة الإرسال ----------
create table if not exists public.resend_requests (
  id bigserial primary key,
  branch_id int not null references public.branches(id) on delete cascade,
  kind text not null check (kind in ('sales', 'waste')),
  req_date date not null,
  note text,
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists resend_open_idx on public.resend_requests (branch_id, kind, req_date) where status = 'open';

alter table public.resend_requests enable row level security;
drop policy if exists admin_all on public.resend_requests;
create policy admin_all on public.resend_requests for all to authenticated using (public.is_admin()) with check (public.is_admin());
do $$ begin
  begin alter publication supabase_realtime add table public.resend_requests; exception when duplicate_object then null; end;
end $$;

-- عند إعادة الإرسال من الفرع يُغلق الطلب تلقائياً
create or replace function public.resend_mark_done() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'sales' then
    update resend_requests set status = 'done', done_at = now()
    where status = 'open' and kind = 'sales' and branch_id = new.branch_id and req_date = new.sale_date;
  else
    update resend_requests set status = 'done', done_at = now()
    where status = 'open' and kind = 'waste' and branch_id = new.branch_id and req_date = new.waste_date;
  end if;
  return new;
end $$;

drop trigger if exists resend_done_sales on public.sales;
create trigger resend_done_sales after insert on public.sales for each row execute function public.resend_mark_done();
drop trigger if exists resend_done_waste on public.waste_records;
create trigger resend_done_waste after insert on public.waste_records for each row execute function public.resend_mark_done();

-- ---------- 2) حذف تقرير يوم كامل (للإدارة) ----------
-- p_kind: 'sales' أو 'waste'. p_resend = true يطلب من الفرع إعادة الإرسال
create or replace function public.admin_delete_report(p_branch int, p_date date, p_kind text,
    p_resend boolean default false, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare cnt int := 0; b branches;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into b from branches where id = p_branch;
  if not found then raise exception 'الفرع غير موجود'; end if;
  if p_kind = 'sales' then
    delete from sales where branch_id = p_branch and sale_date = p_date;   -- طلبات التعديل المرتبطة تُحذف معه
    get diagnostics cnt = row_count;
  elsif p_kind = 'waste' then
    delete from waste_records where branch_id = p_branch and waste_date = p_date;
    get diagnostics cnt = row_count;
  else raise exception 'نوع التقرير غير صحيح'; end if;
  update resend_requests set status = 'cancelled', done_at = now()
  where status = 'open' and branch_id = p_branch and kind = p_kind and req_date = p_date;
  if p_resend then
    insert into resend_requests (branch_id, kind, req_date, note)
    values (p_branch, p_kind, p_date, nullif(btrim(coalesce(p_note, '')), ''));
  end if;
  return json_build_object('ok', true, 'deleted', cnt, 'resend', p_resend);
end $$;

-- ---------- 3) تعديل كمية سطر توالف (للإدارة) ----------
-- الحبة بالعدد، والوزن بالجرام. التكلفة تُعاد حسابها بسعر الوحدة المحفوظ
create or replace function public.admin_update_waste(p_id bigint, p_qty numeric) returns json
language plpgsql security definer set search_path = public as $$
declare r waste_records; q numeric;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into r from waste_records where id = p_id;
  if not found then raise exception 'السطر غير موجود'; end if;
  q := p_qty;
  if q is null or q <= 0 then raise exception 'اكتب كمية أكبر من صفر'; end if;
  if r.unit = 'piece' and q <> trunc(q) then raise exception 'العدد يجب أن يكون رقماً صحيحاً'; end if;
  update waste_records
     set qty = q, cost = round(case when unit = 'weight' then q / 1000 * unit_cost else q * unit_cost end, 2)
   where id = p_id
  returning * into r;
  return json_build_object('ok', true, 'qty', r.qty, 'cost', r.cost);
end $$;

revoke execute on function public.admin_delete_report(int, date, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.admin_update_waste(bigint, numeric)                  from public, anon, authenticated;
grant  execute on function public.admin_delete_report(int, date, text, boolean, text) to authenticated;
grant  execute on function public.admin_update_waste(bigint, numeric)                  to authenticated;

-- ---------- 4) التأخير: اليوم المطلوب إعادة إرساله لا يُحسب تأخيراً ----------
-- مهلة إعادة الإرسال 24 ساعة من وقت الطلب
create or replace function public.late_rows() returns table (branch_id int, missing date[], late_count int)
language sql stable security definer set search_path = public as $$
  with d as (
    select b.id as bid, g::date as dd
    from branches b
    cross join lateral generate_series(b.track_from, riyadh_today() - 1, interval '1 day') g
    where b.active and not b.late_exempt
  ), x as (
    select d.bid, d.dd, s.created_at,
           greatest(((d.dd + 1)::timestamp + interval '9 hours') at time zone 'Asia/Riyadh',
                    (select max(q.created_at) + interval '24 hours' from resend_requests q
                      where q.branch_id = d.bid and q.kind = 'sales' and q.req_date = d.dd and q.status <> 'cancelled')) as deadline
    from d left join sales s on s.branch_id = d.bid and s.sale_date = d.dd
  )
  select bid,
         coalesce(array_agg(dd order by dd) filter (where created_at is null), '{}'::date[]),
         (count(*) filter (where created_at is null or created_at > deadline))::int
  from x
  where deadline <= now()
  group by bid
$$;
revoke execute on function public.late_rows() from public, anon, authenticated;

-- ---------- 5) صفحة الفرع: طلبات إعادة الإرسال المفتوحة ----------
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
    'waste_link', case when b.waste then (select value from app_settings where key = 'waste_whatsapp_link') end,
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
