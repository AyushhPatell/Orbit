//
//  OrbitRoute.swift
//  ORBITMac
//

import Foundation

/// Must match `orbit-core` /chat `route_hint` and response `route` literals.
enum OrbitRoute: String, Codable, Sendable {
    case local
    case cloud
    case tooling
}
