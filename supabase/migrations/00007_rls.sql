-- RLS helpers and policies (SRS §3, §5.2, §9, §10, §12, §14, §18).

SET search_path = public, extensions, pg_catalog;
-- Every policy comments who it allows. Blocked / deleted accounts are denied
-- except reading their own profile (so the app can show the block message).

-- ---------------------------------------------------------------------------
-- Helpers (used by policies; also used by 00008 functions)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_not_blocked()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.profiles AS p
      WHERE p.id = auth.uid()
        AND (
          p.is_blocked
          OR (p.blocked_until IS NOT NULL AND p.blocked_until > now())
          OR p.deleted_at IS NOT NULL
        )
    );
$$;

CREATE OR REPLACE FUNCTION public.current_staff_level()
RETURNS public.staff_level
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.level
  FROM public.staff AS s
  WHERE s.user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.is_office()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.current_staff_level() IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.is_owner_or_super()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.current_staff_level() IN ('owner', 'super_admin');
$$;

CREATE OR REPLACE FUNCTION public.can_gn_read_nic(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS target
    JOIN public.verification_requests AS vr
      ON vr.user_id = target.id
    JOIN public.officer_position_villages AS opv
      ON opv.village_id = target.village_id
    JOIN public.officer_positions AS op
      ON op.id = opv.position_id
    WHERE target.id = p_user_id
      AND op.person_user_id = auth.uid()
      AND op.active
      AND op.can_verify_users
      AND vr.status IN ('pending', 'approved')
  );
$$;

CREATE OR REPLACE FUNCTION public.can_approve_listing(p_listing_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.listings AS l
    JOIN public.officer_position_villages AS opv
      ON opv.village_id = l.village_id
    JOIN public.officer_position_categories AS opc
      ON opc.category_id = l.category_id
     AND opc.position_id = opv.position_id
    JOIN public.officer_positions AS op
      ON op.id = opv.position_id
    WHERE l.id = p_listing_id
      AND op.person_user_id = auth.uid()
      AND op.active
      AND op.can_approve_listings
  );
$$;

CREATE OR REPLACE FUNCTION public.is_listing_provider(p_listing_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.listings AS l
    WHERE l.id = p_listing_id
      AND l.provider_id = auth.uid()
  );
$$;

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
      AND NOT pf.is_blocked
      AND pf.deleted_at IS NULL
  );
$$;

CREATE OR REPLACE FUNCTION public.is_officer_of_position(p_position_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.officer_positions AS op
    WHERE op.id = p_position_id
      AND op.person_user_id = auth.uid()
      AND op.active
  );
