document.documentElement.classList.add("js");

const header = document.querySelector("[data-header]");
const nav = document.querySelector("[data-nav]");
const navToggle = document.querySelector("[data-nav-toggle]");

navToggle?.addEventListener("click", () => {
  const open = navToggle.getAttribute("aria-expanded") === "true";
  navToggle.setAttribute("aria-expanded", String(!open));
  navToggle.setAttribute("aria-label", open ? "打开导航" : "关闭导航");
  nav?.toggleAttribute("data-open", !open);
});

nav?.addEventListener("click", (event) => {
  if (!(event.target instanceof HTMLAnchorElement)) return;
  navToggle?.setAttribute("aria-expanded", "false");
  navToggle?.setAttribute("aria-label", "打开导航");
  nav.removeAttribute("data-open");
});

window.addEventListener("scroll", () => {
  header?.toggleAttribute("data-scrolled", window.scrollY > 24);
}, { passive: true });

const observer = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.setAttribute("data-visible", "");
    observer.unobserve(entry.target);
  }
}, { threshold: 0.12 });

document.querySelectorAll(".reveal").forEach((element) => observer.observe(element));
