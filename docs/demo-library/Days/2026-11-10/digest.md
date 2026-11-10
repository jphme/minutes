## Overview
The morning is spent building the scheduled report export for the analytics product, with a design check-in with Priya and the Q1 roadmap meeting. The roadmap is settled: exports first, then the Snowflake connector.

## Timeline
- **08:50–09:40** Coding: scheduler for report exports (job table, time zones, PDF rendering)
  - Contoso wants Monday 07:00 in their local time, so schedules carry a time zone
  - Chose a lighter PDF library; the HTML template is reused for the email body
- **09:05** Podcast (from the Mac): most dashboard views are people looking for one number; push short reports instead
- **09:50** Desk chat with Priya about the scheduler design
  - Worker polls the job table every minute and takes jobs with a lock
  - Idempotency key per run (report ID plus scheduled time) so retries do not send duplicates
- **10:00–10:35** Product roadmap Q1 (separately recorded)
- **10:55** Phone call with Lena (speaker): Snowflake trial account by Thursday, region Frankfurt, admin login for Priya
- **11:58** Export PR is up; next, questions for the Contoso interview

## Action items
- [ ] **Alex**: Write the roadmap one-pager (Friday)
- [ ] **Alex**: Draft interview questions for Contoso Retail (today, 14:30)
- [ ] **Alex**: Review the contractor job description from Lena
- [ ] **Lena**: Request the Snowflake trial account in Frankfurt with an admin login for Priya
- [ ] **Priya**: Review the export scheduler PR (today)

## Decisions
- Schedules store a time zone; runs use an idempotency key (report ID plus scheduled time).
- Use the lighter PDF library; keep the template as plain HTML.
- Retry three times with exponential backoff, then mark the run failed.

## Open questions
- Size limit and pagination for large exports are still undefined.
