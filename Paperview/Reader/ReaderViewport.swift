import Foundation
import CryptoKit

struct ReaderViewport: Codable {
    var position: ReadingPosition
    var horizontal: Double
    var isValid: Bool {
        (1...10000).contains(position.page) && position.scroll.isFinite && (0...1).contains(position.scroll) &&
        position.zoom.isFinite && (0.5...3).contains(position.zoom) && horizontal.isFinite && (0...1).contains(horizontal)
    }
    static func key(owner: String, paperID: String) -> String {
        let data = try! JSONEncoder().encode([owner, paperID])
        return "reader.viewport." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func saved(key: String, in defaults: UserDefaults) -> ReaderViewport? {
        guard let data = defaults.data(forKey: key), let viewport = try? JSONDecoder().decode(Self.self, from: data), viewport.isValid else { return nil }
        return viewport
    }
    func save(key: String, in defaults: UserDefaults) {
        guard isValid else { return }
        defaults.set(try! JSONEncoder().encode(self), forKey: key)
    }
}