$$;

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
      AND (c.user_id = auth.uid() OR op.person_user_id = auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.notice_visible_to_me(p_notice_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.notices AS n
    JOIN public.profiles AS me
      ON me.id = auth.uid()
    WHERE n.id = p_notice_id
      AND n.status = 'sent'
      AND (
        EXISTS (
          SELECT 1
          FROM public.subscriptions AS s
          WHERE s.user_id = me.id
            AND s.position_id = n.position_id
            AND s.status = 'active'
        )
        OR (
          n.is_public
          AND (
            COALESCE(cardinality(n.audience_village_ids), 0) = 0
            OR me.village_id = ANY (n.audience_village_ids)
          )
          AND (
            n.audience_age_min IS NULL
            OR EXTRACT(YEAR FROM age(current_date, me.birth_date)) >= n.audience_age_min
          )
          AND (
            n.audience_age_max IS NULL
            OR EXTRACT(YEAR FROM age(current_date, me.birth_date)) <= n.audience_age_max
          )
          AND (
            n.audience_gender IS NULL
            OR me.gender = n.audience_gender
          )
        )
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.provider_nic_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
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
-- Enable RLS on every public table
-- ---------------------------------------------------------------------------

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.districts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ds_divisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.villages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nic_hashes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nic_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.verification_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.area_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.listing_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.officer_positions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.officer_position_villages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.officer_position_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notice_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.review_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.complaints ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promotions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_subscriptions ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- app_settings
-- ---------------------------------------------------------------------------

-- Signed-in, non-blocked users may read settings (limits are not secrets).
CREATE POLICY app_settings_select_authenticated ON public.app_settings
  FOR SELECT TO authenticated
  USING (public.is_not_blocked());

-- Owner and super admin may change settings (SRS §15).
CREATE POLICY app_settings_write_owner_super ON public.app_settings
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- districts, ds_divisions, villages
-- ---------------------------------------------------------------------------

-- Any signed-in, non-blocked user may read the area tree (village dropdown, §4).
CREATE POLICY districts_select_authenticated ON public.districts
  FOR SELECT TO authenticated
  USING (public.is_not_blocked());

-- Owner and super admin maintain districts.
CREATE POLICY districts_write_owner_super ON public.districts
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- Any signed-in, non-blocked user may read DS divisions.
CREATE POLICY ds_divisions_select_authenticated ON public.ds_divisions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked());

-- Owner and super admin maintain DS divisions.
CREATE POLICY ds_divisions_write_owner_super ON public.ds_divisions
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- Any signed-in, non-blocked user may read villages (active filter is applied in the app).
CREATE POLICY villages_select_authenticated ON public.villages
  FOR SELECT TO authenticated
  USING (public.is_not_blocked());

-- Owner and super admin maintain villages.
CREATE POLICY villages_write_owner_super ON public.villages
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

-- The signed-in user may read their own row, including when blocked (block message).
CREATE POLICY profiles_select_own ON public.profiles
  FOR SELECT TO authenticated
  USING (id = auth.uid());

-- Office staff may read every profile (user management, §15).
CREATE POLICY profiles_select_office ON public.profiles
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- A new account may insert its own profile (sign-up, §5.1). Blocked phones are rejected in a trigger.
CREATE POLICY profiles_insert_own ON public.profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

-- The user may update their own non-privileged fields (enforced further by trigger).
CREATE POLICY profiles_update_own ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid() AND public.is_not_blocked())
  WITH CHECK (id = auth.uid() AND public.is_not_blocked());

-- Office may update profiles (recovery, village, verification status).
CREATE POLICY profiles_update_office ON public.profiles
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- Owner and super admin may insert profiles for admin-managed / pre-created accounts.
CREATE POLICY profiles_insert_office ON public.profiles
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- nic_hashes: no client policies. Writes go through SECURITY DEFINER functions.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- nic_records (SRS §5.2)
-- ---------------------------------------------------------------------------

-- The user may read their own NIC row.
CREATE POLICY nic_records_select_own ON public.nic_records
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- GN of the user's village may read NIC for pending/approved requests only.
CREATE POLICY nic_records_select_gn ON public.nic_records
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.can_gn_read_nic(user_id));

-- Office staff may read every NIC record.
CREATE POLICY nic_records_select_office ON public.nic_records
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The user may insert their own NIC record (submit for verification).
CREATE POLICY nic_records_insert_own ON public.nic_records
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- The user may update their own NIC row (correct and resubmit after rejection).
CREATE POLICY nic_records_update_own ON public.nic_records
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid())
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- Office may insert/update NIC records (admin-managed providers, recovery).
CREATE POLICY nic_records_write_office ON public.nic_records
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- verification_requests
-- ---------------------------------------------------------------------------

-- The user may read their own verification requests.
CREATE POLICY verification_requests_select_own ON public.verification_requests
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- GN may read pending/approved requests for people in their villages.
CREATE POLICY verification_requests_select_gn ON public.verification_requests
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND status IN ('pending', 'approved')
    AND public.can_gn_read_nic(user_id)
  );

-- Office may read every verification request.
CREATE POLICY verification_requests_select_office ON public.verification_requests
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The user may create a pending request for themselves.
CREATE POLICY verification_requests_insert_own ON public.verification_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND status = 'pending'
  );

-- GN and office may update a request (first decision wins in application logic, §5.2).
CREATE POLICY verification_requests_update_deciders ON public.verification_requests
  FOR UPDATE TO authenticated
  USING (
    public.is_not_blocked()
    AND (public.is_office() OR public.can_gn_read_nic(user_id))
  )
  WITH CHECK (
    public.is_not_blocked()
    AND (public.is_office() OR public.can_gn_read_nic(user_id))
  );

