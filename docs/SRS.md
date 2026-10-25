# Panduwasnuwara App — Software Requirements Specification (v2)

Version 2 · 24 Oct 2026 · Owner: Adheeshana Herath
Replaces the v1 SRS of 7 Oct 2026. There are no phases any more: everything in this document is in scope for the first release, targeted for **end of March 2027**.

> **For the coding agent:** this file is the source of truth for behaviour. When code and this file disagree, this file wins. When something is not covered here, check "Open items" (§20) and ask instead of guessing. Every limit, count or switch marked *(setting)* must be read from the `app_settings` table, never hard-coded.

---

## 1. Overview

Panduwasnuwara is a mobile app (Android + iOS) that brings a rural area's **service providers, residents and government officers** into one place.

- **Residents** find nearby providers (services, food, shops, buyers, vehicles), call them, and review them after a service.
- **Officers** (GN, PHI, midwife, police, hospital, librarian, counsellor, …) send notices to the residents of their villages, verify residents, approve listings in their field, and (counsellors) chat privately.
- **The office** (owner + super admins + admins) runs everything from a web admin panel.
- **Business model:** free 6-month trial. After that, providers pay a subscription on a separate website (not inside the app — see §17) and admin activates it.
- **Government:** officially supports the project.

**Pilot area:** Panduwasnuwara East DS division (Kurunegala district), ~31,790 people. Panduwasnuwara West and Kuliyapitiya East are added later as data, with no code change. Later expansion across Sri Lanka (franchise model) must be possible with the same data model.

---

## 2. Tech stack

| Layer | Choice |
|---|---|
| Mobile app | React Native + **Expo** (TypeScript, Expo Router). One codebase for Android and iOS. Builds with **EAS** (cloud). |
| Backend | **Supabase**: Postgres, Auth (phone OTP), Storage, Edge Functions, Realtime, Row Level Security (RLS) |
| Admin panel | React + Vite + TypeScript web app, Supabase JS client. **Owner / super admin / admin only.** |
| Location & distance | **PostGIS** (`geography(Point, 4326)`) |
| Search | **PGroonga** extension (multilingual full-text search — works for Sinhala and English). Not plain Postgres FTS, not pg_trgm. |
| Maps in app | `react-native-maps` for showing/picking a pin. Directions open the external Google Maps app via URL (no paid Directions API). **No address/place search.** |
| Push notifications | `expo-notifications` (FCM on Android, APNs on iOS) |
| OTP SMS | Supabase phone auth. Development: Supabase **test phone numbers** with fixed OTPs. Production: a Sri Lankan SMS gateway through the Supabase **Send SMS Hook** (gateway not chosen yet). |
| i18n | `react-i18next`; **Noto Sans Sinhala** font |
| Photos | Supabase Storage. Uploaded as-is (decision: no compression for now). |

Store accounts: Apple Developer Program and Google Play, registered as an **organization**. The bundle ID / package name must be generic (not "panduwasnuwara") because the public name will change before wider launch.

---

## 3. Roles

Everyone is first a **user** (one phone number = one account). Provider and officer abilities are added onto the same account.

| Role | Who | Can do |
|---|---|---|
| User | Any resident of a supported village | Browse, search, contact providers (daily limit), contact history, review after a confirmed service, react to notices, subscribe/unsubscribe to officers, emergency list, Contact App Team. Post jobs once NIC is approved (§5). |
| Provider | A user whose NIC is approved/verified and who registered as provider | Everything a user can, plus listings, price lists, photos, hours, On/Off, confirm services, listing stats |
| Officer | Government officer, account created by the office (§9) | In the **mobile app only**, in "Officer mode": the functions switched on for them (notices, verify users, approve listings, approve subscribers, chat, etc.) |
| Area admin | One local admin per DS division | Exists in the data model only; permissions decided at expansion time |

### Office levels (web admin panel)

