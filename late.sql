-- =====================================================================
--  إضافة: أرقام واتساب للفروع + إشعارات التأخير + "صنف آخر" في التوالف
--  شغّل هذا الملف مرة واحدة فقط من: SQL Editor > New query > Run
--  (بعد reps.sql و viewer.sql) — لا يحذف أي بيانات
-- =====================================================================

-- ---------- 1) الأعمدة ----------
alter table public.branches add column if not exists whatsapp text;  -- رقم واتساب الفرع (دولي بدون +)
-- بداية احتساب التأخير: من يوم تشغيل هذا الملف (والمندوب الجديد من يوم إضافته)
alter table public.branches add column if not exists track_from date not null
  default ((now() at time zone 'Asia/Riyadh')::date);
-- الصنف الذي أضافه موظف من الفرع عبر "صنف آخر"
alter table public.waste_items add column if not exists added_by_branch int
  references public.branches(id) on delete set null;

-- ---------- 2) حساب التأخير ----------
-- اليوم D يُعتبر متأخراً إذا جاءت الساعة 9 صباح اليوم التالي (بتوقيت الرياض)
-- ولم تُدخل مبيعاته، أو أُدخلت بعد هذا الموعد.
-- missing = الأيام المتأخرة التي لم تُدخل حتى الآن | late_count = عدد مرات التأخير التراكمي
create or replace function public.late_rows() returns table (branch_id int, missing date[], late_count int)
language sql stable security definer set search_path = public as $$
  with d as (
    select b.id as bid, g::date as dd
    from branches b
    cross join lateral generate_series(b.track_from, riyadh_today() - 1, interval '1 day') g
    where b.active
  ), x as (
    select d.bid, d.dd, s.created_at,
           ((d.dd + 1)::timestamp + interval '9 hours') at time zone 'Asia/Riyadh' as deadline
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

create or replace function public.late_json() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('branch_id', branch_id, 'missing', missing, 'count', late_count)), '[]'::json)
  from late_rows()
$$;
revoke execute on function public.late_json() from public, anon, authenticated;

-- للإدارة
create or replace function public.admin_late() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  return late_json();
end $$;
revoke execute on function public.admin_late() from public, anon, authenticated;
grant  execute on function public.admin_late() to authenticated;

-- ---------- 3) صفحة الفرع: بيانات الفرع + التأخير ----------
create or replace function public.branch_info(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare b branches; v_late json;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;

  select json_build_object('missing', missing, 'count', late_count) into v_late
  from late_rows() where branch_id = b.id;

  return json_build_object(
    'name',       b.name,
    'group_name', b.group_name,
    'credit',     b.credit,
    'waste',      b.waste,
    'logo',       b.logo,
    'today',      riyadh_today(),
    'late',       coalesce(v_late, json_build_object('missing', '[]'::json, 'count', 0)),
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

-- ---------- 4) "صنف آخر": الموظف يضيف صنفاً جديداً فيدخل قائمة الأصناف رسمياً ----------
create or replace function public.branch_add_item(p_token uuid, p_name text, p_unit text, p_cost numeric) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; it waste_items; v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if not b.waste then raise exception 'قسم التوالف غير مفعّل لهذا الفرع'; end if;
  if v_name = '' then raise exception 'اكتب اسم الصنف'; end if;
  if length(v_name) > 80 then raise exception 'اسم الصنف طويل جداً'; end if;
  if p_unit not in ('piece', 'weight') then raise exception 'اختر نوع الصنف'; end if;
  if p_cost is null or p_cost < 0 or p_cost > 100000 then raise exception 'اكتب سعر تكلفة صحيحاً'; end if;

  -- نفس الاسم موجود؟ نستخدمه بدل التكرار
  select * into it from waste_items where lower(btrim(name)) = lower(v_name) order by active desc, id limit 1;
  if found then
    if not it.active then raise exception 'هذا الصنف موجود وموقوف من الإدارة'; end if;
    if it.branch_ids is not null and cardinality(it.branch_ids) > 0 and not (b.id = any(it.branch_ids)) then
      update waste_items set branch_ids = array_append(branch_ids, b.id) where id = it.id returning * into it;
    end if;
    return json_build_object('id', it.id, 'name', it.name, 'unit', it.unit, 'cost', it.cost, 'existed', true);
  end if;

  insert into waste_items (name, unit, cost, branch_ids, added_by_branch)
  values (v_name, p_unit, round(p_cost, 2), null, b.id)
  returning * into it;
  return json_build_object('id', it.id, 'name', it.name, 'unit', it.unit, 'cost', it.cost, 'existed', false);
end $$;
revoke execute on function public.branch_add_item(uuid, text, text, numeric) from public, anon, authenticated;
grant  execute on function public.branch_add_item(uuid, text, text, numeric) to anon, authenticated;

-- ---------- 5) رابط الاطلاع: إضافة التأخير وأرقام الواتساب ----------
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
               'active', b.active, 'credit', b.credit, 'waste', b.waste, 'logo', b.logo, 'is_rep', b.is_rep, 'whatsapp', b.whatsapp)
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

revoke execute on function public.branch_info(uuid)                from public, anon, authenticated;
revoke execute on function public.viewer_data(uuid, date, date)    from public, anon, authenticated;
grant  execute on function public.branch_info(uuid)                to anon, authenticated;
grant  execute on function public.viewer_data(uuid, date, date)    to anon, authenticated;

notify pgrst, 'reload schema';
