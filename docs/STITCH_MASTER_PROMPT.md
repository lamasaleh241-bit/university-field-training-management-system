# Step 21 — Google Stitch Master Prompt (Reference Screen Only)

**Status:** Prompt prepared; generation **Not Run** until an actual Stitch (or alternative design tool) result exists.  
**Reference screen:** S01 — «فرص التدريب» / Browse Training Opportunities, route `/student/opportunities`.  
**Source of truth:** `PRD.md`, `docs/UI_UX_REQUIREMENTS.md`, `docs/UX_BLUEPRINT.md`, `docs/SCREEN_INVENTORY.md`.  
**Scope:** One representative MVP screen, not a multi-page app.

## PROMPT 16 — Paste into Google Stitch

Design **ONE** polished, realistic, accessible **Arabic RTL responsive web application screen** for a university field-training management system. This is the **Student — Browse Training Opportunities** screen (S01), not a generic dashboard and not an equipment marketplace.

### Product context and rules
- Students are associated with one college and one specialty. Show only open training opportunities for the student's college and targeted specialty; opportunities disappear when closed or fully occupied.
- The company representative creates the opportunities, not the student or college admin.
- Each opportunity card should display a clear Arabic title, training company, short description of tasks, eligible specialty, start/end dates, and optionally an approved location and available seats when data exists.
- Primary action on each card: «عرض التفاصيل» leading to opportunity details. Do **not** add direct acceptance or college approval controls here.
- If the student already has an active application, do not show an unrestricted apply CTA; show a contextual notice and a link to «طلباتي» where relevant.
- Navigation: right-side desktop sidebar with «لوحة التحكم»، «فرص التدريب» (active), «طلباتي»، «تدريبي الحالي»، «الحضور والانصراف»، «التقييم النهائي»، «الرسائل»، «الإشعارات»، «حسابي». Hide training-only navigation actions if inapplicable, rather than showing misleading enabled links.
- Top bar: page title «فرص التدريب», college identity as neutral placeholder, notifications and account control. Do not invent a university brand/logo.
- Arabic text must be readable and correctly right-aligned; numbers, email, dates must remain legible.
- Example content is clearly illustrative; do not present fake company/student data as real.

### Visual direction (proposal, not approved design)
Calm contemporary university SaaS: warm off-white surfaces, deep navy text, restrained teal/blue accents, generous whitespace, readable Arabic typography, clear hierarchy, consistent 8px-based spacing as an optional starting point. Cards with subtle borders, strong headings, accessible contrast, obvious primary actions and focus outlines. Avoid decorative illustrations, gradients, clutter, financial widgets, gamification, or features outside MVP.

### States to demonstrate within the SAME screen concept
- Default: 3 illustrative opportunity cards with consistent metadata.
- Loading: skeleton cards replacing content, not a second product screen.
- Empty: «لا توجد فرص مفتوحة مناسبة لتخصصك في الوقت الحالي.» with a useful non-invented next step (e.g. «تحديث الفرص»).
- Error: «تعذر تحميل فرص التدريب. تحقق من اتصالك وحاول مرة أخرى.» with «إعادة المحاولة».
- Opportunity becomes unavailable: contextual notice «لم تعد هذه الفرصة متاحة للتقديم.» and refresh.
- Do not pretend a submission succeeded unless the backend confirms it.

### Responsive and accessibility
Create a desktop layout and mobile adaptation of **this same screen**. At ~1440px, right sidebar + responsive card grid; at ~390px, collapsible navigation and single-column cards. Keep Arabic RTL semantics, keyboard focus visibility, contrast WCAG 4.5:1 normal text and 3:1 large text, labels not conveyed by color alone. Buttons remain reachable with touch.

### Exclusions
Do not design other screens, do not write application code, do not invent chat rooms, payment, continuous GPS tracking, offline attendance, automatic approvals, or extra dashboards. Search/filter controls are not a hard PRD requirement; omit them from the first reference unless the approved UI/UX document expressly requires them. Do not invent brand guidelines or approval status.

### Deliverable
ONE reference screen design with desktop/mobile adaptations, plus brief rationale for layout, RTL, typography, colors, components and the four relevant UI states. Mark any uncertain design decision as **Proposed — Needs Review**.

## PROMPT 19 — Targeted refinement only (after actual review)

Refine **only** the identified visual issue in the existing S01 reference screen: [insert observed issue]. Preserve the exact screen scope, approved product rules, Arabic RTL, navigation, content, and other design choices. Do not add screens, features, fields, or new product behavior. Return the revised same screen and explain the single correction.

## Acceptance checklist
- [ ] One actual screen generated in Stitch or an accessible alternative.
- [ ] Layout, RTL, text hierarchy, contrast and touch targets visually inspected.
- [ ] Mobile adaptation checked.
- [ ] No new MVP feature or invented screen.
- [ ] Screenshot/link/tool ID recorded in `docs/STITCH_SCREEN_REFERENCES.md`.
- [ ] User/design reviewer explicitly approves before calling the screen Approved.

**Note:** This file is a prompt specification. Its presence in GitHub is **not** evidence of an actual generated design.
