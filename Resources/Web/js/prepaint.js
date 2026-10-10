// Resolve before first paint; unavailable storage falls back to the OS theme.
    (() => {
      let preference = 'system';
      try { preference = localStorage.getItem('simmerTheme') || 'system'; } catch {}
      if (!['light', 'dark', 'system'].includes(preference)) preference = 'system';
      const dark = preference === 'dark' || (preference === 'system' && matchMedia('(prefers-color-scheme: dark)').matches);
      document.documentElement.dataset.themePreference = preference;
      document.documentElement.dataset.theme = dark ? 'dark' : 'light';
      document.querySelector('meta[name="theme-color"]').content = dark ? '#161916' : '#f3f3f0';
    })();

document.addEventListener('dblclick', e => {
    e.preventDefault();
  }, { passive: false });
