# نظام مبيعات الفروع
الملفات: schema.sql (قاعدة البيانات) - index.html (لوحة الإدارة) - branch.html (صفحة إدخال الفرع) - common.js - style.css - config.js

1. Supabase: SQL Editor > شغّل schema.sql (بعد تغيير admin@example.com لبريدك). إذا كنت شغّلته سابقاً فشغّل update-01-admin-entry.sql فقط.
2. Authentication > Users > Add user بنفس البريد وكلمة مرور. ثم Authentication > Sign In / Providers: أوقف Allow new users to sign up.
3. Project Settings > API: انسخ Project URL و anon key إلى config.js.
4. ارفع المجلد على GitHub واربطه بـ Vercel (بدون إعدادات بناء).
5. افتح الموقع وسجّل الدخول، ومن "روابط إدخال المبيعات للفروع" انسخ رابط كل فرع وأرسله للموظف.
