//
//  NetworkAudit.swift
//  AIGoodbye
//
//  An honest, verifiable record of every network request this app makes.
//
//  A logging URLProtocol is registered at launch. `canInit` is called by
//  URLSession for every outgoing request; we record it and return false, so
//  the request proceeds normally and nothing is intercepted or modified.
//  That gives the user a real audit trail instead of a marketing promise:
//  if the app ever phoned home, it would show up here.
//

import Foundation
import Combine

struct NetworkEvent: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let path: String
    let date: Date
    let method: String
    /// Human explanation of what this request was for. Decided when the
    /// request is made, because the same path means different things then:
    /// a file listing is part of a download in progress, or a check of a
    /// model the user typed in.
    let purpose: String

    /// - Parameter downloadingRepo: the Hugging Face repository a model
    ///   download is fetching right now, if any.
    nonisolated static func purpose(host: String, path: String, downloadingRepo: String?) -> String {
        guard host.contains("huggingface") || host.contains("hf.co") else {
            return L10n.text("Other")
        }
        let lowered = path.lowercased()
        let isListing = lowered.contains("/api/models/")
        // Part of a download: the downloader lists the repository's files
        // before fetching them, and fetches config.json like any file. Both
        // used to be logged as "checking a model you asked to add".
        if let repo = downloadingRepo?.lowercased(), lowered.contains("/\(repo)") {
            return isListing
                ? L10n.text("Listing model files")
                : L10n.text("Downloading AI model files")
        }
        // Checking a model the user typed in is a few kilobytes of JSON,
        // not a download; the log should say which one this was.
        if isListing || lowered.hasSuffix("config.json") {
            return L10n.text("Checking a model you asked to add")
        }
        return L10n.text("Downloading AI model files")
    }
}

@MainActor
final class NetworkAudit: ObservableObject {
    static let shared = NetworkAudit()

    @Published private(set) var events: [NetworkEvent] = []
    /// Count since install, so the number survives log trimming.
    @Published private(set) var totalCount: Int
    /// The repository a model load is fetching, set by `MLXService` for the
    /// length of the load, so its requests are labelled as a download.
    var downloadingRepo: String?

    private static let countKey = "network_audit_total"
    private static let maxEvents = 100

    private init() {
        totalCount = UserDefaults.standard.integer(forKey: Self.countKey)
    }

    /// Install the observer. Safe to call once at launch.
    static func begin() {
        URLProtocol.registerClass(LoggingURLProtocol.self)
    }

    /// Add the observer to a session configuration the app creates itself.
    /// A globally registered URLProtocol is only consulted by the shared
    /// session, so every configuration we build must opt in explicitly.
    nonisolated static func observe(_ configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        classes.insert(LoggingURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }

    /// Log a request we are about to make on a session that a URLProtocol
    /// cannot observe. Background sessions ignore `protocolClasses` entirely,
    /// and model downloads run on one - so without this the single most
    /// important entry would be missing from the log the Privacy Center
    /// presents as complete.
    nonisolated static func note(_ url: URL, method: String = "GET") {
        Task { @MainActor in
            var request = URLRequest(url: url)
            request.httpMethod = method
            shared.record(request)
        }
    }

    /// Log the files the library's own downloader is about to fetch.
    ///
    /// swift-transformers transfers file bodies on a private `URLSession` of
    /// its own, which neither the registered URLProtocol nor `note(_:)` sees.
    /// Whenever the app hands a download to it, call this with the file URLs
    /// first, or the Privacy Center shows "No network requests" while
    /// gigabytes move - the opposite of what the screen promises.
    nonisolated static func noteLibraryDownload(files: [URL]) {
        guard !files.isEmpty else { return }
        Task { @MainActor in
            for url in files {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                shared.record(request)
            }
        }
    }

    fileprivate func record(_ request: URLRequest) {
        guard let url = request.url, let host = url.host() else { return }
        let path = url.path().isEmpty ? "/" : url.path()
        let event = NetworkEvent(
            host: host,
            path: path,
            date: Date(),
            method: request.httpMethod ?? "GET",
            purpose: NetworkEvent.purpose(host: host, path: path, downloadingRepo: downloadingRepo)
        )
        events.insert(event, at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        totalCount += 1
        UserDefaults.standard.set(totalCount, forKey: Self.countKey)
    }

    func clearLog() {
        events.removeAll()
    }
}

/// Observes requests without handling them. Returning false from `canInit`
/// means URLSession continues exactly as it would have; this class never
/// sees the response body and never modifies traffic.
final class LoggingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        Task { @MainActor in
            NetworkAudit.shared.record(request)
        }
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
