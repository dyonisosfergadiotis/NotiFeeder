struct BookmarksView: View {
    var body: some View {
        NavigationView {
            Text("Hier kommen später deine gespeicherten Artikel.")
                .foregroundColor(.secondary)
                .navigationTitle("Lesezeichen")
        }
    }
}