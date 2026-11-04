import { init, captureException, consoleLoggingIntegration, logger, withStaticSpan } from '@sentry/browser';
import { createLogger, errorAttributes, monitoringOptions, sanitizeSpan } from './monitoring.mjs';

init({
  ...monitoringOptions({ SENTRY_DSN: process.env.PUBLIC_SENTRY_DSN }, 'browser', { consoleLoggingIntegration }),
  beforeSendSpan: withStaticSpan(sanitizeSpan),
});

export const log = createLogger(logger);
export { captureException, errorAttributes };
