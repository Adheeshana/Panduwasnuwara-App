-- Answers to docs/QUESTIONS.md (25 Oct 2026), now in SRS §5.2–§5.4, §6.2–§6.3, §13.
--   Q10/Q11  NIC hash = HMAC-SHA256 with a pepper from Supabase Vault ("nic_hash_pepper").
--            On account deletion only the hash is kept. The same NIC may register again
--            after deletion unless its hash is blocked.
--   Q12      Day 60 (29 Feb) in a non-leap year is an invalid NIC.
--   Q13      Price-change limit counts per listing; one save of the price list = one change.
--   Q16      Promotion banners show to all targeted users; push-only promotions need consent.
-- Nothing here reads the Vault at migration or seed time.

SET search_path = public, extensions, pg_catalog;

-- ---------------------------------------------------------------------------
-- NIC parsing (§5.3): 366-day calendar, Feb always has 29 days
-- ---------------------------------------------------------------------------

-- Day 1–59 = Jan 1 – Feb 28, day 60 = Feb 29 (invalid in a non-leap year), day 61 = Mar 1.
-- The old version mapped day N to Jan 1 + (N − 1), which is one day late after February
-- in non-leap years.
CREATE OR REPLACE FUNCTION public.parse_nic(p_nic text)
RETURNS TABLE (
  is_valid boolean,
  error_code text,
  nic_normalized text,
  birth_date date,
  gender public.gender
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_nic text;
  v_year integer;
  v_day integer;
  v_leap boolean;
  v_gender public.gender := 'male';
BEGIN
  v_nic := upper(regexp_replace(coalesce(p_nic, ''), '\s', '', 'g'));
  nic_normalized := v_nic;
  is_valid := false;
  birth_date := NULL;
  gender := NULL;

  IF v_nic ~ '^[0-9]{9}[VX]$' THEN
    v_year := ('19' || substr(v_nic, 1, 2))::integer;
    v_day := substr(v_nic, 3, 3)::integer;
  ELSIF v_nic ~ '^[0-9]{12}$' THEN
    v_year := substr(v_nic, 1, 4)::integer;
    v_day := substr(v_nic, 5, 3)::integer;
  ELSE
    error_code := 'nic_bad_format';
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_day > 500 THEN
    v_gender := 'female';
    v_day := v_day - 500;
  END IF;

  IF v_day < 1 OR v_day > 366 THEN
    error_code := 'nic_bad_day';
    RETURN NEXT;
    RETURN;
  END IF;

  v_leap := (v_year % 4 = 0 AND v_year % 100 <> 0) OR v_year % 400 = 0;

  IF v_day = 60 AND NOT v_leap THEN
    error_code := 'nic_bad_date';
    RETURN NEXT;
    RETURN;
  END IF;

  is_valid := true;
  error_code := NULL;
  birth_date := make_date(v_year, 1, 1)
    + (v_day - 1)
    - CASE WHEN NOT v_leap AND v_day > 60 THEN 1 ELSE 0 END;
  gender := v_gender;
  RETURN NEXT;
END;
$$;

-- Old 9-digit NICs and their 12-digit replacements are the same NIC:
-- 853400937V → 1985 340 0 0937. The hash is taken over the 12-digit form so that
-- one person cannot register both formats on two accounts (one NIC = one account).
CREATE OR REPLACE FUNCTION public.nic_canonical(p_nic_normalized text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_nic_normalized ~ '^[0-9]{9}[VX]$'
      THEN '19' || substr(p_nic_normalized, 1, 5) || '0' || substr(p_nic_normalized, 6, 4)
    ELSE p_nic_normalized
  END;
$$;

-- HMAC-SHA256 with the Vault secret "nic_hash_pepper". Internal: no client role may
-- execute it (it would be an oracle for guessing NICs).
CREATE OR REPLACE FUNCTION public.hash_nic(p_nic text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_pepper text;
BEGIN
  SELECT s.decrypted_secret
  INTO v_pepper
  FROM vault.decrypted_secrets AS s
  WHERE s.name = 'nic_hash_pepper'
  LIMIT 1;

  IF v_pepper IS NULL OR v_pepper = '' THEN
    RAISE EXCEPTION 'nic_hash_pepper_missing';
  END IF;

  RETURN encode(
    hmac(public.nic_canonical(upper(regexp_replace(p_nic, '\s', '', 'g'))), v_pepper, 'sha256'),
    'hex'
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- nic_records: deleted with the account; nic_hashes keeps the hash (§5.4)
-- ---------------------------------------------------------------------------

DROP POLICY nic_records_insert_own ON public.nic_records;
DROP POLICY nic_records_update_own ON public.nic_records;
DROP POLICY nic_records_write_office ON public.nic_records;

-- Previously ON DELETE SET NULL, which kept the readable NIC number after deletion.
DELETE FROM public.nic_records WHERE user_id IS NULL;
ALTER TABLE public.nic_records DROP CONSTRAINT nic_records_user_id_fkey;
ALTER TABLE public.nic_records ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE public.nic_records
  ADD CONSTRAINT nic_records_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES public.profiles (id) ON DELETE CASCADE;

-- Uniqueness is now nic_records.nic_hash (live accounts only). nic_hashes is the
-- history kept after deletion, so a re-used hash there is not an error.
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

  IF EXISTS (
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

  IF EXISTS (
    SELECT 1
    FROM public.blocks AS b
    WHERE b.nic_hash = NEW.nic_hash
      AND (b.until IS NULL OR b.until > now())
  ) THEN
    RAISE EXCEPTION 'nic_blocked';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.nic_records AS nr
    WHERE nr.nic_hash = NEW.nic_hash
      AND nr.user_id <> NEW.user_id
  ) THEN
    RAISE EXCEPTION 'nic_already_used';
  END IF;

  INSERT INTO public.nic_hashes (nic_hash)
  VALUES (NEW.nic_hash)
  ON CONFLICT (nic_hash) DO NOTHING;

  RETURN NEW;
END;
$$;

-- Submit (or correct after rejection) an NIC and open a verification request (§5.2).
-- p_user_id is for the office (admin-managed providers); users submit for themselves.
CREATE OR REPLACE FUNCTION public.submit_nic(p_nic text, p_user_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := coalesce(p_user_id, auth.uid());
  v_status public.verification_status;
  v_request_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_not_blocked() THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  IF v_user_id <> auth.uid() AND NOT public.is_office() THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  SELECT p.verification_status
  INTO v_status
  FROM public.profiles AS p
  WHERE p.id = v_user_id
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'profile_not_found';
  END IF;

  IF v_status NOT IN ('none', 'rejected') THEN
    RAISE EXCEPTION 'nic_already_submitted';
  END IF;

  IF EXISTS (SELECT 1 FROM public.nic_records AS nr WHERE nr.user_id = v_user_id) THEN
    UPDATE public.nic_records
    SET nic_number = p_nic
    WHERE user_id = v_user_id;
  ELSE
    -- Derived columns are filled by nic_records_before_write.
    INSERT INTO public.nic_records (
      user_id, nic_number, nic_hash, birth_date_from_nic, gender_from_nic
    )
    SELECT v_user_id, p_nic, '', pn.birth_date, pn.gender
    FROM public.parse_nic(p_nic) AS pn;
  END IF;

  INSERT INTO public.verification_requests (user_id, status)
  VALUES (v_user_id, 'pending')
  RETURNING id INTO v_request_id;

  UPDATE public.profiles
  SET verification_status = 'pending'
  WHERE id = v_user_id;

  RETURN v_request_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Price lists (§6.2, §6.3): one save = one change, counted per listing
-- ---------------------------------------------------------------------------

ALTER TABLE public.price_changes ADD COLUMN change_set_id uuid;
UPDATE public.price_changes SET change_set_id = id WHERE change_set_id IS NULL;
ALTER TABLE public.price_changes ALTER COLUMN change_set_id SET NOT NULL;
CREATE INDEX price_changes_change_set_id_idx ON public.price_changes (change_set_id);

-- Price items and change rows are written only by save_price_list / decide_price_change.
DROP POLICY price_items_insert_own ON public.price_items;
DROP POLICY price_items_insert_office ON public.price_items;
DROP POLICY price_items_update_own ON public.price_items;
DROP POLICY price_items_update_office ON public.price_items;
DROP POLICY price_items_delete_own ON public.price_items;
DROP POLICY price_changes_insert_own ON public.price_changes;
DROP POLICY price_changes_write_office ON public.price_changes;

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
BEGIN
  SELECT l.price_frequency
  INTO v_freq
  FROM public.listings AS l
  WHERE l.id = p_listing_id;

  IF v_freq IS NULL THEN
    RETURN false;
  END IF;

  v_limit := public.app_setting_int('price_change_limit_' || v_freq::text);

  IF v_limit IS NULL THEN
    RETURN false;
  END IF;

  IF v_freq = 'daily' THEN
    v_start := date_trunc('day', timezone('Asia/Colombo', now())) AT TIME ZONE 'Asia/Colombo';
  ELSIF v_freq = 'weekly' THEN
    v_start := date_trunc('week', timezone('Asia/Colombo', now())) AT TIME ZONE 'Asia/Colombo';
  ELSE
    v_start := date_trunc('month', timezone('Asia/Colombo', now())) AT TIME ZONE 'Asia/Colombo';
  END IF;

  -- One save (change set) counts once, however many items it changed.
  SELECT count(DISTINCT pc.change_set_id)::integer
  INTO v_count
  FROM public.price_changes AS pc
  WHERE pc.listing_id = p_listing_id
    AND pc.status = 'applied'
    AND pc.created_at >= v_start;

  RETURN v_count < v_limit;
END;
$$;

-- Internal: apply every row of a change set to price_items.
CREATE OR REPLACE FUNCTION public.apply_price_change_set(p_change_set_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r public.price_changes;
  v_item_id uuid;
BEGIN
  FOR r IN
    SELECT *
    FROM public.price_changes AS pc
    WHERE pc.change_set_id = p_change_set_id
    ORDER BY pc.created_at, pc.id
  LOOP
    IF r.old_name IS NULL THEN
      INSERT INTO public.price_items (listing_id, name, price, unit, kind)
      VALUES (r.listing_id, r.new_name, r.new_price, r.new_unit, r.new_kind)
      RETURNING id INTO v_item_id;

      UPDATE public.price_changes SET price_item_id = v_item_id WHERE id = r.id;
    ELSIF r.new_name IS NULL THEN
      DELETE FROM public.price_items WHERE id = r.price_item_id;
    ELSE
      UPDATE public.price_items
      SET name = r.new_name,
          price = r.new_price,
          unit = r.new_unit,
          kind = r.new_kind
      WHERE id = r.price_item_id;
    END IF;
  END LOOP;
END;
$$;

-- Saves the whole price list of a listing. p_items is a JSON array of
-- {id?, name, price, unit?, kind}; items left out are removed.
-- Returns 'unchanged', 'applied', or 'pending_approval' (over the limit: users keep
-- seeing the old prices until the office approves). Office saves apply directly and are
-- not limited (the "more items via Contact App Team" path).
CREATE OR REPLACE FUNCTION public.save_price_list(p_listing_id uuid, p_items jsonb)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_office boolean := public.is_office();
  v_set uuid := gen_random_uuid();
  v_max integer;
  v_item jsonb;
  v_id uuid;
  v_name text;
  v_price numeric(12, 2);
  v_unit text;
  v_kind public.price_kind;
  v_old public.price_items;
  v_kept uuid[] := '{}';
  v_changes integer := 0;
BEGIN
  IF NOT public.is_not_blocked()
     OR NOT (public.is_listing_provider(p_listing_id) OR v_is_office) THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  -- One save at a time per listing.
  PERFORM 1 FROM public.listings AS l WHERE l.id = p_listing_id FOR UPDATE;

  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'price_items_must_be_array';
  END IF;

  IF NOT v_is_office THEN
    v_max := public.app_setting_int('price_items_max');
    IF v_max IS NULL THEN
      RAISE EXCEPTION 'setting_missing: price_items_max';
    END IF;
    IF jsonb_array_length(p_items) > v_max THEN
      RAISE EXCEPTION 'too_many_price_items';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.price_changes AS pc
      WHERE pc.listing_id = p_listing_id
        AND pc.status = 'pending'
    ) THEN
      RAISE EXCEPTION 'price_change_pending';
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_id := nullif(v_item ->> 'id', '')::uuid;
    v_name := nullif(btrim(v_item ->> 'name'), '');
    v_price := (v_item ->> 'price')::numeric(12, 2);
    v_unit := nullif(btrim(v_item ->> 'unit'), '');
    v_kind := coalesce(v_item ->> 'kind', 'we_sell')::public.price_kind;

    IF v_name IS NULL OR v_price IS NULL OR v_price < 0 THEN
      RAISE EXCEPTION 'invalid_price_item';
    END IF;

    IF v_id IS NULL THEN
      INSERT INTO public.price_changes (
        listing_id, change_set_id, new_name, new_price, new_unit, new_kind, status, created_by
      )
      VALUES (p_listing_id, v_set, v_name, v_price, v_unit, v_kind, 'pending', auth.uid());
      v_changes := v_changes + 1;
    ELSE
      SELECT *
      INTO v_old
      FROM public.price_items AS pi
      WHERE pi.id = v_id
        AND pi.listing_id = p_listing_id;

      IF v_old.id IS NULL OR v_id = ANY (v_kept) THEN
        RAISE EXCEPTION 'invalid_price_item';
      END IF;
      v_kept := v_kept || v_id;

      IF (v_old.name, v_old.price, v_old.unit, v_old.kind)
         IS DISTINCT FROM (v_name, v_price, v_unit, v_kind) THEN
        INSERT INTO public.price_changes (
          listing_id, change_set_id, price_item_id,
          old_name, new_name, old_price, new_price, old_unit, new_unit, old_kind, new_kind,
          status, created_by
        )
        VALUES (
          p_listing_id, v_set, v_id,
          v_old.name, v_name, v_old.price, v_price, v_old.unit, v_unit, v_old.kind, v_kind,
          'pending', auth.uid()
        );
        v_changes := v_changes + 1;
      END IF;
    END IF;
  END LOOP;

  -- Items not in the saved list are removed.
  INSERT INTO public.price_changes (
    listing_id, change_set_id, price_item_id,
    old_name, old_price, old_unit, old_kind, status, created_by
  )
  SELECT p_listing_id, v_set, pi.id, pi.name, pi.price, pi.unit, pi.kind, 'pending', auth.uid()
  FROM public.price_items AS pi
  WHERE pi.listing_id = p_listing_id
    AND NOT (pi.id = ANY (v_kept));
  GET DIAGNOSTICS v_id = ROW_COUNT;

  IF v_changes = 0 AND NOT EXISTS (
    SELECT 1 FROM public.price_changes AS pc WHERE pc.change_set_id = v_set
  ) THEN
    RETURN 'unchanged';
  END IF;

  IF v_is_office OR public.price_change_within_limit(p_listing_id) THEN
    PERFORM public.apply_price_change_set(v_set);
    UPDATE public.price_changes
    SET status = 'applied',
        decided_at = now(),
        decided_by = CASE WHEN v_is_office THEN auth.uid() END
    WHERE change_set_id = v_set;
    RETURN 'applied';
  END IF;

  RETURN 'pending_approval';
END;
$$;

-- Office approves or rejects an over-limit save (§6.3, §15).
CREATE OR REPLACE FUNCTION public.decide_price_change(p_change_set_id uuid, p_approve boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_listing_id uuid;
BEGIN
  IF NOT (public.is_not_blocked() AND public.is_office()) THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

  SELECT pc.listing_id
  INTO v_listing_id
  FROM public.price_changes AS pc
  WHERE pc.change_set_id = p_change_set_id
    AND pc.status = 'pending'
  LIMIT 1
  FOR UPDATE;

  IF v_listing_id IS NULL THEN
    RAISE EXCEPTION 'price_change_not_pending';
  END IF;

  IF p_approve THEN
    PERFORM public.apply_price_change_set(p_change_set_id);
  END IF;

  UPDATE public.price_changes
  SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END::public.price_change_status,
      decided_by = auth.uid(),
      decided_at = now()
  WHERE change_set_id = p_change_set_id
    AND status = 'pending';

  INSERT INTO public.audit_log (action, actor_id, subject_type, subject_id, payload)
  VALUES (
    CASE WHEN p_approve THEN 'price_change_approved' ELSE 'price_change_rejected' END,
    auth.uid(),
    'listing',
    v_listing_id,
    jsonb_build_object('change_set_id', p_change_set_id)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Promotions (§13): banner to every targeted user; push-only promotions only to
-- users with promo_consent (push itself is sent by an Edge Function using the same rule).
-- ---------------------------------------------------------------------------

DROP POLICY promotions_select_audience ON public.promotions;

CREATE POLICY promotions_select_audience ON public.promotions
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND now() >= starts_at
    AND now() <= ends_at
    AND EXISTS (
      SELECT 1
      FROM public.profiles AS me
      WHERE me.id = auth.uid()
        AND (is_banner OR me.promo_consent)
        AND (
          COALESCE(cardinality(audience_village_ids), 0) = 0
          OR me.village_id = ANY (audience_village_ids)
        )
        AND (
          audience_age_min IS NULL
          OR EXTRACT(YEAR FROM age(current_date, me.birth_date)) >= audience_age_min
        )
        AND (
          audience_age_max IS NULL
          OR EXTRACT(YEAR FROM age(current_date, me.birth_date)) <= audience_age_max
        )
        AND (audience_gender IS NULL OR me.gender = audience_gender)
    )
  );
