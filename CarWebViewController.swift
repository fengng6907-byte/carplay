import UIKit
import WebKit
import SwiftUI

/// Phone/external-display web playback host. Do not install this controller in a
/// CPTemplateApplicationScene: public CarPlay APIs do not expose arbitrary WebKit UI.
@MainActor
final class CarWebViewController: UIViewController, WebVideoControlling {
    private enum ScriptMessage {
        static let mediaState = "omniCastMediaState"
        static let navigation = "omniCastNavigation"
    }

    private(set) var webView: WKWebView!
    private var pendingCommand: WebMediaCommand?
    var interactionAllowed = true {
        didSet { updateInteractionPolicy() }
    }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.websiteDataStore = .default()

        let content = WKUserContentController()
        content.addUserScript(WKUserScript(
            source: Self.viewportAndAutomotiveCSS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        content.addUserScript(WKUserScript(
            source: Self.mediaBridge,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))

        // WKUserContentController strongly retains handlers, so use a weak proxy.
        content.add(WeakScriptHandler(target: self), name: ScriptMessage.mediaState)
        configuration.userContentController = content

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.customUserAgent = Self.desktopSafariUserAgent
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        PlayerManager.shared.attach(webController: self)
        updateInteractionPolicy()
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: ScriptMessage.mediaState)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // WKWebView follows the scene/window bounds, including ultrawide external displays.
        webView.frame = view.bounds
    }

