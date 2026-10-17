-- Demo-only seed data. DO NOT use this password or these users outside a local sandbox.
-- Shared demo password for all accounts: LocalDemo!2026
-- Password hashes are bcrypt via pgcrypto; the application must use bcrypt-compatible verification.

BEGIN;

INSERT INTO public.roles (code, name_ar) VALUES
  ('student', 'طالب'),
  ('academic_supervisor', 'مشرف أكاديمي'),
  ('company_representative', 'مسؤول جهة التدريب'),
  ('college_admin', 'مسؤول التدريب في الكلية'),
  ('system_admin', 'المسؤول الأعلى')
ON CONFLICT (code) DO UPDATE SET name_ar = EXCLUDED.name_ar;

INSERT INTO public.colleges (id, name_ar, status, timezone) VALUES
  ('10000000-0000-0000-0000-000000000001', 'كلية النخبة التجريبية', 'active', 'Asia/Riyadh'),
  ('10000000-0000-0000-0000-000000000002', 'كلية الأفق التجريبية', 'active', 'Asia/Dubai')
ON CONFLICT (id) DO UPDATE SET
  name_ar = EXCLUDED.name_ar,
  status = EXCLUDED.status,
  timezone = EXCLUDED.timezone,
  updated_at = now();

INSERT INTO public.specialties (id, college_id, name_ar, code, is_active) VALUES
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'نظم المعلومات', 'IS', true),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'علوم الحاسب', 'CS', true)
ON CONFLICT (id) DO UPDATE SET
  college_id = EXCLUDED.college_id,
  name_ar = EXCLUDED.name_ar,
  code = EXCLUDED.code,
  is_active = EXCLUDED.is_active,
  updated_at = now();

-- Sample requirements are placeholders solely to make local screens testable.
INSERT INTO public.specialty_training_requirements
  (id, college_id, specialty_id, minimum_total_minutes, training_duration_days, daily_work_limit_minutes)