| Level | Can create | Block / delete accounts | Other |
|---|---|---|---|
| Owner | Super admins, admins, officers, users, providers | Yes | Everything |
| Super admin | Admins, officers, users, providers (not other super admins) | Yes | All approvals, can give **verified** status and **blue tick**, categories, promotions, settings, logs |
| Admin | Officers, users, providers | No | Approvals that give **approved** (not verified) status, listings without blue tick, notice approval, job approval, support inbox |

Pilot runs with the owner plus up to 3 super admins in one office. **Officers have no web panel access.**

---

## 4. Areas, villages and language

- Area tree: **District → DS division → Village.** Every table that holds area data carries `ds_division_id`, so new areas are data only.
- Villages are a fixed list loaded by super admin from the DS office list. Each village has Sinhala and English names and a **centre point** (used for distance to home-based providers, §6.4).
- Users pick their village from a **searchable dropdown** and never type a village name. Only villages in the list exist, so **people outside the supported area cannot register.** (The dropdown is how the area restriction is enforced.)
- Officers are assigned one or more villages. No separate GN-division table is needed.
- Language chosen on first launch: **Sinhala or English** (Tamil later). Menus, buttons, categories and system notifications are translated. User-typed text (names, price items, notices) is shown as written.

Needed from the DS office: the village list (with approximate centre locations) and the officer positions.

---

## 5. Users, sign-up and verification

### 5.1 Sign-up

| Field | Rule |
|---|---|
| Phone number | Required, verified by OTP. One account per number. No password. |
| Name | Required |
| Village | Required, searchable dropdown (§4) |
| Birth date | Required, full date. **Must be 16 or older** — validate on the form and again on the server. |
| Gender | Required (used for officer and promotion targeting) |
| Language | Sinhala / English |
| Promotions consent | Checkbox, off unless ticked |

**No NIC at sign-up.** The app is usable immediately after sign-up.

On sign-up the user is automatically subscribed to every officer position of their village whose subscription mode is **Auto** (§9.3).

### 5.2 NIC verification (one "Verified" concept)

There is **one** verification for a person. It is based on the NIC and checked by the GN of the user's village. (There is no separate "village verification" and "NIC verification" any more.)

**When it is asked for:** only when the user wants to (a) become a provider or (b) post a job. A user may also request it voluntarily from their profile. Not every user is sent to the GN — only those who submit an NIC.

**Steps**
1. Before asking for the NIC, show a screen explaining why it is needed and who will see it.
2. User enters the **NIC number only** (no photos).
3. App parses the NIC (§5.3) and checks that **birth date and gender match** the sign-up details. On mismatch, show an error and a "Contact App Team" option; do not submit.
4. Check the NIC is not already used by another account (**one NIC = one account**). Store a hash for the uniqueness check.
5. A verification request is created. Anyone allowed (below) can decide it.

**What the GN sees** in the request: **name, NIC number, birth date, village. Nothing else.** (A GN may have many villages and many people with the same name — these four fields are enough to identify the person.)

**Who can decide and what it gives**

| Decided by | Result |
|---|---|
| GN of the user's village (officer with "verify users" on) | **Verified** |
| Super admin / owner | **Verified** |
| Admin | **Approved** (not verified) |
| Any of them rejects | **Rejected** with a reason; user can correct and resubmit |

- Statuses: `none → pending → approved | verified | rejected`.
- Both **approved** and **verified** unlock becoming a provider and posting jobs. The difference is the mark shown on the profile (only "Verified" shows the verified mark).
- **No conflicts:** several people can act on the same request. The first decision applies. A later GN or super admin approval may **upgrade** `approved → verified`. Requests already `verified` disappear from every queue. Every decision is written to the audit log. (See open item §20.1 for a GN rejecting an admin-approved person.)
- In the early months GNs are not yet using the app, so admins/super admins handle requests; GNs take over as they join.
- NIC data is readable only by the user, the GN(s) of that village (pending/approved requests only) and the office. Enforced by RLS.

