-- =====================================================================
--  صور أصناف الفواتير (أفق النكهات) — شغّله مرة واحدة بعد invoices.sql
-- =====================================================================
alter table public.inv_items add column if not exists image text;   -- صورة مصغرة (JPEG مضغوطة)

create or replace function public.inv_data(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare b branches; v_today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  select * into b from branches where token = p_token and active;
  if not found then raise exception 'رابط غير صالح'; end if;
  if not b.invoice_mode then raise exception 'نقطة الفواتير غير مفعلة لهذا الفرع'; end if;
  return json_build_object(
    'branch', json_build_object('id', b.id, 'name', b.name, 'logo', b.logo, 'choc_price', b.choc_price),
    'today', v_today,
    'customers', coalesce((select json_agg(json_build_object('id', a.id, 'name', a.name,
        'items', coalesce((select json_agg(ci.item_id) from inv_customer_items ci join inv_items it on it.id = ci.item_id and it.active where ci.account_id = a.id), '[]'::json),
        'balance', coalesce((select round(x.invoiced - x.paid, 2) from inv_balances(b.id) x where x.account_id = a.id), 0))
      order by a.sort_order, a.id) from branch_accounts a where a.branch_id = b.id and a.active), '[]'::json),
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'price', i.price,
        'weighted', i.weighted, 'weight_g', i.weight_g, 'image', i.image) order by i.sort_order, i.id) from inv_items i where i.branch_id = b.id and i.active), '[]'::json),
    'invoices', coalesce((select json_agg(json_build_object('id', v.id, 'no', v.inv_no, 'date', v.inv_date, 'account_id', v.account_id,
        'total', v.total, 'note', v.note, 'by', v.entered_by, 'at', v.created_at, 'choc_price', v.choc_price,
        'lines', (select json_agg(json_build_object('name', l.name, 'unit', l.unit, 'qty', l.qty, 'weight_g', l.weight_g, 'unit_price', l.unit_price, 'total', l.total) order by l.id) from invoice_lines l where l.invoice_id = v.id))
      order by v.inv_no desc) from invoices v where v.branch_id = b.id and v.inv_date >= v_today - 45), '[]'::json),
    'collections', coalesce((select json_agg(json_build_object('id', m.id, 'date', m.move_date, 'amount', m.amount, 'split', m.split, 'note', m.note, 'by', m.entered_by,
        'cash', m.col_cash, 'bank', m.col_bank, 'card', m.col_card) order by m.move_date desc, m.id desc)
      from credit_moves m where m.branch_id = b.id and m.kind = 'collect' and m.move_date >= v_today - 45), '[]'::json)
  );
end $$;

revoke execute on function public.inv_data(uuid) from public;
grant execute on function public.inv_data(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