VALUES
  ('21000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 24000, 60, 480),
  ('21000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002',
   '20000000-0000-0000-0000-000000000002', 24000, 60, 480)
ON CONFLICT (id) DO UPDATE SET
  minimum_total_minutes = EXCLUDED.minimum_total_minutes,
  training_duration_days = EXCLUDED.training_duration_days,
  daily_work_limit_minutes = EXCLUDED.daily_work_limit_minutes,
  updated_at = now();

-- The global system administrator is not assigned to a college.
INSERT INTO public.users
  (id, college_id, email, password_hash, email_verified_at, account_status, first_name, last_name,
   student_number, company_name, specialty_id)
VALUES
  ('30000000-0000-0000-0000-000000000001', NULL, 'admin@example.test',
   crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active', 'مدير', 'النظام', NULL, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email, password_hash = EXCLUDED.password_hash, email_verified_at = EXCLUDED.email_verified_at,
  account_status = EXCLUDED.account_status, first_name = EXCLUDED.first_name, last_name = EXCLUDED.last_name,
  updated_at = now();

-- One college administrator per college; both are activated by the seeded system administrator.
INSERT INTO public.users
  (id, college_id, email, password_hash, email_verified_at, account_status, first_name, last_name,
   student_number, company_name, specialty_id, activation_approved_by, activation_approved_at)
VALUES
  ('30000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001',
   'college1.admin@example.test', crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active',
   'مسؤول', 'الكلية الأولى', NULL, NULL, NULL, '30000000-0000-0000-0000-000000000001', now()),
  ('30000000-0000-0000-0000-000000000024', '10000000-0000-0000-0000-000000000002',
   'college2.admin@example.test', crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active',
   'مسؤول', 'الكلية الثانية', NULL, NULL, NULL, '30000000-0000-0000-0000-000000000001', now())
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email, password_hash = EXCLUDED.password_hash, email_verified_at = EXCLUDED.email_verified_at,
  account_status = EXCLUDED.account_status, first_name = EXCLUDED.first_name, last_name = EXCLUDED.last_name,
  activation_approved_by = EXCLUDED.activation_approved_by, activation_approved_at = EXCLUDED.activation_approved_at,
  updated_at = now();

-- College 1: student, academic supervisor, and company representative.
INSERT INTO public.users
  (id, college_id, email, password_hash, email_verified_at, account_status, first_name, last_name,
   student_number, company_name, specialty_id, activation_approved_by, activation_approved_at)
VALUES
  ('30000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001',
   'student1@example.test', crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active',
   'طالب', 'تجريبي أول', 'DEMO-001', NULL, '20000000-0000-0000-0000-000000000001',
   '30000000-0000-0000-0000-000000000014', now()),
  ('30000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001',
   'supervisor1@example.test', crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active',
   'مشرف', 'أكاديمي أول', NULL, NULL, NULL, '30000000-0000-0000-0000-000000000014', now()),
  ('30000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001',
   'company1@example.test', crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active',
   'مسؤول', 'شركة أول', NULL, 'شركة تدريب تجريبية أولى', NULL,
   '30000000-0000-0000-0000-000000000014', now()),
-- College 2: student, academic supervisor, and company representative.
  ('30000000-0000-0000-0000-000000000021', '10000000-0000-0000-0000-000000000002',
   'student2@example.test', crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active',
   'طالب', 'تجريبي ثانٍ', 'DEMO-002', NULL, '20000000-0000-0000-0000-000000000002',
   '30000000-0000-0000-0000-000000000024', now()),
  ('30000000-0000-0000-0000-000000000022', '10000000-0000-0000-0000-000000000002',
   'supervisor2@example.test', crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active',
   'مشرف', 'أكاديمي ثانٍ', NULL, NULL, NULL, '30000000-0000-0000-0000-000000000024', now()),
  ('30000000-0000-0000-0000-000000000023', '10000000-0000-0000-0000-000000000002',
   'company2@example.test', crypt('LocalDemo!2026', gen_salt('bf', 12)), now(), 'active',
   'مسؤول', 'شركة ثانٍ', NULL, 'شركة تدريب تجريبية ثانية', NULL,
   '30000000-0000-0000-0000-000000000024', now())
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email, password_hash = EXCLUDED.password_hash, email_verified_at = EXCLUDED.email_verified_at,
  account_status = EXCLUDED.account_status, first_name = EXCLUDED.first_name, last_name = EXCLUDED.last_name,
  student_number = EXCLUDED.student_number, company_name = EXCLUDED.company_name,
  specialty_id = EXCLUDED.specialty_id, activation_approved_by = EXCLUDED.activation_approved_by,
  activation_approved_at = EXCLUDED.activation_approved_at, updated_at = now();

INSERT INTO public.user_roles (id, user_id, role_id, college_id, granted_by, status)
SELECT v.id, v.user_id, r.id, v.college_id, v.granted_by, 'active'::assignment_status
FROM (VALUES
  ('31000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000001'::uuid, 'system_admin', NULL::uuid, NULL::uuid),
  ('31000000-0000-0000-0000-000000000014'::uuid, '30000000-0000-0000-0000-000000000014'::uuid, 'college_admin', '10000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000001'::uuid),
  ('31000000-0000-0000-0000-000000000011'::uuid, '30000000-0000-0000-0000-000000000011'::uuid, 'student', '10000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000014'::uuid),
  ('31000000-0000-0000-0000-000000000012'::uuid, '30000000-0000-0000-0000-000000000012'::uuid, 'academic_supervisor', '10000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000014'::uuid),
  ('31000000-0000-0000-0000-000000000013'::uuid, '30000000-0000-0000-0000-000000000013'::uuid, 'company_representative', '10000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000014'::uuid),
  ('31000000-0000-0000-0000-000000000024'::uuid, '30000000-0000-0000-0000-000000000024'::uuid, 'college_admin', '10000000-0000-0000-0000-000000000002'::uuid, '30000000-0000-0000-0000-000000000001'::uuid),
  ('31000000-0000-0000-0000-000000000021'::uuid, '30000000-0000-0000-0000-000000000021'::uuid, 'student', '10000000-0000-0000-0000-000000000002'::uuid, '30000000-0000-0000-0000-000000000024'::uuid),
  ('31000000-0000-0000-0000-000000000022'::uuid, '30000000-0000-0000-0000-000000000022'::uuid, 'academic_supervisor', '10000000-0000-0000-0000-000000000002'::uuid, '30000000-0000-0000-0000-000000000024'::uuid),
  ('31000000-0000-0000-0000-000000000023'::uuid, '30000000-0000-0000-0000-000000000023'::uuid, 'company_representative', '10000000-0000-0000-0000-000000000002'::uuid, '30000000-0000-0000-0000-000000000024'::uuid)
) AS v(id, user_id, role_code, college_id, granted_by)
JOIN public.roles r ON r.code = v.role_code
ON CONFLICT (id) DO UPDATE SET
  user_id = EXCLUDED.user_id, role_id = EXCLUDED.role_id, college_id = EXCLUDED.college_id,
  granted_by = EXCLUDED.granted_by, status = EXCLUDED.status;

INSERT INTO public.evaluation_criteria (code, name_ar, display_order, is_active) VALUES
  ('discipline', 'الالتزام والانضباط', 1, true),
  ('work_quality', 'جودة العمل', 2, true),
  ('professional_skills', 'المهارات المهنية', 3, true),
  ('teamwork', 'العمل الجماعي', 4, true),
  ('training_objectives', 'تحقيق أهداف التدريب', 5, true),
  ('initiative_innovation', 'المبادرة والابتكار', 6, true)
ON CONFLICT (code) DO UPDATE SET
  name_ar = EXCLUDED.name_ar, display_order = EXCLUDED.display_order, is_active = EXCLUDED.is_active;

COMMIT;
