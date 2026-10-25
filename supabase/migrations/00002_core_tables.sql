-- Core area, identity, office, settings, devices, blocks, audit (SRS §3, §4, §5, §14, §16).

SET search_path = public, extensions, pg_catalog;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

CREATE TYPE public.gender AS ENUM ('male', 'female');
CREATE TYPE public.job_gender AS ENUM ('male', 'female', 'any');
CREATE TYPE public.app_language AS ENUM ('si', 'en');
CREATE TYPE public.verification_status AS ENUM (
  'none',
  'pending',
  'approved',
  'verified',
  'rejected'
);
CREATE TYPE public.staff_level AS ENUM ('owner', 'super_admin', 'admin');
CREATE TYPE public.subscription_mode AS ENUM ('auto', 'open', 'approval', 'code');
CREATE TYPE public.subscription_status AS ENUM ('active', 'pending', 'rejected');
CREATE TYPE public.main_group AS ENUM (
  'services',
  'food',
  'shops_and_products',
  'buyers',
  'vehicles'
);
CREATE TYPE public.price_frequency AS ENUM ('daily', 'weekly', 'monthly', 'occasional');
CREATE TYPE public.price_kind AS ENUM ('we_sell', 'we_buy');
CREATE TYPE public.price_change_status AS ENUM (
  'pending',
  'approved',
  'rejected',
  'applied'
);
CREATE TYPE public.listing_status AS ENUM ('pending', 'approved', 'rejected');
CREATE TYPE public.service_claim_status AS ENUM ('pending', 'yes', 'no');
CREATE TYPE public.notice_status AS ENUM (
  'pending',
  'approved',
  'rejected',
  'sent',
  'cancelled'
);
CREATE TYPE public.job_status AS ENUM ('pending', 'approved', 'rejected', 'expired');
CREATE TYPE public.support_ticket_kind AS ENUM (
  'request',
  'complaint',
  'suggestion',
  'nic_mismatch'
);
CREATE TYPE public.support_ticket_status AS ENUM ('open', 'closed');
CREATE TYPE public.listing_rejection_reason AS ENUM (
  'documents_missing',
  'wrong_location',
  'licence_missing',
  'other'
);

-- ---------------------------------------------------------------------------
-- updated_at helper
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- app_settings (key / jsonb value). All *(setting)* values live here.
-- ---------------------------------------------------------------------------

CREATE TABLE public.app_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER app_settings_set_updated_at
  BEFORE UPDATE ON public.app_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.app_setting(p_key text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
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
SECURITY DEFINER
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
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (s.value #>> '{}')::boolean
  FROM public.app_settings AS s
  WHERE s.key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- Areas: District → DS division → Village (SRS §4, §16)
-- ---------------------------------------------------------------------------

CREATE TABLE public.districts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name_si text NOT NULL,
  name_en text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (name_en)
);

CREATE TABLE public.ds_divisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  district_id uuid NOT NULL REFERENCES public.districts (id) ON DELETE RESTRICT,
  name_si text NOT NULL,
  name_en text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (district_id, name_en)
);

CREATE TABLE public.villages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ds_division_id uuid NOT NULL REFERENCES public.ds_divisions (id) ON DELETE RESTRICT,
  name_si text NOT NULL,
  name_en text NOT NULL,
  center geography (Point, 4326) NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ds_division_id, name_en)
);

CREATE INDEX villages_ds_division_id_idx ON public.villages (ds_division_id);
CREATE INDEX villages_center_gix ON public.villages USING gist (center);
CREATE INDEX villages_name_en_pgroonga_idx ON public.villages USING pgroonga (name_en);
CREATE INDEX villages_name_si_pgroonga_idx ON public.villages USING pgroonga (name_si);

-- ---------------------------------------------------------------------------
-- Profiles (= auth.users.id) (SRS §5, §16)
-- ---------------------------------------------------------------------------

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  phone text NOT NULL,
  full_name text NOT NULL,
  village_id uuid NOT NULL REFERENCES public.villages (id) ON DELETE RESTRICT,
  ds_division_id uuid NOT NULL REFERENCES public.ds_divisions (id) ON DELETE RESTRICT,
  birth_date date NOT NULL,
  gender public.gender NOT NULL,
  preferred_language public.app_language NOT NULL,
  promo_consent boolean NOT NULL DEFAULT false,
  verification_status public.verification_status NOT NULL DEFAULT 'none',
  is_blocked boolean NOT NULL DEFAULT false,
  blocked_until timestamptz,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (phone)
);

