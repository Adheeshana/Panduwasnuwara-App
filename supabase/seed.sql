-- Seed for SRS §19 step 1: Kurunegala → Panduwasnuwara East, sample villages,
-- §7 categories, §13 national emergency numbers, app_settings defaults.

SET search_path = public, extensions, pg_catalog;

INSERT INTO public.app_settings (key, value) VALUES
  ('contact_daily_limit', '10'::jsonb),
  ('review_min_account_days', '3'::jsonb),
  ('price_change_limit_daily', '1'::jsonb),
  ('price_change_limit_weekly', '2'::jsonb),
  ('price_change_limit_monthly', '2'::jsonb),
  ('price_change_limit_occasional', '2'::jsonb),
  ('officer_override_enabled', 'true'::jsonb);

INSERT INTO public.districts (name_si, name_en)
VALUES ('කුරුණෑගල', 'Kurunegala');

INSERT INTO public.ds_divisions (district_id, name_si, name_en)
SELECT d.id, 'පඬුවස්නුවර නැගෙනහිර', 'Panduwasnuwara East'
FROM public.districts AS d
WHERE d.name_en = 'Kurunegala';

INSERT INTO public.villages (ds_division_id, name_si, name_en, center, active)
SELECT
  ds.id,
  v.name_si,
  v.name_en,
  ST_SetSRID(ST_MakePoint(v.lng, v.lat), 4326)::geography,
  true
FROM public.ds_divisions AS ds
CROSS JOIN (
  VALUES
    ('හෙට්ටිපොල', 'Hettipola', 80.185, 7.608),
    ('පල්ලේගම', 'Pallegama', 80.210, 7.590),
    ('රඹඩගල්ල', 'Rambadagalla', 80.230, 7.570),
    ('මොරගනේ', 'Moragane', 80.195, 7.560),
    ('කඩහපොල', 'Kadahapola', 80.220, 7.615)
) AS v (name_si, name_en, lng, lat)
WHERE ds.name_en = 'Panduwasnuwara East';

INSERT INTO public.emergency_contacts (
  ds_division_id, name_si, name_en, phone, is_national, sort_order
)
VALUES
  (NULL, 'පොලිසිය', 'Police', '119', true, 1),
  (NULL, 'සුව සැරිය', 'Suwa Seriya ambulance', '1990', true, 2),
  (NULL, 'ගිනි නිවීම', 'Fire', '110', true, 3);

