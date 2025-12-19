import SwiftUI

struct NativeScrollToolbarView: View {
    @State private var isToolbarVisible: Visibility = .visible
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(1...30, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 15)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(height: 100)
                            .overlay(Text("Nachricht \(index)"))
                            .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Posteingang")
            // 1. Scroll-Logik
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldValue, newValue in
                let threshold: CGFloat = 10
                
                if newValue > oldValue + threshold && isToolbarVisible == .visible {
                    isToolbarVisible = .hidden
                } else if newValue < oldValue - threshold && isToolbarVisible == .hidden {
                    isToolbarVisible = .visible
                }
                
                // Toolbar immer zeigen, wenn man ganz oben ist
                if newValue < 10 { isToolbarVisible = .visible }
            }
            // 2. Die native Toolbar Definition
            .toolbar {
                if isToolbarVisible == .visible{
                    tb1
                }else {
                    tb2
                }
                }
            }
            // 3. DER ENTSCHEIDENDE PUNKT: Sichtbarkeit nativ steuern
            // Die Animation für den Wechsel
            .animation(.default, value: isToolbarVisible)
        }
    }
    
@ToolbarContentBuilder
private var tb1 : some ToolbarContent {
    ToolbarItemGroup(placement: .bottomBar) {
        Button(action: {}) { Image(systemName: "archivebox") }
        Button(action: {}) { Image(systemName: "folder") }
        Spacer()
        Button(action: {}) { Image(systemName: "trash") }
        Button(action: {}) { Image(systemName: "square.and.pencil") }
    }
}
        
        @ToolbarContentBuilder
private var tb2 : some ToolbarContent {
    ToolbarItemGroup(placement: .bottomBar) {
        Button(action: {}) { Image(systemName: "archivebox") }
        Spacer()
        
        Spacer()
        Button(action: {}) { Image(systemName: "square.and.pencil") }
    }
}




#Preview {
    NativeScrollToolbarView()
}
