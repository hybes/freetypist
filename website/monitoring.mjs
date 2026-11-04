export const service = 'freetypist-website';
export const defaultDsn = 'https://cdd8a725c00b40dd8ded87246c3c35b1@error.cnnct.uk/45';

const consolePrefix = `[${service}] `;
const maxText = 16384;
const maxDepth = 12;
const redacted = '[REDACTED]';

// Secret key rules. Keys are split into words (camelCase, `-`, `_`, `.`), so `X-API-Key`, `apiKey` and
// `api_key` all become `xapikey`/`apikey`, and dotted names such as `request.data.otp` are checked by leaf.
const secretParts = [
  'password', 'passwd', 'passphrase', 'passcode', 'secret', 'token', 'apikey', 'accesskey', 'privatekey',
  'authorization', 'cookie', 'sessionid', 'sessionkey', 'csrf', 'xsrf', 'signature', 'credential',
  'recoverycode', 'backupcode', 'verificationcode', 'invitecode', 'signupcode', 'onetimecode',
  'onetimepassword', 'mfacode', 'otpcode', 'cardnumber', 'creditcard', 'securitycode', 'protectionbypass',
];
const secretWords = new Set(['otp', 'totp', 'hotp', 'mfa', '2fa', 'cvv', 'cvc', 'cvv2', 'pwd', 'jwt']);
const secretNames = new Set(['auth', 'session', 'sid', 'pin', 'invite', 'signup']);
const secretQueryNames = new Set(['code', 'state', 'key', 'sig', 'access']);
const queryKeys = new Set(['query', 'querystring', 'search', 'urlquery']);
const authSchemes = new Set(['bearer', 'basic', 'digest', 'token', 'negotiate']);
const headerLine = /\b(proxy-authorization|authorization|set-cookie|cookie)[ \t]*:/i;
const cardNumber = /\b(?:\d[ -]?){12,18}\d\b/g;
const runtimeNoise = /ExperimentalWarning|DeprecationWarning|MaxListenersExceededWarning|MODULE_TYPELESS_PACKAGE_JSON/;

function decodeKey(key) {
  if (!key.includes('%')) return key;
  try { return decodeURIComponent(key); } catch { return key; }
}

function words(segment) {
  return segment.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
}

function keyNames(rawKey) {
  const key = decodeKey(String(rawKey)).slice(0, 256);
  const segments = key.split('.');
  const all = words(key);
  return { all, leafName: words(segments[segments.length - 1]).join(''), fullName: all.join('') };
}

// Unambiguous secret names (password, token, cookie…), never treated as a leading label.
function isStrongSecretKey(rawKey) {
  const { leafName, fullName } = keyNames(rawKey);
  return secretParts.some(part => leafName.includes(part) || fullName.includes(part));
}

export function isSecretKey(rawKey, query = false) {
  if (!String(rawKey)) return false;
  const { all, leafName, fullName } = keyNames(rawKey);
  if (secretParts.some(part => leafName.includes(part) || fullName.includes(part))) return true;
  if (all.some(word => secretWords.has(word))) return true;
  if (secretNames.has(leafName) || secretNames.has(fullName)) return true;
  return query && secretQueryNames.has(leafName);
}

function isKeyChar(code) {
  return (code >= 97 && code <= 122) || (code >= 65 && code <= 90) || (code >= 48 && code <= 57)
    || code === 95 || code === 45 || code === 46 || code === 37 || code === 91 || code === 93;
}

const isSpace = code => code === 32 || code === 9 || code === 13 || code === 10 || code === 12;

function closingQuote(text, start, quote, limit = text.length) {
  for (let index = start + 1; index < limit; index++) {
    const code = text.charCodeAt(index);
    if (code === 92) index++;
    else if (code === quote) return index;
  }
  return -1;
}

