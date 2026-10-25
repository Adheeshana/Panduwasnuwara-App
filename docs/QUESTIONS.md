# Open questions (do not guess)

Items the SRS does not settle. Behaviour was **not** invented in application code; schema choices below are the smallest that still let §19 step 1 compile. Confirm or correct before later steps.

## From SRS §20 (still open)

1. If a GN **rejects** a person an admin already **approved**: proposed in the SRS — stay approved and escalate to super admin. Schema allows a later `rejected` write; no trigger enforces the proposal yet.
2. SMS gateway for production OTP.
3. Final app name and bundle ID.
4. Area admin permissions (table `area_admins` exists with **no extra rights**).
5. Subscription prices and payment website.
6. Search synonyms list (no table yet — SRS says later).

## Schema / seed (this step)

7. **Official Sinhala category titles.** §7 gives English names and mixed keywords. Seed `name_si` values are derived from those keywords, not an official list.
8. **Official village list and centre points.** Seed uses five sample villages (Hettipola, Pallegama, Rambadagalla, Moragane, Kadahapola) with approximate coordinates. Replace with the DS office list.
9. **Local emergency numbers** (police station, hospital, ASP, etc.) are not in the SRS. Seed includes only the national numbers 119, 1990, 110.
10. **NIC hash pepper.** Uniqueness is SHA-256 of the normalised NIC, no secret. Should hashes be HMAC’d with a server secret?
11. **Re-using an NIC after account deletion.** `nic_hashes` is never deleted, so a NIC cannot be registered again even if the old account was not blocked. §5.4 only says to keep the hash so a **blocked** NIC stays blocked.
12. **NIC day-of-year on non-leap years.** §5.3 counts every year as 366 days (29 Feb). `date` cannot store 29 Feb in a non-leap year; parse uses `1 Jan + (day − 1)` (so day 60 is 1 Mar in non-leap years). Confirm.
13. **Price-change limit grain.** §6.3 does not say whether Daily/Weekly/Monthly/Occasional limits are per listing, per price item, or per save. `price_change_within_limit` counts **applied** rows per **listing** in the window.
14. **Weekly public-notice limit default** when creating an officer (`officer_positions.weekly_public_limit` is nullable).
15. **Home-based listing coordinates.** Direct `SELECT` on `listings` is not granted to ordinary users (would leak the pin). Browse goes through `listings_browse` and `search_listings()`, which null the point when `show_location` is false.
16. **Promotion banners vs consent.** Push follows `promo_consent`; whether a home-screen banner may show without consent is not stated. RLS currently shows targeted active promotions to matching users regardless of consent.
17. **Village change and Auto subscriptions.** New Auto positions of the new village are added. Old subscriptions are left (user can unsubscribe). Not specified whether old Auto subs should be removed.
18. **Review interval (30 days)** and **notice edit window (1 hour)** are rules, not marked *(setting)*. They are not in `app_settings` yet.
19. **Minimum age 16** is a product rule, not a setting; `is_age_at_least_16` hard-codes 16 years.
20. **PGroonga on hosted Supabase.** Local Docker images and some hosted regions do not ship PGroonga. Migrations require it as specified in §2. Confirm the target project can `CREATE EXTENSION pgroonga`.
21. **Chat encryption at rest.** Relies on Postgres/Supabase disk encryption; no extra column-level encryption.
22. **Category icon keys** in seed (`scissors`, `hammer`, …) are placeholders until the icon set is chosen.
23. **Staff list visibility.** Admins cannot read the full `staff` table (only their own row). Owner/super admin can. Confirm admins should not see other admins.
24. **Two super admins to block a super admin** is application logic, not a database constraint.
25. **Overnight working hours** (close_time before open_time) are not specified; open-now treats them as closed.
