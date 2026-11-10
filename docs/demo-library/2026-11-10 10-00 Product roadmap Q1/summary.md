# Q1 roadmap: exports and Snowflake first, dashboards in Q2

## Summary
The team agreed the Q1 priorities for the analytics product: scheduled report exports first, then the Snowflake connector, with SAML-only SSO built in parallel by a contractor. Self-serve dashboards move to Q2 and get a design spike in January. Alex will write up the plan as a one-pager by Friday.

## Customer demand
- Lena counted about 200 support tickets in October: 41 ask for exports, 33 for the Snowflake connector; SSO is requested mostly by larger accounts.
- Contoso Retail asked twice for weekly exports for their store managers; two other prospects need the connector.

## Effort estimates
- Scheduled exports: about 3 weeks (CSV and PDF first, Excel later), since the query layer exists.
- Snowflake connector: 4 to 6 weeks, depending on credential handling.
- SAML-only SSO: about 2 weeks, overlapping with the connector, so a second engineer is needed.
- Self-serve dashboards: 8 to 10 weeks including a new editor; too large for Q1.

## Risks
- Exports can reach millions of rows, so pagination and a size limit are needed before promising anything to customers.
- No Snowflake sandbox account yet.

## Decisions
- Q1 order: scheduled exports (shipping by mid-January), Snowflake connector, SAML SSO in parallel.
- Hire a contractor for three months; finance has budget for one person.
- Dashboards become the headline of Q2, preceded by a design spike in January with two customer sessions.

## Action items
- [ ] **Alex**: Write the roadmap one-pager and share it with the team (Friday)
- [ ] **Tom**: Send the dashboard design spike plan to Alex (Thursday)
- [ ] **Lena**: Ask her Snowflake contact for a sandbox account (today)
- [ ] **Lena**: Start hiring the contractor
- [ ] **Priya**: Define pagination and size limits for exports

## Open questions
- Should Excel export move into Q1 if the CSV and PDF work finishes early?
