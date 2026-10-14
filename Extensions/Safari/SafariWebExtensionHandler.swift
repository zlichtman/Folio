import SafariServices

/// Safari asks a web extension's app extension to answer native messages. Folio's extension talks to the app over
/// its local connection instead, so this only acknowledges.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems:[reply],completionHandler:nil)
    }
}
