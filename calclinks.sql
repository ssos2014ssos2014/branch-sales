-- =====================================================================
--  رابط مشاركة حاسبة تكلفة المنتج (للاستخدام فقط بدون أي صلاحية)
--  شغّل هذا الملف مرة واحدة فقط (بعد costcalc2.sql) — لا يحذف أي بيانات
--  صاحب الرابط يرى الحاسبة فقط: يقرأ أسماء المكونات وأسعارها، ولا يحفظ ولا يعدّل أي شيء
-- =====================================================================

create table if not exists public.calc_links (
  id serial primary key,
  token uuid not null unique default gen_random_uuid(),
  label text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.calc_links enable row level security;
drop policy if exists admin_all on public.calc_links;
create policy admin_all on public.calc_links for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- بيانات الحاسبة لصاحب الرابط: المكونات المفعّلة فقط (قراءة فقط)
create or replace function public.calc_data(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare l calc_links;
begin
  select * into l from calc_links where token = p_token and active;
  if not found then raise exception 'رابط الحاسبة غير صحيح أو تم إيقافه'; end if;
  return json_build_object(
    'label', l.label,
    'ings', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'price_per_kg', i.price_per_kg, 'unit', i.unit, 'active', true) order by i.name)
                      from cost_ingredients i where i.active), '[]'::json));
end $$;

revoke execute on function public.calc_data(uuid) from public, anon, authenticated;
grant execute on function public.calc_data(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
