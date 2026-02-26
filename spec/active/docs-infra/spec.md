# Feature: Cloudflare DNS + Hosting Infra for docs.trakrf.id

## Origin
Linear issue [TRA-327](https://linear.app/trakrf/issue/TRA-327). The Docusaurus project has been scaffolded in `trakrf/docs` (TRA-328, PR #3), so we now need the Cloudflare infrastructure to host it.

## Outcome
`docs.trakrf.id` resolves over HTTPS and serves the Docusaurus site from `trakrf/docs`, deployed automatically via Cloudflare Pages on push to `main`.

## User Story
As the TrakRF team
We want a documentation portal hosted at docs.trakrf.id
So that users and integrators can access product documentation

## Context
**Current**: The `trakrf/docs` repo has a Docusaurus project ready to deploy, but no infrastructure exists to serve it.
**Existing pattern**: `trakrf/www` (Astro site) is already hosted via Cloudflare Pages with custom domains (`trakrf.id`, `preview.trakrf.id`). The docs site follows the exact same pattern.
**Desired**: Mirror the `www` Pages setup for the `docs` repo, with `docs.trakrf.id` as the custom domain.

## Technical Requirements

### New Cloudflare Pages Project (`domains/pages.tf`)
- New `cloudflare_pages_project.docs` resource
- Source: `trakrf/docs` GitHub repo, production branch `main`
- Build command: Docusaurus build (likely `pnpm build`, output dir `build`)
- Auto-deploy on push (production + preview deployments enabled)

### DNS Record (`domains/main.tf`)
- CNAME record: `docs` -> Pages project subdomain
- Proxied through Cloudflare (like the existing `www` pattern)

### Custom Domain (`domains/pages.tf`)
- `cloudflare_pages_domain.docs_custom` attaching `docs.trakrf.id` to the Pages project

### SSL/TLS
- Handled automatically by Cloudflare proxy + existing zone-level strict SSL settings
- No additional configuration needed

## What This Does NOT Include
- No preview subdomain (e.g., `preview.docs.trakrf.id`) — can add later if needed
- No changes to the `trakrf/docs` repo itself (already handled by TRA-328)
- No GitHub Actions pipeline — Cloudflare Pages' built-in GitHub integration handles deploy

## Validation Criteria
- [ ] `tofu plan` shows only the expected new resources (Pages project, DNS record, custom domain)
- [ ] `tofu apply` succeeds cleanly
- [ ] `docs.trakrf.id` resolves via DNS
- [ ] Site loads over HTTPS with valid certificate
- [ ] Push to `trakrf/docs` main branch triggers automatic deployment

## Notes
- Docusaurus default build output dir is `build` (not `dist` like Astro) — verify against the actual `trakrf/docs` config
- The existing `www` Pages project in `pages.tf` is the template to follow
