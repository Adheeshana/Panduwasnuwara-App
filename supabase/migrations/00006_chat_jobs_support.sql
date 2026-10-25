-- Chat, jobs, promotions, emergency, support, provider subscriptions (SRS §12, §13, §16, §17).

SET search_path = public, extensions, pg_catalog;

CREATE TABLE public.chats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  position_id uuid NOT NULL REFERENCES public.officer_positions (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, position_id)
);

CREATE INDEX chats_position_id_idx ON public.chats (position_id);

CREATE TABLE public.chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid NOT NULL REFERENCES public.chats (id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX chat_messages_chat_id_idx ON public.chat_messages (chat_id, created_at);

CREATE TABLE public.chat_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid NOT NULL REFERENCES public.chats (id) ON DELETE CASCADE,
  reporter_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX chat_reports_chat_id_idx ON public.chat_reports (chat_id);

CREATE TABLE public.jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  ds_division_id uuid NOT NULL REFERENCES public.ds_divisions (id) ON DELETE RESTRICT,
  village_id uuid REFERENCES public.villages (id) ON DELETE SET NULL,
  title text NOT NULL,
  age_min integer,
  age_max integer,
  gender public.job_gender NOT NULL DEFAULT 'any',
  pay_text text,
  place text,
  benefits text,
  expires_at date NOT NULL,
  status public.job_status NOT NULL DEFAULT 'pending',
  approved_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX jobs_status_idx ON public.jobs (status);
CREATE INDEX jobs_ds_division_id_idx ON public.jobs (ds_division_id);
CREATE INDEX jobs_title_pgroonga_idx ON public.jobs USING pgroonga (title);

CREATE TRIGGER jobs_set_updated_at
  BEFORE UPDATE ON public.jobs
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.promotions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ds_division_id uuid NOT NULL REFERENCES public.ds_divisions (id) ON DELETE RESTRICT,
  title text NOT NULL,
  body text,
  audience_village_ids uuid[] NOT NULL DEFAULT '{}',
  audience_age_min integer,
  audience_age_max integer,
  audience_gender public.gender,
  is_banner boolean NOT NULL DEFAULT false,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  created_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX promotions_ds_division_id_idx ON public.promotions (ds_division_id);

CREATE TRIGGER promotions_set_updated_at
  BEFORE UPDATE ON public.promotions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.emergency_contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ds_division_id uuid REFERENCES public.ds_divisions (id) ON DELETE CASCADE,
  name_si text NOT NULL,
  name_en text NOT NULL,
  phone text NOT NULL,
  is_national boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX emergency_contacts_ds_division_id_idx ON public.emergency_contacts (ds_division_id);

CREATE TRIGGER emergency_contacts_set_updated_at
  BEFORE UPDATE ON public.emergency_contacts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.support_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  kind public.support_ticket_kind NOT NULL DEFAULT 'request',
  subject text,
  status public.support_ticket_status NOT NULL DEFAULT 'open',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX support_tickets_user_id_idx ON public.support_tickets (user_id);
CREATE INDEX support_tickets_status_idx ON public.support_tickets (status);

CREATE TRIGGER support_tickets_set_updated_at
  BEFORE UPDATE ON public.support_tickets
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.support_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid NOT NULL REFERENCES public.support_tickets (id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX support_messages_ticket_id_idx ON public.support_messages (ticket_id, created_at);

-- After the 6-month trial (SRS §17). Schema only in this step.
CREATE TABLE public.provider_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES public.providers (user_id) ON DELETE CASCADE,
  starts_at date NOT NULL,
  ends_at date NOT NULL,
  activated_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX provider_subscriptions_provider_id_idx ON public.provider_subscriptions (provider_id);
