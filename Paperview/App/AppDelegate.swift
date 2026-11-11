import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: BrowserController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let browser = BrowserController()
        self.browser = browser
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: browser)
        self.window = window
        window.makeKeyAndVisible()
        if let url = options.urlContexts.first?.url { browser.open(url) }
        if let url = options.userActivities.first?.webpageURL { browser.open(url) }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { browser?.open(url) }
    }
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL { browser?.open(url) }
    }
}
