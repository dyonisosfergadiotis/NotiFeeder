//
//  TrackableWebView.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 19.12.25.
//


import SwiftUI
import WebKit

// 1. Der Brückenschlag: WKWebView für SwiftUI mit Scroll-Tracking
struct TrackableWebView: UIViewRepresentable {
    let url: URL
    @Binding var isScrollingDown: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.scrollView.delegate = context.coordinator
        let request = URLRequest(url: url)
        webView.load(request)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(isScrollingDown: $isScrollingDown)
    }
    
    class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var isScrollingDown: Bool
        private var lastOffset: CGFloat = 0
        
        init(isScrollingDown: Binding<Bool>) {
            _isScrollingDown = isScrollingDown
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let currentOffset = scrollView.contentOffset.y
            let threshold: CGFloat = 5
            
            // Verhindert Flackern am oberen Rand
            if currentOffset <= 0 {
                if isScrollingDown { isScrollingDown = false }
                return
            }
            
            // Scroll-Richtung bestimmen
            if currentOffset > lastOffset + threshold {
                if !isScrollingDown { isScrollingDown = true }
            } else if currentOffset < lastOffset - threshold {
                if isScrollingDown { isScrollingDown = false }
            }
            
            lastOffset = currentOffset
        }
    }
}

// 2. Die Hauptansicht
struct WebViewContainerView: View {
    @State private var isScrollingDown = false
    @State private var toolbarVisibility: Visibility = .visible
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                
                // Die WebView
                TrackableWebView(
                    url: URL(string: "https://www.apple.com")!,
                    isScrollingDown: $isScrollingDown
                )
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            // Native Toolbar Steuerung
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(action: {}) { Image(systemName: "chevron.left") }
                    Spacer()
                    Button(action: {}) { Image(systemName: "arrow.clockwise") }
                    Spacer()
                    Button(action: {}) { Image(systemName: "chevron.right") }
                }
            }
            // Reagiert auf das Scrollen der WebView
            .toolbar(isScrollingDown ? .hidden : .visible, for: .bottomBar)
            .animation(.easeInOut(duration: 0.2), value: isScrollingDown)
        }
    }
}

#Preview {
    WebViewContainerView()
}
