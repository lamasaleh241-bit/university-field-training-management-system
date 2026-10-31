-- Migration 002: tenant context, authorization helpers, PostgreSQL RLS policies.
-- The API must set app.user_id and app.college_id from authenticated server-side identity
-- inside each transaction. Never expose app_runtime DB credentials to end users.

BEGIN;

DO $$
DECLARE
  v_runtime pg_roles%ROWTYPE;
  v_policy_owner pg_roles%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_runtime') THEN
    CREATE ROLE app_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_policy_owner') THEN
    CREATE ROLE app_policy_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
  END IF;
  SELECT * INTO v_runtime FROM pg_roles WHERE rolname = 'app_runtime';
  SELECT * INTO v_policy_owner FROM pg_roles WHERE rolname = 'app_policy_owner';
  IF v_runtime.rolcanlogin OR v_runtime.rolsuper OR v_runtime.rolbypassrls
     OR v_runtime.rolcreatedb OR v_runtime.rolcreaterole THEN
    RAISE EXCEPTION 'app_runtime must be NOLOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, and NOBYPASSRLS';
  END IF;
  IF v_policy_owner.rolcanlogin OR v_policy_owner.rolsuper OR NOT v_policy_owner.rolbypassrls
     OR v_policy_owner.rolcreatedb OR v_policy_owner.rolcreaterole THEN
    RAISE EXCEPTION 'app_policy_owner must be NOLOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, and BYPASSRLS';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member
    WHERE m.roleid = v_policy_owner.oid AND r.rolcanlogin
  ) THEN
    RAISE EXCEPTION 'app_policy_owner must not be granted to any LOGIN role';
  END IF;
END;
$$;

CREATE SCHEMA IF NOT EXISTS app_private;
REVOKE ALL ON SCHEMA app_private FROM PUBLIC;
GRANT USAGE ON SCHEMA app_private TO app_runtime;
GRANT USAGE ON SCHEMA app_private TO app_policy_owner;
GRANT CREATE ON SCHEMA app_private TO app_policy_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_policy_owner;
GRANT INSERT ON public.audit_logs TO app_policy_owner;

-- The signing key is visible only to the non-login policy owner and database administrators.
CREATE TABLE app_private.context_signing_keys (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  signing_key bytea NOT NULL
);
INSERT INTO app_private.context_signing_keys (singleton, signing_key)
VALUES (true, public.gen_random_bytes(32));
REVOKE ALL ON app_private.context_signing_keys FROM PUBLIC, app_runtime;
GRANT SELECT ON app_private.context_signing_keys TO app_policy_owner;

CREATE OR REPLACE FUNCTION app_private.context_is_valid() RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE
  v_user_id uuid;
  v_college_id uuid;
  v_user_raw text;
  v_college_raw text;
  v_signature text;
  v_key bytea;
  v_expected text;
  v_user_scope_matches boolean;
BEGIN
  v_user_raw := nullif(current_setting('app.user_id', true), '');
  v_college_raw := nullif(current_setting('app.college_id', true), '');
  v_signature := nullif(current_setting('app.context_signature', true), '');
  IF v_user_raw IS NULL OR v_signature IS NULL THEN RETURN false; END IF;
  BEGIN
    v_user_id := v_user_raw::uuid;
    IF v_college_raw IS NOT NULL THEN v_college_id := v_college_raw::uuid; END IF;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN false;
  END;
  SELECT signing_key INTO v_key FROM app_private.context_signing_keys WHERE singleton = true;
  v_expected := encode(public.hmac(
    convert_to(v_user_id::text || ':' || coalesce(v_college_id::text, ''), 'UTF8'), v_key, 'sha256'
  ), 'hex');
  IF v_signature <> v_expected THEN RETURN false; END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.id = v_user_id AND u.college_id IS NOT DISTINCT FROM v_college_id
  ) INTO v_user_scope_matches;
  RETURN v_user_scope_matches;
END;
$$;

CREATE OR REPLACE FUNCTION app_private.current_user_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT CASE WHEN app_private.context_is_valid()
    THEN nullif(current_setting('app.user_id', true), '')::uuid ELSE NULL::uuid END
$$;

CREATE OR REPLACE FUNCTION app_private.current_college_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT CASE WHEN app_private.context_is_valid()
    THEN nullif(current_setting('app.college_id', true), '')::uuid ELSE NULL::uuid END
$$;

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

CREATE OR REPLACE FUNCTION app_private.is_system_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$ SELECT app_private.has_role('system_admin', NULL::uuid) $$;

