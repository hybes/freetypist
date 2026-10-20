const examples = {
  completion: { before: 'Thank you for ', suggestion: 'your help with this.', after: 'Thank you for your help with this.', hint: 'Accept a suggestion with Tab' },
  spelling: { before: 'I’ll definately be there.', suggestion: '', after: 'I’ll definitely be there.', hint: 'Fix “definately” with Tab' },
  emoji: { before: 'Ship :rocket:', suggestion: '', after: 'Ship 🚀', hint: 'Replace :rocket: with Tab' },
};
let selected = 'completion';
let accepted = false;
const typed = document.querySelector('#example-typed');
const ghost = document.querySelector('#example-ghost');
const hint = document.querySelector('#example-hint');
const accept = document.querySelector('#example-accept');

function render() {
  const example = examples[selected];
  typed.textContent = accepted ? example.after : example.before;
  ghost.textContent = accepted ? '' : example.suggestion;
  hint.textContent = accepted ? 'Accepted. Choose another example to try again.' : example.hint;
  accept.disabled = accepted;
  document.querySelectorAll('[data-example]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.example === selected)));
}
accept.addEventListener('click', () => { accepted = true; render(); });
document.querySelectorAll('[data-example]').forEach(button => button.addEventListener('click', () => {
  selected = button.dataset.example; accepted = false; render();
}));

const download = document.querySelector('#download');
const status = document.querySelector('#release-status');
fetch('/release.json', { cache: 'no-store', signal: AbortSignal.timeout(10000) }).then(async response => {
  if (!response.ok) throw new Error('Unavailable');
  const release = await response.json();
  status.textContent = `v${release.version} · Apple silicon · macOS ${release.minimumSystemVersion}+ · ${Math.round(release.size / 1e6)} MB · Notarised by Apple`;
}).catch(() => {
  status.textContent = 'The download is being prepared. Please check back shortly.';
  download.textContent = 'Download being prepared';
  download.setAttribute('aria-disabled', 'true');
  download.removeAttribute('href');
});
