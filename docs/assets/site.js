/* AI Boot Pro — 页面交互（无依赖、无外部请求） */
(function () {
  "use strict";

  var doc = document;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- 滚动进度 + 顶栏状态 + 回到顶部 ---------- */
  var bar = doc.getElementById("progress-bar");
  var topbar = doc.getElementById("topbar");
  var toTop = doc.getElementById("to-top");
  var ticking = false;

  function onScroll() {
    var y = window.scrollY || doc.documentElement.scrollTop;
    var h = doc.documentElement.scrollHeight - window.innerHeight;
    var pct = h > 0 ? Math.min(100, Math.max(0, (y / h) * 100)) : 0;
    if (bar) bar.style.width = pct.toFixed(2) + "%";
    if (topbar) topbar.classList.toggle("is-stuck", y > 8);
    if (toTop) toTop.classList.toggle("show", y > 560);
    ticking = false;
  }

  window.addEventListener("scroll", function () {
    if (!ticking) {
      ticking = true;
      window.requestAnimationFrame(onScroll);
    }
  }, { passive: true });
  onScroll();

  if (toTop) {
    toTop.addEventListener("click", function () {
      window.scrollTo({ top: 0, behavior: reduce ? "auto" : "smooth" });
    });
  }

  /* ---------- 移动端菜单 ---------- */
  var toggle = doc.getElementById("menu-toggle");
  var mobileNav = doc.getElementById("mobile-nav");

  function setMenu(open) {
    if (!toggle || !mobileNav) return;
    toggle.setAttribute("aria-expanded", String(open));
    mobileNav.hidden = !open;
  }

  if (toggle && mobileNav) {
    toggle.addEventListener("click", function () {
      setMenu(mobileNav.hidden);
    });
    mobileNav.addEventListener("click", function (e) {
      if (e.target.closest("a")) setMenu(false);
    });
    doc.addEventListener("keydown", function (e) {
      if (e.key === "Escape") setMenu(false);
    });
    window.addEventListener("resize", function () {
      if (window.innerWidth > 860) setMenu(false);
    });
  }

  /* ---------- 滚动出现 ---------- */
  var revealables = [].slice.call(doc.querySelectorAll("[data-reveal]"));
  if (reduce || !("IntersectionObserver" in window)) {
    revealables.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    revealables.forEach(function (el) { io.observe(el); });
  }

  /* ---------- 导航高亮 ---------- */
  var navLinks = [].slice.call(doc.querySelectorAll(".nav a"));
  var sections = navLinks
    .map(function (a) { return doc.querySelector(a.getAttribute("href")); })
    .filter(Boolean);

  if ("IntersectionObserver" in window && sections.length) {
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        navLinks.forEach(function (a) {
          a.setAttribute("aria-current", a.getAttribute("href") === "#" + entry.target.id ? "true" : "false");
        });
      });
    }, { rootMargin: "-45% 0px -50% 0px" });
    sections.forEach(function (s) { spy.observe(s); });
  }

  /* ---------- 复制 ---------- */
  var toast = doc.getElementById("toast");
  var toastTimer = 0;

  function showToast(msg) {
    if (!toast) return;
    toast.textContent = msg;
    toast.classList.add("show");
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      toast.classList.remove("show");
    }, 1600);
  }

  function fallbackCopy(text) {
    var ta = doc.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    doc.body.appendChild(ta);
    ta.select();
    try { doc.execCommand("copy"); } catch (e) { /* ignore */ }
    doc.body.removeChild(ta);
  }

  doc.addEventListener("click", function (e) {
    var btn = e.target.closest("[data-copy]");
    if (!btn) return;
    var text = btn.getAttribute("data-copy") || "";
    var done = function () {
      var old = btn.getAttribute("data-label") || btn.textContent;
      btn.setAttribute("data-label", old);
      btn.textContent = "已复制";
      btn.classList.add("done");
      showToast("已复制到剪贴板");
      window.setTimeout(function () {
        btn.textContent = old;
        btn.classList.remove("done");
      }, 1600);
    };

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
    } else {
      fallbackCopy(text);
      done();
    }
  });

  /* ---------- 开机日志逐行出现 ---------- */
  var log = doc.getElementById("boot-log");
  if (log) {
    var lines = [].slice.call(log.children);
    if (reduce) {
      lines.forEach(function (l) { l.classList.add("on"); });
    } else {
      lines.forEach(function (l, i) {
        window.setTimeout(function () { l.classList.add("on"); }, 260 + i * 130);
      });
    }
  }

  /* ---------- 页脚年份 ---------- */
  var yearEl = doc.getElementById("year");
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());
})();
