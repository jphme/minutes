# Standup, hiring plan and pricing workshop: three tiers agreed

## Summary
Alex's day centred on the pricing workshop, which ended with an agreement on three tiers priced by editors and connected data sources, unlimited viewers and a 30-day trial. Earlier, the weekly standup surfaced the query cache success and the accidental staging outage, and the engineering job post got its salary range of 70 to 90 thousand EUR. Next up are the revenue model (Thursday), the job post (tomorrow), and the roadmap meeting and Contoso interview tomorrow.

## Timeline
- **08:40–08:55** PR review and empty state copy: cache invalidation PR reviewed; copy sent to Tom
- **09:30–09:45** Weekly team standup: query cache cut load time to under 1.5 s; staging outage traced to a migration run; separate notes exist
- **10:05** Hiring plan: one backend engineer, remote within Europe; job post drafted
- **11:15** Churn analysis from Lena: small single-source accounts leave after about three months
- **12:30** Call with Mira: small accounts pay about 260 EUR per month; engineering salary range 70 to 90 thousand EUR
- **15:10** Contoso usage: 42 active users but only 4 editors, a clear case against seat pricing
- **16:00–16:50** Pricing workshop: tiers by editors and sources, unlimited viewers, 30-day trial, announcement in January; separate notes exist

## Action items
- [ ] **Alex**: Publish the engineering job post (tomorrow)
- [ ] **Alex**: Collect suggestions for the tier names
- [ ] **Alex**: Prepare questions for the Contoso interview (tomorrow, 14:30)
- [ ] **Mira**: Revenue model with the three tiers and grandfathering scenarios (Thursday)
- [ ] **Sam**: Three customer calls to test the pricing framing (next week)
- [ ] **Priya**: Add a confirmation prompt to the migration script
- [x] **Alex**: Send empty state copy to Tom

## Decisions
- Three pricing tiers with unlimited viewers; editors and data sources are the pricing levers.
- 30-day trial limited to two data sources; two months free on annual billing.
- Existing customers are grandfathered for 12 months; announcement planned for January with the exports launch.
- Migration script gets a confirmation prompt.

## Open questions
- What should the tiers be called?
- Is a price of about 900 EUR for the Growth tier acceptable for customers who face an increase?
