-- =====================================================================
--  أقسام التوالف الجديدة + التصنيف التلقائي لأي صنف يُضاف
--  شغّل هذا الملف مرة واحدة فقط (بعد items.sql) — لا يحذف أي بيانات
-- =====================================================================

-- تحديد القسم من اسم الصنف (الترتيب مهم: "معمول تمر" بيتفور ومعمول، "تشيز كيك" كيك، "صينية تمر" تمور)
create or replace function public.guess_category(p_name text) returns text
language sql immutable set search_path = public as $$
  select case
    when p_name ~ '(بيتفور|بيتي فور|بتي فور|معمول|كعك|غريبة|بسكويت|بسكوت)' then 'البيتفور والمعمول'
    when p_name ~ 'بسبوس'                                                 then 'البسبوسة'
    when p_name ~ '(تشيز|كيك|تورت|جاتو)'                                  then 'الكيك والتشيز'
    when p_name ~ '(شوكولا|شوكلا|شكولا|شوكو)'                             then 'الشوكولاتة'
    when p_name ~ 'تمر'                                                   then 'التمور'
    when p_name ~ 'عنب'                                                   then 'ورق العنب'
    when p_name ~ '(خلية|كرواسون|كروسان|كرواسان)'                         then 'الخلايا والكرواسون'
    when p_name ~ '(معجنات|سمبوس|جبنية|فطائر|فطيرة|بيتزا|صفيح|مناقيش|فطاير)' then 'المعجنات'
    when p_name ~ '(بقلاوة|بقالوة|بلح الشام|كنافة|هريسة|قطايف|لقيمات|لقيمة)' then 'البقلاوة والحلويات الشرقية'
    when p_name ~ 'صينية'                                                 then 'الكيك والتشيز'
    else 'أخرى' end
$$;

-- إعادة تقسيم الأصناف (عدا أي قسم خاص كتبته الإدارة بنفسها)
update public.waste_items set category = guess_category(name)
where category in ('أخرى', 'المعجنات', 'الخلايا والكرواسون', 'ورق العنب', 'الحلويات الشرقية', 'التمور', 'الكيك والصواني',
                   'البسبوسة', 'الكيك والتشيز', 'الشوكولاتة', 'البيتفور والمعمول', 'البقلاوة والحلويات الشرقية')
   or category is null or btrim(category) = '';

-- أي صنف جديد بدون قسم (أو "أخرى") يدخل قسمه تلقائياً
create or replace function public.waste_items_auto_category() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(btrim(new.category), '') in ('', 'أخرى', 'تلقائي') then
    new.category := guess_category(new.name);
  end if;
  return new;
end $$;

drop trigger if exists waste_items_auto_category on public.waste_items;
create trigger waste_items_auto_category
  before insert or update of name, category on public.waste_items
  for each row execute function public.waste_items_auto_category();

notify pgrst, 'reload schema';
