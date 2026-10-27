-- Follow-up fixes for hosted Supabase deployment.
-- This migration intentionally does not alter 00001-00010.

SET search_path = public, extensions, pg_catalog;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM authenticated, anon, PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM authenticated, anon, PUBLIC;
GRANT USAGE ON SCHEMA public TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.app_settings, public.districts, public.ds_divisions, public.villages,
  public.staff, public.area_admins, public.devices, public.blocks,
  public.categories, public.listings, public.listing_photos,
  public.providers, public.officer_positions, public.officer_position_villages,
  public.officer_position_categories, public.subscriptions, public.notices,
  public.reviews, public.review_reports, public.complaints, public.chats,
  public.chat_reports, public.jobs, public.promotions, public.emergency_contacts,
  public.support_tickets, public.support_messages, public.provider_subscriptions
TO authenticated;

GRANT SELECT, INSERT, UPDATE ON
  public.profiles, public.verification_requests, public.service_claims
TO authenticated;

GRANT SELECT ON
  public.nic_records, public.audit_log, public.price_items, public.price_changes,
  public.contacts, public.listings_browse, public.verification_queue,
  public.chat_messages
TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON
  public.nic_records, public.nic_hashes, public.price_items, public.price_changes,
  public.contacts, public.notice_reactions, public.officer_position_codes
FROM authenticated, anon, PUBLIC;
GRANT INSERT ON public.chat_messages TO authenticated;
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.notice_reactions
FROM authenticated, anon, PUBLIC;

GRANT EXECUTE ON FUNCTION
  public.is_not_blocked(), public.current_staff_level(), public.is_office(),
  public.is_owner_or_super(), public.can_gn_read_nic(uuid),
  public.can_approve_listing(uuid), public.is_listing_provider(uuid),
  public.is_live_listing(uuid), public.is_officer_of_position(uuid),
  public.is_chat_participant(uuid), public.notice_visible_to_me(uuid),
  public.provider_nic_ok(), public.profile_is_blocked(boolean, timestamptz),
  public.app_setting(text), public.app_setting_int(text),
  public.app_setting_bool(text), public.parse_nic(text),
  public.is_age_at_least_16(date), public.today_colombo(),
  public.contact_count_today(), public.can_contact_listing(uuid),
  public.register_contact(uuid),
  public.search_listings(text, geography, uuid, double precision, boolean, text),
  public.notice_reaction_count(uuid), public.listing_photo_count(uuid),
  public.submit_nic(text, uuid), public.price_change_within_limit(uuid),
  public.save_price_list(uuid, jsonb), public.decide_price_change(uuid, boolean),
  public.get_position_code(uuid), public.regenerate_position_code(uuid),
  public.subscribe_with_code(text), public.react_to_notice(uuid),
  public.unreact_notice(uuid), public.my_auth_phone()
TO authenticated;

REVOKE EXECUTE ON FUNCTION public.hash_nic(text) FROM authenticated, anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.nic_canonical(text) FROM authenticated, anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.generate_position_code() FROM authenticated, anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apply_price_change_set(uuid) FROM authenticated, anon, PUBLIC;

-- 00010 assigned ROW_COUNT (bigint) to a UUID variable when deleting price
-- items. Recreate the function with a correctly typed diagnostics variable.
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
  v_removed integer;
BEGIN
  IF NOT public.is_not_blocked()
     OR NOT (public.is_listing_provider(p_listing_id) OR v_is_office) THEN
    RAISE EXCEPTION 'not_allowed';
  END IF;

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
      SELECT 1 FROM public.price_changes AS pc
      WHERE pc.listing_id = p_listing_id AND pc.status = 'pending'
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
        listing_id, change_set_id, new_name, new_price, new_unit, new_kind,
        status, created_by
      )
      VALUES (
        p_listing_id, v_set, v_name, v_price, v_unit, v_kind, 'pending',
        auth.uid()
      );
      v_changes := v_changes + 1;
    ELSE
      SELECT * INTO v_old
      FROM public.price_items AS pi
      WHERE pi.id = v_id AND pi.listing_id = p_listing_id;

      IF v_old.id IS NULL OR v_id = ANY (v_kept) THEN
        RAISE EXCEPTION 'invalid_price_item';
      END IF;
      v_kept := v_kept || v_id;

      IF (v_old.name, v_old.price, v_old.unit, v_old.kind)
         IS DISTINCT FROM (v_name, v_price, v_unit, v_kind) THEN
        INSERT INTO public.price_changes (
          listing_id, change_set_id, price_item_id, old_name, new_name,
          old_price, new_price, old_unit, new_unit, old_kind, new_kind,
          status, created_by
        )
        VALUES (
          p_listing_id, v_set, v_id, v_old.name, v_name, v_old.price,
          v_price, v_old.unit, v_unit, v_old.kind, v_kind, 'pending',
          auth.uid()
        );
        v_changes := v_changes + 1;
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.price_changes (
    listing_id, change_set_id, price_item_id, old_name, old_price, old_unit,
    old_kind, status, created_by
  )
  SELECT
    p_listing_id, v_set, pi.id, pi.name, pi.price, pi.unit, pi.kind,
    'pending', auth.uid()
  FROM public.price_items AS pi
  WHERE pi.listing_id = p_listing_id
    AND NOT (pi.id = ANY (v_kept));
  GET DIAGNOSTICS v_removed = ROW_COUNT;

  IF v_changes = 0 AND v_removed = 0 THEN
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

GRANT EXECUTE ON FUNCTION public.save_price_list(uuid, jsonb) TO authenticated;
