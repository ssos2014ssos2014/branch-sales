-- =====================================================================
--  إضافة: السداد الجزئي لأقساط الفروع والتمويلات
--  شغّل هذا الملف مرة واحدة فقط (بعد fin.sql) — لا يحذف أي بيانات
-- =====================================================================
-- due_amount = المبلغ المستحق وقت أول سداد | amount = ما تم سداده حتى الآن
-- إذا كان amount أقل من due_amount فهو سداد جزئي، وإذا تساويا فهو "تم السداد"
alter table public.fund_payments add column if not exists due_amount numeric(14,2);
alter table public.loan_payments add column if not exists due_amount numeric(14,2);

-- السدادات القديمة كانت كاملة
update public.fund_payments set due_amount = amount where due_amount is null;
update public.loan_payments set due_amount = amount where due_amount is null;

notify pgrst, 'reload schema';