-- Categories: name_si is taken from §7 keywords / English titles (see docs/QUESTIONS.md).
INSERT INTO public.categories (main_group, name_si, name_en, icon, keywords, hidden)
VALUES
  (
    'services',
    'සැලෝන් සහ රූපලාවන්‍ය',
    'Salon and beauty',
    'scissors',
    ARRAY['සැලෝන්', 'හිසකෙස් කැපීම', 'salon', 'saloon', 'hair cut', 'beauty'],
    false
  ),
  (
    'services',
    'වඩු කාර්මික',
    'Carpentry',
    'hammer',
    ARRAY['වඩු කාර්මික', 'carpenter', 'wadu', 'furniture repair'],
    false
  ),
  (
    'services',
    'විදුලි කාර්මික',
    'Electrician',
    'zap',
    ARRAY['විදුලි කාර්මික', 'electrician', 'wiring'],
    false
  ),
  (
    'services',
    'ජලනල කාර්මික',
    'Plumbing',
    'droplet',
    ARRAY['ජලනල කාර්මික', 'plumber', 'pipe', 'wathura'],
    false
  ),
  (
    'services',
    'මේසන් සහ ගොඩනැගිලි',
    'Masonry and building work',
    'brick',
    ARRAY['මේසන්', 'mason', 'bas', 'gewal hadanna'],
    false
  ),
  (
    'services',
    'තණකොළ කැපීම',
    'Grass cutting',
    'grass',
    ARRAY['තණකොළ කැපීම', 'grass cutting', 'thanakola kapanna'],
    false
  ),
  (
    'services',
    'ගස් කැපීම',
    'Tree cutting',
    'tree',
    ARRAY['ගස් කැපීම', 'tree cutting', 'gas kapanna'],
    false
  ),
  (
    'services',
    'ගොයම් කැපීම',
    'Paddy harvesting',
    'wheat',
    ARRAY['ගොයම් කැපීම', 'harvesting', 'goyam kapanna'],
    false
  ),
  (
    'services',
    'ඇඳුම් මැසීම',
    'Tailoring',
    'shirt',
    ARRAY['ඇඳුම් මැසීම', 'tailor', 'mahana'],
    false
  ),
  (
    'services',
    'ජංගම දුරකථන සහ රූපවාහිනී අලුත්වැඩියා',
    'Phone and TV repair',
    'smartphone',
    ARRAY['ජංගම දුරකථන අලුත්වැඩියා', 'phone repair', 'TV repair'],
    false
  ),
  (
    'services',
    'උපකරණ අලුත්වැඩියා',
    'Appliance repair',
    'wrench',
    ARRAY['රෙදි සෝදන යන්ත්‍ර', 'washing machine repair', 'fridge repair'],
    false
  ),
  (
    'services',
    'ටියුෂන් සහ ගුරුවරු',
    'Tuition and teachers',
    'book',
    ARRAY['ටියුෂන්', 'guru', 'teacher', 'tuition', 'class'],
    false
  ),
  (
    'services',
    'නීති සේවා',
    'Legal services',
    'scale',
    ARRAY['නීතිඥ', 'lawyer', 'neethigna', 'attorney'],
    false
  ),
  (
    'services',
    'ඡායාරූප සහ වීඩියෝ',
    'Photography and video',
    'camera',
    ARRAY['ඡායාරූප', 'photographer', 'wedding video'],
    false
  ),
  (
    'services',
    'සැරසිලි',
    'Decorations',
    'sparkles',
    ARRAY['සැරසිලි', 'decoration', 'sarasili', 'wedding deco'],
    false
  ),
  (
    'services',
    'කේටරින්',
    'Catering',
    'utensils',
    ARRAY['කේටරින්', 'catering', 'kama hadanna'],
    false
  ),
  (
    'services',
    'පිරිසිදු කිරීම',
    'Cleaning',
    'sparkle',
    ARRAY['පිරිසිදු කිරීම', 'cleaning', 'house cleaning'],
    false
  ),
  (
    'food',
    'අවන්හල් සහ හෝටල්',
    'Restaurants and hotels',
    'utensils-crossed',
    ARRAY['අවන්හල', 'hotel', 'restaurant', 'rice and curry', 'koththu', 'fried rice'],
    false
  ),
  (
    'food',
    'බේකරි',
    'Bakery',
    'croissant',
    ARRAY['බේකරි', 'bakery', 'paan'],
    false
  ),
  (
    'food',
    'කේක්',
    'Cake makers',
    'cake',
    ARRAY['කේක්', 'cake', 'birthday cake'],
    false
  ),
  (
    'food',
    'ගෙදර කෑම',
    'Home-cooked food',
    'home',
    ARRAY['ගෙදර කෑම', 'home food', 'lunch packet', 'bath packet'],
    false
  ),
  (
    'shops_and_products',
    'ඇඳුම්',
    'Clothing',
    'hanger',
    ARRAY['ඇඳුම්', 'clothes', 'saree', 'shirt'],
    false
  ),
  (
    'shops_and_products',
    'ඉලෙක්ට්‍රොනික',
    'Electronics',
    'cpu',
    ARRAY['ඉලෙක්ට්‍රොනික', 'phone', 'laptop', 'tab'],
    false
  ),
  (
    'shops_and_products',
    'විදුලි උපකරණ',
    'Electrical items',
    'plug',
    ARRAY['විදුලි උපකරණ', 'fan', 'bulb', 'switch'],
    false
  ),
  (
    'shops_and_products',
    'ගෘහ භාණ්ඩ',
    'Furniture and household items',
    'armchair',
    ARRAY['ගෘහ භාණ්ඩ', 'furniture', 'table', 'iron board', 'almari'],
    false
  ),
  (
    'shops_and_products',
    'මැටි බඳුන් සහ උයන බඩු',
    'Pottery and cooking items',
    'pot',
    ARRAY['මැටි බඳුන්', 'mutti', 'pots', 'cooking items'],
    false
  ),
  (
    'shops_and_products',
    'හාඩ්වෙයාර් සහ ගොඩනැගිලි ද්‍රව්‍ය',
    'Hardware and building materials',
    'warehouse',
    ARRAY['හාඩ්වෙයාර්', 'කළු ගල්', 'වැලි', 'සිමෙන්ති', 'kalu gal', 'weli', 'cement'],
    false
  ),
  (
    'shops_and_products',
    'සිල්ලර',
    'Grocery',
    'shopping-basket',
    ARRAY['සිල්ලර', 'grocery', 'kade'],
    false
  ),
  (
    'buyers',
    'පොල් මිලදී ගන්නන්',
    'Coconut buyers',
    'coconut',
    ARRAY['පොල්', 'coconut', 'pol'],
    false
  ),
  (
    'buyers',
    'කජු මිලදී ගන්නන්',
    'Cashew buyers',
    'nut',
    ARRAY['කජු', 'cashew', 'kaju'],
    false
  ),
  (
    'buyers',
    'රබර් මිලදී ගන්නන්',
    'Rubber buyers',
    'circle',
    ARRAY['රබර්', 'rubber'],
    false
  ),
  (
    'buyers',
    'වී මිලදී ගන්නන්',
    'Paddy buyers',
    'sack',
    ARRAY['වී', 'paddy', 'wee'],
    false
  ),
  (
    'buyers',
    'පලතුරු සහ එළවළු මිලදී ගන්නන්',
    'Fruit and vegetable buyers',
    'apple',
    ARRAY['පලතුරු', 'එළවළු', 'rambutan', 'kesel', 'elawalu'],
    false
  ),
  (
    'buyers',
    'පරණ යකඩ මිලදී ගන්නන්',
    'Scrap buyers',
    'recycle',
    ARRAY['පරණ යකඩ', 'scrap', 'parana yakada'],
    false
  ),
  (
    'vehicles',
    'වාහන කුලියට',
    'Vehicle rent',
    'car',
    ARRAY['වාහන කුලියට', 'vehicle rent', 'van', 'car'],
    false
  ),
  (
    'vehicles',
    'ත්‍රිරෝද රථ',
    'Three-wheeler hire',
    'bike',
    ARRAY['ත්‍රිරෝද රථ', 'three wheel', 'tuk'],
    false
  ),
  (
    'vehicles',
    'ලොරි සහ ට්‍රැක්ටර්',
    'Lorry and tractor hire',
    'truck',
    ARRAY['ලොරි', 'ට්‍රැක්ටර්', 'lorry', 'tractor'],
    false
  );