-- ---------------------------------------------------------------------------
-- staff, area_admins
-- ---------------------------------------------------------------------------

-- A staff member may read their own staff row (to know their level).
CREATE POLICY staff_select_own ON public.staff
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- Owner and super admin may read the full staff list.
CREATE POLICY staff_select_owner_super ON public.staff
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super());

-- Owner may insert any staff level; super admin may insert admins only (WITH CHECK).
CREATE POLICY staff_insert_owner_super ON public.staff
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND (
      public.current_staff_level() = 'owner'
      OR (
        public.current_staff_level() = 'super_admin'
        AND level = 'admin'
      )
    )
  );

-- Owner may update/delete staff; super admin may update/delete admins only.
CREATE POLICY staff_update_owner_super ON public.staff
  FOR UPDATE TO authenticated
  USING (
    public.is_not_blocked()
    AND (
      public.current_staff_level() = 'owner'
      OR (public.current_staff_level() = 'super_admin' AND level = 'admin')
    )
  )
  WITH CHECK (
    public.is_not_blocked()
    AND (
      public.current_staff_level() = 'owner'
      OR (
        public.current_staff_level() = 'super_admin'
        AND level = 'admin'
      )
    )
  );

CREATE POLICY staff_delete_owner_super ON public.staff
  FOR DELETE TO authenticated
  USING (
    public.is_not_blocked()
    AND (
      public.current_staff_level() = 'owner'
      OR (public.current_staff_level() = 'super_admin' AND level = 'admin')
    )
  );

-- Owner and super admin may read area-admin assignments (no extra permissions yet, §20.4).
CREATE POLICY area_admins_select_owner_super ON public.area_admins
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super());

-- Owner and super admin may write area-admin assignments.
CREATE POLICY area_admins_write_owner_super ON public.area_admins
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- devices
-- ---------------------------------------------------------------------------

-- The user may read their own devices.
CREATE POLICY devices_select_own ON public.devices
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- Office may read devices (fake-review / block-device checks).
CREATE POLICY devices_select_office ON public.devices
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The user may insert/update/delete their own device rows.
CREATE POLICY devices_write_own ON public.devices
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid())
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- blocks (owner / super admin only, §14)
-- ---------------------------------------------------------------------------

-- Owner and super admin may read blocks.
CREATE POLICY blocks_select_owner_super ON public.blocks
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super());

-- Owner and super admin may insert/update/delete blocks.
CREATE POLICY blocks_write_owner_super ON public.blocks
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- audit_log (owner / super admin read; inserts via definer/trigger)
-- ---------------------------------------------------------------------------

-- Owner and super admin may read the audit log.
CREATE POLICY audit_log_select_owner_super ON public.audit_log
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- categories
-- ---------------------------------------------------------------------------

-- Any signed-in, non-blocked user may read categories (browse / dropdown).
CREATE POLICY categories_select_authenticated ON public.categories
  FOR SELECT TO authenticated
  USING (public.is_not_blocked());

-- Super admin and owner manage categories (§7).
CREATE POLICY categories_write_owner_super ON public.categories
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- providers
-- ---------------------------------------------------------------------------

-- The provider may read their own row.
CREATE POLICY providers_select_own ON public.providers
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- Office may read every provider.
CREATE POLICY providers_select_office ON public.providers
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- Officers who approve listings may read the provider of a listing in their queue.
CREATE POLICY providers_select_approving_officer ON public.providers
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND EXISTS (
      SELECT 1
      FROM public.listings AS l
      WHERE l.provider_id = providers.user_id
        AND public.can_approve_listing(l.id)
    )
  );

-- An NIC-approved user may register as a provider for themselves.
CREATE POLICY providers_insert_own ON public.providers
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND public.provider_nic_ok()
  );

-- Office may create admin-managed providers.
CREATE POLICY providers_insert_office ON public.providers
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- The provider may update their own row.
CREATE POLICY providers_update_own ON public.providers
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid())
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- Office may update providers.
CREATE POLICY providers_update_office ON public.providers
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- listings (no general-user SELECT — location would leak for home-based, §6.4)
-- ---------------------------------------------------------------------------