CREATE OR REPLACE FUNCTION app_private.is_college_admin(p_college_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$ SELECT app_private.has_role('college_admin', p_college_id) $$;

CREATE OR REPLACE FUNCTION app_private.is_company_for_opportunity(p_opportunity_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.training_opportunities o
    WHERE o.id = p_opportunity_id
      AND o.college_id = app_private.current_college_id()
      AND o.created_by_user_id = app_private.current_user_id()
      AND app_private.has_role('company_representative', o.college_id)
  )
$$;

CREATE OR REPLACE FUNCTION app_private.can_read_opportunity(p_opportunity_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.training_opportunities o
    WHERE o.id = p_opportunity_id
      AND o.college_id = app_private.current_college_id()
      AND (
        app_private.is_college_admin(o.college_id)
        OR app_private.is_company_for_opportunity(o.id)
        OR EXISTS (
          SELECT 1 FROM public.trainings t
          WHERE t.opportunity_id = o.id
            AND ((t.academic_supervisor_user_id = app_private.current_user_id()
                  AND app_private.has_role('academic_supervisor', o.college_id))
              OR (t.student_user_id = app_private.current_user_id()
                  AND app_private.has_role('student', o.college_id)))
        )
        OR (
          app_private.has_role('student', o.college_id)
          AND o.status = 'open'
          AND EXISTS (
            SELECT 1 FROM public.users u
            JOIN public.opportunity_specialties os ON os.specialty_id = u.specialty_id
            WHERE u.id = app_private.current_user_id()
              AND u.college_id = o.college_id
              AND os.college_id = o.college_id
              AND os.opportunity_id = o.id
          )
          AND (SELECT count(*) FROM public.training_applications a
               WHERE a.opportunity_id = o.id AND a.status = 'approved') < o.seat_limit
        )
      )
  )
$$;

CREATE OR REPLACE FUNCTION app_private.is_company_for_training(p_training_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.trainings t
    JOIN public.training_opportunities o ON o.id = t.opportunity_id AND o.college_id = t.college_id
    WHERE t.id = p_training_id
      AND t.college_id = app_private.current_college_id()
      AND o.created_by_user_id = app_private.current_user_id()
      AND app_private.has_role('company_representative', t.college_id)
  )
$$;

CREATE OR REPLACE FUNCTION app_private.can_read_training(p_training_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.trainings t
    WHERE t.id = p_training_id
      AND t.college_id = app_private.current_college_id()
      AND (
        app_private.is_college_admin(t.college_id)
        OR (t.student_user_id = app_private.current_user_id() AND app_private.has_role('student', t.college_id))
        OR (t.academic_supervisor_user_id = app_private.current_user_id() AND app_private.has_role('academic_supervisor', t.college_id))
        OR EXISTS (
          SELECT 1 FROM public.training_supervisor_assignments sa
          WHERE sa.training_id = t.id AND sa.college_id = t.college_id
            AND sa.supervisor_user_id = app_private.current_user_id() AND sa.end_at IS NULL
            AND app_private.has_role('academic_supervisor', t.college_id)
        )
        OR app_private.is_company_for_training(t.id)
      )
  )
$$;

CREATE OR REPLACE FUNCTION app_private.can_read_application(p_application_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.training_applications a
    JOIN public.training_opportunities o ON o.id = a.opportunity_id AND o.college_id = a.college_id
    WHERE a.id = p_application_id
      AND a.college_id = app_private.current_college_id()
      AND (
        (a.student_user_id = app_private.current_user_id() AND app_private.has_role('student', a.college_id))
        OR (o.created_by_user_id = app_private.current_user_id() AND app_private.has_role('company_representative', a.college_id))
        OR app_private.is_college_admin(a.college_id)
        OR EXISTS (SELECT 1 FROM public.trainings t WHERE t.application_id = a.id
                   AND t.academic_supervisor_user_id = app_private.current_user_id())
      )
  )
$$;

CREATE OR REPLACE FUNCTION app_private.can_read_user(p_target_user_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT p_target_user_id = app_private.current_user_id()
    OR EXISTS (
      SELECT 1 FROM public.users target
      WHERE target.id = p_target_user_id
        AND target.college_id = app_private.current_college_id()
        AND app_private.is_college_admin(target.college_id)
    )
    OR EXISTS (
      SELECT 1
      FROM public.trainings t
      JOIN public.training_opportunities o ON o.id = t.opportunity_id AND o.college_id = t.college_id
      WHERE t.college_id = app_private.current_college_id()
        AND app_private.can_read_training(t.id)
        AND p_target_user_id IN (t.student_user_id, t.academic_supervisor_user_id, o.created_by_user_id)
    )
    OR EXISTS (
      SELECT 1 FROM public.training_applications a
      JOIN public.training_opportunities o ON o.id = a.opportunity_id AND o.college_id = a.college_id
      WHERE a.college_id = app_private.current_college_id()
        AND ((a.student_user_id = app_private.current_user_id() AND o.created_by_user_id = p_target_user_id)
          OR (o.created_by_user_id = app_private.current_user_id() AND a.student_user_id = p_target_user_id))
    )
$$;

CREATE OR REPLACE FUNCTION app_private.can_read_site(p_site_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.training_sites s
    WHERE s.id = p_site_id AND s.college_id = app_private.current_college_id()
      AND (
        app_private.is_college_admin(s.college_id)
        OR (s.created_by_user_id = app_private.current_user_id()
            AND app_private.has_role('company_representative', s.college_id))
        OR (s.approval_status = 'approved' AND EXISTS (
          SELECT 1 FROM public.opportunity_sites os
          JOIN public.training_opportunities o ON o.id = os.opportunity_id AND o.college_id = os.college_id
          WHERE os.site_id = s.id AND os.college_id = s.college_id
            AND (app_private.can_read_opportunity(o.id) OR EXISTS (
              SELECT 1 FROM public.trainings t WHERE t.opportunity_id = o.id AND app_private.can_read_training(t.id)
            ))
        ))
      )
  )
$$;

CREATE OR REPLACE FUNCTION app_private.can_read_file(p_file_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.file_assets f
    WHERE f.id = p_file_id AND f.college_id = app_private.current_college_id()
      AND (
        f.uploaded_by_user_id = app_private.current_user_id()
        OR (app_private.is_college_admin(f.college_id) AND EXISTS (
          SELECT 1 FROM public.official_request_files rf
          JOIN public.official_requests r ON r.id = rf.request_id AND r.college_id = rf.college_id
          WHERE rf.file_id = f.id AND rf.college_id = f.college_id
            AND r.status IN ('submitted','under_review')
        ))
        OR EXISTS (
          SELECT 1 FROM public.training_applications a
          JOIN public.training_opportunities o ON o.id = a.opportunity_id AND o.college_id = a.college_id
          WHERE a.resume_file_id = f.id AND a.college_id = f.college_id
            AND o.created_by_user_id = app_private.current_user_id()
        )
      )
  )
$$;

CREATE OR REPLACE FUNCTION app_private.can_read_evaluation(p_evaluation_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.final_evaluations e
    WHERE e.id = p_evaluation_id AND e.college_id = app_private.current_college_id()
      AND (
        app_private.is_college_admin(e.college_id)
        OR EXISTS (
          SELECT 1 FROM public.trainings t
          WHERE t.id = e.training_id
            AND ((t.student_user_id = app_private.current_user_id() AND e.status = 'submitted')
              OR t.academic_supervisor_user_id = app_private.current_user_id()
              OR app_private.is_company_for_training(t.id))
        )
      )
  )
$$;

CREATE OR REPLACE FUNCTION app_private.can_read_conversation(p_conversation_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.conversation_participants cp
    WHERE cp.conversation_id = p_conversation_id
      AND cp.user_id = app_private.current_user_id()
      AND cp.college_id = app_private.current_college_id()
  ) OR EXISTS (
    SELECT 1
    FROM public.conversations c
    JOIN public.audit_logs al ON al.college_id = c.college_id
      AND al.actor_user_id = app_private.current_user_id()
      AND al.action = 'conversation.exceptional_access'
      AND al.reason IS NOT NULL AND length(btrim(al.reason)) > 0
      AND al.metadata->>'conversation_id' = c.id::text
    WHERE c.id = p_conversation_id
      AND c.college_id = app_private.current_college_id()
      AND app_private.is_college_admin(c.college_id)
      AND (
        EXISTS (SELECT 1 FROM public.dispute_reports d WHERE d.training_id = c.training_id
                AND d.college_id = c.college_id AND d.status IN ('open', 'under_review'))
        OR EXISTS (SELECT 1 FROM public.official_requests r WHERE r.training_id = c.training_id
                   AND r.college_id = c.college_id AND r.status IN ('submitted', 'under_review'))
      )
  )
$$;

CREATE OR REPLACE FUNCTION app_private.log_exceptional_conversation_access(
  p_conversation_id uuid, p_case_type text, p_case_id uuid, p_reason text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE
  v_college_id uuid;
  v_training_id uuid;
  v_case_ok boolean := false;
BEGIN
  SELECT c.college_id, c.training_id INTO v_college_id, v_training_id
  FROM public.conversations c WHERE c.id = p_conversation_id;
  IF v_college_id IS NULL OR v_college_id <> app_private.current_college_id()
     OR NOT app_private.is_college_admin(v_college_id) THEN
    RAISE EXCEPTION 'Not authorized for exceptional conversation access' USING ERRCODE = '42501';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'A reason is required for exceptional conversation access' USING ERRCODE = '23514';
  END IF;
  IF p_case_type = 'dispute' THEN
    SELECT EXISTS (SELECT 1 FROM public.dispute_reports d WHERE d.id = p_case_id
      AND d.training_id = v_training_id AND d.college_id = v_college_id
      AND d.status IN ('open', 'under_review')) INTO v_case_ok;
  ELSIF p_case_type = 'official_request' THEN
    SELECT EXISTS (SELECT 1 FROM public.official_requests r WHERE r.id = p_case_id
      AND r.training_id = v_training_id AND r.college_id = v_college_id
      AND r.status IN ('submitted', 'under_review')) INTO v_case_ok;
  END IF;
  IF NOT v_case_ok THEN
    RAISE EXCEPTION 'No active, related dispute or official request' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.audit_logs (college_id, actor_user_id, action, entity_type, entity_id, reason, metadata)
  VALUES (v_college_id, app_private.current_user_id(), 'conversation.exceptional_access', 'conversation',
          p_conversation_id, btrim(p_reason), jsonb_build_object('conversation_id', p_conversation_id,
          'training_id', v_training_id, 'case_type', p_case_type, 'case_id', p_case_id));
END;
$$;

CREATE OR REPLACE FUNCTION app_private.guard_approved_seat_capacity() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
DECLARE
  v_limit integer;
  v_approved integer;
BEGIN
  IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status <> 'approved') THEN
    -- Serialize final approvals per opportunity so concurrent college approvals cannot oversubscribe seats.
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.opportunity_id::text, 0));
    SELECT seat_limit INTO v_limit FROM public.training_opportunities
      WHERE id = NEW.opportunity_id AND college_id = NEW.college_id;
    SELECT count(*) INTO v_approved FROM public.training_applications
      WHERE opportunity_id = NEW.opportunity_id AND college_id = NEW.college_id
        AND status = 'approved' AND id <> NEW.id;
    IF v_approved >= v_limit THEN
      RAISE EXCEPTION 'No seats remain; approval cannot reserve a seat' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER applications_capacity_guard_trg
  BEFORE INSERT OR UPDATE OF status ON public.training_applications
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_approved_seat_capacity();