### 5.3 NIC parsing rules

- **Old format:** 9 digits + `V` or `X` (e.g. `853400937V`). Year = `19` + digits 1–2. Day number = digits 3–5.
- **New format:** 12 digits (e.g. `198534000937`). Year = digits 1–4. Day number = digits 5–7.
- If day number > 500 → **female**, subtract 500. Otherwise male.
- Day number counts every year as having 366 days (February always has 29) — convert to a date accordingly.
- Reject impossible values (day 0, day > 366 after adjustment, wrong length/characters).

### 5.4 Account rules

- **Contact history:** list of providers contacted, with date/time and a button to the listing.
- **Become a provider:** button in profile → requires NIC approved/verified → provider registration (§6).
- **Account recovery:** change number = OTP to both old and new numbers. Lost number = admin verifies by phone call (name, village, birth date; NIC if given) and sets the new number. Recycled number = if no login for 6 months, ask the person to confirm the account name after OTP.
- **Account deletion** inside the app and from a web link (Google Play requires both). Account held 30 days, then removed.

| Data | On deletion |
|---|---|
| Profile, phone, village | Deleted |
| Reviews written | Kept, shown as "Deleted user" |
| Provider listings and photos | Deleted |
| NIC record | Deleted (keep only the hash, so a blocked NIC stays blocked) |
| Counselling chats | Deleted |
| Subscriptions | Removed |

- One phone used by a family is fine: one account per phone; family members use the same account.

---

## 6. Providers and listings

A provider is a person (NIC approved or verified). Each thing they offer is a separate **listing** in one category, with its own photos, price list, hours and approval.

Example: Nimal has a "Cake shop" listing in Food (approved by PHI → blue tick) and a "Decorations" listing (approved by admin → no tick). Cake photos never show on the decorations listing.

### 6.1 Provider registration
- NIC must already be approved/verified (§5.2). If not, the user is taken through NIC verification first.
- Business or company name (optional).
- **Admin-managed providers:** people without a smartphone are registered by admin at the office. Their own phone number is shown to users. When they give a service they call the office and admin confirms it in the panel.

### 6.2 Listing fields

| Field | Rule |
|---|---|
| Category | Searchable dropdown. If not found, provider types a name; super admin creates the category and assigns the listing. |
| Photos | Up to 4, optional |
| Description | Short text |
| Price list | Up to 10 items: name, price, unit, type "We sell" / "We buy". More via Contact App Team. |
| Price update frequency | Daily, Weekly, Monthly, Occasional (limits in §6.3) |
| Location | Current GPS or pin dragged on the map; satellite view available |
| Show location on map | Yes / No (home-based) — §6.4 |
| Working days and hours | Pick days; the same hours apply to each picked day |
| On / Off | Off hides the listing from search until turned On |

### 6.3 Prices
- A price stays until the provider changes it. **Prices never expire and are never greyed out.**
- **"Updated Xh ago" label:** shown **only** for listings with **Daily** frequency, and **only for 23 hours** after the update (e.g. "Pol 1 – Rs. 140 · Updated 5h ago"). After 23 hours, no label; the price simply stays. Weekly/Monthly/Occasional listings never show the label.
- Change limits *(settings)*: **Daily** 1 change per day · **Weekly** 2 per week · **Monthly** 2 per month · **Occasional** 2 per month.
- A change beyond the limit goes to admin approval; users keep seeing the old price until approved.
- Every price change is logged; owner and super admin see the history on the provider page.

### 6.4 Location and distance
- **Shop shown (default):** the pin is shown on the listing. Tapping it opens the **Google Maps app with directions from the user's current location to the pin** (URL deep link — no paid API).
- **Home-based (location hidden):** no pin and no map button. Users see the **village name** and a **distance calculated from the village centre**, not from the provider's real location.
- Distance in search uses PostGIS: real pin for shown listings, village centre for hidden ones.