// Returns the end of a secret value. Quoted sections (`a="secret"`) and bracketed values (`{...}`, `[...]`)
// belong to the value, so the whole secret is removed even when it is an array or object.
function valueEnd(text, start, query) {
  let index = start;
  let depth = 0;
  while (index < text.length) {
    const code = text.charCodeAt(index);
    if ((code === 34 || code === 39) && (depth > 0 || index === start || text[index - 1] === '=')) {
      const end = closingQuote(text, index, code);
      index = end === -1 ? text.length : end + 1;
      continue;
    }
    if (code === 34 || code === 39) break;
    if (code === 123 || code === 91) { depth++; index++; continue; }
    if ((code === 125 || code === 93) && depth > 0) { depth--; index++; continue; }
    if (depth === 0) {
      if (isSpace(code) || code === 38 || code === 60 || code === 62) break;
      if (query ? code === 35 : (code === 44 || code === 59 || code === 41 || code === 93 || code === 125)) break;
    }
    index++;
  }
  return index;
}

function wordEnd(text, start) {
  let index = start;
  while (index < text.length && !isSpace(text.charCodeAt(index))) index++;
  return index;
}

function skipSpaces(text, start) {
  let index = start;
  while (index < text.length && (text.charCodeAt(index) === 32 || text.charCodeAt(index) === 9)) index++;
  return index;
}

function looksEncoded(value) {
  return value.length >= 8 && /^[A-Za-z0-9+/=._-]+$/.test(value) && /[0-9+/=]|.[A-Z]/.test(value);
}

// One left-to-right pass per line. Each key run is read once and the scan always moves forward, so the cost
// stays linear in the length of the text.
function scrubLine(line, forceQuery) {
  let output = '';
  let copied = 0;
  let index = 0;
  const firstText = skipSpaces(line, 0);
  const replace = (start, end, quoted) => {
    output += line.slice(copied, start) + (quoted ? `"${redacted}"` : redacted);
    copied = end;
  };
  while (index < line.length) {
    const code = line.charCodeAt(index);
    let keyStart = index;
    let keyEnd;
    let keyText;
    if (code === 34 || code === 39) {
      const end = closingQuote(line, index, code, Math.min(line.length, index + 200));
      if (end === -1) { index++; continue; }
      const after = skipSpaces(line, end + 1);
      if (line[after] !== ':' && line[after] !== '=') { index++; continue; }
      keyText = line.slice(index + 1, end);
      keyEnd = end + 1;
    } else if (isKeyChar(code)) {
      keyEnd = index;
      while (keyEnd < line.length && isKeyChar(line.charCodeAt(keyEnd))) keyEnd++;
      keyText = line.slice(index, keyEnd);
    } else { index++; continue; }

    const previous = keyStart > 0 ? line[keyStart - 1] : '';
    const query = forceQuery || previous === '?' || previous === '&' || previous === '#';
    const separatorAt = skipSpaces(line, keyEnd);
    const separator = line[separatorAt];
    const lower = keyText.toLowerCase();

    if (separator !== ':' && separator !== '=') {
      if (authSchemes.has(lower) && lower !== 'token' && separatorAt > keyEnd && separatorAt < line.length) {
        const end = wordEnd(line, separatorAt);
        const credential = line.slice(separatorAt, end);
        if (lower === 'bearer' || looksEncoded(credential)) { replace(separatorAt, end); index = end; continue; }
      }
      index = keyEnd;
      continue;
    }

    if (separator === ':' && line.startsWith('//', separatorAt + 1)) {
      // URL authority: keep the user name, remove a password in `scheme://user:password@host`.
      const authorityStart = separatorAt + 3;
      let authorityEnd = authorityStart;
      let colon = -1;
      while (authorityEnd < line.length) {
        const char = line[authorityEnd];
        if (char === '/' || char === '?' || char === '#' || char === '@' || isSpace(line.charCodeAt(authorityEnd))) break;
        if (char === ':' && colon === -1) colon = authorityEnd;
        authorityEnd++;
      }
      if (line[authorityEnd] === '@' && colon !== -1) replace(colon + 1, authorityEnd);
      index = authorityEnd;
      continue;
    }

    const valueStart = skipSpaces(line, separatorAt + 1);
    // A leading `area:` followed by a phrase is a label (`session: could not verify the request`). Unambiguous
    // secret names and quoted or bracketed values are never labels.
    const label = !query && separator === ':' && keyStart === firstText && valueStart > separatorAt + 1
      && !'"\'[{'.includes(line[valueStart]) && wordEnd(line, valueStart) < line.trimEnd().length
      && !isStrongSecretKey(keyText);
    if (label || !isSecretKey(keyText, query)) { index = separatorAt + 1; continue; }

    // A cookie list (`cookie=a="x"; b="y"`) is one value, so redact to the end of the line.
    let end = !query && keyNames(keyText).leafName.includes('cookie') ? line.length : valueEnd(line, valueStart, query);
    if (authSchemes.has(line.slice(valueStart, end).toLowerCase()) && end < line.length) {
      end = valueEnd(line, skipSpaces(line, end), query);
    }
    if (end > valueStart) replace(valueStart, end, line[valueStart] === '"' && line[end - 1] === '"');
    index = Math.max(end, separatorAt + 1);
  }
  return output + line.slice(copied);
}