CREATE OR REPLACE FUNCTION app_private.record_supervisor_note_revision() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF NEW.note_text IS DISTINCT FROM OLD.note_text THEN
    INSERT INTO public.supervisor_note_revisions
      (college_id, note_id, changed_by_user_id, previous_text, new_text)
    VALUES (OLD.college_id, OLD.id, app_private.current_user_id(), OLD.note_text, NEW.note_text);
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER supervisor_note_revision_trg
  BEFORE UPDATE OF note_text ON public.supervisor_notes
  FOR EACH ROW EXECUTE FUNCTION app_private.record_supervisor_note_revision();

CREATE OR REPLACE FUNCTION app_private.prevent_evaluation_reopen() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF OLD.status = 'submitted' THEN
    RAISE EXCEPTION 'Submitted final evaluations are immutable' USING ERRCODE = '23514';
  END IF;
  IF NEW.status = 'submitted' AND NEW.submitted_at IS NULL THEN
    NEW.submitted_at := now();
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER final_evaluation_immutable_trg
  BEFORE UPDATE ON public.final_evaluations
  FOR EACH ROW EXECUTE FUNCTION app_private.prevent_evaluation_reopen();

CREATE OR REPLACE FUNCTION app_private.guard_college_timezone_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, app_private
AS $$
BEGIN
  IF NEW.timezone IS DISTINCT FROM OLD.timezone AND NOT app_private.is_system_admin() THEN
    RAISE EXCEPTION 'Only a system administrator may change a college timezone' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER colleges_timezone_guard_trg
  BEFORE UPDATE OF timezone ON public.colleges
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_college_timezone_update();

