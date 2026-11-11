import Foundation

struct PaperRoute: Equatable {
    let paperID: String
    let followID: String?
}

struct WebBridge {
    let origin: URL
    var accountOrigin: URL? = nil

    func trusts(_ url: URL) -> Bool {
        guard let a = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return a.scheme == b.scheme && a.host == b.host && port(a) == port(b)
            && b.user == nil && b.password == nil
    }

    // Account navigation shares WebKit's cookie store, without granting the
    // Space JavaScript bridge or native API privileges (trusts remains narrow).
    func permitsNavigation(_ url: URL) -> Bool {
        #if DEBUG
        if let accountOrigin, Self.loopbackOrigin(accountOrigin),
           WebBridge(origin: accountOrigin).trusts(url) { return true }
        #endif
        return trusts(url) || (url.scheme == "https" && url.host == "accounts.toni.foo"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil)
    }

    private func port(_ url: URLComponents) -> Int? { url.port ?? (url.scheme == "https" ? 443 : 80) }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    func paper(_ url: URL) -> PaperRoute? {
        guard trusts(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard (path.count == 3 || (path.count == 4 && path[3].isEmpty)),
              path[0].isEmpty, path[1] == "paper", Self.validID(String(path[2])) else { return nil }
        let query = parts.queryItems ?? []
        guard query.allSatisfy({ $0.name == "follow" }), query.count <= 1 else { return nil }
        let follow = query.first?.value
        guard query.isEmpty || (follow.map(Self.validID) ?? false) else { return nil }
        return PaperRoute(paperID: String(path[2]), followID: follow)
    }

    static func launchOrigin(arguments: [String]) -> URL {
        #if DEBUG
        if let raw = arguments.first(where: { $0.hasPrefix("--space-test-origin=") })?.split(separator: "=", maxSplits: 1).last,
           let url = URL(string: String(raw)), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
           c.scheme == "http", ["127.0.0.1", "localhost", "[::1]", "::1"].contains(c.host ?? ""),
           c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
           c.path.isEmpty || c.path == "/" { return url }
        #endif
        return URL(string: "https://space.toni.foo")!
    }

    static func launchAccountOrigin(arguments: [String]) -> URL? {
        #if DEBUG
        if let raw = arguments.first(where: { $0.hasPrefix("--accounts-test-origin=") })?.split(separator: "=", maxSplits: 1).last,
           let url = URL(string: String(raw)), loopbackOrigin(url) { return url }
        #endif
        return nil
    }

    private static func loopbackOrigin(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(c.host ?? "")
            && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
            && (c.path.isEmpty || c.path == "/")
    }

    // Main-frame document-start only. No secrets or configurable native endpoints.
    static let script = #"""
    (() => {
      let locked = false;
      const parse = value => {
        try { const u = new URL(value, location.href);
          return u.origin === location.origin && /^\/paper\/[A-Za-z0-9_-]{1,256}\/?$/.test(u.pathname) && !u.hash &&
            [...u.searchParams.keys()].every(k => k === 'follow') && u.searchParams.getAll('follow').length <= 1 &&
            (!u.searchParams.has('follow') || /^[A-Za-z0-9_-]{1,256}$/.test(u.searchParams.get('follow'))) ? u : null;
        } catch { return null; }
      };
      const open = value => { const u = parse(value); if (!u) return false;
        if (!locked) { locked = true; window.webkit.messageHandlers.paper.postMessage(u.href); } return true; };
      for (const name of ['pushState','replaceState']) {
        const original = history[name]; history[name] = function(state, unused, url) {
          if (url != null && open(url)) return;
          return original.apply(this, arguments);
        };
      }
      document.addEventListener('click', e => { const a = e.target.closest?.('a[href]');
        if (a && parse(a.href)) { e.preventDefault(); e.stopImmediatePropagation(); open(a.href); }
      }, true);
      let previous = location.href;
      addEventListener('popstate', e => { const target = location.href;
        if (parse(target)) { history.replaceState(null, '', previous); e.stopImmediatePropagation(); open(target); }
        else previous = target;
      }, true);
      const push = history.pushState, replace = history.replaceState;
      history.pushState = function() { const r = push.apply(this, arguments); previous = location.href; return r; };
      history.replaceState = function() { const r = replace.apply(this, arguments); previous = location.href; return r; };
      Object.defineProperty(window, '__paperviewPause', {value: () => { locked = true; }});
      Object.defineProperty(window, '__paperviewResume', {value: () => { locked = false; }});
    })();
    """#
}
