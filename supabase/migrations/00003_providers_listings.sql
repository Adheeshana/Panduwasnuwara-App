-- Providers, categories, listings, photos, prices (SRS §6, §7, §16).

SET search_path = public, extensions, pg_catalog;

CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  main_group public.main_group NOT NULL,
  name_si text NOT NULL,
  name_en text NOT NULL,
  icon text,
  keywords text[] NOT NULL DEFAULT '{}',
  hidden boolean NOT NULL DEFAULT false,
  search_document text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX categories_main_group_idx ON public.categories (main_group);
CREATE INDEX categories_search_pgroonga_idx ON public.categories USING pgroonga (search_document);

CREATE TRIGGER categories_set_updated_at
  BEFORE UPDATE ON public.categories
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.categories_refresh_search_document()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.search_document := concat_ws(
    ' ',
    NEW.name_si,
    NEW.name_en,
    array_to_string(NEW.keywords, ' ')
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER categories_search_document
  BEFORE INSERT OR UPDATE OF name_si, name_en, keywords ON public.categories
  FOR EACH ROW
  EXECUTE FUNCTION public.categories_refresh_search_document();

CREATE TABLE public.providers (
  user_id uuid PRIMARY KEY REFERENCES public.profiles (id) ON DELETE CASCADE,
  business_name text,
  admin_managed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER providers_set_updated_at
  BEFORE UPDATE ON public.providers
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.listings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES public.providers (user_id) ON DELETE CASCADE,
  category_id uuid NOT NULL REFERENCES public.categories (id) ON DELETE RESTRICT,
  title text NOT NULL,
  description text,
  location geography (Point, 4326),
  show_location boolean NOT NULL DEFAULT true,
  village_id uuid NOT NULL REFERENCES public.villages (id) ON DELETE RESTRICT,
  ds_division_id uuid NOT NULL REFERENCES public.ds_divisions (id) ON DELETE RESTRICT,
  price_frequency public.price_frequency NOT NULL DEFAULT 'occasional',
  working_days smallint[] NOT NULL DEFAULT '{}',
  open_time time,
  close_time time,
  is_on boolean NOT NULL DEFAULT true,
  status public.listing_status NOT NULL DEFAULT 'pending',
  approved_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  approver_role text,
  rejection_reason public.listing_rejection_reason,
  rejection_note text,
  blue_tick boolean NOT NULL DEFAULT false,
  blue_tick_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  view_count integer NOT NULL DEFAULT 0,
  service_count integer NOT NULL DEFAULT 0,
  review_count integer NOT NULL DEFAULT 0,
  rating_sum integer NOT NULL DEFAULT 0,
  search_document text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT listings_working_days_chk CHECK (
    working_days <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::smallint[]
  )
);

CREATE INDEX listings_provider_id_idx ON public.listings (provider_id);
CREATE INDEX listings_category_id_idx ON public.listings (category_id);
CREATE INDEX listings_village_id_idx ON public.listings (village_id);
CREATE INDEX listings_ds_division_id_idx ON public.listings (ds_division_id);
CREATE INDEX listings_status_on_idx ON public.listings (status, is_on);
CREATE INDEX listings_location_gix ON public.listings USING gist (location);
CREATE INDEX listings_search_pgroonga_idx ON public.listings USING pgroonga (search_document);

CREATE TRIGGER listings_set_updated_at
  BEFORE UPDATE ON public.listings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.listings_sync_ds_division()
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

CREATE TRIGGER listings_sync_ds_division
  BEFORE INSERT OR UPDATE OF village_id ON public.listings
  FOR EACH ROW
  EXECUTE FUNCTION public.listings_sync_ds_division();

CREATE TABLE public.listing_photos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid NOT NULL REFERENCES public.listings (id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  sort_order smallint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX listing_photos_listing_id_idx ON public.listing_photos (listing_id);

CREATE TABLE public.price_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid NOT NULL REFERENCES public.listings (id) ON DELETE CASCADE,
  name text NOT NULL,
  price numeric(12, 2) NOT NULL,
  unit text,
  kind public.price_kind NOT NULL DEFAULT 'we_sell',
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX price_items_listing_id_idx ON public.price_items (listing_id);
CREATE INDEX price_items_name_pgroonga_idx ON public.price_items USING pgroonga (name);

CREATE TRIGGER price_items_set_updated_at
  BEFORE UPDATE ON public.price_items
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.price_changes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid NOT NULL REFERENCES public.listings (id) ON DELETE CASCADE,
  price_item_id uuid REFERENCES public.price_items (id) ON DELETE SET NULL,
  old_name text,
  new_name text,
  old_price numeric(12, 2),
  new_price numeric(12, 2),
  old_unit text,
  new_unit text,
  old_kind public.price_kind,
  new_kind public.price_kind,
  status public.price_change_status NOT NULL DEFAULT 'applied',
  decided_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  decided_at timestamptz,
  created_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX price_changes_listing_id_idx ON public.price_changes (listing_id);
CREATE INDEX price_changes_status_idx ON public.price_changes (status);

-- Search document on listings: provider name, business name, title, category, keywords,
-- description, price item names (SRS §8).
CREATE OR REPLACE FUNCTION public.refresh_listing_search_document(p_listing_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.listings AS l
  SET search_document = concat_ws(
    ' ',
    l.title,
    l.description,
    pr.business_name,
    pf.full_name,
    c.name_si,
    c.name_en,
    array_to_string(c.keywords, ' '),
    (
      SELECT string_agg(pi.name, ' ')
      FROM public.price_items AS pi
      WHERE pi.listing_id = l.id
    )
  )
  FROM public.providers AS pr
  JOIN public.profiles AS pf ON pf.id = pr.user_id
  JOIN public.categories AS c ON c.id = l.category_id
  WHERE l.id = p_listing_id
    AND pr.user_id = l.provider_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.listings_search_document_from_listing()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM public.refresh_listing_search_document(NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER listings_refresh_search_document
  AFTER INSERT OR UPDATE OF title, description, category_id, provider_id
  ON public.listings
  FOR EACH ROW
  EXECUTE FUNCTION public.listings_search_document_from_listing();

CREATE OR REPLACE FUNCTION public.listings_search_document_from_price()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_listing_id uuid;
BEGIN
  v_listing_id := COALESCE(NEW.listing_id, OLD.listing_id);
  PERFORM public.refresh_listing_search_document(v_listing_id);
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER price_items_refresh_listing_search
  AFTER INSERT OR UPDATE OF name OR DELETE
  ON public.price_items
  FOR EACH ROW
  EXECUTE FUNCTION public.listings_search_document_from_price();
