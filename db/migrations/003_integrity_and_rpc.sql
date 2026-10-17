-- Migration 003: narrow RPCs and integrity guards for role transitions and tenant-sensitive records.
BEGIN;

GRANT INSERT ON public.users, public.user_roles TO app_policy_owner;
GRANT UPDATE ON public.users TO app_policy_owner;
GRANT INSERT ON public.application_status_history TO app_policy_owner;
GRANT UPDATE (academic_supervisor_user_id, updated_at) ON public.trainings TO app_policy_owner;

-- Every usable role must belong to an active, email-verified account.
CREATE OR REPLACE FUNCTION app_private.has_role(p_code text, p_college_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    JOIN public.roles r ON r.id = ur.role_id
    JOIN public.users u ON u.id = ur.user_id
    WHERE ur.user_id = app_private.current_user_id()
      AND ur.status = 'active'
      AND u.account_status = 'active'
      AND u.email_verified_at IS NOT NULL
      AND r.code = p_code
      AND ur.college_id IS NOT DISTINCT FROM p_college_id
  )
$$;
ALTER FUNCTION app_private.has_role(text, uuid) OWNER TO app_policy_owner;

-- Self-registration is deliberately limited to non-privileged, pending role assignments.
CREATE OR REPLACE FUNCTION app_private.register_user(
  p_college_id uuid,
  p_email text,
  p_password_hash text,
  p_first_name text,
  p_last_name text,
  p_role_code text,
  p_student_number text DEFAULT NULL,
  p_company_name text DEFAULT NULL,
  p_specialty_id uuid DEFAULT NULL,
  p_phone text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE
  v_user_id uuid := gen_random_uuid();
  v_role_id integer;
BEGIN
  IF p_role_code NOT IN ('student', 'academic_supervisor', 'company_representative') THEN
    RAISE EXCEPTION 'This role cannot be self-registered' USING ERRCODE = '42501';
  END IF;
  IF p_email IS NULL OR length(btrim(p_email)) = 0 OR p_password_hash IS NULL OR length(p_password_hash) < 20 THEN
    RAISE EXCEPTION 'A valid email and server-generated password hash are required' USING ERRCODE = '23514';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.colleges WHERE id = p_college_id AND status = 'active') THEN
    RAISE EXCEPTION 'Selected college is unavailable' USING ERRCODE = '23514';
  END IF;
  SELECT id INTO v_role_id FROM public.roles WHERE code = p_role_code;
  IF v_role_id IS NULL THEN RAISE EXCEPTION 'Configured role not found'; END IF;
  IF p_role_code = 'student' THEN
    IF p_student_number IS NULL OR length(btrim(p_student_number)) = 0 OR p_specialty_id IS NULL THEN
      RAISE EXCEPTION 'Student number and specialty are required' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.specialties WHERE id = p_specialty_id
      AND college_id = p_college_id AND is_active) THEN
      RAISE EXCEPTION 'Selected specialty is not active in this college' USING ERRCODE = '23514';
    END IF;
  ELSIF p_role_code = 'company_representative' THEN
    IF p_company_name IS NULL OR length(btrim(p_company_name)) = 0 THEN
      RAISE EXCEPTION 'Company name is required' USING ERRCODE = '23514';
    END IF;
  END IF;

  INSERT INTO public.users
    (id, college_id, email, password_hash, account_status, first_name, last_name, phone,
     student_number, company_name, specialty_id)
  VALUES
    (v_user_id, p_college_id, lower(btrim(p_email)), p_password_hash, 'pending_activation',
     btrim(p_first_name), btrim(p_last_name), nullif(btrim(p_phone), ''),
     nullif(btrim(p_student_number), ''), nullif(btrim(p_company_name), ''), p_specialty_id);

  INSERT INTO public.user_roles (user_id, role_id, college_id, status)
  VALUES (v_user_id, v_role_id, p_college_id, 'pending');
  RETURN v_user_id;
END;
$$;
ALTER FUNCTION app_private.register_user(uuid,text,text,text,text,text,text,text,uuid,text) OWNER TO app_policy_owner;