-- Functions used by RLS are owned by a non-login BYPASSRLS role; application connections cannot assume it.
ALTER FUNCTION app_private.context_is_valid() OWNER TO app_policy_owner;
ALTER FUNCTION app_private.current_user_id() OWNER TO app_policy_owner;
ALTER FUNCTION app_private.current_college_id() OWNER TO app_policy_owner;
ALTER FUNCTION app_private.has_role(text, uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.is_system_admin() OWNER TO app_policy_owner;
ALTER FUNCTION app_private.is_college_admin(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.is_company_for_opportunity(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.can_read_opportunity(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.is_company_for_training(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.can_read_training(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.can_read_application(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.can_read_user(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.can_read_site(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.can_read_file(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.can_read_evaluation(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.can_read_conversation(uuid) OWNER TO app_policy_owner;
ALTER FUNCTION app_private.log_exceptional_conversation_access(uuid, text, uuid, text) OWNER TO app_policy_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_policy_owner;
GRANT INSERT ON public.audit_logs, public.supervisor_note_revisions TO app_policy_owner;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app_private FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app_private TO app_runtime, app_policy_owner;

-- RLS applies to every table with college-scoped rows (including FORCE for table owners).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'colleges','users','user_roles','specialties','specialty_training_requirements',
    'training_opportunities','opportunity_specialties','training_sites','opportunity_sites',
    'file_assets','training_applications','application_status_history','trainings',
    'training_supervisor_assignments','attendance_records','attendance_change_requests',
    'supervisor_notes','supervisor_note_revisions','final_evaluations','evaluation_items','conversations',
    'conversation_participants','messages','dispute_reports','official_requests',
    'official_request_files','notifications','audit_logs'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
  END LOOP;
END;
$$;

-- Public reference tables: read-only to runtime connections.
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evaluation_criteria ENABLE ROW LEVEL SECURITY;
CREATE POLICY roles_read ON public.roles FOR SELECT TO app_runtime USING (true);
CREATE POLICY evaluation_criteria_read ON public.evaluation_criteria FOR SELECT TO app_runtime USING (true);

-- Colleges: public reads of active colleges support registration; admins manage only their scope.
CREATE POLICY colleges_read ON public.colleges FOR SELECT TO app_runtime
  USING (status = 'active' OR id = app_private.current_college_id() OR app_private.is_system_admin());
CREATE POLICY colleges_insert_system_admin ON public.colleges FOR INSERT TO app_runtime
  WITH CHECK (app_private.is_system_admin());
CREATE POLICY colleges_update_admin ON public.colleges FOR UPDATE TO app_runtime
  USING (app_private.is_system_admin() OR app_private.is_college_admin(id))
  WITH CHECK (app_private.is_system_admin() OR app_private.is_college_admin(id));

-- Users and role assignments.
CREATE POLICY users_read_related ON public.users FOR SELECT TO app_runtime
  USING (id = app_private.current_user_id() OR app_private.can_read_user(id));
CREATE POLICY users_insert_self ON public.users FOR INSERT TO app_runtime
  WITH CHECK (id = app_private.current_user_id() AND college_id = app_private.current_college_id());
CREATE POLICY users_update_self_or_college_admin ON public.users FOR UPDATE TO app_runtime
  USING (id = app_private.current_user_id() OR app_private.is_college_admin(college_id))
  WITH CHECK ((id = app_private.current_user_id() AND college_id IS NOT DISTINCT FROM app_private.current_college_id())
    OR (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id)));

CREATE POLICY user_roles_read_self_or_admin ON public.user_roles FOR SELECT TO app_runtime
  USING (user_id = app_private.current_user_id()
    OR app_private.is_college_admin(college_id)
    OR (college_id IS NULL AND app_private.is_system_admin()));
CREATE POLICY user_roles_insert_self_or_admin ON public.user_roles FOR INSERT TO app_runtime
  WITH CHECK (
    (user_id = app_private.current_user_id() AND college_id = app_private.current_college_id()
      AND status = 'pending' AND EXISTS (SELECT 1 FROM public.roles r WHERE r.id = role_id
        AND r.code IN ('student','academic_supervisor','company_representative')))
    OR app_private.is_college_admin(college_id)
    OR (college_id IS NULL AND app_private.is_system_admin()
      AND EXISTS (SELECT 1 FROM public.roles r WHERE r.id = role_id AND r.code = 'system_admin'))
  );
CREATE POLICY user_roles_update_college_admin ON public.user_roles FOR UPDATE TO app_runtime
  USING (app_private.is_college_admin(college_id))
  WITH CHECK (app_private.is_college_admin(college_id));

-- College-managed specialties and training requirements.
CREATE POLICY specialties_read_college ON public.specialties FOR SELECT TO app_runtime
  USING (college_id = app_private.current_college_id() AND (
    app_private.is_college_admin(college_id)
    OR EXISTS (SELECT 1 FROM public.users u WHERE u.id=app_private.current_user_id()
      AND u.college_id=specialties.college_id AND u.specialty_id=specialties.id
      AND app_private.has_role('student',specialties.college_id))
    OR EXISTS (SELECT 1 FROM public.opportunity_specialties os
      WHERE os.specialty_id=specialties.id AND os.college_id=specialties.college_id
        AND app_private.can_read_opportunity(os.opportunity_id))
    OR EXISTS (SELECT 1 FROM public.trainings t WHERE t.specialty_id=specialties.id
      AND t.college_id=specialties.college_id AND app_private.can_read_training(t.id))
  ));
CREATE POLICY specialties_insert_admin ON public.specialties FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));
CREATE POLICY specialties_update_admin ON public.specialties FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));

CREATE POLICY requirements_read_college ON public.specialty_training_requirements FOR SELECT TO app_runtime
  USING (college_id = app_private.current_college_id() AND (
    app_private.is_college_admin(college_id)
    OR EXISTS (SELECT 1 FROM public.users u WHERE u.id=app_private.current_user_id()
      AND u.college_id=specialty_training_requirements.college_id
      AND u.specialty_id=specialty_training_requirements.specialty_id
      AND app_private.has_role('student',specialty_training_requirements.college_id))
    OR EXISTS (SELECT 1 FROM public.trainings t WHERE t.specialty_id=specialty_training_requirements.specialty_id
      AND t.college_id=specialty_training_requirements.college_id
      AND (t.academic_supervisor_user_id=app_private.current_user_id()
        OR EXISTS (SELECT 1 FROM public.training_supervisor_assignments sa WHERE sa.training_id=t.id
          AND sa.college_id=t.college_id AND sa.supervisor_user_id=app_private.current_user_id() AND sa.end_at IS NULL))
      AND app_private.has_role('academic_supervisor',specialty_training_requirements.college_id))
  ));
CREATE POLICY requirements_insert_admin ON public.specialty_training_requirements FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));
CREATE POLICY requirements_update_admin ON public.specialty_training_requirements FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));

-- Opportunities: students see only matching open, not-full opportunities; owners manage their listings.
CREATE POLICY opportunities_read_allowed ON public.training_opportunities FOR SELECT TO app_runtime
  USING (app_private.can_read_opportunity(id));
CREATE POLICY opportunities_insert_company ON public.training_opportunities FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND created_by_user_id = app_private.current_user_id()
    AND app_private.has_role('company_representative', college_id));
CREATE POLICY opportunities_update_company ON public.training_opportunities FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND created_by_user_id = app_private.current_user_id()
    AND app_private.has_role('company_representative', college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND created_by_user_id = app_private.current_user_id());

CREATE POLICY opportunity_specialties_read ON public.opportunity_specialties FOR SELECT TO app_runtime
  USING (app_private.can_read_opportunity(opportunity_id) OR app_private.is_college_admin(college_id));
CREATE POLICY opportunity_specialties_company_manage ON public.opportunity_specialties FOR ALL TO app_runtime
  USING (app_private.is_company_for_opportunity(opportunity_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_company_for_opportunity(opportunity_id));

-- Training locations.
CREATE POLICY sites_read_related ON public.training_sites FOR SELECT TO app_runtime
  USING (app_private.can_read_site(id));
CREATE POLICY sites_insert_company ON public.training_sites FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND created_by_user_id = app_private.current_user_id()
    AND app_private.has_role('company_representative', college_id)
    AND approval_status = 'pending' AND approved_by_user_id IS NULL AND approved_at IS NULL);
CREATE POLICY sites_update_company_pending ON public.training_sites FOR UPDATE TO app_runtime
  USING (created_by_user_id = app_private.current_user_id()
    AND app_private.has_role('company_representative', college_id)
    AND approval_status = 'pending')
  WITH CHECK (college_id = app_private.current_college_id()
    AND created_by_user_id = app_private.current_user_id() AND approval_status = 'pending'
    AND approved_by_user_id IS NULL AND approved_at IS NULL);
CREATE POLICY sites_update_college_admin ON public.training_sites FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));
CREATE POLICY opportunity_sites_read ON public.opportunity_sites FOR SELECT TO app_runtime
  USING (app_private.can_read_opportunity(opportunity_id) OR app_private.is_college_admin(college_id));
