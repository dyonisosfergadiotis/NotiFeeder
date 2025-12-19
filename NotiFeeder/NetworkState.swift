//
//  NetworkState.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 15.12.25.
//


import Foundation
import Combine
import SwiftUI

final class NetworkState: ObservableObject {
    @Published var isOffline = false
}