-- The application verifies its one-time email token, then signs this proof server-side.
CREATE OR REPLACE FUNCTION app_private.complete_email_verification(p_user_id uuid, p_proof text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE
  v_email text;
  v_verified_at timestamptz;
  v_key bytea;
  v_expected text;
BEGIN
  SELECT email, email_verified_at INTO v_email, v_verified_at FROM public.users WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0002'; END IF;
  SELECT signing_key INTO v_key FROM app_private.context_signing_keys WHERE singleton = true;
  v_expected := encode(public.hmac(
    convert_to('email-verified:' || p_user_id::text || ':' || lower(v_email), 'UTF8'), v_key, 'sha256'
  ), 'hex');
  IF p_proof IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Invalid email verification proof' USING ERRCODE = '42501';
  END IF;
  IF v_verified_at IS NULL THEN
    UPDATE public.users SET email_verified_at = now(), updated_at = now() WHERE id = p_user_id;
  END IF;
END;
$$;
ALTER FUNCTION app_private.complete_email_verification(uuid,text) OWNER TO app_policy_owner;
REVOKE ALL ON FUNCTION app_private.register_user(uuid,text,text,text,text,text,text,text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app_private.complete_email_verification(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_private.register_user(uuid,text,text,text,text,text,text,text,uuid,text) TO app_runtime;
GRANT EXECUTE ON FUNCTION app_private.complete_email_verification(uuid,text) TO app_runtime;

-- Restrict direct profile writes: self-service profile fields only; administrators may approve activation only.
CREATE OR REPLACE FUNCTION app_private.guard_user_profile_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE v_superuser boolean := false;
BEGIN
  SELECT coalesce(rolsuper, false) INTO v_superuser FROM pg_roles WHERE rolname = current_user;
  IF current_user = 'app_policy_owner' OR v_superuser THEN RETURN NEW; END IF;

  IF OLD.id = app_private.current_user_id() THEN
    IF (to_jsonb(NEW) - ARRAY['first_name','last_name','phone','updated_at'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['first_name','last_name','phone','updated_at']) THEN
      RAISE EXCEPTION 'Self-service may update profile name and phone only' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF app_private.is_college_admin(OLD.college_id) AND OLD.college_id = app_private.current_college_id() THEN
    IF (to_jsonb(NEW) - ARRAY['account_status','activation_approved_by','activation_approved_at','updated_at'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['account_status','activation_approved_by','activation_approved_at','updated_at']) THEN
      RAISE EXCEPTION 'College administrators may update activation fields only' USING ERRCODE = '42501';
    END IF;
    IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
      IF OLD.account_status <> 'pending_activation' OR NEW.account_status NOT IN ('active','rejected')
         OR NEW.activation_approved_by IS DISTINCT FROM app_private.current_user_id()
         OR NEW.activation_approved_at IS NULL THEN
        RAISE EXCEPTION 'Invalid account activation decision' USING ERRCODE = '42501';
      END IF;
      IF NEW.account_status = 'active' AND NEW.email_verified_at IS NULL THEN
        RAISE EXCEPTION 'Email must be verified before activation' USING ERRCODE = '23514';
      END IF;
    ELSIF NEW.activation_approved_by IS DISTINCT FROM OLD.activation_approved_by
       OR NEW.activation_approved_at IS DISTINCT FROM OLD.activation_approved_at THEN
      RAISE EXCEPTION 'Activation audit fields may change only with the initial decision' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'User profile update is not authorized' USING ERRCODE = '42501';
END;
$$;
CREATE TRIGGER users_profile_update_guard_trg
  BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION app_private.guard_user_profile_update();

-- A college administrator can activate a role only after the account itself is verified and active.
DROP POLICY user_roles_insert_self_or_admin ON public.user_roles;
CREATE POLICY user_roles_insert_self_or_admin ON public.user_roles FOR INSERT TO app_runtime
  WITH CHECK (
    (user_id = app_private.current_user_id() AND status = 'pending')
    OR (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id)
      AND (status <> 'active' OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = user_roles.user_id
        AND u.college_id = user_roles.college_id AND u.account_status = 'active' AND u.email_verified_at IS NOT NULL)))
    OR (college_id IS NULL AND app_private.is_system_admin()
      AND EXISTS (SELECT 1 FROM public.roles r WHERE r.id = role_id AND r.code = 'system_admin'))
  );
DROP POLICY user_roles_update_college_admin ON public.user_roles;
CREATE POLICY user_roles_update_college_admin ON public.user_roles FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id)
    AND (status <> 'active' OR EXISTS (SELECT 1 FROM public.users u WHERE u.id = user_roles.user_id
      AND u.college_id = user_roles.college_id AND u.account_status = 'active' AND u.email_verified_at IS NOT NULL)));

-- Application updates may change only the fields belonging to the actor's decision stage.
CREATE OR REPLACE FUNCTION app_private.guard_application_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE v_superuser boolean := false;
BEGIN
  SELECT coalesce(rolsuper, false) INTO v_superuser FROM pg_roles WHERE rolname = current_user;
  IF current_user = 'app_policy_owner' OR v_superuser THEN RETURN NEW; END IF;
  IF OLD.id IS DISTINCT FROM NEW.id OR OLD.college_id IS DISTINCT FROM NEW.college_id
     OR OLD.opportunity_id IS DISTINCT FROM NEW.opportunity_id
     OR OLD.student_user_id IS DISTINCT FROM NEW.student_user_id THEN
    RAISE EXCEPTION 'Application identity and relationships are immutable' USING ERRCODE = '42501';
  END IF;

  IF OLD.student_user_id = app_private.current_user_id()
     AND app_private.has_role('student', OLD.college_id) THEN
    IF (to_jsonb(NEW) - ARRAY['student_message','resume_file_id','status','submitted_at','updated_at'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['student_message','resume_file_id','status','submitted_at','updated_at'])
       OR (OLD.status <> 'draft' AND (NEW.student_message IS DISTINCT FROM OLD.student_message
         OR NEW.resume_file_id IS DISTINCT FROM OLD.resume_file_id))
       OR (NEW.resume_file_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.file_assets f
         WHERE f.id=NEW.resume_file_id AND f.college_id=OLD.college_id
           AND f.uploaded_by_user_id=OLD.student_user_id))
       OR (OLD.status='draft' AND NEW.status NOT IN ('draft','submitted_company_review','cancelled_by_student'))
       OR (OLD.status<>'draft' AND NEW.status<>'cancelled_by_student')
       OR (NEW.status='submitted_company_review' AND NOT app_private.can_read_opportunity(OLD.opportunity_id)) THEN
      RAISE EXCEPTION 'Student may edit only a draft or cancel an active application' USING ERRCODE = '42501';
    END IF;
    IF OLD.status='draft' AND NEW.status='submitted_company_review' THEN
      NEW.submitted_at := coalesce(NEW.submitted_at,now());
    ELSE
      NEW.submitted_at := OLD.submitted_at;
    END IF;
    RETURN NEW;
  END IF;

  IF app_private.is_company_for_opportunity(OLD.opportunity_id) THEN
    IF OLD.status <> 'submitted_company_review'
       OR (to_jsonb(NEW) - ARRAY['status','company_decided_by','company_decided_at','company_rejection_reason','updated_at'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','company_decided_by','company_decided_at','company_rejection_reason','updated_at'])
       OR NEW.status NOT IN ('college_review','company_rejected')
       OR NEW.company_decided_by IS DISTINCT FROM app_private.current_user_id()
       OR NEW.company_decided_at IS NULL
       OR (NEW.status = 'company_rejected' AND coalesce(length(btrim(NEW.company_rejection_reason)),0)=0) THEN
      RAISE EXCEPTION 'Invalid company decision update' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF app_private.is_college_admin(OLD.college_id) THEN
    IF OLD.status <> 'college_review'
       OR (to_jsonb(NEW) - ARRAY['status','college_decided_by','college_decided_at','college_rejection_reason','updated_at'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','college_decided_by','college_decided_at','college_rejection_reason','updated_at'])
       OR NEW.status NOT IN ('approved','college_rejected')
       OR NEW.college_decided_by IS DISTINCT FROM app_private.current_user_id()
       OR NEW.college_decided_at IS NULL
       OR (NEW.status = 'college_rejected' AND coalesce(length(btrim(NEW.college_rejection_reason)),0)=0) THEN
      RAISE EXCEPTION 'Invalid college decision update' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Application update is not authorized' USING ERRCODE = '42501';
END;
$$;
CREATE TRIGGER applications_update_guard_trg
  BEFORE UPDATE ON public.training_applications FOR EACH ROW EXECUTE FUNCTION app_private.guard_application_update();

DROP POLICY applications_update_student ON public.training_applications;
CREATE POLICY applications_update_student ON public.training_applications FOR UPDATE TO app_runtime
  USING (student_user_id=app_private.current_user_id() AND college_id=app_private.current_college_id()
    AND status IN ('draft','submitted_company_review','college_review'))
  WITH CHECK (student_user_id=app_private.current_user_id() AND college_id=app_private.current_college_id()
    AND status IN ('draft','submitted_company_review','cancelled_by_student'));
DROP POLICY applications_insert_student ON public.training_applications;
CREATE POLICY applications_insert_student ON public.training_applications FOR INSERT TO app_runtime
  WITH CHECK (student_user_id=app_private.current_user_id() AND college_id=app_private.current_college_id()
    AND app_private.has_role('student',college_id) AND status='draft'
    AND app_private.can_read_opportunity(opportunity_id)
    AND (resume_file_id IS NULL OR EXISTS (SELECT 1 FROM public.file_assets f
      WHERE f.id=resume_file_id AND f.college_id=college_id AND f.uploaded_by_user_id=student_user_id)));

CREATE OR REPLACE FUNCTION app_private.record_application_status_history() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.application_status_history
      (college_id, application_id, from_status, to_status, changed_by_user_id, reason)
    VALUES (NEW.college_id, NEW.id, NULL, NEW.status, app_private.current_user_id(), 'created');
  ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.application_status_history
      (college_id, application_id, from_status, to_status, changed_by_user_id, reason)
    VALUES (NEW.college_id, NEW.id, OLD.status, NEW.status, app_private.current_user_id(), NULL);
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.record_application_status_history() OWNER TO app_policy_owner;
CREATE TRIGGER application_status_history_trg
  AFTER INSERT OR UPDATE OF status ON public.training_applications
  FOR EACH ROW EXECUTE FUNCTION app_private.record_application_status_history();
REVOKE INSERT ON public.application_status_history FROM app_runtime;

-- Keep training parties, application identity, and supervisor assignment consistent.
CREATE OR REPLACE FUNCTION app_private.guard_training_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE
  v_app public.training_applications%ROWTYPE;
  v_student_specialty uuid;
BEGIN
  SELECT * INTO v_app FROM public.training_applications WHERE id = NEW.application_id
    AND college_id = NEW.college_id AND status = 'approved';
  IF NOT FOUND OR v_app.student_user_id IS DISTINCT FROM NEW.student_user_id
     OR v_app.opportunity_id IS DISTINCT FROM NEW.opportunity_id THEN
    RAISE EXCEPTION 'Training must match a college-approved application' USING ERRCODE = '23514';
  END IF;
  SELECT specialty_id INTO v_student_specialty FROM public.users
    WHERE id = NEW.student_user_id AND college_id = NEW.college_id AND account_status = 'active';
  IF v_student_specialty IS NULL OR NEW.specialty_id IS DISTINCT FROM v_student_specialty THEN
    RAISE EXCEPTION 'Training specialty must match the approved student specialty' USING ERRCODE = '23514';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.users u JOIN public.user_roles ur ON ur.user_id = u.id AND ur.college_id = u.college_id
    JOIN public.roles r ON r.id = ur.role_id
    WHERE u.id = NEW.academic_supervisor_user_id AND u.college_id = NEW.college_id
      AND u.account_status = 'active' AND u.email_verified_at IS NOT NULL
      AND ur.status = 'active' AND r.code = 'academic_supervisor'
  ) THEN
    RAISE EXCEPTION 'Assigned academic supervisor must have an active supervisor role' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.guard_training_insert() OWNER TO app_policy_owner;
CREATE TRIGGER trainings_insert_integrity_trg
  BEFORE INSERT ON public.trainings FOR EACH ROW EXECUTE FUNCTION app_private.guard_training_insert();

CREATE OR REPLACE FUNCTION app_private.guard_training_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE v_superuser boolean := false;
BEGIN
  SELECT coalesce(rolsuper, false) INTO v_superuser FROM pg_roles WHERE rolname = current_user;
  IF current_user = 'app_policy_owner' OR v_superuser THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - ARRAY['status','ended_at','ended_by_user_id','end_request_id','updated_at'])
     IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','ended_at','ended_by_user_id','end_request_id','updated_at']) THEN
    RAISE EXCEPTION 'Training identity and requirements are immutable after creation' USING ERRCODE = '42501';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status <> 'ended_early' THEN
    RAISE EXCEPTION 'College administrator may only end training early through a formal request' USING ERRCODE = '42501';
  END IF;
  IF NEW.status = 'ended_early' AND OLD.status <> 'ended_early' THEN
    IF NOT app_private.is_college_admin(OLD.college_id)
       OR NEW.ended_by_user_id IS DISTINCT FROM app_private.current_user_id()
       OR NEW.ended_at IS NULL OR NEW.end_request_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.official_requests r WHERE r.id = NEW.end_request_id
          AND r.training_id = NEW.id AND r.college_id = NEW.college_id AND r.status = 'approved') THEN
      RAISE EXCEPTION 'Early termination requires an approved formal request' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.guard_training_update() OWNER TO app_policy_owner;
CREATE TRIGGER trainings_update_integrity_trg
  BEFORE UPDATE ON public.trainings FOR EACH ROW EXECUTE FUNCTION app_private.guard_training_update();

CREATE OR REPLACE FUNCTION app_private.guard_supervisor_assignment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.assigned_by_user_id IS DISTINCT FROM app_private.current_user_id()
       OR NOT app_private.is_college_admin(NEW.college_id)
       OR NOT EXISTS (
         SELECT 1 FROM public.users u JOIN public.user_roles ur ON ur.user_id=u.id AND ur.college_id=u.college_id
         JOIN public.roles r ON r.id=ur.role_id
         WHERE u.id=NEW.supervisor_user_id AND u.college_id=NEW.college_id AND u.account_status='active'
           AND u.email_verified_at IS NOT NULL AND ur.status='active' AND r.code='academic_supervisor'
       )
       OR (NEW.change_request_id IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.official_requests q WHERE q.id=NEW.change_request_id
           AND q.training_id=NEW.training_id AND q.college_id=NEW.college_id AND q.status='approved'
       )) THEN
      RAISE EXCEPTION 'Invalid supervisor assignment' USING ERRCODE = '23514';
    END IF;
  ELSE
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.college_id IS DISTINCT FROM OLD.college_id
       OR NEW.training_id IS DISTINCT FROM OLD.training_id OR NEW.supervisor_user_id IS DISTINCT FROM OLD.supervisor_user_id
       OR NEW.assigned_by_user_id IS DISTINCT FROM OLD.assigned_by_user_id
       OR NEW.start_at IS DISTINCT FROM OLD.start_at OR NEW.change_request_id IS DISTINCT FROM OLD.change_request_id
       OR OLD.end_at IS NOT NULL OR NEW.end_at IS NULL OR NOT app_private.is_college_admin(OLD.college_id) THEN
      RAISE EXCEPTION 'Only an active assignment may be ended by the college administrator' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.guard_supervisor_assignment() OWNER TO app_policy_owner;
CREATE TRIGGER supervisor_assignment_integrity_trg
  BEFORE INSERT OR UPDATE ON public.training_supervisor_assignments
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_supervisor_assignment();

CREATE OR REPLACE FUNCTION app_private.sync_training_supervisor() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  UPDATE public.trainings SET academic_supervisor_user_id = NEW.supervisor_user_id, updated_at = now()
  WHERE id = NEW.training_id AND college_id = NEW.college_id;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.sync_training_supervisor() OWNER TO app_policy_owner;
CREATE TRIGGER supervisor_assignment_sync_training_trg
  AFTER INSERT ON public.training_supervisor_assignments
  FOR EACH ROW EXECUTE FUNCTION app_private.sync_training_supervisor();

-- Conversations remain between the two actual training parties; college staff use the audited access RPC only.
CREATE OR REPLACE FUNCTION app_private.is_training_party(p_training_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.trainings t
    JOIN public.training_opportunities o ON o.id=t.opportunity_id AND o.college_id=t.college_id
    WHERE t.id=p_training_id AND t.college_id=app_private.current_college_id()
      AND (
        (t.student_user_id=app_private.current_user_id() AND app_private.has_role('student',t.college_id))
        OR ((t.academic_supervisor_user_id=app_private.current_user_id()
             OR EXISTS (SELECT 1 FROM public.training_supervisor_assignments a WHERE a.training_id=t.id
               AND a.college_id=t.college_id AND a.supervisor_user_id=app_private.current_user_id() AND a.end_at IS NULL))
            AND app_private.has_role('academic_supervisor',t.college_id))
        OR (o.created_by_user_id=app_private.current_user_id()
            AND app_private.has_role('company_representative',t.college_id))
      )
  )
$$;
ALTER FUNCTION app_private.is_training_party(uuid) OWNER TO app_policy_owner;

CREATE OR REPLACE FUNCTION app_private.can_read_conversation(p_conversation_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.conversation_participants cp
    WHERE cp.conversation_id=p_conversation_id AND cp.user_id=app_private.current_user_id()
      AND cp.college_id=app_private.current_college_id()
  ) OR EXISTS (
    SELECT 1 FROM public.conversations c
    JOIN public.audit_logs al ON al.college_id=c.college_id
      AND al.actor_user_id=app_private.current_user_id()
      AND al.action='conversation.exceptional_access'
      AND al.reason IS NOT NULL AND length(btrim(al.reason))>0
      AND al.metadata->>'conversation_id'=c.id::text
    WHERE c.id=p_conversation_id AND c.college_id=app_private.current_college_id()
      AND app_private.is_college_admin(c.college_id)
      AND (
        (al.metadata->>'case_type'='dispute' AND EXISTS (
          SELECT 1 FROM public.dispute_reports d WHERE d.id=(al.metadata->>'case_id')::uuid
            AND d.training_id=c.training_id AND d.college_id=c.college_id AND d.status IN ('open','under_review')
        ))
        OR (al.metadata->>'case_type'='official_request' AND EXISTS (
          SELECT 1 FROM public.official_requests r WHERE r.id=(al.metadata->>'case_id')::uuid
            AND r.training_id=c.training_id AND r.college_id=c.college_id AND r.status IN ('submitted','under_review')
        ))
      )
  )
$$;
ALTER FUNCTION app_private.can_read_conversation(uuid) OWNER TO app_policy_owner;

CREATE OR REPLACE FUNCTION app_private.conversation_has_two_participants(p_conversation_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$ SELECT count(*) = 2 FROM public.conversation_participants WHERE conversation_id=p_conversation_id $$;
ALTER FUNCTION app_private.conversation_has_two_participants(uuid) OWNER TO app_policy_owner;

CREATE OR REPLACE FUNCTION app_private.conversation_training_id(p_conversation_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$ SELECT training_id FROM public.conversations WHERE id=p_conversation_id $$;
ALTER FUNCTION app_private.conversation_training_id(uuid) OWNER TO app_policy_owner;

CREATE OR REPLACE FUNCTION app_private.guard_conversation_participant_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE v_training_id uuid; v_count integer;
BEGIN
  IF NEW.user_id IS DISTINCT FROM app_private.current_user_id()
     OR app_private.is_college_admin(NEW.college_id)
     OR NOT app_private.is_training_party(app_private.conversation_training_id(NEW.conversation_id)) THEN
    RAISE EXCEPTION 'Conversation participants must be the two actual training parties' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.conversation_id::text, 1));
  SELECT count(*) INTO v_count FROM public.conversation_participants WHERE conversation_id=NEW.conversation_id;
  IF v_count >= 2 THEN RAISE EXCEPTION 'A conversation may have only two participants' USING ERRCODE = '23514'; END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.guard_conversation_participant_insert() OWNER TO app_policy_owner;
CREATE TRIGGER conversation_participant_guard_trg
  BEFORE INSERT ON public.conversation_participants FOR EACH ROW
  EXECUTE FUNCTION app_private.guard_conversation_participant_insert();

DROP POLICY conversations_insert_training_party ON public.conversations;
CREATE POLICY conversations_insert_training_party ON public.conversations FOR INSERT TO app_runtime
  WITH CHECK (college_id=app_private.current_college_id() AND app_private.is_training_party(training_id));
DROP POLICY participants_insert_self ON public.conversation_participants;
CREATE POLICY participants_insert_self ON public.conversation_participants FOR INSERT TO app_runtime
  WITH CHECK (user_id=app_private.current_user_id() AND college_id=app_private.current_college_id()
    AND app_private.is_training_party(app_private.conversation_training_id(conversation_id))
    AND NOT app_private.is_college_admin(college_id));
DROP POLICY messages_insert_participant ON public.messages;
CREATE POLICY messages_insert_participant ON public.messages FOR INSERT TO app_runtime
  WITH CHECK (sender_user_id=app_private.current_user_id() AND college_id=app_private.current_college_id()
    AND app_private.conversation_has_two_participants(conversation_id)
    AND EXISTS (SELECT 1 FROM public.conversation_participants cp
      WHERE cp.conversation_id=conversation_id AND cp.user_id=app_private.current_user_id()
        AND cp.college_id=messages.college_id));

-- Persist application transition history through a trigger, never through arbitrary client inserts.
REVOKE INSERT ON public.supervisor_note_revisions FROM app_runtime;
ALTER FUNCTION app_private.record_supervisor_note_revision() SECURITY DEFINER;
ALTER FUNCTION app_private.record_supervisor_note_revision() OWNER TO app_policy_owner;
REVOKE ALL ON FUNCTION app_private.record_supervisor_note_revision() FROM PUBLIC;

-- Constrain final evaluations to the company representative and immutable training identity.
DROP POLICY evaluations_insert_company ON public.final_evaluations;
CREATE POLICY evaluations_insert_company ON public.final_evaluations FOR INSERT TO app_runtime
  WITH CHECK (college_id=app_private.current_college_id() AND submitted_by_user_id=app_private.current_user_id()
    AND status='draft' AND app_private.is_company_for_training(training_id));
CREATE OR REPLACE FUNCTION app_private.guard_evaluation_identity() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.submitted_by_user_id IS DISTINCT FROM app_private.current_user_id()
       OR NOT app_private.is_company_for_training(NEW.training_id) THEN
      RAISE EXCEPTION 'Final evaluation must be authored by the assigned company representative' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF OLD.status='submitted'
       OR (to_jsonb(NEW) - ARRAY['status','general_comment','submitted_at','updated_at'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','general_comment','submitted_at','updated_at'])
       OR NOT app_private.is_company_for_training(OLD.training_id)
       OR NEW.status NOT IN ('draft','submitted') THEN
      RAISE EXCEPTION 'Invalid final evaluation update' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER final_evaluation_identity_guard_trg
  BEFORE INSERT OR UPDATE ON public.final_evaluations
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_evaluation_identity();

-- Approval/rejection of attendance is a company decision; students cannot rewrite check-in history or relationships.
CREATE OR REPLACE FUNCTION app_private.guard_attendance_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE v_limit integer; v_minutes integer;
BEGIN
  IF OLD.id IS DISTINCT FROM NEW.id OR OLD.college_id IS DISTINCT FROM NEW.college_id
     OR OLD.training_id IS DISTINCT FROM NEW.training_id OR OLD.attendance_date IS DISTINCT FROM NEW.attendance_date
     OR OLD.check_in_at IS DISTINCT FROM NEW.check_in_at OR OLD.check_in_latitude IS DISTINCT FROM NEW.check_in_latitude
     OR OLD.check_in_longitude IS DISTINCT FROM NEW.check_in_longitude
     OR OLD.check_in_accuracy_meters IS DISTINCT FROM NEW.check_in_accuracy_meters
     OR OLD.check_in_site_id IS DISTINCT FROM NEW.check_in_site_id THEN
    RAISE EXCEPTION 'Attendance identity and check-in evidence are immutable; use a correction request' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (SELECT 1 FROM public.trainings t WHERE t.id=OLD.training_id
      AND t.student_user_id=app_private.current_user_id())
     AND app_private.has_role('student',OLD.college_id) THEN
    IF OLD.status IN ('approved','rejected')
       OR (to_jsonb(NEW) - ARRAY['check_out_at','check_out_latitude','check_out_longitude','check_out_accuracy_meters','check_out_site_id','status','updated_at'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['check_out_at','check_out_latitude','check_out_longitude','check_out_accuracy_meters','check_out_site_id','status','updated_at'])
       OR NEW.status NOT IN ('incomplete','pending_company_approval','exception_pending') THEN
      RAISE EXCEPTION 'Student may submit checkout evidence only; corrections require a request' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF app_private.is_company_for_training(OLD.training_id) THEN
    IF OLD.status NOT IN ('pending_company_approval','exception_pending')
       OR (to_jsonb(NEW) - ARRAY['status','company_reviewed_by','company_reviewed_at','rejection_reason','approved_minutes','updated_at'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','company_reviewed_by','company_reviewed_at','rejection_reason','approved_minutes','updated_at'])
       OR NEW.status NOT IN ('approved','rejected')
       OR NEW.company_reviewed_by IS DISTINCT FROM app_private.current_user_id()
       OR NEW.company_reviewed_at IS NULL THEN
      RAISE EXCEPTION 'Invalid company attendance decision' USING ERRCODE = '42501';
    END IF;
    IF NEW.status='approved' THEN
      IF NEW.check_in_at IS NULL OR NEW.check_out_at IS NULL OR NEW.check_out_at < NEW.check_in_at THEN
        RAISE EXCEPTION 'Check-in and checkout are required for approval' USING ERRCODE = '23514';
      END IF;
      SELECT r.daily_work_limit_minutes INTO v_limit FROM public.trainings t
        JOIN public.specialty_training_requirements r ON r.college_id=t.college_id AND r.specialty_id=t.specialty_id
        WHERE t.id=NEW.training_id AND t.college_id=NEW.college_id;
      IF v_limit IS NULL THEN RAISE EXCEPTION 'Daily specialty limit is not configured' USING ERRCODE = '23514'; END IF;
      v_minutes := floor(extract(epoch FROM (NEW.check_out_at-NEW.check_in_at))/60)::integer;
      NEW.approved_minutes := least(v_minutes,v_limit);
      NEW.rejection_reason := NULL;
    ELSE
      IF coalesce(length(btrim(NEW.rejection_reason)),0)=0 THEN
        RAISE EXCEPTION 'A rejection reason is required' USING ERRCODE = '23514';
      END IF;
      NEW.approved_minutes := 0;
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Attendance update is not authorized' USING ERRCODE = '42501';
END;
$$;
ALTER FUNCTION app_private.guard_attendance_update() OWNER TO app_policy_owner;
CREATE TRIGGER attendance_update_integrity_trg
  BEFORE UPDATE ON public.attendance_records FOR EACH ROW EXECUTE FUNCTION app_private.guard_attendance_update();

CREATE OR REPLACE FUNCTION app_private.guard_attendance_request_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF OLD.id IS DISTINCT FROM NEW.id OR OLD.college_id IS DISTINCT FROM NEW.college_id
     OR OLD.training_id IS DISTINCT FROM NEW.training_id OR OLD.attendance_record_id IS DISTINCT FROM NEW.attendance_record_id
     OR OLD.requester_user_id IS DISTINCT FROM NEW.requester_user_id OR OLD.request_type IS DISTINCT FROM NEW.request_type
     OR OLD.reason IS DISTINCT FROM NEW.reason THEN
    RAISE EXCEPTION 'Attendance correction request contents are immutable after submission' USING ERRCODE = '42501';
  END IF;
  IF NOT app_private.is_company_for_training(OLD.training_id)
     OR OLD.status <> 'pending_company_review'
     OR NEW.status NOT IN ('approved','rejected')
     OR NEW.decided_by_user_id IS DISTINCT FROM app_private.current_user_id()
     OR NEW.decided_at IS NULL
     OR (NEW.status='rejected' AND coalesce(length(btrim(NEW.decision_reason)),0)=0) THEN
    RAISE EXCEPTION 'Invalid company correction-request decision' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.guard_attendance_request_update() OWNER TO app_policy_owner;
CREATE TRIGGER attendance_request_update_guard_trg
  BEFORE UPDATE ON public.attendance_change_requests
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_attendance_request_update();

-- College decisions may update decision fields, not the original reporter or request contents.
CREATE OR REPLACE FUNCTION app_private.guard_official_request_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF (to_jsonb(NEW) - ARRAY['status','decided_by_user_id','decision','decided_at','updated_at'])
     IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','decided_by_user_id','decision','decided_at','updated_at'])
     OR NOT app_private.is_college_admin(OLD.college_id)
     OR OLD.status NOT IN ('submitted','under_review')
     OR NEW.status NOT IN ('under_review','approved','rejected') THEN
    RAISE EXCEPTION 'Invalid official-request review update' USING ERRCODE = '42501';
  END IF;
  IF NEW.status='under_review' AND (NEW.decided_by_user_id IS DISTINCT FROM OLD.decided_by_user_id
       OR NEW.decided_at IS DISTINCT FROM OLD.decided_at OR NEW.decision IS DISTINCT FROM OLD.decision) THEN
    RAISE EXCEPTION 'Review-in-progress cannot rewrite a final decision' USING ERRCODE = '42501';
  END IF;
  IF NEW.status IN ('approved','rejected') AND (
      NEW.decided_by_user_id IS DISTINCT FROM app_private.current_user_id() OR NEW.decided_at IS NULL
      OR coalesce(length(btrim(NEW.decision)),0)=0) THEN
    RAISE EXCEPTION 'Final request decision requires reviewer, time, and decision' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.guard_official_request_update() OWNER TO app_policy_owner;
CREATE TRIGGER official_request_update_guard_trg
  BEFORE UPDATE ON public.official_requests FOR EACH ROW EXECUTE FUNCTION app_private.guard_official_request_update();

CREATE OR REPLACE FUNCTION app_private.guard_dispute_update() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF (to_jsonb(NEW) - ARRAY['status','college_decision_by','college_decision','college_decided_at','updated_at'])
     IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status','college_decision_by','college_decision','college_decided_at','updated_at'])
     OR NOT app_private.is_college_admin(OLD.college_id)
     OR OLD.status NOT IN ('open','under_review')
     OR NEW.status NOT IN ('under_review','resolved','closed') THEN
    RAISE EXCEPTION 'Invalid dispute review update' USING ERRCODE = '42501';
  END IF;
  IF NEW.status='under_review' AND (NEW.college_decision_by IS DISTINCT FROM OLD.college_decision_by
       OR NEW.college_decided_at IS DISTINCT FROM OLD.college_decided_at
       OR NEW.college_decision IS DISTINCT FROM OLD.college_decision) THEN
    RAISE EXCEPTION 'Review-in-progress cannot rewrite a final decision' USING ERRCODE = '42501';
  END IF;
  IF NEW.status IN ('resolved','closed') AND (
      NEW.college_decision_by IS DISTINCT FROM app_private.current_user_id() OR NEW.college_decided_at IS NULL
      OR coalesce(length(btrim(NEW.college_decision)),0)=0) THEN
    RAISE EXCEPTION 'Dispute resolution requires reviewer, time, and decision' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION app_private.guard_dispute_update() OWNER TO app_policy_owner;
CREATE TRIGGER dispute_update_guard_trg
  BEFORE UPDATE ON public.dispute_reports FOR EACH ROW EXECUTE FUNCTION app_private.guard_dispute_update();

-- Recipients may mark their notifications read, but cannot rewrite their content.
CREATE OR REPLACE FUNCTION app_private.guard_notification_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF NEW.user_id IS DISTINCT FROM OLD.user_id
     OR (to_jsonb(NEW) - ARRAY['read_at','updated_at']) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['read_at','updated_at'])
     OR OLD.user_id IS DISTINCT FROM app_private.current_user_id() THEN
    RAISE EXCEPTION 'Only the notification recipient may update read state' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER notification_update_guard_trg
  BEFORE UPDATE ON public.notifications FOR EACH ROW EXECUTE FUNCTION app_private.guard_notification_update();

-- Upload metadata is limited to roles that submit a CV or formal-request attachment.
DROP POLICY file_assets_insert_self ON public.file_assets;
CREATE POLICY file_assets_insert_self ON public.file_assets FOR INSERT TO app_runtime
  WITH CHECK (college_id=app_private.current_college_id() AND uploaded_by_user_id=app_private.current_user_id()
    AND (app_private.has_role('student',college_id) OR app_private.has_role('company_representative',college_id)));

DROP POLICY official_request_files_insert_requester ON public.official_request_files;
CREATE POLICY official_request_files_insert_requester ON public.official_request_files FOR INSERT TO app_runtime
  WITH CHECK (college_id=app_private.current_college_id()
    AND EXISTS (SELECT 1 FROM public.official_requests r WHERE r.id=request_id
      AND r.requester_user_id=app_private.current_user_id() AND r.college_id=official_request_files.college_id)
    AND EXISTS (SELECT 1 FROM public.file_assets f WHERE f.id=file_id
      AND f.college_id=official_request_files.college_id AND f.uploaded_by_user_id=app_private.current_user_id()));

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app_private FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app_private TO app_runtime, app_policy_owner;

COMMIT;