-- The listing owner may read their listings (including pending / off / hidden pin).
CREATE POLICY listings_select_own ON public.listings
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND provider_id = auth.uid());

-- Office may read every listing.
CREATE POLICY listings_select_office ON public.listings
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- Category officers may read listings in their villages and categories.
CREATE POLICY listings_select_approving_officer ON public.listings
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.can_approve_listing(id));

-- The provider may insert their own listing.
CREATE POLICY listings_insert_own ON public.listings
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND provider_id = auth.uid());

-- Office may insert listings (admin-managed providers).
CREATE POLICY listings_insert_office ON public.listings
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- The provider may update their listing.
CREATE POLICY listings_update_own ON public.listings
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND provider_id = auth.uid())
  WITH CHECK (public.is_not_blocked() AND provider_id = auth.uid());

-- Office may update listings (approve, move category, blue tick).
CREATE POLICY listings_update_office ON public.listings
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- Category officers may update listings they can approve (approve / reject only in the app).
CREATE POLICY listings_update_approving_officer ON public.listings
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.can_approve_listing(id))
  WITH CHECK (public.is_not_blocked() AND public.can_approve_listing(id));

-- The provider may delete their listing.
CREATE POLICY listings_delete_own ON public.listings
  FOR DELETE TO authenticated
  USING (public.is_not_blocked() AND provider_id = auth.uid());

-- Owner and super admin may delete listings.
CREATE POLICY listings_delete_owner_super ON public.listings
  FOR DELETE TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- listing_photos
-- ---------------------------------------------------------------------------

-- Anyone not blocked may read photos of live listings.
CREATE POLICY listing_photos_select_live ON public.listing_photos
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_live_listing(listing_id));

-- Owner / office / approving officer may read photos of non-live listings too.
CREATE POLICY listing_photos_select_privileged ON public.listing_photos
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND (
      public.is_listing_provider(listing_id)
      OR public.is_office()
      OR public.can_approve_listing(listing_id)
    )
  );

-- The listing owner may add photos.
CREATE POLICY listing_photos_insert_own ON public.listing_photos
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND public.is_listing_provider(listing_id));

-- Office may add photos (admin-managed).
CREATE POLICY listing_photos_insert_office ON public.listing_photos
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- The listing owner may update/delete photos.
CREATE POLICY listing_photos_update_own ON public.listing_photos
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_listing_provider(listing_id))
  WITH CHECK (public.is_not_blocked() AND public.is_listing_provider(listing_id));

CREATE POLICY listing_photos_delete_own ON public.listing_photos
  FOR DELETE TO authenticated
  USING (public.is_not_blocked() AND public.is_listing_provider(listing_id));

-- ---------------------------------------------------------------------------
-- price_items
-- ---------------------------------------------------------------------------

-- Anyone not blocked may read prices of live listings.
CREATE POLICY price_items_select_live ON public.price_items
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_live_listing(listing_id));

-- Owner / office / approving officer may read prices of non-live listings.
CREATE POLICY price_items_select_privileged ON public.price_items
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND (
      public.is_listing_provider(listing_id)
      OR public.is_office()
      OR public.can_approve_listing(listing_id)
    )
  );

-- The listing owner may insert price items.
CREATE POLICY price_items_insert_own ON public.price_items
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND public.is_listing_provider(listing_id));

-- Office may insert price items.
CREATE POLICY price_items_insert_office ON public.price_items
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- The listing owner may update price items (limit check is a helper in 00008).
CREATE POLICY price_items_update_own ON public.price_items
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_listing_provider(listing_id))
  WITH CHECK (public.is_not_blocked() AND public.is_listing_provider(listing_id));

-- Office may update price items.
CREATE POLICY price_items_update_office ON public.price_items
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- The listing owner may delete price items.
CREATE POLICY price_items_delete_own ON public.price_items
  FOR DELETE TO authenticated
  USING (public.is_not_blocked() AND public.is_listing_provider(listing_id));