### 6.5 Availability
Listing shows **Open / Closed** from working hours. The Off switch overrides that.

### 6.6 Listing approval and blue tick

A new listing (and a listing whose **category, name or location** changes) needs approval before it shows. Prices within limits, hours, On/Off, photos and description do **not** need re-approval. **When an admin moves listings to another category, no re-approval is needed.**

**Who can approve a listing**

| Approved by | Listing goes live? | Blue tick? |
|---|---|---|
| Category officer (officer whose approved categories and villages include this listing) | Yes | **Yes** |
| Super admin / owner | Yes | **Optional** — "Approve with blue tick" or "Approve without" |
| Admin | Yes | No |

- Officers only approve or reject; a rejection needs a reason from a dropdown (documents missing, wrong location, licence/PHI certificate missing, other).
- **No conflicts:** whoever acts first decides. If a listing was approved without a tick, a later category-officer approval or super admin "add blue tick" **adds the tick** without changing anything else. A listing that is already approved does not go back to pending because of another approver.
- **Officer-rejection override** *(setting, on during pilot)*: super admin can approve a listing an officer rejected. No reason needed; logged.
- The blue tick is our own design and is the only "badge" on listings. It means "approved by the responsible officer or super admin". It is visually different from the person's **Verified** mark (§5.2) — use different icons and labels.

### 6.7 Listing stats
Shown on the listing: Views · Services · Rating · Reviews (e.g. "Views 400 · Services 19 · Rating 4.6 · Reviews").

---

## 7. Categories

Super admin manages categories in the admin panel. Listings link to a category by id, so renaming/merging never breaks listings.

| Action | Effect |
|---|---|
| Add | Sinhala name, English name, main group, icon, search keywords (Sinhala, English, Singlish) |
| Rename | Listings follow automatically |
| Merge / move | Move every listing to another category (no re-approval), then remove the old one |
| Hide | New providers cannot pick it; existing listings stay |
| Delete | Blocked while listings exist |

The panel shows how many listings are affected before any change. Which officer approves a category is set on the **officer position** (§9), not on the category.

**Seed list** (main group → category: keywords):

- **Services:** Salon and beauty (සැලෝන්, හිසකෙස් කැපීම, salon, saloon, hair cut, beauty) · Carpentry (වඩු කාර්මික, carpenter, wadu, furniture repair) · Electrician (විදුලි කාර්මික, electrician, wiring) · Plumbing (ජලනල කාර්මික, plumber, pipe, wathura) · Masonry and building work (මේසන්, mason, bas, gewal hadanna) · Grass cutting (තණකොළ කැපීම, grass cutting, thanakola kapanna) · Tree cutting (ගස් කැපීම, tree cutting, gas kapanna) · Paddy harvesting (ගොයම් කැපීම, harvesting, goyam kapanna) · Tailoring (ඇඳුම් මැසීම, tailor, mahana) · Phone and TV repair (ජංගම දුරකථන අලුත්වැඩියා, phone repair, TV repair) · Appliance repair (රෙදි සෝදන යන්ත්‍ර, washing machine repair, fridge repair) · Tuition and teachers (ටියුෂන්, guru, teacher, tuition, class) · Legal services (නීතිඥ, lawyer, neethigna, attorney) · Photography and video (ඡායාරූප, photographer, wedding video) · Decorations (සැරසිලි, decoration, sarasili, wedding deco) · Catering (කේටරින්, catering, kama hadanna) · Cleaning (පිරිසිදු කිරීම, cleaning, house cleaning)
- **Food:** Restaurants and hotels (අවන්හල, hotel, restaurant, rice and curry, koththu, fried rice) · Bakery (බේකරි, bakery, paan) · Cake makers (කේක්, cake, birthday cake) · Home-cooked food (ගෙදර කෑම, home food, lunch packet, bath packet)
- **Shops and products:** Clothing (ඇඳුම්, clothes, saree, shirt) · Electronics (ඉලෙක්ට්‍රොනික, phone, laptop, tab) · Electrical items (විදුලි උපකරණ, fan, bulb, switch) · Furniture and household items (ගෘහ භාණ්ඩ, furniture, table, iron board, almari) · Pottery and cooking items (මැටි බඳුන්, mutti, pots, cooking items) · Hardware and building materials (හාඩ්වෙයාර්, කළු ගල්, වැලි, සිමෙන්ති, kalu gal, weli, cement) · Grocery (සිල්ලර, grocery, kade)
- **Buyers:** Coconut buyers (පොල්, coconut, pol) · Cashew buyers (කජු, cashew, kaju) · Rubber buyers (රබර්, rubber) · Paddy buyers (වී, paddy, wee) · Fruit and vegetable buyers (පලතුරු, එළවළු, rambutan, kesel, elawalu) · Scrap buyers (පරණ යකඩ, scrap, parana yakada)
- **Vehicles:** Vehicle rent (වාහන කුලියට, vehicle rent, van, car) · Three-wheeler hire (ත්‍රිරෝද රථ, three wheel, tuk) · Lorry and tractor hire (ලොරි, ට්‍රැක්ටර්, lorry, tractor)

