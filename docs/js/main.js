// Mint docs - minimal enhancements
(function () {
  // Highlight current section in nav on scroll (lightweight)
  const sections = Array.from(document.querySelectorAll('section[id]'));
  const navLinks = Array.from(document.querySelectorAll('.nav-links a[href^="#"]'));

  function onScroll() {
    let current = '';
    const y = window.scrollY + 120;
    for (const section of sections) {
      if (section.offsetTop <= y) current = section.id;
    }
    for (const link of navLinks) {
      const href = link.getAttribute('href');
      if (!href || href === '#download') continue;
      const active = href === '#' + current;
      link.style.color = active ? 'var(--text)' : '';
    }
  }

  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();
})();
