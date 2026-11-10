# Weekly team standup: query cache shipped, onboarding rework

## Summary
Priya shipped the query cache, cutting median dashboard load time from about 4 s to under 1.5 s, and starts on the export scheduler. Tom is reworking the onboarding wording after two of three test users got stuck. The staging outage on Friday was caused by an accidental migration run.

## Status
- **Priya**: query cache done; starting the scheduler for report exports; needs a review of the cache invalidation PR.
- **Tom**: new onboarding screens tested with three users; reworking the data source step.
- **Lena**: churn analysis shows cancellations are mostly small accounts that never connected a second data source; report due Thursday.

## Staging outage
- Staging was down for two hours on Friday evening because a migration script was run against it by mistake.

## Decisions
- Add a confirmation prompt to the migration script.

## Action items
- [ ] **Alex**: Review the cache invalidation PR (this morning)
- [ ] **Alex**: Send empty state copy to Tom (by lunch)
- [ ] **Lena**: Send Contoso usage numbers to Alex (tonight)
- [ ] **Lena**: Churn report (Thursday)
- [ ] **Priya**: Add a confirmation prompt to the migration script

## Open questions
- Who fills the open engineering position, and when does hiring start?
