// Hero load sequence: each terminal line prints in turn, and the matching
// container lands in the yard as its "Started" line appears.
(() => {
  const root = document.documentElement;
  const lines = document.querySelectorAll('.term .ln');
  lines.forEach((line, i) => {
    line.style.setProperty('--i', i);
    const box = line.dataset.box && document.querySelector(`.box[data-box="${line.dataset.box}"]`);
    if (box) box.style.setProperty('--i', i);
  });
  root.classList.add('js');
  requestAnimationFrame(() => root.classList.add('play'));
})();

// Copy buttons copy the command next to them.
document.addEventListener('click', async (event) => {
  const button = event.target.closest('.copy');
  if (!button) return;
  const holder = button.closest('[data-copy]');
  const text = holder ? holder.dataset.copy : button.parentElement.querySelector('code').textContent;
  try {
    await navigator.clipboard.writeText(text);
    button.textContent = 'Copied';
  } catch {
    button.textContent = 'Copy failed';
  }
  setTimeout(() => { button.textContent = 'Copy'; }, 1600);
});

// Tab sets (install routes, dashboards), each with arrow-key navigation.
document.querySelectorAll('.tabs').forEach((set) => {
  const tabs = [...set.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute('aria-selected', on);
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    });
  };
  // Panels ship visible so the page works without this script.
  select(tabs.find((t) => t.getAttribute('aria-selected') === 'true') || tabs[0]);
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', (event) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
      if (!step) return;
      const next = tabs[(i + step + tabs.length) % tabs.length];
      select(next);
      next.focus();
    });
  });
});
