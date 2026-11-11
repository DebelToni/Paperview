import UIKit
import WebKit

/// Keep the board's webpage viewport fixed; route indirect input into its canvas.
@MainActor final class BoardTrackpad: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    private weak var webView: WKWebView?
    let pan = UIPanGestureRecognizer()
    let pinch = UIPinchGestureRecognizer()
    private(set) var boardActive = false
    private var pageZoomLimits: (CGFloat, CGFloat)?
    private var lastPinchScale: CGFloat = 1

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        pan.allowedScrollTypesMask = .all
        for recognizer in [pan, pinch] {
            recognizer.allowedTouchTypes = [] // UIKit scroll/transform events, never touchscreen touches.
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            webView.addGestureRecognizer(recognizer)
        }
        webView.scrollView.delegate = self
        pan.addTarget(self, action: #selector(scrolled(_:)))
        pinch.addTarget(self, action: #selector(pinched(_:)))
        webView.scrollView.panGestureRecognizer.require(toFail: pan)
    }
    func setBoardActive(_ value: Bool) {
        guard let webView else { return }
        if value && !boardActive { pageZoomLimits = (webView.scrollView.minimumZoomScale, webView.scrollView.maximumZoomScale) }
        boardActive = value
        // Presence, not hover: WebKit can omit DOM hover events for indirect input.
        webView.scrollView.isScrollEnabled = !value
        webView.scrollView.bounces = !value
        webView.scrollView.bouncesZoom = !value
        webView.scrollView.pinchGestureRecognizer?.isEnabled = !value
        if value {
            webView.pageZoom = 1
            webView.scrollView.minimumZoomScale = 1
            webView.scrollView.maximumZoomScale = 1
            scrollViewDidZoom(webView.scrollView)
            scrollViewDidScroll(webView.scrollView)
        } else if let limits = pageZoomLimits {
            webView.scrollView.minimumZoomScale = limits.0
            webView.scrollView.maximumZoomScale = limits.1
            pageZoomLimits = nil
        }
    }
    // WebKit forwards these public callbacks but deliberately ignores an external
    // viewForZooming delegate. Enforce the board's fixed outer viewport here.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard boardActive, abs(scrollView.zoomScale - 1) > 0.001 else { return }
        scrollView.setZoomScale(1, animated: false)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        let fixed = CGPoint(x: -inset.left, y: -inset.top)
        guard boardActive, abs(scrollView.contentOffset.x - fixed.x) > 0.01 || abs(scrollView.contentOffset.y - fixed.y) > 0.01 else { return }
        scrollView.setContentOffset(fixed, animated: false)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        boardActive && (gestureRecognizer === pinch || other === pinch)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { boardActive }
    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed, let webView else { return }
        let delta = recognizer.translation(in: webView)
        recognizer.setTranslation(.zero, in: webView)
        forward(dx: -delta.x, dy: -delta.y, zoom: !recognizer.modifierFlags.intersection([.control, .command]).isEmpty)
    }
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed, recognizer.scale > 0 else { lastPinchScale = 1; return }
        let delta = pinchWheelDelta(scale: recognizer.scale, began: recognizer.state == .began)
        if delta != 0 { forward(dx: 0, dy: delta, zoom: true) }
    }
    func pinchWheelDelta(scale: CGFloat, began: Bool) -> CGFloat {
        precondition(scale.isFinite && scale > 0)
        if began { lastPinchScale = 1 }
        // Indirect transforms report cumulative scale. Never repeatedly apply the
        // absolute value or depend on UIKit honoring a scale=1 reset per update.
        let ratio = scale / lastPinchScale; lastPinchScale = scale
        let movement = log(ratio) * 0.6
        return -100 * min(0.08, max(-0.08, movement))
    }
    func forward(dx: CGFloat, dy: CGFloat, zoom: Bool) {
        guard boardActive, dx.isFinite, dy.isFinite else { return }
        webView?.callAsyncJavaScript("return window.__paperviewTrackpad(dx, dy, zoom)",
            arguments: ["dx": Double(dx), "dy": Double(dy), "zoom": zoom], in: nil, in: .page, completionHandler: nil)
    }
    static let script = #"""
    (() => {
      let active = false, previous = null;
      const canvas = () => document.querySelector('canvas[aria-label="Drawing canvas"]');
      const update = () => {
        const next = !!canvas();
        if (next === active) return;
        active = next;
        const html = document.documentElement, body = document.body;
        const meta = document.querySelector('meta[name="viewport"]');
        if (active) {
          previous = {overscroll: html.style.overscrollBehavior, overflow: html.style.overflow,
            bodyOverflow: body.style.overflow, viewport: meta?.content};
          html.style.overscrollBehavior = 'none'; html.style.overflow = 'hidden'; body.style.overflow = 'hidden';
          if (meta) meta.content = previous.viewport + ', minimum-scale=1, maximum-scale=1, user-scalable=no';
          scrollTo(0, 0);
        } else if (previous) {
          html.style.overscrollBehavior = previous.overscroll; html.style.overflow = previous.overflow;
          body.style.overflow = previous.bodyOverflow;
          if (meta && previous.viewport != null) meta.content = previous.viewport;
        }
        window.webkit.messageHandlers.boardTrackpad.postMessage(active);
      };
      new MutationObserver(update).observe(document, {childList: true, subtree: true});
      update();
      Object.defineProperty(window, '__paperviewTrackpad', {value: (dx, dy, zoom) => {
        const node = canvas(); if (!node) return false;
        const rect = node.getBoundingClientRect();
        node.dispatchEvent(new WheelEvent('wheel', {bubbles: true, cancelable: true,
          clientX: rect.x + rect.width / 2, clientY: rect.y + rect.height / 2,
          deltaX: dx, deltaY: dy, ctrlKey: zoom}));
        return true;
      }});
    })();
    """#
}
