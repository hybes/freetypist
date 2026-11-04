# Website

Cloudflare Worker `freetypist-website` serves `type.cnnct.uk`. Source assets live in `public/`; the Mac app is separate.

Use Node 24 and npm. From this directory:

```sh
npm ci
npm test
npm run dev
```

Deploy by hand with `npm run deploy` and the existing Cloudflare login. To check the deployment without publishing, run `npm run deploy -- --dry-run`.

Wrangler runs `npm run build` before development and deployment. It bundles the Worker and browser SDK locally into `dist/`, then serves `dist/public/`. A clean checkout needs no generated files. There are no separate lint or typecheck commands.

## GlitchTip

Worker and browser errors go to [GlitchTip](https://error.cnnct.uk), organisation `connect-dorset`, project `freetypist-website`. The public DSN is the default in code. Events carry `application: freetypist-website` and a runtime tag.

Errors are sampled at 100%; production traces at 1%. Local development is disabled unless a DSN is explicitly set, and tests always disable reporting. Sessions, streamed spans, logs, metrics, replay, profiling, feedback and cron check-ins are disabled. The SDK does not collect personal data, headers, cookies, query strings or request bodies. The scrubber also removes credentials from error text, breadcrumbs and spans.

Optional overrides are listed in `.env.example`. It is a reference, not a file that the build loads. Export build variables in the shell or set them in Workers Builds. `SENTRY_DSN` is a Worker runtime variable; use `.dev.vars` for local Worker overrides. `PUBLIC_SENTRY_DSN` is the browser's build-time override, and its origin is added to `connect-src` automatically. Scripts remain same-origin.

For local reporting, export `PUBLIC_SENTRY_DSN` before `npm run dev` for browser errors, or set `SENTRY_DSN` in `.dev.vars` for Worker errors. Do not copy the production environment setting into local configuration. Optional `SENTRY_ENVIRONMENT` and `SENTRY_RELEASE` can be set at build time and overridden for the Worker at runtime. Releases default to `freetypist-website@<git commit>`.

When the build-only secret `SENTRY_AUTH_TOKEN` is present in production, source maps for both bundles are uploaded to `https://error.cnnct.uk/` for `connect-dorset/freetypist-website`. The build continues if the token is missing or upload fails. Maps are removed before deployment, including from public assets. There is no commit association or deploy record. Keep the token out of Worker runtime variables.

Run `npm run monitoring:verify` to send one intentional error through the Worker SDK and check that ingestion returns HTTP 200. It is tagged `test: glitchtip-migration` and can be resolved afterwards. Ordinary tests use an in-memory transport.

## Workers Builds

After the PR merges, connect `hybes/freetypist` to the existing Worker with these settings:

| Setting | Value |
| --- | --- |
| Production branch | `master` |
| Root directory | `website` |
| Build command | `npm ci && npm test` |
| Deploy command | `npm run deploy` |
| Build variables | `NODE_VERSION` (24) |
| Build secret | `SENTRY_AUTH_TOKEN` (optional; enables source-map uploads) |

The deploy command runs the bundle build through Wrangler. No runtime variables are required for the supplied DSN. Optional build variables: `PUBLIC_SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`. Optional Worker runtime variables: `SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`. Cloudflare supplies the deployment credentials when the repository is connected to Workers Builds.
