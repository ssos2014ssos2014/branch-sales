-- خلفيات مصمم الصور المعتمدة (شغّله مرة واحدة، ويمكن إعادة تشغيله بأمان)
create table if not exists public.studio_bgs (
  id bigserial primary key,
  name text not null default 'خلفية',
  image text not null,            -- الصورة (JPEG مضغوطة حتى 2400px)
  thumb text,                     -- صورة مصغرة للقائمة
  floor real not null default 0.75,   -- مستوى وقوف المنتجات (نسبة من ارتفاع الصورة)
  cx real not null default 0.5,       -- مكان المنتجات أفقياً
  scale real not null default 1,      -- حجم المنتجات
  blur real not null default 0,       -- تمويه الخلفية
  reflect boolean not null default false,
  light smallint not null default 0,  -- 0 تلقائي، 1 يمين، -1 يسار
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.studio_bgs enable row level security;
drop policy if exists studio_bgs_admin on public.studio_bgs;
create policy studio_bgs_admin on public.studio_bgs for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.studio_bgs to authenticated;
grant usage, select on sequence public.studio_bgs_id_seq to authenticated;
notify pgrst, 'reload schema';