-- ---------------------------------------------------------------------------
-- price_changes
-- ---------------------------------------------------------------------------

-- The listing owner may read the change history of their listing.
CREATE POLICY price_changes_select_own ON public.price_changes
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_listing_provider(listing_id));

-- Office may read every price-change row (provider page, §6.3).
CREATE POLICY price_changes_select_office ON public.price_changes
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The listing owner may insert a change row (applied or pending).
CREATE POLICY price_changes_insert_own ON public.price_changes
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND public.is_listing_provider(listing_id)
    AND created_by = auth.uid()
  );

-- Office may insert and decide over-limit changes.
CREATE POLICY price_changes_write_office ON public.price_changes
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- officer_positions and join tables
-- ---------------------------------------------------------------------------

-- Any signed-in, non-blocked user may read active officer positions (directory, §9.4).
CREATE POLICY officer_positions_select_authenticated ON public.officer_positions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND active);

-- The assigned officer may read their position even if inactive.
CREATE POLICY officer_positions_select_self ON public.officer_positions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND person_user_id = auth.uid());

-- Office may read every position, including inactive.
CREATE POLICY officer_positions_select_office ON public.officer_positions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- Office may create and update positions. No DELETE policy: officers are only deactivated (§9.1).
CREATE POLICY officer_positions_insert_office ON public.officer_positions
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND public.is_office());

CREATE POLICY officer_positions_update_office ON public.officer_positions
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- Anyone who can read a position may read its villages.
CREATE POLICY officer_position_villages_select ON public.officer_position_villages
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND EXISTS (
      SELECT 1
      FROM public.officer_positions AS op
      WHERE op.id = position_id
        AND (
          (op.active)
          OR op.person_user_id = auth.uid()
          OR public.is_office()
        )
    )
  );

-- Office maintains position-village assignments.
CREATE POLICY officer_position_villages_write_office ON public.officer_position_villages
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- Anyone who can read a position may read its approved categories.
CREATE POLICY officer_position_categories_select ON public.officer_position_categories
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND EXISTS (
      SELECT 1
      FROM public.officer_positions AS op
      WHERE op.id = position_id
        AND (
          op.active
          OR op.person_user_id = auth.uid()
          OR public.is_office()
        )
    )
  );

-- Office maintains position-category assignments.
CREATE POLICY officer_position_categories_write_office ON public.officer_position_categories
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- subscriptions
-- ---------------------------------------------------------------------------

-- The user may read their own subscriptions.
CREATE POLICY subscriptions_select_own ON public.subscriptions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- The officer may read subscribers of their position.
CREATE POLICY subscriptions_select_officer ON public.subscriptions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_officer_of_position(position_id));

-- Office may read every subscription.
CREATE POLICY subscriptions_select_office ON public.subscriptions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The user may subscribe (or request) for themselves.
CREATE POLICY subscriptions_insert_own ON public.subscriptions
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- The user may unsubscribe (delete) or update their own row.
CREATE POLICY subscriptions_update_own ON public.subscriptions
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid())
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

CREATE POLICY subscriptions_delete_own ON public.subscriptions
  FOR DELETE TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- Officers with approve-subscribers may update pending rows for their position.
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
  );

-- Office may write subscriptions.
CREATE POLICY subscriptions_write_office ON public.subscriptions
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- notices
-- ---------------------------------------------------------------------------

-- Subscribers / matching public-audience users may read sent notices.
CREATE POLICY notices_select_audience ON public.notices
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.notice_visible_to_me(id));

-- The officer of the position may read all their notices (any status).
CREATE POLICY notices_select_officer ON public.notices
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_officer_of_position(position_id));

-- Office may read every notice (approval queue, §10 / §15).
CREATE POLICY notices_select_office ON public.notices
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- Officers with send-notices may insert a notice for their position.
CREATE POLICY notices_insert_officer ON public.notices
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND author_id = auth.uid()
    AND public.is_officer_of_position(position_id)
    AND EXISTS (
      SELECT 1
      FROM public.officer_positions AS op
      WHERE op.id = position_id
        AND op.can_send_notices
    )
  );