const sqlStatement = /\b(?:insert|update|select|delete|values|where)\b/i;
const boundParameters = /\b(?:parameters|params|bindings|binds)\b[ \t]*[:=][ \t]*/gi;
const parameterKeys = new Set(['parameters', 'params', 'bindings', 'binds', 'values']);
const statementKeys = ['sql', 'query', 'statement', 'text', 'dbstatement', 'dbquerytext'];

const namesSecretColumn = text => words(text.slice(0, maxText)).some(word => isStrongSecretKey(word) || secretWords.has(word));

// Database errors can carry bound parameters. When the statement names a secret column, the parameter list
// cannot be matched to columns safely, so the whole list is redacted.
function scrubBoundParameters(line) {
  if (!sqlStatement.test(line) || !namesSecretColumn(line)) return line;
  let output = '';
  let copied = 0;
  boundParameters.lastIndex = 0;
  for (let match = boundParameters.exec(line); match; match = boundParameters.exec(line)) {
    const start = match.index + match[0].length;
    const end = valueEnd(line, start, false);
    if (end > start) { output += line.slice(copied, start) + redacted; copied = end; }
    boundParameters.lastIndex = Math.max(end, boundParameters.lastIndex);
  }
  return output + line.slice(copied);
}

function luhn(digits) {
  let sum = 0;
  for (let index = 0; index < digits.length; index++) {
    let digit = digits.charCodeAt(digits.length - 1 - index) - 48;
    if (index % 2) { digit *= 2; if (digit > 9) digit -= 9; }
    sum += digit;
  }
  return sum % 10 === 0;
}

export function scrubText(value, { query = false } = {}) {
  const full = String(value);
  const text = full.length > maxText ? full.slice(0, maxText) : full;
  const marker = full.length > maxText ? `…[truncated ${full.length - maxText} chars]` : '';
  const lines = text.split('\n').map(line => {
    const header = headerLine.exec(line);
    if (header) return `${scrubLine(scrubBoundParameters(line.slice(0, header.index)), query)}${header[0]} ${redacted}`;
    return scrubLine(scrubBoundParameters(line), query);
  });
  return lines.join('\n').replace(cardNumber, match => (isCardNumber(match.replace(/\D/g, '')) ? '[REDACTED CARD]' : match)) + marker;
}

const isCardNumber = digits => digits.length >= 13 && digits.length <= 19 && /^[2-6]/.test(digits) && luhn(digits);
const formBody = /^[^\s=&]+=[^\s&]*(?:&[^\s=&]+=[^\s&]*)*$/;

