## What changed
<!-- One or two sentences. Link the work item. -->

Work item:

## Type of change
- [ ] Feature / enhancement
- [ ] Bug fix
- [ ] Hotfix (needs Production deployment right after merge)

## Deployment notes
- [ ] No manual pre/post steps
- [ ] Manual steps required (describe below, they must be done in Partial, UAT **and** Production):

## Checks
- [ ] Gearset validations green: Partial, UAT and Production (validate-only)
- [ ] Apex tests added/updated, coverage >= 75% on changed classes
- [ ] No org-specific values (URLs, IDs, named credentials) hard-coded
- [ ] Destructive changes reviewed (see the `delta-pr-*` artifact on the PR checks run)