CREATE POLICY opportunity_sites_company_manage ON public.opportunity_sites FOR ALL TO app_runtime
  USING (app_private.is_company_for_opportunity(opportunity_id))
  WITH CHECK (college_id = app_private.current_college_id()
    AND app_private.is_company_for_opportunity(opportunity_id)
    AND EXISTS (SELECT 1 FROM public.training_sites s
      WHERE s.id = public.opportunity_sites.site_id
        AND s.college_id = public.opportunity_sites.college_id
        AND s.created_by_user_id = app_private.current_user_id()));

-- Private file metadata. Actual file bytes remain in private object storage.
CREATE POLICY file_assets_read_related ON public.file_assets FOR SELECT TO app_runtime
  USING (app_private.can_read_file(id));
CREATE POLICY file_assets_insert_self ON public.file_assets FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND uploaded_by_user_id = app_private.current_user_id());

-- Applications: student drafts/cancellation; company first decision; college final decision.
CREATE POLICY applications_read_related ON public.training_applications FOR SELECT TO app_runtime
  USING (app_private.can_read_application(id));
CREATE POLICY applications_insert_student ON public.training_applications FOR INSERT TO app_runtime
  WITH CHECK (student_user_id = app_private.current_user_id()
    AND college_id = app_private.current_college_id()
    AND app_private.has_role('student', college_id)
    AND status = 'draft'
    AND app_private.can_read_opportunity(opportunity_id));
