// iOS 外壳：一个全屏横屏的原生窗口，里面只放游戏页面（WKWebView）。
// 只编一次（GitHub Actions 的 macOS 上 swiftc 直接编，不用 Xcode 工程），所有服主共用这个可执行文件；
// 名字、Bundle ID、图标、地址都是服务器出包时换的（Info.plist + shell.json）。
import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        app.isIdleTimerDisabled = true   // 屏幕常亮
        return true
    }
}

// 用场景生命周期（iOS 26 之后苹果要求必须用）；Info.plist 里按 "SceneDelegate" 这个名字找
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.backgroundColor = .black
        w.rootViewController = ShellViewController()
        w.makeKeyAndVisible()
        window = w
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = true
    }
}

final class ShellViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate {
    private var web: WKWebView!
    private let errorView = UIView()
    private var home: URL?
    private var agent = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        loadConfig()
        createWeb()
        buildErrorView()
        if let u = home { web.load(URLRequest(url: u)) } else { showError() }
    }

    private func loadConfig() {
        guard let f = Bundle.main.url(forResource: "shell", withExtension: "json"),
              let d = try? Data(contentsOf: f),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        if let s = o["url"] as? String { home = URL(string: s) }
        agent = (o["agent"] as? String) ?? ""
    }

    private func createWeb() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()
        // iPad 默认按电脑版打开网页，强制手机版，触屏逻辑和手机一致
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile
        // UA 末尾加 App 标识，网页端据此知道是在 App 里（保留 Mobile/ 段，页面的手机判断不受影响）
        cfg.applicationNameForUserAgent = agent.isEmpty ? "Mobile/15E148" : "Mobile/15E148 " + agent
        // 长按不出系统菜单、不选字（输入框照常能选），不能缩放
        let css = "*{-webkit-touch-callout:none;-webkit-user-select:none;-webkit-tap-highlight-color:transparent}"
            + "input,textarea{-webkit-user-select:auto}"
        let js = """
        (function(){var s=document.createElement('style');s.textContent='\(css)';
        (document.head||document.documentElement).appendChild(s);
        var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.name='viewport';
        (document.head||document.documentElement).appendChild(m);}
        m.content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover';})();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let w = WKWebView(frame: view.bounds, configuration: cfg)
        w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.backgroundColor = .black
        w.scrollView.isScrollEnabled = false
        w.scrollView.bounces = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.scrollView.showsVerticalScrollIndicator = false
        w.scrollView.showsHorizontalScrollIndicator = false
        w.scrollView.delegate = self
        w.scrollView.pinchGestureRecognizer?.isEnabled = false
        w.allowsLinkPreview = false
        w.allowsBackForwardNavigationGestures = false
        w.navigationDelegate = self
        w.uiDelegate = self
        view.insertSubview(w, at: 0)
        web = w
    }

    // 不让双击 / 双指缩放
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

    // 站内链接留在游戏里；站外（充值、客服等）交给系统打开
    func webView(_ v: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url else { decisionHandler(.cancel); return }
        let scheme = u.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" { decisionHandler(.allow); return }
        if let h = home?.host, let uh = u.host, h.caseInsensitiveCompare(uh) == .orderedSame {
            decisionHandler(.allow); return
        }
        if a.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        UIApplication.shared.open(u)
        decisionHandler(.cancel)
    }

    // 页面要开新窗口（target=_blank / window.open）时也交给系统
    func webView(_ v: WKWebView, createWebViewWith c: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { UIApplication.shared.open(u) }
        return nil
    }
    // 页面的 alert / confirm / prompt 用原生弹框（WKWebView 默认什么都不显示）
    func webView(_ v: WKWebView, runJavaScriptAlertPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in done() })
        present(a, animated: true)
    }

    func webView(_ v: WKWebView, runJavaScriptConfirmPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in done(true) })
        present(a, animated: true)
    }

    func webView(_ v: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText t: String?,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: p, preferredStyle: .alert)
        a.addTextField { $0.text = t }
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(nil) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in done(a.textFields?.first?.text) })
        present(a, animated: true)
    }

    // 断网 / 服务器连不上：显示 App 自己的提示页，不出现浏览器错误页
    func webView(_ v: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        if (e as NSError).code != NSURLErrorCancelled { showError() }
    }

    func webView(_ v: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        if (e as NSError).code != NSURLErrorCancelled { showError() }
    }

    // 页面进程被系统杀掉（内存不足）时重新加载，不让 App 白屏
    func webViewWebContentProcessDidTerminate(_ v: WKWebView) {
        if let u = home { v.load(URLRequest(url: u)) }
    }

    private func buildErrorView() {
        errorView.frame = view.bounds
        errorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        errorView.backgroundColor = .black
        errorView.isHidden = true
        let label = UILabel()
        label.text = "网络连接失败，请检查网络后重试"
        label.textColor = .white
        label.font = .systemFont(ofSize: 18)
        label.textAlignment = .center
        let btn = UIButton(type: .system)
        btn.setTitle("重新连接", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 18)
        btn.addTarget(self, action: #selector(retry), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, btn])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
        ])
        view.addSubview(errorView)
    }

    private func showError() {
        web.isHidden = true
        errorView.isHidden = false
    }

    @objc private func retry() {
        guard let u = home else { return }
        errorView.isHidden = true
        web.isHidden = false
        web.load(URLRequest(url: u))
    }

    // 全屏横屏：藏状态栏，底部横条自动隐藏，从屏幕边缘滑不会误触系统手势
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
}
