import { init, captureException, consoleLoggingIntegration, logger, withStaticSpan } from '@sentry/browser';
import { createLogger, errorAttributes, isVisitorNetworkFailure, monitoringOptions, sanitizeSpan } from './monitoring.mjs';

init({
  ...monitoringOptions({ SENTRY_DSN: process.env.PUBLIC_SENTRY_DSN }, 'browser', {
    consoleLoggingIntegration, currentUrl: () => globalThis.location?.href, navigator: globalThis.navigator,
  }),
  beforeSendSpan: withStaticSpan(sanitizeSpan),
});

export const log = createLogger(logger);
export { captureException, errorAttributes, isVisitorNetworkFailure };