    func loadMediaPage(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        loadViewIfNeeded()
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    func sendMediaCommand(_ command: WebMediaCommand) {
        loadViewIfNeeded()
        guard !webView.isLoading else {
            pendingCommand = command
            return
        }
        webView.evaluateJavaScript(Self.javaScript(for: command))
    }

    private func updateInteractionPolicy() {
        guard isViewLoaded else { return }
        webView.isUserInteractionEnabled = interactionAllowed
        webView.accessibilityElementsHidden = !interactionAllowed
        webView.evaluateJavaScript("window.OmniCast && window.OmniCast.setInteractionAllowed(\(interactionAllowed));")
    }

    private static func javaScript(for command: WebMediaCommand) -> String {
        switch command {
        case .play: return "window.OmniCast && window.OmniCast.command('play');"
        case .pause: return "window.OmniCast && window.OmniCast.command('pause');"
        case .stop: return "window.OmniCast && window.OmniCast.command('stop');"
        case let .seekRelative(seconds):
            return "window.OmniCast && window.OmniCast.command('seekRelative', \(seconds));"
        case let .seekAbsolute(seconds):
            return "window.OmniCast && window.OmniCast.command('seekAbsolute', \(seconds));"
        }
    }

    /// A current iPad-class Safari UA. Keep this explicit because some media sites
    /// otherwise redirect to their native app. Do not use it to misrepresent capabilities.
    private static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let viewportAndAutomotiveCSS = #"""
    (() => {
      const ensureViewport = () => {
        let viewport = document.querySelector('meta[name="viewport"]');
        if (!viewport) {
          viewport = document.createElement('meta');
          viewport.name = 'viewport';
          document.head.appendChild(viewport);
        }
        viewport.content = 'width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover';
      };

      const installStyle = () => {
        if (document.getElementById('omnicast-automotive-style')) return;
        const style = document.createElement('style');
        style.id = 'omnicast-automotive-style';
        style.textContent = `
          video { max-width: 100vw !important; max-height: 100vh !important; background: #000 !important; }
          button, [role="button"], input[type="range"], select {
            min-width: 56px !important; min-height: 56px !important;
            touch-action: manipulation !important;
          }
          #omnicast-controls {
            position: fixed; left: 50%; bottom: max(24px, env(safe-area-inset-bottom));
            transform: translateX(-50%); z-index: 2147483647; display: flex; gap: 18px;
            padding: 12px 18px; border-radius: 18px; background: rgba(0,0,0,.72);
          }
          #omnicast-controls button { color: white; background: #333; border: 0; border-radius: 12px; font-size: 24px; }
          html.omnicast-input-locked #omnicast-controls { display: none !important; }
        `;
        document.documentElement.appendChild(style);
      };

      // Remove only generic app-promotion and consent banners. Site authentication
      // and paywalls are intentionally left untouched.
      const cleanBanners = () => {
        const selectors = [
          '[aria-label*="Open in app" i]', '[aria-label*="Open in YouTube" i]',
          '[class*="app-banner" i]', '[id*="app-banner" i]',
          '[class*="cookie-banner" i]', '[id*="cookie-banner" i]',
          '[class*="consent-banner" i]'
        ];
        document.querySelectorAll(selectors.join(',')).forEach(node => node.remove());
      };

      ensureViewport(); installStyle(); cleanBanners();
      new MutationObserver(() => { installStyle(); cleanBanners(); })
        .observe(document.documentElement, { childList: true, subtree: true });
    })();
    """#

    private static let mediaBridge = #"""
    (() => {
      const videos = () => Array.from(document.querySelectorAll('video'));
      const primary = () => videos().sort((a, b) => (b.clientWidth*b.clientHeight) - (a.clientWidth*a.clientHeight))[0];
      const report = () => {
        const v = primary(); if (!v) return;
        window.webkit?.messageHandlers?.omniCastMediaState?.postMessage({
          playing: !v.paused && !v.ended,
          buffering: !v.paused && !v.ended && v.readyState < 3,
          ended: v.ended,
          currentTime: Number.isFinite(v.currentTime) ? v.currentTime : 0,
          duration: Number.isFinite(v.duration) ? v.duration : 0,
          title: document.title || ''
        });
      };
      const bind = v => {
        if (v.dataset.omnicastBound) return;
        v.dataset.omnicastBound = '1';
        v.playsInline = true; v.setAttribute('playsinline', '');
        ['play','pause','timeupdate','durationchange','ended'].forEach(e => v.addEventListener(e, report));
      };
      const scan = () => videos().forEach(bind);
      window.OmniCast = {
        command(name, value, broadcast = true) {
          if (broadcast) {
            document.querySelectorAll('iframe').forEach(frame => {
              try { frame.contentWindow.postMessage({omnicastCommand: name, value}, '*'); } catch (_) {}
            });
          }
          const v = primary(); if (!v) return false;
          if (name === 'play') v.play().catch(() => {});
          if (name === 'pause') v.pause();
          if (name === 'stop') { v.pause(); v.currentTime = 0; }
          if (name === 'seekRelative') v.currentTime = Math.max(0, v.currentTime + Number(value || 0));
          if (name === 'seekAbsolute') v.currentTime = Math.max(0, Number(value || 0));
          report(); return true;
        },
        setInteractionAllowed(allowed) {
          document.documentElement.classList.toggle('omnicast-input-locked', !allowed);
        }
      };
      const installControls = () => {
        if (!primary() || document.getElementById('omnicast-controls')) return;
        const controls = document.createElement('div');
        controls.id = 'omnicast-controls';
        const definitions = [
          ['Back 10 seconds', '↶ 10', 'seekRelative', -10],
          ['Play', '▶︎', 'play', 0],
          ['Pause', 'Ⅱ', 'pause', 0],
          ['Forward 10 seconds', '10 ↷', 'seekRelative', 10]
        ];
        definitions.forEach(([label, text, command, value]) => {
          const button = document.createElement('button');
          button.type = 'button'; button.setAttribute('aria-label', label); button.textContent = text;
          button.addEventListener('click', event => {
            event.preventDefault(); window.OmniCast.command(command, value);
          });
          controls.appendChild(button);
        });
        document.documentElement.appendChild(controls);
      };
      window.addEventListener('message', event => {
        const data = event.data;
        if (data && typeof data.omnicastCommand === 'string') {
          window.OmniCast.command(data.omnicastCommand, data.value, false);
        }
      });
      scan(); installControls();
      new MutationObserver(() => { scan(); installControls(); })
        .observe(document.documentElement, { childList: true, subtree: true });
      setInterval(report, 1000);
    })();
    """#
}

extension CarWebViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateInteractionPolicy()
        if let pendingCommand {
            self.pendingCommand = nil
            sendMediaCommand(pendingCommand)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: CarWebViewController?

    init(target: CarWebViewController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "omniCastMediaState",
              let body = message.body as? [String: Any] else { return }
        let playing = body["playing"] as? Bool ?? false
        let buffering = body["buffering"] as? Bool ?? false
        let ended = body["ended"] as? Bool ?? false
        let current = body["currentTime"] as? Double ?? 0
        let duration = body["duration"] as? Double ?? 0
        let title = body["title"] as? String
        Task { @MainActor in
            PlayerManager.shared.receiveWebState(
                isPlaying: playing,
                isBuffering: buffering,
                hasEnded: ended,
                currentTime: current,
                duration: duration,
                title: title
            )
        }
    }
}

/// SwiftUI adapter for the phone scene; CarPlay continues to use UIKit templates.
struct OmniCastWebView: UIViewControllerRepresentable {
    var url: URL?
    var interactionAllowed: Bool

    func makeUIViewController(context: Context) -> CarWebViewController {
        let controller = CarWebViewController()
        controller.interactionAllowed = interactionAllowed
        if let url { controller.loadMediaPage(url) }
        return controller
    }

    func updateUIViewController(_ controller: CarWebViewController, context: Context) {
        controller.interactionAllowed = interactionAllowed
        if let url, controller.webView.url != url, !controller.webView.isLoading {
            controller.loadMediaPage(url)
        }
    }
}