CREATE POLICY applications_update_student ON public.training_applications FOR UPDATE TO app_runtime
  USING (student_user_id = app_private.current_user_id()
    AND status IN ('draft','submitted_company_review','college_review'))
  WITH CHECK (student_user_id = app_private.current_user_id()
    AND status IN ('draft','cancelled_by_student'));
CREATE POLICY applications_update_company ON public.training_applications FOR UPDATE TO app_runtime
  USING (status = 'submitted_company_review'
    AND app_private.is_company_for_opportunity(opportunity_id))
  WITH CHECK (college_id = app_private.current_college_id()
    AND status IN ('college_review','company_rejected')
    AND app_private.is_company_for_opportunity(opportunity_id));
CREATE POLICY applications_update_college_admin ON public.training_applications FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND status = 'college_review'
    AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id()
    AND status IN ('approved','college_rejected') AND app_private.is_college_admin(college_id));

CREATE POLICY application_history_read ON public.application_status_history FOR SELECT TO app_runtime
  USING (app_private.can_read_application(application_id));
CREATE POLICY application_history_insert_related ON public.application_status_history FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND changed_by_user_id = app_private.current_user_id()
    AND app_private.can_read_application(application_id));

-- Active training and supervisor assignments.
CREATE POLICY trainings_read_related ON public.trainings FOR SELECT TO app_runtime
  USING (app_private.can_read_training(id));
CREATE POLICY trainings_insert_college_admin ON public.trainings FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id)
    AND EXISTS (SELECT 1 FROM public.training_applications a WHERE a.id = application_id
      AND a.college_id = college_id AND a.status = 'approved'));
CREATE POLICY trainings_update_college_admin ON public.trainings FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));

CREATE POLICY supervisor_assignments_read_related ON public.training_supervisor_assignments FOR SELECT TO app_runtime
  USING (app_private.can_read_training(training_id));
CREATE POLICY supervisor_assignments_insert_admin ON public.training_supervisor_assignments FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));
CREATE POLICY supervisor_assignments_update_admin ON public.training_supervisor_assignments FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));

-- Daily attendance: student submits, company reviews, college/supervisor read only.
CREATE POLICY attendance_read_related ON public.attendance_records FOR SELECT TO app_runtime
  USING (app_private.can_read_training(training_id));
CREATE POLICY attendance_insert_student ON public.attendance_records FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND app_private.has_role('student', college_id)
    AND EXISTS (SELECT 1 FROM public.trainings t WHERE t.id = training_id
      AND t.student_user_id = app_private.current_user_id() AND t.status = 'active')
    AND status IN ('incomplete','pending_company_approval','exception_pending'));
