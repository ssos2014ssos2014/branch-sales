-- =====================================================================
--  إعادة تنظيم: مصنع أفق النكهات فرع مستقل + المندوب فرع مستقل
--  شغّل هذا الملف مرة واحدة فقط — لا يحذف أي بيانات، والروابط والمبيعات السابقة تبقى كما هي
-- =====================================================================

-- 1) المصنع: فرع مستقل باسم "مصنع أفق النكهات" (آجل + تحصيل مثل البازل الذهبي)
update public.branches
set name = 'مصنع أفق النكهات', credit = true, is_rep = false
where group_name = 'مصنع أفق النكهات' and name = 'المصنع';

-- 2) المندوب الحالي: فرع مستقل باسم "فرع التوزيع رقم 1 (المندوب صادق النهاري)"
--    (نفس الرابط ونفس المبيعات السابقة، وآجل + تحصيل)
update public.branches
set name = 'فرع التوزيع رقم 1 (المندوب صادق النهاري)',
    group_name = 'فرع التوزيع رقم 1 (المندوب صادق النهاري)',
    credit = true, is_rep = false
where id = (
  select id from public.branches
  where group_name = 'مصنع أفق النكهات' and (is_rep or name like 'مندوب%')
  order by id limit 1
);

-- 3) أي مندوب آخر أُضيف سابقاً: يصبح فرعاً مستقلاً باسمه
update public.branches
set group_name = name, is_rep = false
where is_rep or (group_name = 'مصنع أفق النكهات' and name <> 'مصنع أفق النكهات');

-- للتأكد: الفروع بعد التعديل
select id, name as "الفرع", case when credit then 'آجل + تحصيل' else 'نقدي' end as "النوع", active as "مفعّل"
from public.branches order by sort_order, id;
