import Foundation

extension WebBridge {
    /// Account/bootstrap pages may use SPA links. Route those to native screens
    /// before the website can mount its dashboard or board renderer.
    static let nativeRouteScript = #"""
    (() => {
      const route = value => {
        try {
          const u = new URL(value, location.href);
          if (u.origin !== location.origin || u.username || u.password || u.search || u.hash) return null;
          return u.pathname === '/' || /^\/(?:space|join)\/[A-Za-z0-9_-]{1,256}\/?$/.test(u.pathname) ? u.href : null;
        } catch { return null; }
      };
      const open = value => {
        const url = route(value); if (!url) return false;
        window.webkit.messageHandlers.nativeRoute.postMessage(url); return true;
      };
      for (const name of ['pushState', 'replaceState']) {
        const original = history[name];
        history[name] = function(state, unused, url) {
          if (url != null && open(url)) return;
          return original.apply(this, arguments);
        };
      }
      document.addEventListener('click', event => {
        const anchor = event.target.closest?.('a[href]');
        if (anchor && route(anchor.href)) { event.preventDefault(); event.stopImmediatePropagation(); open(anchor.href); }
      }, true);
    })();
    """#
}