---

## 8. Search and filters

Search also looks inside price lists: typing "fried rice" finds a restaurant whose price list has "Fried rice – Rs. 1,000".

- **Searched fields:** provider and business name, listing title, category names and keywords, price item names, description.
- **Engine:** PGroonga index over these fields (Sinhala + English). PostGIS for distance.
- **Result card:** name, distance, Open/Closed, rating, blue tick if any, and the matched price item. Full price list only on the listing page.
- **Filters:** category, distance, open now, price (only where the listing has prices). Category and text search work together.
- **Sort:** nearest first; for Buyers, also "highest buying price".
- **Shown:** only approved listings that are On, from providers not blocked.
- **Later:** a synonyms list kept by super admin (fried rice = ෆ්‍රයිඩ් රයිස් = frai rice).

---

## 9. Officers

### 9.1 Creating officers
- Created **by owner, super admin or admin** in the admin panel, using the officer's **phone number**.
- If an account already exists for that number, the officer role is added to that account. Otherwise an account is pre-created and the officer completes sign-up on first login.
- The officer logs in like any user (**phone OTP**). The app then shows an **"Officer" button** that switches into **Officer mode**. Outside officer mode they use the app as a normal user.
- Officers are never deleted, only deactivated. **Subscriptions and settings belong to the officer position** (e.g. "PHI, Panduwasnuwara East"), so a new person in the position keeps all subscribers.

### 9.2 Officer position settings (set by the office when creating/editing)

| Setting | Options |
|---|---|
| Position title, person name, phone shown to users | e.g. PHI, GN, midwife, police, hospital, librarian, counsellor |
| Villages | One or more |
| **Functions (switch each on/off)** | Send notices · Verify users (GNs) · Approve listings · Chat (counsellors and similar) · Approve subscribers |
| Approves categories | Multi-select (e.g. PHI: Food; decorations officer: Decorations) — used when "Approve listings" is on |
| Subscription mode | **Auto** · **Open** · **Approval** · **Code** (§9.3) |
| Notices need approval | On by default for all officers |
| Urgent notices can skip approval | **Off by default.** The office turns it on later for trusted officers who are comfortable with the app. |
| Weekly public-notice limit | Number *(setting per officer)* |

### 9.3 Subscription modes
- **Auto:** village users are subscribed automatically at sign-up (and when they change village). Typical for GN, police, hospital. Users **can unsubscribe**.
- **Open:** anyone in the area can subscribe without approval.
- **Approval:** user requests; the officer approves or rejects in officer mode.
- **Code:** only users with the officer's code can subscribe (e.g. librarian). Code auto-generated, can be regenerated.
- In every mode, users can unsubscribe at any time.
- Which mode each officer (including midwife) uses is decided by the office per officer — nothing is hard-coded by position title.

