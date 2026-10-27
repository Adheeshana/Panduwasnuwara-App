-- Fixes from the review of 00001–00008 (SRS §5, §6, §9–§12, §14).
-- Main points:
--   * search_listings could not find PostGIS (search_path = public only).
--   * Clients could write privileged columns directly (listing status / blue tick,
--     notice status, job status, review hidden flag, verification decisions,
--     subscription status for Approval/Code positions, self-inserted profile flags).
--   * Contacts and reviews could be inserted without the daily limit / confirmed service.
--   * Removing a notice reaction needed SELECT on notice_reactions, which is not granted.
--   * Temporary blocks (blocked_until) were ignored when hiding listings.
--   * officer_positions.sub_code was readable by every user.
--   * notices.author_id ON DELETE RESTRICT would block account deletion.
--   * Chats had no Block (§12); listings had no way to request a new category (§6.2).
--
-- Guard triggers below are SECURITY INVOKER and only restrict direct client calls
-- (current_user authenticated/anon). Writes made inside SECURITY DEFINER functions run
-- as the function owner and are trusted.

SET search_path = public, extensions, pg_catalog;

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_client_call()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT current_user IN ('authenticated', 'anon');
$$;

-- is_blocked = permanent block; blocked_until = temporary block (§14).
CREATE OR REPLACE FUNCTION public.profile_is_blocked(
  p_is_blocked boolean,
  p_blocked_until timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_is_blocked OR (p_blocked_until IS NOT NULL AND p_blocked_until > now());
$$;

-- Phone of the signed-in auth user (verified by OTP). Returns only the caller's own phone.
CREATE OR REPLACE FUNCTION public.my_auth_phone()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT u.phone
  FROM auth.users AS u
  WHERE u.id = auth.uid();
$$;

-- Rejects client changes to the listed columns. TG_ARGV[0] is 'all' (applies to every
-- client) or 'non_office' (office staff may change them); the rest are column names.
CREATE OR REPLACE FUNCTION public.lock_client_columns()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_old jsonb := to_jsonb(OLD);
  v_new jsonb := to_jsonb(NEW);
  v_col text;
  v_i integer;
BEGIN
  IF NOT public.is_client_call() THEN
    RETURN NEW;
  END IF;

  IF TG_ARGV[0] = 'non_office' AND public.is_office() THEN
    RETURN NEW;
  END IF;

  FOR v_i IN 1 .. TG_NARGS - 1 LOOP
    v_col := TG_ARGV[v_i];
    IF v_old -> v_col IS DISTINCT FROM v_new -> v_col THEN
      RAISE EXCEPTION 'column_not_editable: %', v_col;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

-- These read only rows the caller can already see; they do not need to bypass RLS.
CREATE OR REPLACE FUNCTION public.app_setting(p_key text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT s.value
  FROM public.app_settings AS s
  WHERE s.key = p_key;
$$;

CREATE OR REPLACE FUNCTION public.app_setting_int(p_key text)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT (s.value #>> '{}')::integer
  FROM public.app_settings AS s
  WHERE s.key = p_key;
$$;

CREATE OR REPLACE FUNCTION public.app_setting_bool(p_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT (s.value #>> '{}')::boolean
  FROM public.app_settings AS s
  WHERE s.key = p_key;
$$;

CREATE OR REPLACE FUNCTION public.contact_count_today()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.contacts AS c
  WHERE c.user_id = auth.uid()
    AND c.contact_date = public.today_colombo();
$$;

CREATE OR REPLACE FUNCTION public.provider_nic_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.id = auth.uid()
      AND p.verification_status IN ('approved', 'verified')
  );
$$;

-- ---------------------------------------------------------------------------
-- Blocked providers: honour temporary blocks too (§8, §14)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_live_listing(p_listing_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.listings AS l
    JOIN public.profiles AS pf
      ON pf.id = l.provider_id
    WHERE l.id = p_listing_id
      AND l.status = 'approved'
      AND l.is_on
      AND NOT public.profile_is_blocked(pf.is_blocked, pf.blocked_until)
      AND pf.deleted_at IS NULL
  );
$$;

CREATE OR REPLACE VIEW public.listings_browse
WITH (security_barrier = true) AS
SELECT
  l.id,
  l.provider_id,
  l.category_id,
  l.title,
  l.description,
  CASE WHEN l.show_location THEN l.location ELSE NULL END AS location,
  l.show_location,
  l.village_id,
  l.ds_division_id,
  l.price_frequency,
  l.working_days,
  l.open_time,
  l.close_time,
  l.is_on,
  l.blue_tick,
  l.view_count,
  l.service_count,
  l.review_count,
  l.rating_sum,
  l.created_at,
  COALESCE(pr.business_name, pf.full_name) AS display_name,
  v.name_si AS village_name_si,
  v.name_en AS village_name_en
FROM public.listings AS l
JOIN public.providers AS pr ON pr.user_id = l.provider_id
JOIN public.profiles AS pf ON pf.id = pr.user_id
JOIN public.villages AS v ON v.id = l.village_id
WHERE l.status = 'approved'
  AND l.is_on
  AND NOT public.profile_is_blocked(pf.is_blocked, pf.blocked_until)
  AND pf.deleted_at IS NULL
  AND public.is_not_blocked();

-- Same body as 00008 except: search_path includes extensions (ST_Distance lives there,
-- so the old version failed at runtime) and temporary blocks are honoured.
CREATE OR REPLACE FUNCTION public.search_listings(
  p_query text DEFAULT NULL,
  p_origin geography DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_max_distance_m double precision DEFAULT NULL,
  p_open_now boolean DEFAULT false,
  p_sort text DEFAULT 'nearest'
)
RETURNS TABLE (
  listing_id uuid,
  display_name text,
  title text,
  village_name_si text,
  village_name_en text,
  distance_m double precision,
  is_open boolean,
  blue_tick boolean,
  rating_sum integer,
  review_count integer,
  matched_price_name text,
  matched_price numeric,
  matched_price_kind public.price_kind,
  show_location boolean,
  location geography
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_origin geography;
  v_query text;
BEGIN
  IF NOT public.is_not_blocked() THEN
    RETURN;
  END IF;

  v_origin := p_origin;
  IF v_origin IS NULL THEN
    SELECT v.center
    INTO v_origin
    FROM public.profiles AS p
    JOIN public.villages AS v ON v.id = p.village_id
    WHERE p.id = auth.uid();
  END IF;

  v_query := nullif(btrim(coalesce(p_query, '')), '');

  RETURN QUERY
  WITH live AS (
    SELECT
      l.*,
      COALESCE(pr.business_name, pf.full_name) AS disp,
      v.name_si AS v_si,
      v.name_en AS v_en,
      CASE
        WHEN l.show_location THEN l.location
        ELSE v.center
      END AS effective_location
    FROM public.listings AS l
    JOIN public.providers AS pr ON pr.user_id = l.provider_id
    JOIN public.profiles AS pf ON pf.id = pr.user_id
    JOIN public.villages AS v ON v.id = l.village_id
    WHERE l.status = 'approved'
      AND l.is_on
      AND NOT public.profile_is_blocked(pf.is_blocked, pf.blocked_until)
      AND pf.deleted_at IS NULL
      AND (p_category_id IS NULL OR l.category_id = p_category_id)
      AND (
        v_query IS NULL
        OR l.search_document &@~ v_query
      )
  ),
  priced AS (
    SELECT
      live.*,
      ST_Distance(live.effective_location, v_origin) AS dist,
      (
        live.is_on
        AND live.open_time IS NOT NULL
        AND live.close_time IS NOT NULL
        AND EXTRACT(ISODOW FROM timezone('Asia/Colombo', now()))::smallint
          = ANY (live.working_days)
        AND (timezone('Asia/Colombo', now()))::time >= live.open_time
        AND (timezone('Asia/Colombo', now()))::time < live.close_time
      ) AS open_now,
      (
        SELECT pi.name
        FROM public.price_items AS pi
        WHERE pi.listing_id = live.id
          AND v_query IS NOT NULL
          AND pi.name &@~ v_query
        ORDER BY pi.price DESC
        LIMIT 1
      ) AS match_name,
      (
        SELECT pi.price
        FROM public.price_items AS pi
        WHERE pi.listing_id = live.id
          AND v_query IS NOT NULL
          AND pi.name &@~ v_query
        ORDER BY pi.price DESC
        LIMIT 1
      ) AS match_price,
      (
        SELECT pi.kind
        FROM public.price_items AS pi
        WHERE pi.listing_id = live.id
          AND v_query IS NOT NULL
          AND pi.name &@~ v_query
        ORDER BY pi.price DESC
        LIMIT 1
      ) AS match_kind,
      (
        SELECT max(pi.price)
        FROM public.price_items AS pi
        WHERE pi.listing_id = live.id
          AND pi.kind = 'we_buy'
      ) AS max_buy
    FROM live
  )
  SELECT
    priced.id,
    priced.disp,
    priced.title,
    priced.v_si,
    priced.v_en,
    priced.dist,
    priced.open_now,
    priced.blue_tick,
    priced.rating_sum,
    priced.review_count,
    priced.match_name,
    priced.match_price,
    priced.match_kind,
    priced.show_location,
    CASE WHEN priced.show_location THEN priced.location ELSE NULL END
  FROM priced
  WHERE (p_max_distance_m IS NULL OR priced.dist <= p_max_distance_m)
    AND (NOT p_open_now OR priced.open_now)
  ORDER BY
    CASE WHEN p_sort = 'highest_buy_price' THEN priced.max_buy END DESC NULLS LAST,
    priced.dist ASC NULLS LAST;
END;
$$;

-- ---------------------------------------------------------------------------
-- profiles: privileged columns (§5.1, §14)
-- ---------------------------------------------------------------------------

-- Age + blocked-phone checks. The phone check now runs only when the phone is set or
-- changed; before, it also fired when the office set is_blocked after inserting the
-- block row, so blocking a user failed.
CREATE OR REPLACE FUNCTION public.profiles_before_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_age_at_least_16(NEW.birth_date) THEN
    RAISE EXCEPTION 'must_be_16_or_older';
  END IF;

  IF (TG_OP = 'INSERT' OR NEW.phone IS DISTINCT FROM OLD.phone)
     AND EXISTS (
       SELECT 1
       FROM public.blocks AS b
       WHERE b.phone = NEW.phone
         AND (b.until IS NULL OR b.until > now())
     ) THEN
    RAISE EXCEPTION 'phone_blocked';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.profiles_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_level public.staff_level;
BEGIN
  IF NOT public.is_client_call() THEN
    RETURN NEW;
  END IF;

  v_level := public.current_staff_level();

  IF v_level IS NULL
     AND (TG_OP = 'INSERT' OR NEW.village_id IS DISTINCT FROM OLD.village_id)
     AND NOT EXISTS (
       SELECT 1
       FROM public.villages AS v
       WHERE v.id = NEW.village_id
         AND v.active
     ) THEN
    RAISE EXCEPTION 'village_not_available';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF v_level IS NULL THEN
      -- Self sign-up: the phone is the one verified by OTP, never client input.
      NEW.phone := public.my_auth_phone();
      IF NEW.phone IS NULL THEN
        RAISE EXCEPTION 'phone_not_verified';
      END IF;
    END IF;
    NEW.verification_status := 'none';
    NEW.is_blocked := false;
    NEW.blocked_until := NULL;
    NEW.deleted_at := NULL;
    RETURN NEW;
  END IF;

  NEW.id := OLD.id;
  NEW.created_at := OLD.created_at;
  -- Changes only through verification_requests (§5.2).
  NEW.verification_status := OLD.verification_status;

  IF v_level IS NULL THEN
    NEW.phone := OLD.phone;
    NEW.birth_date := OLD.birth_date;
    NEW.gender := OLD.gender;
    NEW.is_blocked := OLD.is_blocked;
    NEW.blocked_until := OLD.blocked_until;
    NEW.deleted_at := OLD.deleted_at;
    RETURN NEW;
  END IF;

  -- Blocking and deleting accounts: owner and super admin only (§3, §14).
  IF NEW.is_blocked IS DISTINCT FROM OLD.is_blocked
     OR NEW.blocked_until IS DISTINCT FROM OLD.blocked_until
     OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN
    IF v_level NOT IN ('owner', 'super_admin') THEN
      RAISE EXCEPTION 'only_owner_or_super_admin';
    END IF;
  END IF;

  IF OLD.id = auth.uid()
     AND (
       NEW.is_blocked IS DISTINCT FROM OLD.is_blocked
       OR NEW.blocked_until IS DISTINCT FROM OLD.blocked_until
     ) THEN
    RAISE EXCEPTION 'cannot_block_self';
  END IF;

  RETURN NEW;
END;
$$;

-- Named so it fires before profiles_before_write (triggers fire in name order).
CREATE TRIGGER profiles_00_guard
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.profiles_guard();

-- ---------------------------------------------------------------------------
-- verification_requests: decisions (§5.2)
-- Users no longer insert requests directly; submit_nic() (00010) creates them.
-- ---------------------------------------------------------------------------

DROP POLICY verification_requests_insert_own ON public.verification_requests;

CREATE OR REPLACE FUNCTION public.verification_requests_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_level public.staff_level;
  v_is_gn boolean;
  v_status public.verification_status;
  v_reason text;
BEGIN
  IF NOT public.is_client_call() THEN
    RETURN NEW;
  END IF;

  v_level := public.current_staff_level();
  v_is_gn := public.can_gn_read_nic(OLD.user_id);
  v_status := NEW.status;
  v_reason := NEW.reason;
  NEW := OLD;

  IF OLD.user_id = auth.uid() THEN
    RAISE EXCEPTION 'cannot_decide_own_request';
  END IF;

  IF v_status = 'rejected' THEN
    -- A rejection after approval is open item SRS §20.1; not allowed until decided.
    IF OLD.status <> 'pending' THEN
      RAISE EXCEPTION 'request_already_decided';
    END IF;
    IF nullif(btrim(coalesce(v_reason, '')), '') IS NULL THEN
      RAISE EXCEPTION 'rejection_reason_required';
    END IF;
    NEW.status := 'rejected';
    NEW.reason := v_reason;
  ELSIF v_status IN ('approved', 'verified') THEN
    -- GN, super admin and owner give Verified; admin gives Approved.
    IF v_level IN ('owner', 'super_admin') OR (v_level IS NULL AND v_is_gn) THEN
      v_status := 'verified';
    ELSE
      v_status := 'approved';
    END IF;

    -- First decision applies; a later GN / super admin approval upgrades approved → verified.
    IF NOT (
      OLD.status = 'pending'
      OR (OLD.status = 'approved' AND v_status = 'verified')
    ) THEN
      RAISE EXCEPTION 'request_already_decided';
    END IF;
    NEW.status := v_status;
    NEW.reason := NULL;
  ELSE
    RAISE EXCEPTION 'invalid_decision';
  END IF;

  NEW.decided_by := auth.uid();
  NEW.decider_role := CASE WHEN v_level IS NULL THEN 'gn' ELSE v_level::text END;
  NEW.decided_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER verification_requests_00_guard
  BEFORE UPDATE ON public.verification_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.verification_requests_guard();

-- Copies the decision to the profile and writes the audit log (§5.2, §14).
CREATE OR REPLACE FUNCTION public.verification_requests_after_decision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE public.profiles
    SET verification_status = NEW.status
    WHERE id = NEW.user_id;

    INSERT INTO public.audit_log (action, actor_id, subject_type, subject_id, payload)
    VALUES (
      'verification_' || NEW.status::text,
      NEW.decided_by,
      'verification_request',
      NEW.id,
      jsonb_build_object(
        'user_id', NEW.user_id,
        'old_status', OLD.status,
        'new_status', NEW.status,
        'decider_role', NEW.decider_role,
        'reason', NEW.reason
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER verification_requests_after_decision
  AFTER UPDATE ON public.verification_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.verification_requests_after_decision();

-- ---------------------------------------------------------------------------
-- listings: category requests (§6.2) and approval / blue tick rules (§6.6)
-- ---------------------------------------------------------------------------

-- "If not found, provider types a name; super admin creates the category and assigns the listing."
ALTER TABLE public.listings ADD COLUMN requested_category_name text;
ALTER TABLE public.listings ALTER COLUMN category_id DROP NOT NULL;
ALTER TABLE public.listings
  ADD CONSTRAINT listings_category_or_request_chk CHECK (
    category_id IS NOT NULL
    OR nullif(btrim(requested_category_name), '') IS NOT NULL
  );
ALTER TABLE public.listings
  ADD CONSTRAINT listings_approved_has_category_chk CHECK (
    status <> 'approved' OR category_id IS NOT NULL
  );

CREATE OR REPLACE FUNCTION public.listings_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, extensions
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_level public.staff_level;
  v_status public.listing_status;
  v_reason public.listing_rejection_reason;
  v_note text;
  v_tick boolean;
BEGIN
  IF NOT public.is_client_call() THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Every new listing waits for approval, without tick or counters.
    NEW.status := 'pending';
    NEW.approved_by := NULL;
    NEW.approver_role := NULL;
    NEW.rejection_reason := NULL;
    NEW.rejection_note := NULL;
    NEW.blue_tick := false;
    NEW.blue_tick_by := NULL;
    NEW.view_count := 0;
    NEW.service_count := 0;
    NEW.review_count := 0;
    NEW.rating_sum := 0;
    RETURN NEW;
  END IF;

  v_level := public.current_staff_level();
  v_status := NEW.status;
  v_reason := NEW.rejection_reason;
  v_note := NEW.rejection_note;
  v_tick := NEW.blue_tick;

  -- Never written by clients.
  NEW.id := OLD.id;
  NEW.provider_id := OLD.provider_id;
  NEW.view_count := OLD.view_count;
  NEW.service_count := OLD.service_count;
  NEW.review_count := OLD.review_count;
  NEW.rating_sum := OLD.rating_sum;
  NEW.search_document := OLD.search_document;
  NEW.created_at := OLD.created_at;
  -- Decision columns are set below from the caller's role.
  NEW.status := OLD.status;
  NEW.approved_by := OLD.approved_by;
  NEW.approver_role := OLD.approver_role;
  NEW.rejection_reason := OLD.rejection_reason;
  NEW.rejection_note := OLD.rejection_note;
  NEW.blue_tick := OLD.blue_tick;
  NEW.blue_tick_by := OLD.blue_tick_by;

  IF v_level IS NOT NULL THEN
    -- Office. Moving a listing to another category needs no re-approval.
    IF v_tick IS DISTINCT FROM OLD.blue_tick THEN
      IF v_level = 'admin' THEN
        RAISE EXCEPTION 'admin_cannot_set_blue_tick';
      END IF;
      NEW.blue_tick := v_tick;
      NEW.blue_tick_by := CASE WHEN v_tick THEN v_uid END;
    END IF;

    IF v_status IS DISTINCT FROM OLD.status THEN
      IF v_status = 'approved' AND OLD.status = 'pending' THEN
        NULL;
      ELSIF v_status = 'approved'
            AND OLD.status = 'rejected'
            AND OLD.approver_role = 'officer'
            AND v_level IN ('owner', 'super_admin')
            AND coalesce(public.app_setting_bool('officer_override_enabled'), false) THEN
        NULL; -- officer-rejection override, logged by listings_audit
      ELSIF v_status = 'rejected' AND OLD.status = 'pending' THEN
        IF v_reason IS NULL THEN
          RAISE EXCEPTION 'rejection_reason_required';
        END IF;
      ELSE
        RAISE EXCEPTION 'listing_already_decided';
      END IF;

      NEW.status := v_status;
      NEW.approved_by := v_uid;
      NEW.approver_role := v_level::text;
      NEW.rejection_reason := CASE WHEN v_status = 'rejected' THEN v_reason END;
      NEW.rejection_note := CASE WHEN v_status = 'rejected' THEN v_note END;
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.provider_id IS DISTINCT FROM v_uid AND public.can_approve_listing(OLD.id) THEN
    -- Category officer: approve (always with blue tick) or reject. Nothing else changes.
    NEW := OLD;
    IF v_status = 'approved' THEN
      IF OLD.status = 'rejected' THEN
        RAISE EXCEPTION 'listing_already_decided';
      END IF;
      IF OLD.status = 'pending' THEN
        NEW.status := 'approved';
        NEW.approved_by := v_uid;
        NEW.approver_role := 'officer';
        NEW.rejection_reason := NULL;
        NEW.rejection_note := NULL;
      END IF;
      -- Approved without a tick earlier: the officer approval adds it.
      IF NOT OLD.blue_tick THEN
        NEW.blue_tick := true;
        NEW.blue_tick_by := v_uid;
      END IF;
    ELSIF v_status = 'rejected' THEN
      IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'listing_already_decided';
      END IF;
      IF v_reason IS NULL THEN
        RAISE EXCEPTION 'rejection_reason_required';
      END IF;
      NEW.status := 'rejected';
      NEW.approved_by := v_uid;
      NEW.approver_role := 'officer';
      NEW.rejection_reason := v_reason;
      NEW.rejection_note := v_note;
    ELSIF v_status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'officer_can_only_approve_or_reject';
    END IF;
    RETURN NEW;
  END IF;

  -- Provider (RLS limits this to their own listings). A change of category, name or
  -- location needs approval again; a rejected listing can be resubmitted.
  IF NEW.category_id IS DISTINCT FROM OLD.category_id
     OR NEW.requested_category_name IS DISTINCT FROM OLD.requested_category_name
     OR NEW.title IS DISTINCT FROM OLD.title
     OR NEW.village_id IS DISTINCT FROM OLD.village_id
     OR ST_AsBinary(NEW.location) IS DISTINCT FROM ST_AsBinary(OLD.location)
     OR (OLD.status = 'rejected' AND v_status = 'pending') THEN
    NEW.status := 'pending';
    NEW.approved_by := NULL;
    NEW.approver_role := NULL;
    NEW.rejection_reason := NULL;
    NEW.rejection_note := NULL;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER listings_00_guard
  BEFORE INSERT OR UPDATE ON public.listings
  FOR EACH ROW
  EXECUTE FUNCTION public.listings_guard();

CREATE OR REPLACE FUNCTION public.listings_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status OR NEW.blue_tick IS DISTINCT FROM OLD.blue_tick THEN
    INSERT INTO public.audit_log (action, actor_id, subject_type, subject_id, payload)
    VALUES (
      CASE
        WHEN OLD.status = 'rejected'
             AND NEW.status = 'approved'
             AND OLD.approver_role = 'officer'
             AND NEW.approver_role IN ('owner', 'super_admin')
          THEN 'listing_officer_override'
        WHEN NEW.status IS DISTINCT FROM OLD.status
          THEN 'listing_' || NEW.status::text
        WHEN NEW.blue_tick
          THEN 'listing_blue_tick_added'
        ELSE 'listing_blue_tick_removed'
      END,
      auth.uid(),
      'listing',
      NEW.id,
      jsonb_build_object(
        'old_status', OLD.status,
        'new_status', NEW.status,
        'old_blue_tick', OLD.blue_tick,
        'new_blue_tick', NEW.blue_tick,
        'approver_role', NEW.approver_role,
        'rejection_reason', NEW.rejection_reason
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER listings_audit
  AFTER UPDATE ON public.listings
  FOR EACH ROW
  EXECUTE FUNCTION public.listings_audit();

-- Up to N photos per listing (§6.2), N from app_settings.
CREATE OR REPLACE FUNCTION public.listing_photo_count(p_listing_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.listing_photos AS lp
  WHERE lp.listing_id = p_listing_id;
$$;

DROP POLICY listing_photos_insert_own ON public.listing_photos;
DROP POLICY listing_photos_insert_office ON public.listing_photos;

-- The listing owner may add photos, up to listing_photos_max.
CREATE POLICY listing_photos_insert_own ON public.listing_photos
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND public.is_listing_provider(listing_id)
    AND public.listing_photo_count(listing_id) < public.app_setting_int('listing_photos_max')
  );

-- Office may add photos (admin-managed providers), up to listing_photos_max.
CREATE POLICY listing_photos_insert_office ON public.listing_photos
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND public.is_office()
    AND public.listing_photo_count(listing_id) < public.app_setting_int('listing_photos_max')
  );

CREATE TRIGGER listing_photos_lock_columns
  BEFORE UPDATE ON public.listing_photos
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_client_columns('all', 'listing_id');

-- ---------------------------------------------------------------------------
-- providers
-- ---------------------------------------------------------------------------

CREATE TRIGGER providers_lock_columns
  BEFORE UPDATE ON public.providers
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_client_columns('non_office', 'user_id', 'admin_managed');

-- ---------------------------------------------------------------------------
-- contacts: only through register_contact() (daily limit, live listing) (§11)
-- ---------------------------------------------------------------------------

DROP POLICY contacts_insert_own ON public.contacts;

CREATE OR REPLACE FUNCTION public.register_contact(p_listing_id uuid)
RETURNS TABLE (
  allowed boolean,
  already_contacted_today boolean,
  provider_phone text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exists boolean;
  v_phone text;
BEGIN
  IF NOT public.can_contact_listing(p_listing_id) THEN
    allowed := false;
    already_contacted_today := false;
    provider_phone := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.contacts AS c
    WHERE c.user_id = auth.uid()
      AND c.listing_id = p_listing_id
      AND c.contact_date = public.today_colombo()
  )
  INTO v_exists;

  IF NOT v_exists THEN
    INSERT INTO public.contacts (user_id, listing_id, contact_date)
    VALUES (auth.uid(), p_listing_id, public.today_colombo())
    ON CONFLICT (user_id, listing_id, contact_date) DO NOTHING;
  END IF;

  SELECT pf.phone
  INTO v_phone
  FROM public.listings AS l
  JOIN public.profiles AS pf ON pf.id = l.provider_id
  WHERE l.id = p_listing_id;

  allowed := true;
  already_contacted_today := v_exists;
  provider_phone := v_phone;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- service_claims (§11)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.service_claims_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT public.is_client_call() THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.status := 'pending';
    NEW.decided_at := NULL;
    NEW.decided_by := NULL;
    RETURN NEW;
  END IF;

  NEW.contact_id := OLD.contact_id;
  NEW.created_at := OLD.created_at;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    -- Provider answers once (Yes / No). Office may change it later (unlock after complaint).
    IF NOT public.is_office() AND (OLD.status <> 'pending' OR NEW.status = 'pending') THEN
      RAISE EXCEPTION 'claim_already_answered';
    END IF;
    NEW.decided_at := now();
    NEW.decided_by := auth.uid();
  ELSE
    NEW.decided_at := OLD.decided_at;
    NEW.decided_by := OLD.decided_by;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER service_claims_00_guard
  BEFORE INSERT OR UPDATE ON public.service_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.service_claims_guard();

-- ---------------------------------------------------------------------------
-- reviews: only after a confirmed service (§11)
-- ---------------------------------------------------------------------------

-- The 30-day interval is a rule in §11, not a setting (docs/QUESTIONS.md).
CREATE OR REPLACE FUNCTION public.can_review(
  p_listing_id uuid,
  p_provider_id uuid,
  p_service_claim_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_provider_id IS DISTINCT FROM auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.service_claims AS sc
      JOIN public.contacts AS c ON c.id = sc.contact_id
      JOIN public.listings AS l ON l.id = c.listing_id
      WHERE sc.id = p_service_claim_id
        AND sc.status = 'yes'
        AND c.user_id = auth.uid()
        AND c.listing_id = p_listing_id
        AND l.provider_id = p_provider_id
    )
    AND EXISTS (
      SELECT 1
      FROM public.profiles AS me
      WHERE me.id = auth.uid()
        AND me.created_at
          <= now() - make_interval(days => public.app_setting_int('review_min_account_days'))
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.reviews AS r
      WHERE r.user_id = auth.uid()
        AND r.provider_id = p_provider_id
        AND r.created_at > now() - interval '30 days'
    );
$$;

DROP POLICY reviews_insert_own ON public.reviews;

-- A user may review after the provider confirmed the service (§11 rules).
CREATE POLICY reviews_insert_own ON public.reviews
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND NOT hidden
    AND public.can_review(listing_id, provider_id, service_claim_id)
  );

CREATE TRIGGER reviews_lock_refs
  BEFORE UPDATE ON public.reviews
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_client_columns(
    'all', 'listing_id', 'provider_id', 'user_id', 'service_claim_id', 'created_at'
  );

CREATE TRIGGER reviews_lock_hidden
  BEFORE UPDATE ON public.reviews
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_client_columns('non_office', 'hidden');

-- ---------------------------------------------------------------------------
-- complaints, support
-- ---------------------------------------------------------------------------

CREATE TRIGGER complaints_lock_columns
  BEFORE UPDATE ON public.complaints
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_client_columns(
    'all', 'user_id', 'service_claim_id', 'listing_id', 'body'
  );

CREATE TRIGGER support_tickets_lock_columns
  BEFORE UPDATE ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_client_columns('all', 'user_id', 'kind', 'subject');

-- ---------------------------------------------------------------------------
-- jobs: users cannot approve their own job (§13)
-- ---------------------------------------------------------------------------

DROP POLICY jobs_insert_own ON public.jobs;
DROP POLICY jobs_update_own ON public.jobs;

-- NIC-approved/verified users may post jobs; every job starts pending.
CREATE POLICY jobs_insert_own ON public.jobs
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND public.provider_nic_ok()
    AND status = 'pending'
    AND approved_by IS NULL
  );

-- The author may edit a pending or rejected job; it stays / goes back to pending.
CREATE POLICY jobs_update_own ON public.jobs
  FOR UPDATE TO authenticated
  USING (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND status IN ('pending', 'rejected')
  )
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND status = 'pending'
    AND approved_by IS NULL
  );

CREATE TRIGGER jobs_lock_columns
  BEFORE UPDATE ON public.jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_client_columns('all', 'user_id');

-- ---------------------------------------------------------------------------
-- officer subscription codes: not readable by every user (§9.3)
-- ---------------------------------------------------------------------------

CREATE TABLE public.officer_position_codes (
  position_id uuid PRIMARY KEY REFERENCES public.officer_positions (id) ON DELETE CASCADE,
  code text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- No client policies: read / regenerate / subscribe through functions below.
ALTER TABLE public.officer_position_codes ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER officer_position_codes_set_updated_at
  BEFORE UPDATE ON public.officer_position_codes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.officer_position_codes (position_id, code)
SELECT op.id, op.sub_code
FROM public.officer_positions AS op
WHERE op.sub_code IS NOT NULL;

ALTER TABLE public.officer_positions DROP COLUMN sub_code;

CREATE OR REPLACE FUNCTION public.generate_position_code()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = public, extensions
AS $$
DECLARE
  v_code text;
BEGIN
  LOOP
    v_code := upper(encode(gen_random_bytes(4), 'hex'));
    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public.officer_position_codes AS c
      WHERE c.code = v_code
    );
  END LOOP;
  RETURN v_code;
END;
$$;

-- Code is auto-generated when a position is in (or switched to) Code mode.
CREATE OR REPLACE FUNCTION public.officer_positions_ensure_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.subscription_mode = 'code' THEN
    INSERT INTO public.officer_position_codes (position_id, code)
    VALUES (NEW.id, public.generate_position_code())
    ON CONFLICT (position_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER officer_positions_ensure_code
  AFTER INSERT OR UPDATE OF subscription_mode ON public.officer_positions
  FOR EACH ROW
  EXECUTE FUNCTION public.officer_positions_ensure_code();

INSERT INTO public.officer_position_codes (position_id, code)
SELECT op.id, public.generate_position_code()
FROM public.officer_positions AS op
WHERE op.subscription_mode = 'code'
ON CONFLICT (position_id) DO NOTHING;

-- The officer of the position or the office may read its code.
CREATE OR REPLACE FUNCTION public.get_position_code(p_position_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    public.is_not_blocked()
    AND (public.is_officer_of_position(p_position_id) OR public.is_office())
  ) THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  RETURN (
    SELECT c.code
    FROM public.officer_position_codes AS c
    WHERE c.position_id = p_position_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.regenerate_position_code(p_position_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text;
BEGIN
  IF NOT (
    public.is_not_blocked()
    AND (public.is_officer_of_position(p_position_id) OR public.is_office())
  ) THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.officer_positions AS op
    WHERE op.id = p_position_id
      AND op.subscription_mode = 'code'
  ) THEN
    RAISE EXCEPTION 'position_not_in_code_mode';
  END IF;

  v_code := public.generate_position_code();

  INSERT INTO public.officer_position_codes (position_id, code)
  VALUES (p_position_id, v_code)
  ON CONFLICT (position_id) DO UPDATE SET code = EXCLUDED.code;

  RETURN v_code;
END;
$$;

-- A user with the code subscribes to that position (Code mode, §9.3).
CREATE OR REPLACE FUNCTION public.subscribe_with_code(p_code text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_position_id uuid;
BEGIN
  IF NOT public.is_not_blocked()
     OR NOT EXISTS (SELECT 1 FROM public.profiles AS p WHERE p.id = auth.uid()) THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  SELECT op.id
  INTO v_position_id
  FROM public.officer_position_codes AS c
  JOIN public.officer_positions AS op ON op.id = c.position_id
  WHERE c.code = upper(btrim(coalesce(p_code, '')))
    AND op.active
    AND op.subscription_mode = 'code';

  IF v_position_id IS NULL THEN
    RAISE EXCEPTION 'invalid_code';
  END IF;

  INSERT INTO public.subscriptions (user_id, position_id, status)
  VALUES (auth.uid(), v_position_id, 'active')
  ON CONFLICT (user_id, position_id) DO UPDATE SET status = 'active';

  RETURN v_position_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- subscriptions: status must follow the position's mode (§9.3)
-- ---------------------------------------------------------------------------

DROP POLICY subscriptions_insert_own ON public.subscriptions;
DROP POLICY subscriptions_update_own ON public.subscriptions;
DROP POLICY subscriptions_update_officer ON public.subscriptions;

-- Auto / Open: subscribe at once. Approval: request (pending). Code: subscribe_with_code().
CREATE POLICY subscriptions_insert_own ON public.subscriptions
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.officer_positions AS op
      WHERE op.id = position_id
        AND op.active
        AND (
          (op.subscription_mode IN ('auto', 'open') AND status = 'active')
          OR (op.subscription_mode = 'approval' AND status = 'pending')
        )
    )
  );

-- Officers with approve-subscribers may approve or reject requests for their position.
CREATE POLICY subscriptions_update_officer ON public.subscriptions
  FOR UPDATE TO authenticated
  USING (
    public.is_not_blocked()
    AND public.is_officer_of_position(position_id)
    AND EXISTS (
      SELECT 1
      FROM public.officer_positions AS op
      WHERE op.id = position_id
        AND op.can_approve_subscribers
    )
  )
  WITH CHECK (
    public.is_not_blocked()
    AND public.is_officer_of_position(position_id)
    AND status IN ('active', 'rejected')
  );

CREATE TRIGGER subscriptions_lock_columns
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.lock_client_columns('all', 'user_id', 'position_id');

-- ---------------------------------------------------------------------------
-- notices: status comes from the position's approval settings (§9.2, §10)
-- ---------------------------------------------------------------------------

ALTER TABLE public.notices ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.notices DROP CONSTRAINT notices_author_id_fkey;
ALTER TABLE public.notices
  ADD CONSTRAINT notices_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES public.profiles (id) ON DELETE SET NULL;

-- Edit window of 1 hour is a rule in §10, not a setting (docs/QUESTIONS.md).
CREATE OR REPLACE FUNCTION public.notices_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_new public.notices;
  v_need_approval boolean;
  v_skip_urgent boolean;
  v_keep_sent_at timestamptz;
BEGIN
  IF NOT public.is_client_call() THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    NEW.id := OLD.id;
    NEW.position_id := OLD.position_id;
    NEW.author_id := OLD.author_id;
    NEW.created_at := OLD.created_at;
  END IF;

  IF TG_OP = 'UPDATE' AND public.is_office() THEN
    -- Office approves / rejects / cancels.
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NEW.status IN ('approved', 'sent') THEN
        NEW.approved_by := auth.uid();
      END IF;
      IF NEW.status = 'sent' AND NEW.sent_at IS NULL THEN
        NEW.sent_at := now();
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- Officer edits before approval, or within 1 hour of sending (then re-approval).
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      RAISE EXCEPTION 'officer_cannot_change_notice_status';
    END IF;
    IF NOT (
      OLD.status IN ('pending', 'rejected')
      OR (OLD.status IN ('approved', 'sent') AND OLD.sent_at > now() - interval '1 hour')
    ) THEN
      RAISE EXCEPTION 'notice_not_editable';
    END IF;

    v_new := NEW;
    NEW := OLD;
    NEW.body := v_new.body;
    NEW.attachments := v_new.attachments;
    NEW.urgent := v_new.urgent;
    NEW.is_public := v_new.is_public;
    NEW.audience_village_ids := v_new.audience_village_ids;
    NEW.audience_age_min := v_new.audience_age_min;
    NEW.audience_age_max := v_new.audience_age_max;
    NEW.audience_gender := v_new.audience_gender;

    IF OLD.status = 'sent' THEN
      v_keep_sent_at := OLD.sent_at;
    END IF;
  END IF;

  NEW.approved_by := NULL;

  SELECT op.notices_need_approval, op.urgent_can_skip_approval
  INTO v_need_approval, v_skip_urgent
  FROM public.officer_positions AS op
  WHERE op.id = NEW.position_id;

  IF NEW.urgent AND v_skip_urgent THEN
    NEW.status := 'sent';
    NEW.skipped_approval := true;
    NEW.sent_at := coalesce(v_keep_sent_at, now());
  ELSIF NOT v_need_approval THEN
    NEW.status := 'sent';
    NEW.skipped_approval := false;
    NEW.sent_at := coalesce(v_keep_sent_at, now());
  ELSE
    NEW.status := 'pending';
    NEW.skipped_approval := false;
    NEW.sent_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER notices_00_guard
  BEFORE INSERT OR UPDATE ON public.notices
  FOR EACH ROW
  EXECUTE FUNCTION public.notices_guard();

-- Logs notice decisions and urgent notices sent without approval (§14).
CREATE OR REPLACE FUNCTION public.notices_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.skipped_approval
     AND NEW.status = 'sent'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'sent') THEN
    INSERT INTO public.audit_log (action, actor_id, subject_type, subject_id, payload)
    VALUES (
      'notice_sent_without_approval',
      auth.uid(),
      'notice',
      NEW.id,
      jsonb_build_object('position_id', NEW.position_id)
    );
  ELSIF TG_OP = 'UPDATE'
        AND NEW.status IS DISTINCT FROM OLD.status
        AND NEW.status IN ('approved', 'sent', 'rejected', 'cancelled') THEN
    INSERT INTO public.audit_log (action, actor_id, subject_type, subject_id, payload)
    VALUES (
      'notice_' || NEW.status::text,
      auth.uid(),
      'notice',
      NEW.id,
      jsonb_build_object('position_id', NEW.position_id, 'old_status', OLD.status)
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER notices_audit
  AFTER INSERT OR UPDATE ON public.notices
  FOR EACH ROW
  EXECUTE FUNCTION public.notices_audit();

DROP POLICY notices_delete_officer ON public.notices;

-- The officer may delete unsent notices, or sent ones within 1 hour (§10).
CREATE POLICY notices_delete_officer ON public.notices
  FOR DELETE TO authenticated
  USING (
    public.is_not_blocked()
    AND public.is_officer_of_position(position_id)
    AND (
      status IN ('pending', 'rejected')
      OR (status IN ('approved', 'sent') AND sent_at > now() - interval '1 hour')
    )
  );

-- ---------------------------------------------------------------------------
-- notice_reactions: only through functions; nobody reads rows (§10)
-- (DELETE ... WHERE needs SELECT on the table, which is deliberately not granted.)
-- ---------------------------------------------------------------------------

DROP POLICY notice_reactions_insert_own ON public.notice_reactions;
DROP POLICY notice_reactions_delete_own ON public.notice_reactions;

CREATE OR REPLACE FUNCTION public.react_to_notice(p_notice_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (public.is_not_blocked() AND public.notice_visible_to_me(p_notice_id)) THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  INSERT INTO public.notice_reactions (notice_id, user_id)
  VALUES (p_notice_id, auth.uid())
  ON CONFLICT (notice_id, user_id) DO NOTHING;

  RETURN public.notice_reaction_count(p_notice_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.unreact_notice(p_notice_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_not_blocked() THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  DELETE FROM public.notice_reactions
  WHERE notice_id = p_notice_id
    AND user_id = auth.uid();

  RETURN public.notice_reaction_count(p_notice_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- chats: Block button (§12); counsellor side only while the position is active with Chat on
-- ---------------------------------------------------------------------------

ALTER TABLE public.chats
  ADD COLUMN blocked_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  ADD COLUMN blocked_at timestamptz;

CREATE OR REPLACE FUNCTION public.is_chat_participant(p_chat_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chats AS c
    JOIN public.officer_positions AS op
      ON op.id = c.position_id
    WHERE c.id = p_chat_id
      AND (
        c.user_id = auth.uid()
        OR (op.person_user_id = auth.uid() AND op.active AND op.can_chat)
      )
  );
$$;

-- A participant may block the chat (and the person who blocked may unblock).
CREATE POLICY chats_update_participant ON public.chats
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_chat_participant(id))
  WITH CHECK (
    public.is_not_blocked()
    AND public.is_chat_participant(id)
    AND (blocked_by IS NULL OR blocked_by = auth.uid())
  );

CREATE OR REPLACE FUNCTION public.chats_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT public.is_client_call() THEN
    RETURN NEW;
  END IF;

  NEW.id := OLD.id;
  NEW.user_id := OLD.user_id;
  NEW.position_id := OLD.position_id;
  NEW.created_at := OLD.created_at;

  IF NEW.blocked_by IS DISTINCT FROM OLD.blocked_by THEN
    IF OLD.blocked_by IS NOT NULL AND OLD.blocked_by <> auth.uid() THEN
      RAISE EXCEPTION 'blocked_by_other_party';
    END IF;
    NEW.blocked_at := CASE WHEN NEW.blocked_by IS NULL THEN NULL ELSE now() END;
  ELSE
    NEW.blocked_at := OLD.blocked_at;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER chats_00_guard
  BEFORE UPDATE ON public.chats
  FOR EACH ROW
  EXECUTE FUNCTION public.chats_guard();

DROP POLICY chat_messages_insert_participant ON public.chat_messages;

-- A participant may send a message as themselves while the chat is not blocked.
CREATE POLICY chat_messages_insert_participant ON public.chat_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND sender_id = auth.uid()
    AND public.is_chat_participant(chat_id)
    AND EXISTS (
      SELECT 1
      FROM public.chats AS c
      WHERE c.id = chat_id
        AND c.blocked_by IS NULL
    )
  );
