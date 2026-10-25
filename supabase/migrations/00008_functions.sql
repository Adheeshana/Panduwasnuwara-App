-- Helper functions: NIC parse/validate (§5.3), 16+ age (§5.1), daily contact limit (§11),
-- price-change limit (§6.3), distance search (§6.4, §8), reaction count (§10).

SET search_path = public, extensions, pg_catalog;

-- ---------------------------------------------------------------------------
-- NIC parsing (SRS §5.3)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.hash_nic(p_nic text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions
AS $$
  SELECT encode(digest(upper(btrim(p_nic)), 'sha256'), 'hex');
$$;

CREATE OR REPLACE FUNCTION public.parse_nic(p_nic text)
RETURNS TABLE (
  is_valid boolean,
  error_code text,
  nic_normalized text,
  birth_date date,
  gender public.gender
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_nic text;
  v_year integer;
  v_day integer;
  v_gender public.gender := 'male';
  v_date date;
BEGIN
  v_nic := upper(regexp_replace(coalesce(p_nic, ''), '\s', '', 'g'));

  IF v_nic ~ '^[0-9]{9}[VX]$' THEN
    v_year := ('19' || substr(v_nic, 1, 2))::integer;
    v_day := substr(v_nic, 3, 3)::integer;
  ELSIF v_nic ~ '^[0-9]{12}$' THEN
    v_year := substr(v_nic, 1, 4)::integer;
    v_day := substr(v_nic, 5, 3)::integer;
  ELSE
    is_valid := false;
    error_code := 'nic_bad_format';
    nic_normalized := v_nic;
    birth_date := NULL;
    gender := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_day > 500 THEN
    v_gender := 'female';
    v_day := v_day - 500;
  END IF;

  IF v_day < 1 OR v_day > 366 THEN
    is_valid := false;
    error_code := 'nic_bad_day';
    nic_normalized := v_nic;
    birth_date := NULL;
    gender := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Day number on a 366-day calendar (Feb always 29). Stored as Jan 1 + (day - 1),
  -- which is a real Gregorian date. See docs/QUESTIONS.md for non-leap 29 Feb.
  BEGIN
    v_date := (make_date(v_year, 1, 1) + (v_day - 1));
  EXCEPTION
    WHEN others THEN
      is_valid := false;
      error_code := 'nic_bad_date';
      nic_normalized := v_nic;
      birth_date := NULL;
      gender := NULL;
      RETURN NEXT;
      RETURN;
  END;

  is_valid := true;
  error_code := NULL;
  nic_normalized := v_nic;
  birth_date := v_date;
  gender := v_gender;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- 16+ age check (SRS §5.1)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_age_at_least_16(p_birth_date date)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_birth_date IS NOT NULL
    AND (p_birth_date + interval '16 years')::date <= current_date;
$$;

-- ---------------------------------------------------------------------------
-- Contact daily limit (SRS §11) — reads contact_daily_limit from app_settings
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.today_colombo()
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (timezone('Asia/Colombo', now()))::date;
$$;

CREATE OR REPLACE FUNCTION public.contact_count_today()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.contacts AS c
  WHERE c.user_id = auth.uid()
    AND c.contact_date = public.today_colombo();
$$;

CREATE OR REPLACE FUNCTION public.can_contact_listing(p_listing_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    public.is_not_blocked()
    AND public.is_live_listing(p_listing_id)
    AND (
      EXISTS (
        SELECT 1
        FROM public.contacts AS c
        WHERE c.user_id = auth.uid()
          AND c.listing_id = p_listing_id
          AND c.contact_date = public.today_colombo()
      )
      OR public.contact_count_today() < public.app_setting_int('contact_daily_limit')
    );
$$;

-- Records today's contact if needed and returns the provider phone (not via table SELECT).
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
    VALUES (auth.uid(), p_listing_id, public.today_colombo());
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
-- Price change limit (SRS §6.3) — reads price_change_limit_* from app_settings
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.price_change_within_limit(p_listing_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_freq public.price_frequency;
  v_limit integer;
  v_start timestamptz;
  v_count integer;
  v_key text;
BEGIN
  SELECT l.price_frequency
  INTO v_freq
  FROM public.listings AS l
  WHERE l.id = p_listing_id;

  IF v_freq IS NULL THEN
    RETURN false;
  END IF;

  v_key := 'price_change_limit_' || v_freq::text;
  v_limit := public.app_setting_int(v_key);

  IF v_limit IS NULL THEN
    RETURN false;
  END IF;

  IF v_freq = 'daily' THEN
    v_start := date_trunc('day', timezone('Asia/Colombo', now()))
      AT TIME ZONE 'Asia/Colombo';
  ELSIF v_freq = 'weekly' THEN
    v_start := date_trunc('week', timezone('Asia/Colombo', now()))
      AT TIME ZONE 'Asia/Colombo';
  ELSE
    -- monthly and occasional: 2 per month (settings)
    v_start := date_trunc('month', timezone('Asia/Colombo', now()))
      AT TIME ZONE 'Asia/Colombo';
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.price_changes AS pc
  WHERE pc.listing_id = p_listing_id
    AND pc.status = 'applied'
    AND pc.created_at >= v_start;

  RETURN v_count < v_limit;
END;
$$;

-- ---------------------------------------------------------------------------
-- Open / closed from working hours (SRS §6.5)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listing_is_open(p_listing public.listings)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT
    p_listing.is_on
    AND p_listing.open_time IS NOT NULL
    AND p_listing.close_time IS NOT NULL
    AND EXTRACT(ISODOW FROM timezone('Asia/Colombo', now()))::smallint
      = ANY (p_listing.working_days)
    AND (timezone('Asia/Colombo', now()))::time >= p_listing.open_time
    AND (timezone('Asia/Colombo', now()))::time < p_listing.close_time;
$$;

-- ---------------------------------------------------------------------------
-- Distance search (SRS §6.4, §8). Home-based distance uses village centre.
-- Does not return hidden coordinates.
-- ---------------------------------------------------------------------------

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
SET search_path = public
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
      AND NOT pf.is_blocked
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
-- Reaction count only (SRS §10) — never returns who reacted
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.notice_reaction_count(p_notice_id uuid)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_not_blocked() THEN
    RETURN NULL;
  END IF;

  IF NOT (
    public.notice_visible_to_me(p_notice_id)
    OR public.is_office()
    OR EXISTS (
      SELECT 1
      FROM public.notices AS n
      WHERE n.id = p_notice_id
        AND public.is_officer_of_position(n.position_id)
    )
  ) THEN
    RETURN NULL;
  END IF;

  RETURN (
    SELECT count(*)::integer
    FROM public.notice_reactions AS r
    WHERE r.notice_id = p_notice_id
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Triggers: age, privileged profile columns, NIC fill/validate, auto-subscribe
-- ---------------------------------------------------------------------------

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

  IF EXISTS (
    SELECT 1
    FROM public.blocks AS b
    WHERE b.phone = NEW.phone
      AND (b.until IS NULL OR b.until > now())
  ) THEN
    RAISE EXCEPTION 'phone_blocked';
  END IF;

  IF TG_OP = 'UPDATE' AND NOT public.is_office() THEN
    NEW.verification_status := OLD.verification_status;
    NEW.is_blocked := OLD.is_blocked;
    NEW.blocked_until := OLD.blocked_until;
    NEW.deleted_at := OLD.deleted_at;
    NEW.phone := OLD.phone;
    NEW.birth_date := OLD.birth_date;
    NEW.gender := OLD.gender;
  END IF;

  IF public.current_staff_level() = 'admin'
     AND NEW.verification_status = 'verified'
     AND (TG_OP = 'INSERT' OR OLD.verification_status IS DISTINCT FROM 'verified') THEN
    RAISE EXCEPTION 'admin_cannot_grant_verified';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_before_write
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.profiles_before_write();

CREATE OR REPLACE FUNCTION public.nic_records_before_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  parsed record;
BEGIN
  SELECT * INTO parsed FROM public.parse_nic(NEW.nic_number);

  IF NOT parsed.is_valid THEN
    RAISE EXCEPTION '%', parsed.error_code;
  END IF;

  NEW.nic_number := parsed.nic_normalized;
  NEW.nic_hash := public.hash_nic(parsed.nic_normalized);
  NEW.birth_date_from_nic := parsed.birth_date;
  NEW.gender_from_nic := parsed.gender;

  IF TG_OP = 'INSERT' OR OLD.nic_hash IS DISTINCT FROM NEW.nic_hash THEN
    BEGIN
      INSERT INTO public.nic_hashes (nic_hash)
      VALUES (NEW.nic_hash);
    EXCEPTION
      WHEN unique_violation THEN
        RAISE EXCEPTION 'nic_already_used';
    END;
  END IF;

  IF NEW.user_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.id = NEW.user_id
      AND (
        p.birth_date IS DISTINCT FROM parsed.birth_date
        OR p.gender IS DISTINCT FROM parsed.gender
      )
  ) THEN
    RAISE EXCEPTION 'nic_profile_mismatch';
  END IF;

  IF NEW.user_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.blocks AS b
    WHERE b.nic_hash = NEW.nic_hash
      AND (b.until IS NULL OR b.until > now())
  ) THEN
    RAISE EXCEPTION 'nic_blocked';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER nic_records_before_write
  BEFORE INSERT OR UPDATE ON public.nic_records
  FOR EACH ROW
  EXECUTE FUNCTION public.nic_records_before_write();

CREATE OR REPLACE FUNCTION public.profiles_after_insert_auto_subscribe()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.subscriptions (user_id, position_id, status)
  SELECT NEW.id, op.id, 'active'
  FROM public.officer_positions AS op
  JOIN public.officer_position_villages AS opv
    ON opv.position_id = op.id
  WHERE opv.village_id = NEW.village_id
    AND op.active
    AND op.subscription_mode = 'auto'
  ON CONFLICT (user_id, position_id) DO NOTHING;

  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_after_insert_auto_subscribe
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.profiles_after_insert_auto_subscribe();

CREATE OR REPLACE FUNCTION public.profiles_after_update_village_auto_subscribe()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.village_id IS DISTINCT FROM OLD.village_id THEN
    INSERT INTO public.subscriptions (user_id, position_id, status)
    SELECT NEW.id, op.id, 'active'
    FROM public.officer_positions AS op
    JOIN public.officer_position_villages AS opv
      ON opv.position_id = op.id
    WHERE opv.village_id = NEW.village_id
      AND op.active
      AND op.subscription_mode = 'auto'
    ON CONFLICT (user_id, position_id) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_after_update_village_auto_subscribe
  AFTER UPDATE OF village_id ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.profiles_after_update_village_auto_subscribe();

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.app_setting TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_setting_int TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_setting_bool TO authenticated;
GRANT EXECUTE ON FUNCTION public.hash_nic TO authenticated;
GRANT EXECUTE ON FUNCTION public.parse_nic TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_age_at_least_16 TO authenticated;
GRANT EXECUTE ON FUNCTION public.today_colombo TO authenticated;
GRANT EXECUTE ON FUNCTION public.contact_count_today TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_contact_listing TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_contact TO authenticated;
GRANT EXECUTE ON FUNCTION public.price_change_within_limit TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_listings TO authenticated;
GRANT EXECUTE ON FUNCTION public.notice_reaction_count TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_not_blocked TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_office TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_owner_or_super TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_staff_level TO authenticated;
