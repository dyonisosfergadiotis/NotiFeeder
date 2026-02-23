import SwiftUI

extension View {
    @ViewBuilder
    func sheetCornerAlignedScrollContent(bottomInset: CGFloat = UIStylePolicy.Sheet.scrollContentBottomInset) -> some View {
        if #available(iOS 17.0, *) {
            self.contentMargins(.bottom, bottomInset, for: .scrollContent)
        } else {
            self.padding(.bottom, bottomInset)
        }
    }
}
