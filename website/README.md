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

**Issues.** Uncaught errors and handled failures (`captureException`) become issues tagged `service` and `application` (`freetypist-website`), `runtime` (`worker` or `browser`) and, where relevant, `operation` and `stage`. Errors are sampled at 100%; production and preview traces at 1%.

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
- `warn` `release: download details unavailable in the browser …` when the page cannot load `/release.json`. When the visitor's connection dropped the request (`Failed to fetch`, `Load failed`, `NetworkError…` or `AbortError`), it is `info` and raises no issue.
- `info` `download: redirected to <file> (v<version>)` for each `/download` redirect, with country, colo, referrer and user agent.
- Any other `console.warn` or `console.error` in either runtime, through `consoleLoggingIntegration`. Node runtime warnings (`ExperimentalWarning`, `DeprecationWarning` and similar) are dropped.

Identical release failures are logged once a minute per path, status and reason, and the next line reports how many repeats were held back. Lines with different data are never suppressed. Messages start with the area and do not repeat the service name, because GlitchTip shows it already. Open a line to see its attributes. A `[freetypist-website]` console copy goes to Workers logs (`npx wrangler tail`) and the browser console.

**What is sent.** Personal data is kept: emails, names, phone numbers, URLs and paths, query values, request headers such as `User-Agent` and `Referer`, status codes, error messages and stack traces. Only secrets are redacted, in events, breadcrumbs, spans, logs and console copies: passwords, API keys and tokens, `Authorization`/`Proxy-Authorization`/`Cookie`/`Set-Cookie` headers, cookies and session ids, OAuth `code` and `state`, URL signatures, one-time, MFA, recovery, signup and invite codes, Vercel bypass values and card numbers. Keys match in any form (`api-key`, `X-API-Key`, `apiKey`) and at any depth. `code` and `state` are secrets in query strings and OAuth callback bodies, but error `code` fields are kept. Database bound parameters are redacted as a list when the statement names a secret column, because they cannot be matched to columns safely. Values over 16,384 characters are truncated with a marker. IP addresses and user details are not collected (`sendDefaultPii` is off); the site has no accounts, so events have no user.

Sessions, metrics, replay, profiling, feedback and cron check-ins are disabled. If GlitchTip is unreachable, the SDK drops the data; the site and build carry on.

**When it reports.** Only code built by `wrangler deploy` or `wrangler versions upload` reports. Wrangler passes its command to the custom build as `WRANGLER_COMMAND`, and `build.mjs` bakes it into both bundles:

| How the code runs | Reports | `environment` |
| --- | --- | --- |
| `npm run deploy` / `wrangler deploy`, by hand or from Workers Builds | Yes | `production` |
| `wrangler versions upload` (Workers Builds non-production branches) | Yes | `preview` |
| `wrangler deploy --dry-run` | No | `development` |
| `npm run dev` / `wrangler dev`, including `--tunnel` | No | `development` |
| Plain `npm run build`, `node` scripts, anything else | No | `development` |
| `npm test` | Never, even when forced | `development` |

In the browser, a deployed bundle also needs a real browser (headless and scripted ones such as HeadlessChrome, Lightpanda, Playwright or `navigator.webdriver` never report) and the page on a public host. Pages on `localhost`, `127.0.0.1`, `::1`, `0.0.0.0`, `*.local`, `*.localhost`, `*.test`, private, link-local or Tailscale addresses (`10.x`, `192.168.x`, `172.16–31.x`, `169.254.x`, `100.64–127.x`, `*.ts.net`), dotless LAN names and `file://` do not report. As a second check, `beforeSend`, `beforeSendTransaction` and `beforeSendLog` drop anything whose request URL, `Host` header, URL attribute, current page or current Worker request is on one of those hosts. Setting `SENTRY_DSN` or `SENTRY_ENVIRONMENT=production` does not turn reporting on. Wrangler reports a dry run as `deploy`, so `build.mjs` checks the Wrangler process that started it for `--dry-run`. Wrangler rebuilds `dist/` for every `dev` and `deploy`, so a deploy bundle only runs locally if `dist/` is started without Wrangler; the host check is then the only guard.

To report from a local run on purpose, set `SENTRY_FORCE=1`. Export it before `npm run dev` or `npm run build` to force both bundles, or put it in `.dev.vars` to force only the Worker. Forced runs skip the local-host check and are tagged `development` unless `SENTRY_ENVIRONMENT` says otherwise. Leave it unset afterwards.

Optional overrides are listed in `.env.example`. It is a reference, not a file that the build loads. Export build variables in the shell or set them in Workers Builds. `SENTRY_DSN` is a Worker runtime variable; use `.dev.vars` for local Worker overrides. `PUBLIC_SENTRY_DSN` is the browser's build-time override, and its origin is added to `connect-src` automatically. Scripts remain same-origin.

To send local reports somewhere other than the default project, combine `SENTRY_FORCE=1` with `PUBLIC_SENTRY_DSN` (browser) or `SENTRY_DSN` in `.dev.vars` (Worker). Optional `SENTRY_ENVIRONMENT` and `SENTRY_RELEASE` can be set at build time and overridden for the Worker at runtime. Without `SENTRY_ENVIRONMENT`, the environment follows the table above. Releases default to `freetypist-website@<git commit>`.

When the build-only secret `SENTRY_AUTH_TOKEN` is present in a production build (`wrangler deploy`), source maps for both bundles are uploaded to `https://error.cnnct.uk/` for `connect-dorset/freetypist-website`. The build continues if the token is missing or upload fails. Maps are removed before deployment, including from public assets. There is no commit association or deploy record. Keep the token out of Worker runtime variables.

Run `npm run monitoring:verify` to force-send one warn log, one error log and one error event through the Worker SDK and check that GlitchTip returns HTTP 200 for each envelope. Their messages start with `glitchtip-check:` and can be ignored or resolved. Ordinary tests use an in-memory transport.

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

The deploy command runs the bundle build through Wrangler, which sets `WRANGLER_COMMAND` and so turns reporting on. No runtime variables are required for the supplied DSN. Do not set `SENTRY_FORCE` in Workers Builds. Optional build variables: `PUBLIC_SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`. Optional Worker runtime variables: `SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_RELEASE`. Cloudflare supplies the deployment credentials when the repository is connected to Workers Builds.