CREATE POLICY attendance_update_student ON public.attendance_records FOR UPDATE TO app_runtime
  USING (status IN ('incomplete','pending_company_approval','exception_pending')
    AND EXISTS (SELECT 1 FROM public.trainings t WHERE t.id = training_id
      AND t.student_user_id = app_private.current_user_id()))
  WITH CHECK (college_id = app_private.current_college_id()
    AND status IN ('incomplete','pending_company_approval','exception_pending'));
CREATE POLICY attendance_update_company ON public.attendance_records FOR UPDATE TO app_runtime
  USING (status IN ('pending_company_approval','exception_pending')
    AND app_private.is_company_for_training(training_id))
  WITH CHECK (college_id = app_private.current_college_id()
    AND status IN ('approved','rejected','exception_pending'));

CREATE POLICY attendance_requests_read_related ON public.attendance_change_requests FOR SELECT TO app_runtime
  USING (student_user_id = app_private.current_user_id()
    OR app_private.is_college_admin(college_id)
    OR app_private.can_read_training(training_id));
CREATE POLICY attendance_requests_insert_student ON public.attendance_change_requests FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND student_user_id = app_private.current_user_id()
    AND app_private.has_role('student', college_id)
    AND EXISTS (SELECT 1 FROM public.trainings t WHERE t.id = training_id
      AND t.student_user_id = app_private.current_user_id()));
CREATE POLICY attendance_requests_update_company ON public.attendance_change_requests FOR UPDATE TO app_runtime
  USING (status = 'pending_company_review' AND app_private.is_company_for_training(training_id))
  WITH CHECK (status IN ('approved','rejected') AND app_private.is_company_for_training(training_id));

-- Academic supervisor notes are private; college admin can read but never write.
CREATE POLICY supervisor_notes_read ON public.supervisor_notes FOR SELECT TO app_runtime
  USING (app_private.is_college_admin(college_id)
    OR author_supervisor_user_id = app_private.current_user_id()
    OR app_private.can_read_training(training_id)
       AND EXISTS (SELECT 1 FROM public.trainings t WHERE t.id = training_id
                   AND t.academic_supervisor_user_id = app_private.current_user_id()));
CREATE POLICY supervisor_notes_insert ON public.supervisor_notes FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND author_supervisor_user_id = app_private.current_user_id()
    AND app_private.has_role('academic_supervisor', college_id)
    AND app_private.can_read_training(training_id));
CREATE POLICY supervisor_notes_update_author ON public.supervisor_notes FOR UPDATE TO app_runtime
  USING (author_supervisor_user_id = app_private.current_user_id()
    AND app_private.has_role('academic_supervisor', college_id)
    AND app_private.can_read_training(training_id))
  WITH CHECK (author_supervisor_user_id = app_private.current_user_id());
CREATE POLICY note_revisions_read ON public.supervisor_note_revisions FOR SELECT TO app_runtime
  USING (app_private.is_college_admin(college_id)
    OR changed_by_user_id = app_private.current_user_id()
    OR EXISTS (SELECT 1 FROM public.supervisor_notes n WHERE n.id = note_id
      AND n.author_supervisor_user_id = app_private.current_user_id()));
CREATE POLICY note_revisions_insert_author ON public.supervisor_note_revisions FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND changed_by_user_id = app_private.current_user_id());

-- Final evaluation: company authoring, read-only to student/supervisor/college after submission.
CREATE POLICY evaluations_read_related ON public.final_evaluations FOR SELECT TO app_runtime
  USING (app_private.can_read_evaluation(id));
CREATE POLICY evaluations_insert_company ON public.final_evaluations FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND app_private.is_company_for_training(training_id)
    AND status IN ('draft','submitted'));
CREATE POLICY evaluations_update_company_draft ON public.final_evaluations FOR UPDATE TO app_runtime
  USING (status = 'draft' AND app_private.is_company_for_training(training_id))
  WITH CHECK (app_private.is_company_for_training(training_id) AND status IN ('draft','submitted'));
CREATE POLICY evaluation_items_read_related ON public.evaluation_items FOR SELECT TO app_runtime
  USING (app_private.can_read_evaluation(evaluation_id));
CREATE POLICY evaluation_items_insert_company ON public.evaluation_items FOR INSERT TO app_runtime
  WITH CHECK (EXISTS (SELECT 1 FROM public.final_evaluations e WHERE e.id = evaluation_id
    AND e.status = 'draft' AND app_private.is_company_for_training(e.training_id)));
CREATE POLICY evaluation_items_update_company ON public.evaluation_items FOR UPDATE TO app_runtime
  USING (EXISTS (SELECT 1 FROM public.final_evaluations e WHERE e.id = evaluation_id
    AND e.status = 'draft' AND app_private.is_company_for_training(e.training_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM public.final_evaluations e WHERE e.id = evaluation_id
    AND e.status = 'draft' AND app_private.is_company_for_training(e.training_id)));
CREATE POLICY evaluation_items_delete_company ON public.evaluation_items FOR DELETE TO app_runtime
  USING (EXISTS (SELECT 1 FROM public.final_evaluations e WHERE e.id = evaluation_id
    AND e.status = 'draft' AND app_private.is_company_for_training(e.training_id)));

-- Direct messages: only participants; college admin requires an active case and an audit record.
CREATE POLICY conversations_read_related ON public.conversations FOR SELECT TO app_runtime
  USING (app_private.can_read_conversation(id));
CREATE POLICY conversations_insert_training_party ON public.conversations FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.can_read_training(training_id)
    AND NOT app_private.is_college_admin(college_id));
