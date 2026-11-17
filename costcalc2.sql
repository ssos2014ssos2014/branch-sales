-- =====================================================================
--  حاسبة تكلفة المنتج (تحديث): مكونات بالحبة + أكثر من سعر بيع للمنتج
--  شغّل هذا الملف مرة واحدة فقط (بعد costcalc.sql) — لا يحذف أي بيانات
-- =====================================================================

-- نوع المكون: weight = بالوزن (السعر لكل 1 كيلو)، piece = بالحبة (السعر لكل 1 حبة)
alter table public.cost_ingredients add column if not exists unit text not null default 'weight';
do $$ begin
  alter table public.cost_ingredients add constraint cost_ing_unit_chk check (unit in ('weight', 'piece'));
exception when duplicate_object then null; end $$;

-- أسعار البيع المقترحة للمنتج (أكثر من سعر). sell_price يبقى = السعر الأول
alter table public.cost_products add column if not exists sell_prices jsonb not null default '[]'::jsonb;
update public.cost_products set sell_prices = jsonb_build_array(sell_price)
where sell_price is not null and sell_prices = '[]'::jsonb;

notify pgrst, 'reload schema';
