import { init, captureException, withStaticSpan } from '@sentry/browser';
import { monitoringOptions, sanitizeSpan } from './monitoring.mjs';

init({
  ...monitoringOptions({ SENTRY_DSN: process.env.PUBLIC_SENTRY_DSN }, 'browser'),
  beforeSendSpan: withStaticSpan(sanitizeSpan),
});

export { captureException };