-- The officer may update their position's notices (edit window enforced later in app).
CREATE POLICY notices_update_officer ON public.notices
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_officer_of_position(position_id))
  WITH CHECK (public.is_not_blocked() AND public.is_officer_of_position(position_id));

-- Office may update notices (approve / reject / cancel).
CREATE POLICY notices_update_office ON public.notices
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- The officer may delete their unsent notices.
CREATE POLICY notices_delete_officer ON public.notices
  FOR DELETE TO authenticated
  USING (
    public.is_not_blocked()
    AND public.is_officer_of_position(position_id)
    AND status IN ('pending', 'rejected')
  );

-- ---------------------------------------------------------------------------
-- notice_reactions: INSERT/DELETE only. No SELECT (SRS §10). Count via function.
-- ---------------------------------------------------------------------------

-- Any signed-in, non-blocked user may add their own reaction to a notice they can see.
CREATE POLICY notice_reactions_insert_own ON public.notice_reactions
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND public.notice_visible_to_me(notice_id)
  );

-- The user may remove their own reaction.
CREATE POLICY notice_reactions_delete_own ON public.notice_reactions
  FOR DELETE TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- contacts
-- ---------------------------------------------------------------------------

-- The user may read their own contact history.
CREATE POLICY contacts_select_own ON public.contacts
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- The listing provider may read contacts on their listings (service confirmation).
CREATE POLICY contacts_select_provider ON public.contacts
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_listing_provider(listing_id));

-- Office may read contacts.
CREATE POLICY contacts_select_office ON public.contacts
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The user may insert a contact row for themselves (daily limit checked in helper).
CREATE POLICY contacts_insert_own ON public.contacts
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- service_claims
-- ---------------------------------------------------------------------------

-- The contacting user may read claims for their contacts.
CREATE POLICY service_claims_select_user ON public.service_claims
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND EXISTS (
      SELECT 1
      FROM public.contacts AS c
      WHERE c.id = contact_id
        AND c.user_id = auth.uid()
    )
  );

-- The listing provider may read claims on their listings.
CREATE POLICY service_claims_select_provider ON public.service_claims
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND EXISTS (
      SELECT 1
      FROM public.contacts AS c
      WHERE c.id = contact_id
        AND public.is_listing_provider(c.listing_id)
    )
  );

-- Office may read claims (admin-managed confirm, §11).
CREATE POLICY service_claims_select_office ON public.service_claims
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The contacting user may insert a pending claim ("Service received").
CREATE POLICY service_claims_insert_user ON public.service_claims
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND status = 'pending'
    AND EXISTS (
      SELECT 1
      FROM public.contacts AS c
      WHERE c.id = contact_id
        AND c.user_id = auth.uid()
    )
  );

-- The provider may update the claim (Yes / No).
CREATE POLICY service_claims_update_provider ON public.service_claims
  FOR UPDATE TO authenticated
  USING (
    public.is_not_blocked()
    AND EXISTS (
      SELECT 1
      FROM public.contacts AS c
      WHERE c.id = contact_id
        AND public.is_listing_provider(c.listing_id)
    )
  )
  WITH CHECK (
    public.is_not_blocked()
    AND EXISTS (
      SELECT 1
      FROM public.contacts AS c
      WHERE c.id = contact_id
        AND public.is_listing_provider(c.listing_id)
    )
  );

-- Office may update claims (admin-managed providers).
CREATE POLICY service_claims_update_office ON public.service_claims
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- reviews
-- ---------------------------------------------------------------------------

-- Anyone not blocked may read non-hidden reviews on live listings.
CREATE POLICY reviews_select_live ON public.reviews
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND NOT hidden
    AND public.is_live_listing(listing_id)
  );

-- The author may read their own reviews (including hidden).
CREATE POLICY reviews_select_own ON public.reviews
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- The listing provider may read reviews on their listings (cannot delete, §11).
CREATE POLICY reviews_select_provider ON public.reviews
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND provider_id = auth.uid());