CREATE INDEX profiles_village_id_idx ON public.profiles (village_id);
CREATE INDEX profiles_ds_division_id_idx ON public.profiles (ds_division_id);
CREATE INDEX profiles_verification_status_idx ON public.profiles (verification_status);

CREATE TRIGGER profiles_set_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.sync_profile_ds_division()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  SELECT v.ds_division_id
  INTO NEW.ds_division_id
  FROM public.villages AS v
  WHERE v.id = NEW.village_id;

  IF NEW.ds_division_id IS NULL THEN
    RAISE EXCEPTION 'village_id does not exist';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_sync_ds_division
  BEFORE INSERT OR UPDATE OF village_id ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_profile_ds_division();

-- ---------------------------------------------------------------------------
-- NIC uniqueness hashes survive account deletion (SRS §5.4).
-- nic_records hold the readable number under strict RLS (SRS §5.2, §16).
-- ---------------------------------------------------------------------------

CREATE TABLE public.nic_hashes (
  nic_hash text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.nic_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  nic_number text NOT NULL,
  nic_hash text NOT NULL REFERENCES public.nic_hashes (nic_hash) ON DELETE RESTRICT,
  birth_date_from_nic date NOT NULL,
  gender_from_nic public.gender NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX nic_records_user_id_uidx ON public.nic_records (user_id)
  WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX nic_records_nic_hash_uidx ON public.nic_records (nic_hash);

CREATE TRIGGER nic_records_set_updated_at
  BEFORE UPDATE ON public.nic_records
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.verification_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  status public.verification_status NOT NULL DEFAULT 'pending',
  decided_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  decider_role text,
  reason text,
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT verification_requests_status_chk CHECK (
    status IN ('pending', 'approved', 'verified', 'rejected')
  )
);

CREATE INDEX verification_requests_user_id_idx ON public.verification_requests (user_id);
CREATE INDEX verification_requests_status_idx ON public.verification_requests (status);

CREATE TRIGGER verification_requests_set_updated_at
  BEFORE UPDATE ON public.verification_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Office staff and area admins (SRS §3). Area admin has no permissions yet (§20.4).
-- ---------------------------------------------------------------------------

CREATE TABLE public.staff (
  user_id uuid PRIMARY KEY REFERENCES public.profiles (id) ON DELETE CASCADE,
  level public.staff_level NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX staff_one_owner_uidx ON public.staff (level)
  WHERE level = 'owner';

CREATE TABLE public.area_admins (
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  ds_division_id uuid NOT NULL REFERENCES public.ds_divisions (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, ds_division_id)
);

-- ---------------------------------------------------------------------------
-- Devices (SRS §11 device-id check, §14 push)
-- ---------------------------------------------------------------------------

CREATE TABLE public.devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  device_id text NOT NULL,
  push_token text,
  last_seen timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, device_id)
);

CREATE INDEX devices_user_id_idx ON public.devices (user_id);

-- ---------------------------------------------------------------------------
-- Blocks (SRS §14): phone + NIC hash (+ optional device)
-- ---------------------------------------------------------------------------

CREATE TABLE public.blocks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  phone text,
  nic_hash text,
  device_id text,
  until timestamptz,
  block_device boolean NOT NULL DEFAULT false,
  created_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX blocks_phone_idx ON public.blocks (phone);
CREATE INDEX blocks_nic_hash_idx ON public.blocks (nic_hash);
CREATE INDEX blocks_device_id_idx ON public.blocks (device_id);

-- ---------------------------------------------------------------------------
-- Audit log (SRS §14)
-- ---------------------------------------------------------------------------

CREATE TABLE public.audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL,
  actor_id uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  subject_type text,
  subject_id uuid,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX audit_log_actor_id_idx ON public.audit_log (actor_id);
CREATE INDEX audit_log_subject_idx ON public.audit_log (subject_type, subject_id);
CREATE INDEX audit_log_created_at_idx ON public.audit_log (created_at DESC);