function scrubString(value, key) {
  const leaf = words(String(key).split('.').pop() || '').join('');
  if (queryKeys.has(leaf)) return scrubText(value, { query: true });
  if ((leaf === 'data' || leaf === 'body') && value.length <= maxText && formBody.test(value)) return scrubText(value, { query: true });
  const trimmed = value.trimStart();
  if ((trimmed.startsWith('{') || trimmed.startsWith('[')) && value.length <= maxText) {
    try { return JSON.stringify(scrubValue(JSON.parse(value), key)); } catch {}
  }
  return scrubText(value);
}

export function scrubValue(value, key = '', depth = 0, seen = new WeakSet()) {
  if (value === null || value === undefined || typeof value === 'boolean') return value;
  if (key !== '' && isSecretKey(key)) return redacted;
  if (typeof value === 'string') return scrubString(value, key);
  if (typeof value === 'number') return Number.isSafeInteger(value) && isCardNumber(String(value)) ? '[REDACTED CARD]' : value;
  if (typeof value === 'bigint') return isCardNumber(String(value)) ? '[REDACTED CARD]' : value;
  if (typeof value !== 'object') return value;
  if (depth > maxDepth) return '[TRUNCATED]';
  if (value instanceof Date) return value;
  if (value instanceof Error) {
    return { name: value.name, message: scrubText(value.message), stack: value.stack && scrubText(value.stack) };
  }
  if (seen.has(value)) return '[Circular]';
  seen.add(value);
  try {
    const leaf = words(String(key).split('.').pop() || '').join('');
    if (Array.isArray(value)) {
      const pairs = queryKeys.has(leaf) || leaf === 'headers';
      return value.map(entry => (pairs && Array.isArray(entry) && entry.length === 2 && typeof entry[0] === 'string'
        ? [entry[0], isSecretKey(entry[0], true) ? redacted : scrubValue(entry[1], key, depth + 2, seen)]
        : scrubValue(entry, key, depth + 1, seen)));
    }
    // Query objects and OAuth callback bodies (`code` with `state`) use query rules, so `code`, `state` and `key`
    // are secrets there. Elsewhere `code` stays, because it is usually an error or status code.
    const query = queryKeys.has(leaf) || (typeof value.code === 'string' && typeof value.state === 'string');
    const entries = Object.entries(value);
    const statement = entries.find(([childKey, entry]) => typeof entry === 'string' && statementKeys.includes(words(childKey).join('')))?.[1];
    const secretParameters = statement !== undefined && sqlStatement.test(statement) && namesSecretColumn(statement);
    return Object.fromEntries(entries.map(([childKey, entry]) => [
      childKey, (query && isSecretKey(childKey, true)) || (secretParameters && parameterKeys.has(words(childKey).join('')))
        ? redacted : scrubValue(entry, childKey, depth + 1, seen),
    ]));
  } finally {
    seen.delete(value);
  }
}

export function sanitizeEvent(event) {
  try {
    return scrubValue(event);
  } catch (error) {
    try {
      return {
        event_id: event.event_id, timestamp: event.timestamp, level: event.level || 'error', platform: event.platform,
        tags: { application: service, service },
        message: `monitoring: event could not be scrubbed (${error?.name || typeof error})`,
      };
    } catch { return null; }
  }
}

export function sanitizeBreadcrumb(breadcrumb) {
  try { return scrubValue(breadcrumb); } catch { return null; }
}

export function sanitizeSpan(span) {
  try { return scrubValue(span); } catch { return { ...span, description: redacted, data: {} }; }
}

export function sanitizeLog(log, { runtime, hostName } = {}) {
  const attributes = log.attributes || {};
  const message = String(log.message ?? '');
  const fromConsole = attributes['sentry.origin'] === 'auto.log.console';
  // Console copies of our own logger lines are already sent directly; runtime warnings are noise.
  if (fromConsole && (message.startsWith(consolePrefix) || runtimeNoise.test(message))) return null;
  const serviceAttributes = { 'service.name': service, runtime, ...(hostName ? { 'host.name': hostName } : {}) };
  try {
    return { ...log, message: scrubText(message), attributes: { ...scrubValue(attributes), ...serviceAttributes } };
  } catch (error) {
    return { ...log, message: `monitoring: log could not be scrubbed (${error?.name || typeof error})`, attributes: serviceAttributes };
  }
}