### 9.4 What officers do in Officer mode (mobile)
- **Notices:** write (text, images, PDF), choose urgent or normal, choose audience (§10), see reach count before sending, see status (pending / approved / rejected / sent).
- **Verify users** (if on): queue of pending NIC requests for their villages showing only name, NIC, birth date, village. Approve / reject with reason. Bulk approve.
- **Approve listings** (if on): queue of listings in their categories and villages. Approve (gives blue tick) / reject with reason.
- **Approve subscribers** (if Approval mode).
- **Chats** (if on): incoming and past chats.
- **Code** (if Code mode): view and regenerate.
- Users see officers by position; tapping one shows the name and phone number.

---

## 10. Notices

- **Notices feed:** one feed, like a WhatsApp channel, with notices only from positions the user is subscribed to, each with date and time. Text, images and PDFs. Users cannot write in it.
- **Reactions:** any logged-in user can react. **Everyone, including owner and super admin, sees only the count.** Who reacted is stored only to prevent double reactions and is never shown or exposed through any API.
- **Public notices:** an officer can target villages, an age range and a gender, reaching users who did not subscribe. Before submitting, the officer sees how many users it will reach. Weekly limit per officer.
- **Approval:** every notice waits for admin or super admin approval, **except** an urgent notice from an officer who has "Urgent notices can skip approval" switched on — that one is sent at once and appears in the panel for review afterwards. Urgent notices go to the top of the approval queue with a louder alert.
- Officers can edit or delete within 1 hour of sending; an edit after approval goes back for approval.
- **Midwife:** notices are common advice (e.g. drink more water in hot weather) and clinic dates. No individual records or due dates are kept.

---

## 11. Contact, service confirmation and reviews

Only a service the provider confirms can be reviewed.

1. User taps **Contact** on a listing. The provider's phone number appears and a contact record (date/time) is saved to the user's history.
2. **Daily contact limit:** **10 different listings per user per day** *(setting, adjust after the pilot)*. Tapping Contact on the same listing again the same day does not count again. At the limit, show a friendly message.
3. After contacting, the listing and the history entry show a **"Service received" (සේවාව ලැබුණා)** button. The button is shown **only** if the user has contacted that listing.
4. When the user taps it, the provider gets: "Did you give a service to <partial user name>?" **Yes / No**. (No prompt is sent for every contact — only when the user taps "Service received".)
5. On **Yes**, the user can review: 1–5 stars, text, one optional photo.
6. Reviews sit behind a **Reviews** button on the listing.

**Rules**
- Any logged-in user can review (no NIC needed); account must be at least 3 days old *(setting)*.
- One review per user per provider per 30 days; the user can edit it.
- Providers cannot delete reviews. Admin and super admin can hide/delete.
- **Report** button on every review → admin.
- If the provider says No or does not answer, the user can send a **Complaint** to admin, who calls both sides and can unlock the review.
- For admin-managed providers, admin confirms the service in the panel.

**Against fake reviews**
- One account per phone number; one account per NIC.
- Blocking blocks the phone number **and** the NIC hash (§14).
- Device ID saved at login: if a provider's own device logs into a reviewer account, that review is blocked (extra check only; not relied on).
- Admin calls 5–10 random reviewers a week; a provider caught faking gets a warning, then suspension.
- Shown rating is a weighted (Bayesian) average with the count, e.g. "4.6 (23 reviews)".

---

## 12. Counselling chat

