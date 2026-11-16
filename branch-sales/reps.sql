-- =====================================================================
--  إضافة: مناديب التوزيع (مصنع أفق النكهات)
--  شغّل هذا الملف مرة واحدة فقط من: SQL Editor > New query > Run
-- =====================================================================

-- علامة المندوب
alter table public.branches add column if not exists is_rep boolean not null default false;

update public.branches set is_rep = true
where group_name = 'مصنع أفق النكهات' and name = 'مندوب التوزيع';

-- الإدارة تضيف مناديب جدد
drop policy if exists admin_insert_branches on public.branches;
create policy admin_insert_branches on public.branches
  for insert to authenticated with check (public.is_admin());

notify pgrst, 'reload schema';