// Logger for this site's own lines. GlitchTip shows the service name at the start of each line, so the
// message starts with the area. The console copy carries the service prefix and goes to hosting logs.
export function createLogger(sentryLogger, { output = process.env.NODE_ENV === 'test' ? null : console } = {}) {
  const write = (level, message, attributes = {}) => {
    try { output?.[level](`${consolePrefix}${scrubText(message)}`, scrubValue(attributes)); } catch {}
    try { sentryLogger?.[level](message, attributes); } catch {}
  };
  return {
    info: (message, attributes) => write('info', message, attributes),
    warn: (message, attributes) => write('warn', message, attributes),
    error: (message, attributes) => write('error', message, attributes),
  };
}

// Allows one line per key per window. The next allowed line reports how many were held back. Callers must
// include anything unique (paths, ids, statuses) in the key so that distinct data is never dropped.
export function createRepeatGate(windowMs = 60_000, now = () => Date.now()) {
  const seen = new Map();
  return key => {
    const time = now();
    const entry = seen.get(key);
    if (entry && time - entry.at < windowMs) { entry.held++; return null; }
    if (seen.size > 500) seen.clear();
    seen.set(key, { at: time, held: 0 });
    return { repeats: entry?.held || 0 };
  };
}

export function errorAttributes(error) {
  return { 'error.type': error?.name || typeof error, 'error.message': String(error?.message ?? error) };
}

// Hosts that only exist on this machine or the local network: loopback, private and link-local addresses,
// reserved development suffixes and LAN names without a dot.
export function isLocalHost(rawHost) {
  let host = String(rawHost ?? '').trim().toLowerCase();
  if (host.startsWith('[')) host = host.slice(1, host.includes(']') ? host.indexOf(']') : undefined);
  else if (host.split(':').length === 2) host = host.split(':')[0];
  host = host.replace(/\.$/, '');
  if (!host) return false;
  if (host.includes(':')) {
    if (host === '::1' || host === '::' || /^(f[cd]|fe[89ab])/.test(host)) return true;
    const mapped = host.match(/^::ffff:(?:(\d+\.\d+\.\d+\.\d+)|([0-9a-f]{1,4}):([0-9a-f]{1,4}))$/);
    if (!mapped) return false;
    if (mapped[1]) return isLocalHost(mapped[1]);
    const [high, low] = [parseInt(mapped[2], 16), parseInt(mapped[3], 16)];
    return isLocalHost(`${high >> 8}.${high & 255}.${low >> 8}.${low & 255}`);
  }
  const ipv4 = host.match(/^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/);
  if (ipv4) {
    const [a, b] = [Number(ipv4[1]), Number(ipv4[2])];
    return a === 0 || a === 127 || a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31) || (a === 169 && b === 254);
  }
  return !host.includes('.') || /\.(localhost|local|test|internal|lan|home\.arpa)$/.test(host);
}

// Host name of an absolute URL, or of a bare `host[:port]` when `bare` is set. Paths and relative URLs give ''.
function hostOf(value, bare = false) {
  const text = String(value?.value ?? value ?? '').trim();
  const absolute = /^[a-z][a-z0-9+.-]*:\/\//i.test(text);
  if (!absolute && !(bare && /^[a-z0-9.\-[\]:]+$/i.test(text))) return '';
  try { return new URL(absolute ? text : `http://${text}`).hostname; } catch { return ''; }
}