- For officers with Chat on, subscribed users see a **"Counselling service"** button in that officer's notices, opening a private chat. The counsellor has a **Chats** list in officer mode.
- Only the user and the counsellor can read the chat in the app; admins cannot read it through the panel (RLS). Messages encrypted at rest and deleted with the user's account. **No end-to-end encryption.**
- The **privacy policy** must say clearly that chats are not end-to-end encrypted and may be handed to police or courts when required by law.
- **Report** and **Block** buttons inside the chat.
- Chat header shows the national mental health helpline **1926**.
- The whole app is 16+ (§5.1), so no separate age rule for chat.

---

## 13. Jobs, promotions, emergency and support

**Jobs.** Users whose NIC is **approved or verified** can post. Every job is approved by admin or super admin before it shows, and disappears after its expiry date.

| In the list | On the detail page |
|---|---|
| Job title, age range (e.g. 20–45), gender (male/female/any), pay (e.g. 8 hours, Rs. 3,000), place | Benefits (e.g. travel free, 2 meals), Contact button |

**Promotions.** A business contacts the office; super admin builds the promotion in the panel and targets villages, age and gender. Push goes only to users who ticked promotions consent and is labelled "Promotion"; can also run as a home-screen banner. Payment handled offline.

**Emergency.** A red button on every screen lists:
- National: **119** police, **1990** Suwa Seriya ambulance, **110** fire.
- Local numbers kept by super admin: police station, hospital, officials outside the area (e.g. ASP Kuliyapitiya).
- The list is cached on the phone and works offline.

**Contact App Team.** An inbox where users and providers send requests (e.g. more price items, NIC mismatch), complaints and suggestions; office answers.

---

## 14. Notifications, blocking and logs

| Notification type | Default |
|---|---|
| Notices from subscribed officers | On (stop one by unsubscribing) |
| Government public notices | On |
| Promotions | Follows consent checkbox |
| Service confirmations and reviews | On |

Same types are set up as Android notification channels.

**Blocking** (owner and super admin only)
- Can block any account except their own; blocking another super admin needs two of them.
- Length: 7 days, 30 days or permanent; unblock any time.
- Blocks the **phone number and the NIC hash**, so the person cannot register again with either.
- "Block device too" checkbox, off by default (families share phones).
- The person is logged out at once and sees a message with the office phone number.
- Blocked provider's listings hidden; blocked officer's pending notices cancelled; blocked user's reviews can be hidden.
- Every RLS policy checks the blocked flag.

**Logs** (owner and super admin): every approval/verification and who gave it, overrides, blue ticks, blocks, deletions, price changes, urgent notices sent without approval, subscription activations.

---

## 15. Admin panel (web — owner, super admin, admin only)

| Area | Features |
|---|---|
| Dashboard | Counts of users, providers, listings; pending items |
| Approvals | NIC verification requests (bulk), provider listings (with/without blue tick for super admin), officer notices (urgent first), notices sent without approval (review), jobs, over-limit price changes, new category requests |
| Manage | Users; providers incl. admin-managed profiles and confirming their services; **officer positions and all their settings (§9.2)**; admins |
| Content | Categories, villages (with centre points), DS divisions, emergency contacts, promotions, search synonyms (later) |
| Support | Contact App Team inbox, review complaints, reported reviews and chats, weekly random-call list |
| Subscriptions (after trial) | Activate a provider's subscription after checking payment, NIC, phone and provider name (§17) |
| Settings | Officer-rejection override, price-change limits, contact daily limit, review minimum account age, weekly public-notice limits |
| Logs | §14 |

What each level sees follows §3.

---

## 16. Data model outline (to be finalised in the schema step)

All tables carry `created_at`; area tables carry `ds_division_id`. Names are suggestions.