-- Office may read every review.
CREATE POLICY reviews_select_office ON public.reviews
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The user may insert a review of themselves as author.
CREATE POLICY reviews_insert_own ON public.reviews
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- The author may edit their review.
CREATE POLICY reviews_update_own ON public.reviews
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid())
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- Admin and super admin (and owner) may hide/delete reviews (§11).
CREATE POLICY reviews_update_office ON public.reviews
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

CREATE POLICY reviews_delete_office ON public.reviews
  FOR DELETE TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- review_reports, complaints
-- ---------------------------------------------------------------------------

-- The reporter may read their own review reports.
CREATE POLICY review_reports_select_own ON public.review_reports
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND reporter_id = auth.uid());

-- Office may read every review report.
CREATE POLICY review_reports_select_office ON public.review_reports
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- Any signed-in user may report a review.
CREATE POLICY review_reports_insert_own ON public.review_reports
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND reporter_id = auth.uid());

-- The complainant may read their own complaints.
CREATE POLICY complaints_select_own ON public.complaints
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- Office may read every complaint.
CREATE POLICY complaints_select_office ON public.complaints
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The user may file a complaint.
CREATE POLICY complaints_insert_own ON public.complaints
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- Office may update complaint status.
CREATE POLICY complaints_update_office ON public.complaints
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- chats / messages (SRS §12: only user + counsellor; office has no read)
-- ---------------------------------------------------------------------------

-- A participant (user or the counsellor of that position) may read the chat.
CREATE POLICY chats_select_participant ON public.chats
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_chat_participant(id));

-- A subscribed user may open a chat with a position that has chat on.
CREATE POLICY chats_insert_user ON public.chats
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.officer_positions AS op
      JOIN public.subscriptions AS s
        ON s.position_id = op.id
       AND s.user_id = auth.uid()
       AND s.status = 'active'
      WHERE op.id = position_id
        AND op.active
        AND op.can_chat
    )
  );

-- A participant may read messages in their chat.
CREATE POLICY chat_messages_select_participant ON public.chat_messages
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_chat_participant(chat_id));

-- A participant may send a message as themselves.
CREATE POLICY chat_messages_insert_participant ON public.chat_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND sender_id = auth.uid()
    AND public.is_chat_participant(chat_id)
  );

-- The reporter may read their own chat reports (not the other party's messages).
CREATE POLICY chat_reports_select_own ON public.chat_reports
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND reporter_id = auth.uid());

-- Office may read chat reports (metadata only — not chat_messages).
CREATE POLICY chat_reports_select_office ON public.chat_reports
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- A participant may report a chat.
CREATE POLICY chat_reports_insert_own ON public.chat_reports
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND reporter_id = auth.uid()
    AND public.is_chat_participant(chat_id)
  );

-- ---------------------------------------------------------------------------
-- jobs
-- ---------------------------------------------------------------------------

-- Anyone not blocked may read approved, not-yet-expired jobs.
CREATE POLICY jobs_select_live ON public.jobs
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND status = 'approved'
    AND expires_at >= current_date
  );

-- The author may read their own jobs.
CREATE POLICY jobs_select_own ON public.jobs
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- Office may read every job.
CREATE POLICY jobs_select_office ON public.jobs
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- NIC-approved/verified users may post jobs for themselves.
CREATE POLICY jobs_insert_own ON public.jobs
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND user_id = auth.uid()
    AND public.provider_nic_ok()
  );

-- The author may update their own job while it is not yet approved.
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
  );

-- Office may update jobs (approve / reject).
CREATE POLICY jobs_update_office ON public.jobs
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- promotions
-- ---------------------------------------------------------------------------

-- Targeted users may read currently active promotions.
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

-- Super admin and owner manage promotions (§13, §15).
CREATE POLICY promotions_select_owner_super ON public.promotions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super());

CREATE POLICY promotions_write_owner_super ON public.promotions
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- emergency_contacts
-- ---------------------------------------------------------------------------

-- Any signed-in, non-blocked user may read emergency numbers (cached in the app, §13).
CREATE POLICY emergency_contacts_select_authenticated ON public.emergency_contacts
  FOR SELECT TO authenticated
  USING (public.is_not_blocked());

