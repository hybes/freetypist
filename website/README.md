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

Worker and browser errors and logs go to [GlitchTip](https://error.cnnct.uk), organisation `connect-dorset`, project `freetypist-website`. The public DSN is the default in code. All monitoring options, the scrubber and the logger live in `monitoring.mjs`.

**Issues.** Uncaught errors and handled failures (`captureException`) become issues tagged `service` and `application` (`freetypist-website`), `runtime` (`worker` or `browser`) and, where relevant, `operation` and `stage`. Errors are sampled at 100%; production traces at 1%.

**Logs.** The Logs page receives structured logs from both runtimes. Every line has these attributes:

| Attribute | Value |
| --- | --- |
| `service.name` | `freetypist-website`; pick it in the **Service** filter to see only this site |
| `runtime` | `worker` or `browser` |
| `sentry.environment`, `sentry.release` | Set by the SDK |
| `host.name` | Not set: Workers have no host name. Worker lines carry `cloudflare.colo` instead |

What is logged:

- `error` `release: metadata …` when `mac.json` cannot be fetched, returns an error status, is not JSON or fails validation (with the reason, status, path and duration).
- `error`/`warn` `release: upstream returned <status> for <file>` and `release: <file> fetch failed …` from the download and appcast proxy. 5xx and appcast failures are errors; other 4xx archive responses are warnings.
- `warn` `release: download details unavailable in the browser …` when the page cannot load `/release.json`.
- `info` `download: redirected to <file> (v<version>)` for each `/download` redirect, with country, colo, referrer and user agent.
- Any other `console.warn` or `console.error` in either runtime, through `consoleLoggingIntegration`. Node runtime warnings (`ExperimentalWarning`, `DeprecationWarning` and similar) are dropped.

Identical release failures are logged once a minute per path, status and reason, and the next line reports how many repeats were held back. Lines with different data are never suppressed. Messages start with the area and do not repeat the service name, because GlitchTip shows it already. Open a line to see its attributes. A `[freetypist-website]` console copy goes to Workers logs (`npx wrangler tail`) and the browser console.

**What is sent.** Personal data is kept: emails, names, phone numbers, URLs and paths, query values, request headers such as `User-Agent` and `Referer`, status codes, error messages and stack traces. Only secrets are redacted, in events, breadcrumbs, spans, logs and console copies: passwords, API keys and tokens, `Authorization`/`Proxy-Authorization`/`Cookie`/`Set-Cookie` headers, cookies and session ids, OAuth `code` and `state`, URL signatures, one-time, MFA, recovery, signup and invite codes, Vercel bypass values and card numbers. Keys match in any form (`api-key`, `X-API-Key`, `apiKey`) and at any depth. Values over 16,384 characters are truncated with a marker. IP addresses and user details are not collected (`sendDefaultPii` is off); the site has no accounts, so events have no user.

Sessions, metrics, replay, profiling, feedback and cron check-ins are disabled. Local development is disabled unless a DSN is explicitly set, and tests always disable reporting. If GlitchTip is unreachable, the SDK drops the data; the site and build carry on.

Optional overrides are listed in `.env.example`. It is a reference, not a file that the build loads. Export build variables in the shell or set them in Workers Builds. `SENTRY_DSN` is a Worker runtime variable; use `.dev.vars` for local Worker overrides. `PUBLIC_SENTRY_DSN` is the browser's build-time override, and its origin is added to `connect-src` automatically. Scripts remain same-origin.

For local reporting, export `PUBLIC_SENTRY_DSN` before `npm run dev` for browser errors, or set `SENTRY_DSN` in `.dev.vars` for Worker errors. Do not copy the production environment setting into local configuration. Optional `SENTRY_ENVIRONMENT` and `SENTRY_RELEASE` can be set at build time and overridden for the Worker at runtime. Releases default to `freetypist-website@<git commit>`.

When the build-only secret `SENTRY_AUTH_TOKEN` is present in production, source maps for both bundles are uploaded to `https://error.cnnct.uk/` for `connect-dorset/freetypist-website`. The build continues if the token is missing or upload fails. Maps are removed before deployment, including from public assets. There is no commit association or deploy record. Keep the token out of Worker runtime variables.

Run `npm run monitoring:verify` to send one warn log, one error log and one error event through the Worker SDK and check that GlitchTip returns HTTP 200 for each envelope. Their messages start with `glitchtip-check:` and can be ignored or resolved. Ordinary tests use an in-memory transport.

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