// True when an event, transaction or log came from a local address: its request URL or Host header, a URL
// attribute on a log, or the page or request being handled when it was captured.
function fromLocalHost(item, currentUrl) {
  const headers = item?.request?.headers || {};
  const attributes = item?.attributes || {};
  let current;
  try { current = currentUrl?.(); } catch {}
  const urls = [item?.request?.url, attributes['url.full'], attributes['http.url'], attributes.url, current];
  const hosts = [headers.host, headers.Host, attributes['server.address']];
  return urls.some(value => isLocalHost(hostOf(value))) || hosts.some(value => isLocalHost(hostOf(value, true)));
}

// Wrangler tells the build which command it runs for (build.mjs bakes it into both bundles). Only
// `wrangler deploy` and `wrangler versions upload` produce code that runs on Cloudflare; `wrangler dev`,
// a plain `npm run build`, tests and scripts have no command or `dev`.
const deployCommands = new Map([['deploy', 'production'], ['versions upload', 'preview']]);
const isOn = value => /^(1|true|yes)$/i.test(String(value ?? '').trim());

export function deployment(env = {}) {
  const hosted = deployCommands.get(String(process.env.WRANGLER_COMMAND ?? '').trim());
  return {
    deployed: Boolean(hosted),
    force: isOn(env.SENTRY_FORCE) || isOn(process.env.SENTRY_FORCE),
    environment: env.SENTRY_ENVIRONMENT || process.env.SENTRY_ENVIRONMENT || hosted || 'development',
  };
}

// Sends only from real deployments. In the browser the page must also be on a public host. SENTRY_FORCE=1
// turns sending on anywhere except tests, for deliberate local checks.
export function monitoringOptions(env = {}, runtime = 'worker', { consoleLoggingIntegration, hostName, currentUrl } = {}) {
  const { deployed, force, environment } = deployment(env);
  const explicitDsn = env.SENTRY_DSN?.trim();
  const testing = environment === 'test' || env.NODE_ENV === 'test' || process.env.NODE_ENV === 'test';
  let pageHost = '';
  try { pageHost = runtime === 'browser' ? hostOf(currentUrl?.()) : ''; } catch { pageHost = ''; }
  const hosted = deployed && (runtime !== 'browser' || (pageHost !== '' && !isLocalHost(pageHost)));
  const remote = item => force || !fromLocalHost(item, currentUrl);
  return {
    dsn: explicitDsn || defaultDsn,
    enabled: !testing && (force || hosted),
    environment,
    release: env.SENTRY_RELEASE || process.env.SENTRY_RELEASE || undefined,
    sampleRate: 1,
    tracesSampleRate: environment === 'production' ? 0.01 : 0,
    traceLifecycle: 'static',
    tracePropagationTargets: [],
    sendDefaultPii: false,
    dataCollection: {
      userInfo: false, cookies: false, httpHeaders: true, httpBodies: [], urlQueryParams: true,
      graphQL: { document: false, variables: false }, genAI: { inputs: false, outputs: false },
      mcp: { inputs: false, outputs: false }, databaseQueryData: false, queues: false,
      stackFrameVariables: false, frameContextLines: 0,
    },
    sendClientReports: false,
    beforeSendLog: log => (remote(log) ? sanitizeLog(log, { runtime, hostName }) : null),
    beforeSendMetric: () => null,
    maxBreadcrumbs: 50,
    initialScope: { tags: { application: service, service, monitoring_backend: 'glitchtip', runtime } },
    integrations: defaults => [
      ...defaults.filter(integration => !['BrowserSession', 'ProcessSession', 'CronTriggers', 'ConversationId'].includes(integration.name)),
      ...(consoleLoggingIntegration ? [consoleLoggingIntegration({ levels: ['warn', 'error'] })] : []),
    ],
    beforeSend: event => (remote(event) ? sanitizeEvent(event) : null),
    beforeSendTransaction: event => (remote(event) ? sanitizeEvent(event) : null),
    beforeBreadcrumb: sanitizeBreadcrumb,
  };
}
