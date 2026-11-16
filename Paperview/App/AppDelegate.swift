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
    private var app: SpaceAppController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let app = SpaceAppController()
        self.app = app
        let window = UIWindow(windowScene: scene)
        window.rootViewController = app
        self.window = window
        window.makeKeyAndVisible()
        if let url = options.urlContexts.first?.url { app.open(url) }
        if let url = options.userActivities.first?.webpageURL { app.open(url) }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { app?.open(url) }
    }
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL { app?.open(url) }
    }
}
