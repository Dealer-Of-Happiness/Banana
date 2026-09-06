//
//  ShareViewController.swift
//  AiGoodbyeShare
//
//  "Ask AiGoodbye" in the iOS share sheet. Accepts text, links, PDFs,
//  documents and images from any app.
//
//  Extensions run with a tiny memory budget, so this never loads a model:
//  it saves what was shared into the shared App Group container and opens
//  the main app, which does the thinking. Nothing leaves the device.
//

import UIKit
import UniformTypeIdentifiers
import Social

final class ShareViewController: UIViewController {

    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        label.text = NSLocalizedString("Opening AiGoodbye...", comment: "")
        label.textAlignment = .center
        label.textColor = .label
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        Task { await handleInput() }
    }

    private func handleInput() async {
        guard let item = (extensionContext?.inputItems as? [NSExtensionItem])?.first,
              let providers = item.attachments else {
            finish()
            return
        }

        for provider in providers {
            if let shared = await extract(from: provider) {
                SharedInbox.write(shared)
                openHostApp()
                return
            }
        }
        finish()
    }

    /// Pull the most useful representation out of the shared attachment.
    private func extract(from provider: NSItemProvider) async -> SharedInbox.Item? {
        // A URL (web page link)
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadItem(provider, type: UTType.url.identifier) as? URL {
            if url.isFileURL {
                if let name = SharedInbox.copyIntoContainer(url) {
                    return SharedInbox.Item(kind: .file, fileName: name, displayName: url.lastPathComponent)
                }
            } else {
                return SharedInbox.Item(kind: .url, text: url.absoluteString, displayName: url.host())
            }
        }

        // Plain text / selected text
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadItem(provider, type: UTType.plainText.identifier) as? String {
            return SharedInbox.Item(kind: .text, text: text)
        }

        // PDFs, documents and images. `loadFileRepresentation` gives a
        // temporary file that is deleted as soon as the handler returns, so
        // the copy has to happen INSIDE the handler.
        for type in [UTType.pdf, UTType.image, UTType.text, UTType.item]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let copied = await copyFileRepresentation(provider, type: type.identifier) {
                return copied
            }
            // Some providers (Photos in particular) vend a UIImage or Data
            // rather than a file, so fall back to writing the bytes.
            if let value = await loadItem(provider, type: type.identifier) {
                if let url = value as? URL, url.isFileURL,
                   let name = SharedInbox.copyIntoContainer(url) {
                    return SharedInbox.Item(kind: .file, fileName: name, displayName: url.lastPathComponent)
                }
                if let image = value as? UIImage, let data = image.jpegData(compressionQuality: 0.9),
                   let name = SharedInbox.writeIntoContainer(data, suggestedName: "shared.jpg") {
                    return SharedInbox.Item(kind: .file, fileName: name, displayName: "shared.jpg")
                }
                if let data = value as? Data,
                   let name = SharedInbox.writeIntoContainer(data, suggestedName: "shared.dat") {
                    return SharedInbox.Item(kind: .file, fileName: name, displayName: "shared.dat")
                }
            }
        }
        return nil
    }

    /// Copies the provider's file while it is still guaranteed to exist.
    private func copyFileRepresentation(_ provider: NSItemProvider, type: String) async -> SharedInbox.Item? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url, let name = SharedInbox.copyIntoContainer(url) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: SharedInbox.Item(
                    kind: .file, fileName: name, displayName: url.lastPathComponent
                ))
            }
        }
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async -> Any? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    // MARK: - Handoff

    private func openHostApp() {
        guard let url = URL(string: "\(SharedInbox.urlScheme)://shared") else {
            finish()
            return
        }
        // Walk the responder chain to reach UIApplication.open from an
        // extension (the documented workaround).
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:]) { [weak self] _ in self?.finish() }
                return
            }
            responder = current.next
        }
        finish()
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
