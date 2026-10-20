const examples = {
  completion: { before: 'Thanks for ', suggestion: 'your help.', after: 'Thanks for your help.', hint: 'Press Tab to accept', description: 'FreeTypist suggests “your help.” after “Thanks for ”. Tab accepts the suggestion.' },
  spelling: { before: 'I’ll definately be there.', target: 'definately', after: 'I’ll definitely be there.', hint: 'Fix “definately” with Tab', description: 'Tab corrects “I’ll definately be there.” to “I’ll definitely be there.”' },
  emoji: { before: 'Ship :rocket:', target: ':rocket:', after: 'Ship 🚀', hint: 'Replace :rocket: with Tab', description: 'Tab replaces “Ship :rocket:” with “Ship 🚀”.' },
};
let selected = 'completion';
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
let playing = !reducedMotion.matches;
let phase = playing ? 'typing' : 'suggestion';
let characters = playing ? 0 : Array.from(examples[selected].before).length;
let visible = !('IntersectionObserver' in window);
let timer;
const demo = document.querySelector('.example');
const typed = document.querySelector('#example-typed');
const ghost = document.querySelector('#example-ghost');
const hint = document.querySelector('#example-hint');
const accept = document.querySelector('#example-accept');
const play = document.querySelector('#example-play');
const description = document.querySelector('#example-description');

function render() {
  const example = examples[selected];
  const accepted = phase === 'accepted';
  const suggesting = phase === 'suggestion' || phase === 'pressing';
  typed.textContent = accepted ? example.after : Array.from(example.before).slice(0, characters).join('');
  if (suggesting && example.target) {
    const start = example.before.indexOf(example.target);
    const replacement = document.createElement('span');
    replacement.className = 'replacement';
    replacement.textContent = example.target;
    typed.replaceChildren(example.before.slice(0, start), replacement, example.before.slice(start + example.target.length));
  }
  ghost.textContent = suggesting ? (example.suggestion || '') : '';
  hint.textContent = accepted ? 'Accepted with Tab' : example.hint;
  description.textContent = example.description;
  accept.disabled = accepted || phase === 'pressing';
  accept.classList.toggle('is-pressed', phase === 'pressing');
  demo.dataset.playing = String(playing);
  demo.dataset.phase = phase;
  play.hidden = false;
  play.textContent = playing ? 'Pause' : 'Play';
  play.setAttribute('aria-label', playing ? 'Pause automatic examples' : 'Play automatic examples');
  document.querySelectorAll('[data-example]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.example === selected)));
}

function queue() {
  clearTimeout(timer);
  if (!playing || !visible || document.hidden) return;
  const delay = { typing: 75, suggestion: 1500, pressing: 180, accepted: 2200 }[phase];
  timer = setTimeout(advance, delay);
}

function advance() {
  if (phase === 'typing') {
    characters++;
    if (characters >= Array.from(examples[selected].before).length) phase = 'suggestion';
  } else if (phase === 'suggestion') {
    phase = 'pressing';
  } else if (phase === 'pressing') {
    phase = 'accepted';
  } else {
    const names = Object.keys(examples);
    selected = names[(names.indexOf(selected) + 1) % names.length];
    phase = 'typing';
    characters = 0;
  }
  render();
  queue();
}

accept.addEventListener('click', () => { phase = 'accepted'; render(); queue(); });
play.addEventListener('click', () => { playing = !playing; render(); queue(); });
document.querySelectorAll('[data-example]').forEach(button => button.addEventListener('click', () => {
  selected = button.dataset.example;
  phase = 'suggestion';
  characters = Array.from(examples[selected].before).length;
  render();
  queue();
}));
reducedMotion.addEventListener('change', event => {
  if (event.matches) {
    playing = false;
    phase = 'suggestion';
    characters = Array.from(examples[selected].before).length;
    render();
    queue();
  }
});
document.addEventListener('visibilitychange', queue);
if ('IntersectionObserver' in window) {
  new IntersectionObserver(entries => {
    visible = entries[0].isIntersecting;
    queue();
  }, { threshold: 0.15 }).observe(demo);
}
render();
queue();

const download = document.querySelector('#download');
const status = document.querySelector('#release-status');
fetch('/release.json', { cache: 'no-store', signal: AbortSignal.timeout(10000) }).then(async response => {
  if (!response.ok) throw new Error('Unavailable');
  const release = await response.json();
  const platform = document.createElement('span');
  platform.className = 'release-line';
  platform.textContent = `v${release.version} · Apple silicon · macOS ${release.minimumSystemVersion.replace(/\.0$/, '')}+`;
  const trust = document.createElement('span');
  trust.className = 'release-line';
  trust.textContent = `${Math.round(release.size / 1e6)} MB download · Notarised by Apple`;
  status.replaceChildren(platform, trust);
}).catch(() => {
  status.textContent = 'The download is being prepared. Please check back shortly.';
  download.textContent = 'Download being prepared';
  download.setAttribute('aria-disabled', 'true');
  download.removeAttribute('href');
});
