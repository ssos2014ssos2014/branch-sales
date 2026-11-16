-- =====================================================================
--  إضافة: المبيعات الآجلة والتحصيل (البازل الذهبي + مصنع أفق النكهات)
--  شغّل هذا الملف مرة واحدة فقط من: SQL Editor > New query > Run
--  لا يحذف أي بيانات، ولا يحتاج إعادة تشغيل schema.sql
-- =====================================================================

-- ---------- 1) الأعمدة الجديدة ----------
alter table public.branches add column if not exists credit boolean not null default false;  -- فرع مبيعاته آجلة
alter table public.sales    add column if not exists collected numeric(14,2) not null default 0; -- المبلغ المحصّل في اليوم
alter table public.correction_requests add column if not exists old_collected numeric(14,2);
alter table public.correction_requests add column if not exists new_collected numeric(14,2);

do $$ begin
  begin alter table public.sales add constraint sales_collected_nonneg check (collected >= 0);
  exception when duplicate_object then null; end;
  begin alter table public.correction_requests add constraint corr_new_collected_nonneg check (new_collected is null or new_collected >= 0);
  exception when duplicate_object then null; end;
end $$;

-- ---------- 2) تحديد الفروع الآجلة ----------
update public.branches set credit = true
where group_name in ('البازل الذهبي', 'مصنع أفق النكهات');

-- ---------- 3) حذف النسخ القديمة من الدوال (تُستبدل بنسخ تدعم التحصيل) ----------
drop function if exists public.submit_sale(uuid, date, numeric);
drop function if exists public.request_correction(uuid, date, numeric, text);
drop function if exists public.admin_submit_sale(int, date, numeric);

-- ---------- 4) دوال صفحة الفرع ----------
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
    'today',      riyadh_today(),
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

create or replace function public.submit_sale(p_token uuid, p_date date, p_amount numeric, p_collected numeric default 0) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; v_col numeric;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if p_date is null then raise exception 'اختر التاريخ أولاً'; end if;
  if p_date > riyadh_today() then raise exception 'لا يمكن إدخال مبيعات لتاريخ لم يأتِ بعد'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;
  v_col := case when b.credit then coalesce(p_collected, 0) else 0 end;
  if v_col < 0 then raise exception 'أدخل مبلغ تحصيل صحيحاً'; end if;
  if exists (select 1 from sales where branch_id = b.id and sale_date = p_date) then
    raise exception 'مبيعات هذا التاريخ مُدخلة من قبل. استخدم طلب التعديل إذا كان المبلغ خاطئاً.';
  end if;

  insert into sales (branch_id, sale_date, amount, collected)
  values (b.id, p_date, round(p_amount, 2), round(v_col, 2));
  return json_build_object('ok', true);
exception when unique_violation then
  raise exception 'مبيعات هذا التاريخ مُدخلة من قبل. استخدم طلب التعديل إذا كان المبلغ خاطئاً.';
end $$;

create or replace function public.request_correction(p_token uuid, p_date date, p_new_amount numeric,
                                                     p_note text default null, p_new_collected numeric default null) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; s sales; v_col numeric;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط الفرع غير صحيح. اطلب الرابط من الإدارة.'; end if;
  if p_new_amount is null or p_new_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;

  select * into s from sales where branch_id = b.id and sale_date = p_date;
  if not found then raise exception 'لا توجد مبيعات مسجلة لهذا التاريخ'; end if;

  if b.credit then
    v_col := round(coalesce(p_new_collected, s.collected), 2);
    if v_col < 0 then raise exception 'أدخل مبلغ تحصيل صحيحاً'; end if;
    if round(p_new_amount, 2) = s.amount and v_col = s.collected then
      raise exception 'المبالغ الجديدة مطابقة للمبالغ المسجلة';
    end if;
  else
    v_col := null;
    if round(p_new_amount, 2) = s.amount then raise exception 'المبلغ الجديد مطابق للمبلغ المسجل'; end if;
  end if;

  if exists (select 1 from correction_requests where sale_id = s.id and status = 'pending') then
    raise exception 'يوجد طلب تعديل لهذا التاريخ بانتظار الإدارة';
  end if;

  insert into correction_requests (sale_id, branch_id, sale_date, old_amount, new_amount, old_collected, new_collected, note)
  values (s.id, b.id, p_date, s.amount, round(p_new_amount, 2),
          case when b.credit then s.collected end, v_col, nullif(trim(p_note), ''));
  return json_build_object('ok', true);
end $$;

-- ---------- 5) دوال الإدارة ----------
create or replace function public.approve_correction(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r correction_requests;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into r from correction_requests where id = p_id for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if r.status <> 'pending' then raise exception 'تمت معالجة هذا الطلب من قبل'; end if;

  update sales set amount = r.new_amount,
                   collected = coalesce(r.new_collected, collected),
                   updated_at = now()
  where id = r.sale_id;
  update correction_requests set status = 'approved', decided_at = now() where id = p_id;
end $$;

create or replace function public.admin_submit_sale(p_branch_id int, p_date date, p_amount numeric, p_collected numeric default 0) returns json
language plpgsql security definer set search_path = public as $$
declare b branches; v_col numeric;
begin
  if not is_admin() then raise exception 'غير مصرح'; end if;
  select * into b from branches where id = p_branch_id and active;
  if not found then raise exception 'اختر الفرع'; end if;
  if p_date is null then raise exception 'اختر التاريخ'; end if;
  if p_date > riyadh_today() then raise exception 'لا يمكن إدخال مبيعات لتاريخ لم يأتِ بعد'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'أدخل مبلغاً صحيحاً'; end if;
  v_col := case when b.credit then coalesce(p_collected, 0) else 0 end;
  if v_col < 0 then raise exception 'أدخل مبلغ تحصيل صحيحاً'; end if;
  if exists (select 1 from sales where branch_id = b.id and sale_date = p_date) then
    raise exception 'مبيعات هذا الفرع لهذا التاريخ مُدخلة من قبل';
  end if;

  insert into sales (branch_id, sale_date, amount, collected, entered_by)
  values (b.id, p_date, round(p_amount, 2), round(v_col, 2), 'admin');
  return json_build_object('ok', true);
exception when unique_violation then
  raise exception 'مبيعات هذا الفرع لهذا التاريخ مُدخلة من قبل';
end $$;

-- ---------- 6) صلاحيات تنفيذ الدوال الجديدة ----------
revoke execute on function public.submit_sale(uuid, date, numeric, numeric)                    from public, anon, authenticated;
revoke execute on function public.request_correction(uuid, date, numeric, text, numeric)       from public, anon, authenticated;
revoke execute on function public.admin_submit_sale(int, date, numeric, numeric)               from public, anon, authenticated;
revoke execute on function public.branch_info(uuid)                                            from public, anon, authenticated;
revoke execute on function public.approve_correction(bigint)                                   from public, anon, authenticated;

grant execute on function public.submit_sale(uuid, date, numeric, numeric)              to anon, authenticated;
grant execute on function public.request_correction(uuid, date, numeric, text, numeric) to anon, authenticated;
grant execute on function public.branch_info(uuid)                                      to anon, authenticated;
grant execute on function public.admin_submit_sale(int, date, numeric, numeric)         to authenticated;
grant execute on function public.approve_correction(bigint)                             to authenticated;

-- تحديث ذاكرة الواجهة البرمجية في Supabase فوراً
notify pgrst, 'reload schema';