CREATE POLICY participants_read_related ON public.conversation_participants FOR SELECT TO app_runtime
  USING (user_id = app_private.current_user_id()
    OR app_private.can_read_conversation(conversation_id));
CREATE POLICY participants_insert_self ON public.conversation_participants FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND user_id = app_private.current_user_id()
    AND EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = conversation_id
      AND app_private.can_read_training(c.training_id)));

CREATE POLICY messages_read_related ON public.messages FOR SELECT TO app_runtime
  USING (app_private.can_read_conversation(conversation_id));
CREATE POLICY messages_insert_participant ON public.messages FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND sender_user_id = app_private.current_user_id()
    AND EXISTS (SELECT 1 FROM public.conversation_participants cp
      WHERE cp.conversation_id = conversation_id AND cp.user_id = app_private.current_user_id()));

-- Formal reports and requests.
CREATE POLICY disputes_read_related ON public.dispute_reports FOR SELECT TO app_runtime
  USING (app_private.is_college_admin(college_id)
    OR reported_by_user_id = app_private.current_user_id()
    OR app_private.can_read_training(training_id));
CREATE POLICY disputes_insert_party ON public.dispute_reports FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND reported_by_user_id = app_private.current_user_id()
    AND app_private.can_read_training(training_id)
    AND NOT app_private.is_college_admin(college_id));
CREATE POLICY disputes_update_college_admin ON public.dispute_reports FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));

CREATE POLICY official_requests_read_related ON public.official_requests FOR SELECT TO app_runtime
  USING (requester_user_id = app_private.current_user_id()
    OR app_private.is_college_admin(college_id)
    OR app_private.can_read_training(training_id));
CREATE POLICY official_requests_insert_party ON public.official_requests FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND requester_user_id = app_private.current_user_id()
    AND app_private.can_read_training(training_id));
CREATE POLICY official_requests_update_college_admin ON public.official_requests FOR UPDATE TO app_runtime
  USING (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));

CREATE POLICY official_request_files_read ON public.official_request_files FOR SELECT TO app_runtime
  USING (EXISTS (SELECT 1 FROM public.official_requests r WHERE r.id = request_id
    AND (r.requester_user_id = app_private.current_user_id()
      OR app_private.is_college_admin(r.college_id)
      OR app_private.can_read_training(r.training_id))));
CREATE POLICY official_request_files_insert_requester ON public.official_request_files FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id()
    AND EXISTS (SELECT 1 FROM public.official_requests r WHERE r.id = request_id
      AND r.requester_user_id = app_private.current_user_id() AND r.college_id = college_id));

-- Notifications are private to the recipient. Only the recipient may update read_at through the API.
CREATE POLICY notifications_read_recipient ON public.notifications FOR SELECT TO app_runtime
  USING (college_id = app_private.current_college_id() AND recipient_user_id = app_private.current_user_id());
CREATE POLICY notifications_insert_college_admin ON public.notifications FOR INSERT TO app_runtime
  WITH CHECK (college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id));
CREATE POLICY notifications_update_recipient ON public.notifications FOR UPDATE TO app_runtime
  USING (recipient_user_id = app_private.current_user_id() AND college_id = app_private.current_college_id())
  WITH CHECK (recipient_user_id = app_private.current_user_id() AND college_id = app_private.current_college_id());

-- Audit log: read-only to the college administrator; exceptional access writes through a checked function.
CREATE POLICY audit_logs_read_college_admin ON public.audit_logs FOR SELECT TO app_runtime
  USING ((college_id = app_private.current_college_id() AND app_private.is_college_admin(college_id))
    OR (college_id IS NULL AND app_private.is_system_admin()));

-- Runtime table privileges. RLS remains the row-level enforcement layer.
GRANT USAGE ON SCHEMA public TO app_runtime;
GRANT SELECT ON public.roles, public.evaluation_criteria TO app_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.colleges, public.users, public.user_roles, public.specialties,
  public.specialty_training_requirements, public.training_opportunities,
  public.opportunity_specialties, public.training_sites, public.opportunity_sites,
  public.file_assets, public.training_applications, public.application_status_history,
  public.trainings, public.training_supervisor_assignments, public.attendance_records,
  public.attendance_change_requests, public.supervisor_notes, public.supervisor_note_revisions,
  public.final_evaluations, public.evaluation_items, public.conversations,
  public.conversation_participants, public.messages, public.dispute_reports,
  public.official_requests, public.official_request_files, public.notifications,
  public.audit_logs TO app_runtime;
REVOKE INSERT, UPDATE, DELETE ON public.roles, public.evaluation_criteria FROM app_runtime;
REVOKE INSERT, UPDATE, DELETE ON public.audit_logs FROM app_runtime;
GRANT EXECUTE ON FUNCTION app_private.log_exceptional_conversation_access(uuid, text, uuid, text) TO app_runtime;

COMMIT;
