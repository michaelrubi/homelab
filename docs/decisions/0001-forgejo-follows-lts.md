# 0001: Forgejo follows LTS releases

- **Status:** accepted, 2026-11-28. Takes effect once Forgejo is on 19.
- **Applies to:** `codeberg.org/forgejo/forgejo` in `manifests/productivity/forgejo.yaml`

## Context

Forgejo is Flux's own git source. If it's down or its database is broken, nothing in this repo deploys, including the fix. Every Forgejo major runs one-way database migrations, so each major upgrade needs a pre-upgrade `pg_dump`, Flux suspended for the whole window, and a rollback that rebuilds the database.

Forgejo publishes a [fixed release schedule](https://forgejo.org/docs/next/admin/release-schedule/) ([JSON](https://codeberg.org/forgejo/docs/raw/branch/next/release-schedule.json)). There's a release every quarter. The April release each year is LTS and is supported for about 15 months: 7, 11, 15, 19, 23. The other releases are supported for about three months, ending two weeks after the next release ships.

On 2026-11-09 this cluster moved from 15.0 LTS to 17.0 (#194). Nobody chose to leave LTS. Renovate opened the major bump as it does for any image, and nothing in `renovate.json` held Forgejo back. The one-way migrations, and the lack of a dump taken before 17, mean there's no way back to 15. That puts the cluster on the short-support track: 17 reaches end of life on 2027-01-28, and 18 is supported only from 2027-01-14 to 2027-04-29.

## Decision

Run Forgejo on LTS releases only. Get back onto LTS by the shortest path:

1. 17 → 18 between 2027-01-14 and 2027-01-28 ([runbook](../runbooks/forgejo-18-upgrade.md)).
2. 18 → 19 LTS between 2027-04-15 and 2027-04-29.
3. Stay on 19 until 23 LTS (due 2028-04-13). 19 is supported until 2028-07-13.

Once on 19, add a Renovate rule that allows only LTS majors for Forgejo, with a `description` explaining why, the same way the Postgres rule does. Patch and minor updates within the LTS line keep coming through as usual.

## Consequences

- **Good:** one major upgrade a year instead of four, with a three-month overlap between consecutive LTS releases instead of two weeks. That's fewer one-way migrations on the service GitOps depends on.
- **Bad:** new features arrive up to a year late, and each LTS-to-LTS jump spans four releases of breaking changes at once. The upgrade runbook has to check all of them.
- **Cost now:** two non-LTS upgrades (18, then 19) in about three months.

## Alternatives considered

- **Follow every release.** That means more upgrade practice, but four one-way migrations a year on Flux's git source, each in a two-week window. Rejected for this service. Other apps here can keep tracking latest.
- **Stay on 17 or 18 past end of life.** Rejected: security fixes stop.