-- Super admin and owner maintain local numbers.
CREATE POLICY emergency_contacts_write_owner_super ON public.emergency_contacts
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_owner_or_super())
  WITH CHECK (public.is_not_blocked() AND public.is_owner_or_super());

-- ---------------------------------------------------------------------------
-- support
-- ---------------------------------------------------------------------------

-- The user may read their own tickets.
CREATE POLICY support_tickets_select_own ON public.support_tickets
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND user_id = auth.uid());

-- Office may read every ticket.
CREATE POLICY support_tickets_select_office ON public.support_tickets
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- The user may open a ticket.
CREATE POLICY support_tickets_insert_own ON public.support_tickets
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND user_id = auth.uid());

-- Office may update ticket status.
CREATE POLICY support_tickets_update_office ON public.support_tickets
  FOR UPDATE TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- Ticket participants (user or office) may read messages on tickets they can see.
CREATE POLICY support_messages_select ON public.support_messages
  FOR SELECT TO authenticated
  USING (
    public.is_not_blocked()
    AND EXISTS (
      SELECT 1
      FROM public.support_tickets AS t
      WHERE t.id = ticket_id
        AND (t.user_id = auth.uid() OR public.is_office())
    )
  );

-- The ticket owner may write a message.
CREATE POLICY support_messages_insert_own ON public.support_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_not_blocked()
    AND sender_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.support_tickets AS t
      WHERE t.id = ticket_id
        AND t.user_id = auth.uid()
    )
  );

-- Office may write a reply on any ticket.
CREATE POLICY support_messages_insert_office ON public.support_messages
  FOR INSERT TO authenticated
  WITH CHECK (public.is_not_blocked() AND sender_id = auth.uid() AND public.is_office());

-- ---------------------------------------------------------------------------
-- provider_subscriptions
-- ---------------------------------------------------------------------------

-- The provider may read their own subscription periods.
CREATE POLICY provider_subscriptions_select_own ON public.provider_subscriptions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND provider_id = auth.uid());

-- Office may read every provider subscription.
CREATE POLICY provider_subscriptions_select_office ON public.provider_subscriptions
  FOR SELECT TO authenticated
  USING (public.is_not_blocked() AND public.is_office());

-- Office may activate subscriptions after offline payment (§17).
CREATE POLICY provider_subscriptions_write_office ON public.provider_subscriptions
  FOR ALL TO authenticated
  USING (public.is_not_blocked() AND public.is_office())
  WITH CHECK (public.is_not_blocked() AND public.is_office());

-- ---------------------------------------------------------------------------
-- Safe listing browse view (nulls home-based coordinates, §6.4)
-- ---------------------------------------------------------------------------

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
  AND NOT pf.is_blocked
  AND pf.deleted_at IS NULL
  AND public.is_not_blocked();

-- GN / office verification queue: only name, NIC, birth date, village (§5.2).
CREATE OR REPLACE VIEW public.verification_queue
WITH (security_barrier = true) AS
SELECT
  vr.id AS request_id,
  vr.status,
  vr.created_at,
  p.id AS user_id,
  p.full_name,
  p.birth_date,
  v.id AS village_id,
  v.name_si AS village_name_si,
  v.name_en AS village_name_en,
  nr.nic_number
FROM public.verification_requests AS vr
JOIN public.profiles AS p ON p.id = vr.user_id
JOIN public.villages AS v ON v.id = p.village_id
JOIN public.nic_records AS nr ON nr.user_id = p.id
WHERE vr.status IN ('pending', 'approved')
  AND public.is_not_blocked()
  AND (public.is_office() OR public.can_gn_read_nic(p.id));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT USAGE ON SCHEMA public TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON public.listings_browse TO authenticated;
GRANT SELECT ON public.verification_queue TO authenticated;

REVOKE ALL ON public.nic_hashes FROM authenticated, anon, PUBLIC;
REVOKE SELECT ON public.notice_reactions FROM authenticated, anon, PUBLIC;
GRANT INSERT, DELETE ON public.notice_reactions TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON public.audit_log FROM authenticated, anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON public.listings_browse FROM authenticated, anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON public.verification_queue FROM authenticated, anon, PUBLIC;