- `districts`, `ds_divisions`, `villages` (`name_si`, `name_en`, `center geography(Point)`, `active`)
- `profiles` (= `auth.users.id`; phone, full_name, village_id, ds_division_id, birth_date, gender, language, promo_consent, verification_status, is_blocked, blocked_until, deleted_at)
- `nic_records` (user_id, nic_number, nic_hash **unique**, birth_date_from_nic, gender_from_nic) — strict RLS
- `verification_requests` (user_id, status, decided_by, decider_role, reason, decided_at)
- `staff` (user_id, level: owner | super_admin | admin)
- `officer_positions` (title, ds_division_id, person_user_id, phone_shown, function flags, subscription_mode, sub_code, notices_need_approval, urgent_can_skip_approval, weekly_public_limit, active)
- `officer_position_villages`, `officer_position_categories`
- `providers` (user_id, business_name, admin_managed)
- `categories` (main_group, name_si, name_en, icon, keywords, hidden)
- `listings` (provider_id, category_id, title, description, location geography, show_location, village_id, price_frequency, working_days, open_time, close_time, is_on, status, approved_by, approver_role, blue_tick, blue_tick_by, counters)
- `listing_photos`, `price_items` (name, price, unit, kind sell/buy, updated_at), `price_changes` (old, new, status, decided_by)
- `contacts` (user_id, listing_id, contact_date) — unique per user/listing/day
- `service_claims` (contact_id, status pending/yes/no), `reviews`, `review_reports`, `complaints`
- `devices` (user_id, device_id, push_token, last_seen)
- `subscriptions` (user_id, position_id, status active/pending)
- `notices` (position_id, author_id, body, attachments, urgent, audience, status, approved_by, skipped_approval), `notice_reactions` (never readable row-by-row — count via function)
- `chats`, `chat_messages`, `chat_reports`
- `jobs`, `promotions`, `emergency_contacts`, `support_tickets`, `support_messages`
- `blocks` (phone, nic_hash, device_id, until), `audit_log`, `app_settings` (key/value)
- `provider_subscriptions` (after trial)

---

## 17. Payments (after the 6-month trial)

- Provider subscriptions (4- or 6-month) are paid on a **separate website**, not in the app.
- After payment, admin checks the provider's **NIC, phone number and provider name** and activates the subscription in the admin panel.
- **The app must not contain a pay button or a link to the payment website** (Apple/Google in-app purchase rules). The app may say "Your subscription has ended — contact the office".
- Prices and website: decided later.

---

## 18. Non-functional

- **Security:** RLS on every table; officers only see data for their villages and categories; NIC numbers never leave the allowed readers; no service-role key in the mobile app or admin panel.
- **Offline:** emergency list cached; last search results may be cached.
- **Performance:** search results < 2 s on 4G for the pilot data size.
- **Store/legal (before submission):** test account with fixed OTP for Apple/Google reviewers; privacy policy and terms (incl. NIC use and counselling chat disclosure); Data Safety / privacy labels declaring phone, NIC, location; in-app account deletion + web deletion link; Report/Block for user content. Do not claim "official government app" in the store listing without the written letter.

---

## 19. Build order (suggested)

1. Supabase project, extensions (PostGIS, PGroonga), schema, RLS, seed (DS division, villages, categories, settings).
2. Mobile: language choice, phone OTP sign-up (16+), profile, village dropdown.
3. Mobile: browse, search, listing page, contact + daily limit, contact history, emergency button.
4. Mobile: NIC verification flow, become a provider, listings, price lists, photos, hours, On/Off.
5. Admin panel: login, approvals (NIC, listings, prices), categories, villages, officer positions, settings, logs.
6. Mobile: Officer mode — notices, verify users, approve listings, subscribers, code.
7. Notices feed, subscriptions, reactions, push notifications.
8. Service received → confirm → reviews, reports, complaints.
9. Counselling chat, jobs, promotions, Contact App Team.
10. Blocking, account deletion, polish, store preparation.

---

## 20. Open items

1. If a GN **rejects** a person an admin already **approved**: proposed — the person stays approved and the case goes to super admin to decide (no automatic downgrade). Confirm.
2. SMS gateway for production OTP.
3. Final app name and bundle ID.
4. Area admin permissions (before expansion).
5. Subscription prices and payment website.
6. Search synonyms list.
