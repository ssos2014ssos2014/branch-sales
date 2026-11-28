-- =====================================================================
--  صافي النقد المسلم: روابط اطلاع فقط لموظف (index.html?cash=TOKEN)
--  صاحب الرابط يرى فقط: المبيعات النقدية والمصروفات النقدية وصافي النقد المسلم لكل فرع ويوم
--  لا يرى المبيعات البنكية ولا أي بيانات أخرى، ولا يستطيع التعديل
--  شغّل هذا الملف مرة واحدة — لا يحذف أي بيانات، ويمكن إعادة تشغيله بأمان
-- =====================================================================

create table if not exists public.cash_links (
  id serial primary key,
  token uuid not null unique default gen_random_uuid(),
  label text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.cash_links enable row level security;
drop policy if exists admin_all on public.cash_links;
create policy admin_all on public.cash_links for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.cash_data(p_token uuid, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
declare l cash_links; v_today date := (now() at time zone 'Asia/Riyadh')::date; v_from date; v_to date;
begin
  select * into l from cash_links where token = p_token and active;
  if not found then raise exception 'الرابط غير صحيح أو تم إيقافه'; end if;
  v_to := least(coalesce(p_to, v_today), v_today);
  v_from := greatest(coalesce(p_from, date_trunc('month', v_today)::date), v_to - 400);
  return json_build_object(
    'label', l.label, 'today', v_today, 'from', v_from, 'to', v_to,
    'branches', coalesce((select json_agg(json_build_object('id', b.id, 'name', b.name, 'logo', b.logo) order by b.sort_order, b.id)
       from branches b where b.active and b.sales_pay and not b.credit), '[]'::json),
    'rows', coalesce((select json_agg(json_build_object('d', s.sale_date, 'b', s.branch_id, 'cash', coalesce(s.amt_cash, 0), 'exp', coalesce(s.expenses, '[]'::jsonb)) order by s.sale_date, s.branch_id)
       from sales s join branches b on b.id = s.branch_id
       where b.active and b.sales_pay and not b.credit and s.sale_date between v_from and v_to and s.amt_cash is not null), '[]'::json));
end $$;

revoke execute on function public.cash_data(uuid, date, date) from public, anon, authenticated;
grant execute on function public.cash_data(uuid, date, date) to anon, authenticated;

notify pgrst, 'reload schema';
