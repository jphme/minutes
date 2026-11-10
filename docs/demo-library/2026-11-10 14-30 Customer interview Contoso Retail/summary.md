# Contoso Retail interview: weekly store reports and Snowflake connection

## Summary
Hannah Brooks, regional operations lead at Contoso Retail, wants automated weekly reports for about 30 store managers instead of the screenshots she sends by hand every Monday. Contoso's data team now runs on Snowflake and will not renew a tool that needs manual CSV uploads. Contoso would pilot with five stores for two weeks once weekly exports are available.

## Current workflow
- Hannah checks weekend sales per store on Monday and forwards screenshots to about 30 store managers; this takes almost an hour.
- Managers cannot filter anything and send follow-up questions.
- Data arrives through nightly CSV uploads that break about once a month.

## Report requirements
- Weekly email per store with revenue against last week and last year, top ten products and stock-outs.
- Comparison with the regional average would be a strong extra.
- PDF for managers (mostly on phones); Excel for the finance team.

## Platform and security
- Central data team moved to Snowflake in summer; a direct connector would remove the upload step.
- IT requires SAML SSO for new tools from January; Contoso granted an exception until March.
- The dashboard editor is too complicated for store managers; they want templates where they only change the store.

## Decisions
- Contoso pilots weekly exports with five stores for two weeks, then rolls out to all stores if it works.

## Action items
- [ ] **Hannah**: Send an example of the screenshot report she sends today (today)
- [ ] **Alex**: Prototype of the weekly report for Hannah (before Christmas)
- [ ] **Alex**: Confirm SAML SSO is available before the March exception ends

## Open questions
- Is a budget for additional seats realistic after the pilot?
- Which regional average should the comparison use?
