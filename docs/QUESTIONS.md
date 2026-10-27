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

7. **Resolved:** Keep the sample Sinhala category titles and keywords for now; the official list comes later.
8. **Resolved:** Keep the sample village list and approximate centre points for now; the DS office list comes later.
9. **Resolved:** Leave local emergency numbers empty; the super admin adds them from the admin panel. Seed contains only national numbers.
10. **Resolved:** NIC uniqueness uses HMAC-SHA-256 with the Supabase Vault secret `nic_hash_pepper`; it is never stored in git or seed data.
11. **Resolved:** Delete the readable NIC record with the account but retain its hash. The same NIC may register again after deletion unless that hash is blocked.
12. **Resolved:** Reject day 60 for a NIC year that is not a leap year.
13. **Resolved:** Count one price-list save as one change per listing, regardless of the number of changed items.
14. **Weekly public-notice limit default** when creating an officer (`officer_positions.weekly_public_limit` is nullable).
15. **Home-based listing coordinates.** Direct `SELECT` on `listings` is not granted to ordinary users (would leak the pin). Browse goes through `listings_browse` and `search_listings()`, which null the point when `show_location` is false.
16. **Resolved:** Home-screen banners show to all targeted users; push notifications require `promo_consent = true`.
17. **Village change and Auto subscriptions.** New Auto positions of the new village are added. Old subscriptions are left (user can unsubscribe). Not specified whether old Auto subs should be removed.
18. **Review interval (30 days)** and **notice edit window (1 hour)** are rules, not marked *(setting)*. They are not in `app_settings` yet.
19. **Minimum age 16** is a product rule, not a setting; `is_age_at_least_16` hard-codes 16 years.
20. **Resolved:** PGroonga is available on the target hosted Supabase project and remains required.
21. **Chat encryption at rest.** Relies on Postgres/Supabase disk encryption; no extra column-level encryption.
22. **Category icon keys** in seed (`scissors`, `hammer`, …) are placeholders until the icon set is chosen.
23. **Staff list visibility.** Admins cannot read the full `staff` table (only their own row). Owner/super admin can. Confirm admins should not see other admins.
24. **Two super admins to block a super admin** is application logic, not a database constraint.
25. **Overnight working hours** (close_time before open_time) are not specified; open-now treats them as closed.
