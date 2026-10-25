-- Contacts, service claims, reviews, reports, complaints (SRS §11, §16).

SET search_path = public, extensions, pg_catalog;

CREATE TABLE public.contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  listing_id uuid NOT NULL REFERENCES public.listings (id) ON DELETE CASCADE,
  contact_date date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, listing_id, contact_date)
);

CREATE INDEX contacts_user_id_date_idx ON public.contacts (user_id, contact_date);
CREATE INDEX contacts_listing_id_idx ON public.contacts (listing_id);

CREATE TABLE public.service_claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id uuid NOT NULL REFERENCES public.contacts (id) ON DELETE CASCADE,
  status public.service_claim_status NOT NULL DEFAULT 'pending',
  decided_at timestamptz,
  decided_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contact_id)
);

CREATE TRIGGER service_claims_set_updated_at
  BEFORE UPDATE ON public.service_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid NOT NULL REFERENCES public.listings (id) ON DELETE CASCADE,
  provider_id uuid NOT NULL REFERENCES public.providers (user_id) ON DELETE CASCADE,
  user_id uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  service_claim_id uuid REFERENCES public.service_claims (id) ON DELETE SET NULL,
  stars smallint NOT NULL,
  body text,
  photo_path text,
  hidden boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reviews_stars_chk CHECK (stars BETWEEN 1 AND 5)
);

CREATE INDEX reviews_listing_id_idx ON public.reviews (listing_id);
CREATE INDEX reviews_provider_id_idx ON public.reviews (provider_id);
CREATE INDEX reviews_user_id_idx ON public.reviews (user_id);

CREATE TRIGGER reviews_set_updated_at
  BEFORE UPDATE ON public.reviews
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.review_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_id uuid NOT NULL REFERENCES public.reviews (id) ON DELETE CASCADE,
  reporter_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX review_reports_review_id_idx ON public.review_reports (review_id);

CREATE TABLE public.complaints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  service_claim_id uuid REFERENCES public.service_claims (id) ON DELETE SET NULL,
  listing_id uuid REFERENCES public.listings (id) ON DELETE SET NULL,
  body text NOT NULL,
  status public.support_ticket_status NOT NULL DEFAULT 'open',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX complaints_user_id_idx ON public.complaints (user_id);

CREATE TRIGGER complaints_set_updated_at
  BEFORE UPDATE ON public.complaints
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();
