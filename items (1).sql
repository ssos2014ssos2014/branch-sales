-- =====================================================================
--  إضافة: تصنيف أصناف التوالف + تصحيح الأسماء + رقم الصنف (للاستيراد من الفواتير)
--  شغّل هذا الملف مرة واحدة فقط (بعد late.sql و exempt.sql) — لا يحذف أي بيانات
-- =====================================================================

-- ---------- 1) الأعمدة ----------
alter table public.waste_items add column if not exists category text not null default 'أخرى';  -- تصنيف الصنف
alter table public.waste_items add column if not exists code text;                               -- رقم الصنف في فواتير المورد

-- ---------- 2) تصحيح الأسماء (والسجلات السابقة بنفس الاسم حتى تبقى التقارير موحدة) ----------
with m(old_name, new_name) as (values
  ('معجنات كبير1', 'معجنات كبير'),
  ('معجنات مستطيل1', 'معجنات مستطيل'),
  ('معجنات وسط1', 'معجنات وسط'),
  ('خلية كروسان كبير1', 'خلية كرواسون كبير'),
  ('خلية كروسان صغير1', 'خلية كرواسون صغير'),
  ('خلية عادي صغير1', 'خلية عادي صغير'),
  ('ورق عنب وسط1', 'ورق عنب وسط'),
  ('ورق عنب صغير1', 'ورق عنب صغير'),
  ('بقالوة دمعة', 'بقلاوة دمعة'),
  ('بقالوة صغير 1', 'بقلاوة صغير'),
  ('بسبوسة مشكل1', 'بسبوسة مشكلة'),
  ('تشيز كيك كبير1', 'تشيز كيك كبير'),
  ('صينية شوكلا مكشوف مخمل 1كيلو', 'صينية شوكولاتة مكشوفة مخمل 1 كيلو'),
  ('سمبوسة بالكيلو', 'سمبوسة'),
  ('بلح الشام بالكيلو', 'بلح الشام'),
  ('جبنية بالكيلو', 'جبنية')
), u as (
  update public.waste_items w set name = m.new_name
  from m where w.name = m.old_name
    and not exists (select 1 from public.waste_items x where x.name = m.new_name)
  returning w.id, m.new_name
)
update public.waste_records r set item_name = u.new_name from u where r.item_id = u.id;

-- ---------- 3) رقم الصنف كما في فواتير Planet Bakery ----------
with c(code, name) as (values
  ('2001', 'معجنات كبير'),
  ('2002', 'معجنات مستطيل'),
  ('2003', 'معجنات وسط'),
  ('2004', 'معجنات صغير 10'),
  ('2006', 'بقلاوة دمعة'),
  ('2008', 'بقلاوة صغير'),
  ('2010', 'ورق عنب وسط'),
  ('2011', 'ورق عنب صغير'),
  ('2017', 'خلية كرواسون كبير'),
  ('2018', 'خلية كرواسون صغير'),
  ('2019', 'خلية عادي كبير'),
  ('2020', 'خلية عادي صغير'),
  ('2034', 'جبنية'),
  ('2036', 'بلح الشام'),
  ('2038', 'بسبوسة مشكلة'),
  ('2039', 'سمبوسة'),
  ('2042', 'صينية شوكولاتة مكشوفة مخمل 1 كيلو'),
  ('2050', 'صينية تمر محشي دائري'),
  ('2052', 'تمر محشي صحن وسط'),
  ('2053', 'تمر محشي صحن ربع'),
  ('2055', 'تشيز كيك كبير')
)
update public.waste_items w set code = c.code from c where w.name = c.name and w.code is null;

-- ---------- 4) التصنيف التلقائي (للأصناف غير المصنفة فقط) ----------
update public.waste_items set category = case
    when name like '%تمر%'                                                   then 'التمور'
    when name like 'خلية%' or name like '%كرواسون%' or name like '%كروسان%'   then 'الخلايا والكرواسون'
    when name like 'ورق عنب%'                                                then 'ورق العنب'
    when name like 'معجنات%' or name like '%سمبوس%' or name like 'جبنية%'
      or name like '%فطائر%' or name like '%فطيرة%'                            then 'المعجنات'
    when name like '%بقلاوة%' or name like '%بقالوة%' or name like '%بسبوسة%'
      or name like '%بلح الشام%' or name like '%كنافة%' or name like '%معمول%'
      or name like '%هريسة%'                                                 then 'الحلويات الشرقية'
    when name like '%كيك%' or name like 'صينية%' or name like '%تورت%'        then 'الكيك والصواني'
    else 'أخرى' end
where category = 'أخرى';

-- ---------- 5) صفحة الفرع: إرسال التصنيف مع الأصناف ----------
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
        select json_agg(json_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost', i.cost, 'category', i.category) order by i.category, i.name)
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


-- ---------- 6) "صنف آخر" مع التصنيف ----------
drop function if exists public.branch_add_item(uuid, text, text, numeric);
create or replace function public.branch_add_item(p_token uuid, p_name text, p_unit text, p_cost numeric, p_category text default 'أخرى') returns json
language plpgsql security definer set search_path = public as $$
declare b branches; it waste_items;
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_cat  text := coalesce(nullif(btrim(p_category), ''), 'أخرى');
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if not b.waste then raise exception 'قسم التوالف غير مفعّل لهذا الفرع'; end if;
  if v_name = '' then raise exception 'اكتب اسم الصنف'; end if;
  if length(v_name) > 80 then raise exception 'اسم الصنف طويل جداً'; end if;
  if length(v_cat) > 40 then v_cat := 'أخرى'; end if;
  if p_unit not in ('piece', 'weight') then raise exception 'اختر نوع الصنف'; end if;
  if p_cost is null or p_cost < 0 or p_cost > 100000 then raise exception 'اكتب سعر تكلفة صحيحاً'; end if;

  select * into it from waste_items where lower(btrim(name)) = lower(v_name) order by active desc, id limit 1;
  if found then
    if not it.active then raise exception 'هذا الصنف موجود وموقوف من الإدارة'; end if;
    if it.branch_ids is not null and cardinality(it.branch_ids) > 0 and not (b.id = any(it.branch_ids)) then
      update waste_items set branch_ids = array_append(branch_ids, b.id) where id = it.id returning * into it;
    end if;
    return json_build_object('id', it.id, 'name', it.name, 'unit', it.unit, 'cost', it.cost, 'category', it.category, 'existed', true);
  end if;

  insert into waste_items (name, unit, cost, branch_ids, added_by_branch, category)
  values (v_name, p_unit, round(p_cost, 2), null, b.id, v_cat)
  returning * into it;
  return json_build_object('id', it.id, 'name', it.name, 'unit', it.unit, 'cost', it.cost, 'category', it.category, 'existed', false);
end $$;

revoke execute on function public.branch_info(uuid)                                from public, anon, authenticated;
revoke execute on function public.branch_add_item(uuid, text, text, numeric, text) from public, anon, authenticated;
grant  execute on function public.branch_info(uuid)                                to anon, authenticated;
grant  execute on function public.branch_add_item(uuid, text, text, numeric, text) to anon, authenticated;

notify pgrst, 'reload schema';
