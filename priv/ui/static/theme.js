/* Light/dark switch. Loaded in <head> without defer so a stored choice is applied before first
   paint (no flash of the wrong theme). The CSS does the rest via `color-scheme` + light-dark():
   no data-theme attribute means "follow the OS". Click handling is delegated from the document so
   it keeps working across htmx swaps. */
(function () {
  var root = document.documentElement;
  var KEY = "yammr-theme";

  try {
    var stored = localStorage.getItem(KEY);
    if (stored === "light" || stored === "dark") root.dataset.theme = stored;
  } catch (e) { /* storage disabled: fall back to the OS preference */ }

  document.addEventListener("click", function (e) {
    var btn = e.target.closest("[data-theme-toggle]");
    if (!btn) return;
    var dark = root.dataset.theme
      ? root.dataset.theme === "dark"
      : matchMedia("(prefers-color-scheme: dark)").matches;
    var next = dark ? "light" : "dark";
    root.dataset.theme = next;
    try { localStorage.setItem(KEY, next); } catch (e) { /* ignore */ }
  });
})();
