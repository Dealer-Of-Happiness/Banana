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

    /// Human explanation of what this request was for.
    var purpose: String {
        if host.contains("huggingface") || host.contains("hf.co") {
            return L10n.text("Downloading AI model files")
        }
        return L10n.text("Other")
    }
}

@MainActor
final class NetworkAudit: ObservableObject {
    static let shared = NetworkAudit()

    @Published private(set) var events: [NetworkEvent] = []
    /// Count since install, so the number survives log trimming.
    @Published private(set) var totalCount: Int

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

    fileprivate func record(_ request: URLRequest) {
        guard let url = request.url, let host = url.host() else { return }
        let event = NetworkEvent(
            host: host,
            path: url.path().isEmpty ? "/" : url.path(),
            date: Date(),
            method: request.httpMethod ?? "GET"
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
