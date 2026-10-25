-- Officer positions, subscriptions, notices, reactions (SRS §9, §10, §16).

SET search_path = public, extensions, pg_catalog;

CREATE TABLE public.officer_positions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ds_division_id uuid NOT NULL REFERENCES public.ds_divisions (id) ON DELETE RESTRICT,
  title text NOT NULL,
  person_name text,
  person_user_id uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  phone_shown text,
  can_send_notices boolean NOT NULL DEFAULT false,
  can_verify_users boolean NOT NULL DEFAULT false,
  can_approve_listings boolean NOT NULL DEFAULT false,
  can_chat boolean NOT NULL DEFAULT false,
  can_approve_subscribers boolean NOT NULL DEFAULT false,
  subscription_mode public.subscription_mode NOT NULL,
  sub_code text,
  notices_need_approval boolean NOT NULL DEFAULT true,
  urgent_can_skip_approval boolean NOT NULL DEFAULT false,
  weekly_public_limit integer,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX officer_positions_ds_division_id_idx ON public.officer_positions (ds_division_id);
CREATE INDEX officer_positions_person_user_id_idx ON public.officer_positions (person_user_id);
CREATE UNIQUE INDEX officer_positions_sub_code_uidx ON public.officer_positions (sub_code)
  WHERE sub_code IS NOT NULL;

CREATE TRIGGER officer_positions_set_updated_at
  BEFORE UPDATE ON public.officer_positions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.officer_position_villages (
  position_id uuid NOT NULL REFERENCES public.officer_positions (id) ON DELETE CASCADE,
  village_id uuid NOT NULL REFERENCES public.villages (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (position_id, village_id)
);

CREATE TABLE public.officer_position_categories (
  position_id uuid NOT NULL REFERENCES public.officer_positions (id) ON DELETE CASCADE,
  category_id uuid NOT NULL REFERENCES public.categories (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (position_id, category_id)
);

CREATE TABLE public.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  position_id uuid NOT NULL REFERENCES public.officer_positions (id) ON DELETE CASCADE,
  status public.subscription_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, position_id)
);

CREATE INDEX subscriptions_position_id_idx ON public.subscriptions (position_id);
CREATE INDEX subscriptions_user_id_idx ON public.subscriptions (user_id);

CREATE TRIGGER subscriptions_set_updated_at
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.notices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  position_id uuid NOT NULL REFERENCES public.officer_positions (id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE RESTRICT,
  body text NOT NULL,
  attachments jsonb NOT NULL DEFAULT '[]'::jsonb,
  urgent boolean NOT NULL DEFAULT false,
  is_public boolean NOT NULL DEFAULT false,
  audience_village_ids uuid[] NOT NULL DEFAULT '{}',
  audience_age_min integer,
  audience_age_max integer,
  audience_gender public.gender,
  status public.notice_status NOT NULL DEFAULT 'pending',
  approved_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  skipped_approval boolean NOT NULL DEFAULT false,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX notices_position_id_idx ON public.notices (position_id);
CREATE INDEX notices_status_idx ON public.notices (status);
CREATE INDEX notices_sent_at_idx ON public.notices (sent_at DESC);

CREATE TRIGGER notices_set_updated_at
  BEFORE UPDATE ON public.notices
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Who reacted is stored only to prevent doubles (SRS §10). No row-level reads.
CREATE TABLE public.notice_reactions (
  notice_id uuid NOT NULL REFERENCES public.notices (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (notice_id, user_id)
);
