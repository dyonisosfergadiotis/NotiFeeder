# NotiFeeder

NotiFeeder is a native iOS/iPadOS app for managing arbitrary RSS feeds. It aggregates fresh articles, displays them in a compact card layout, supports bookmarking, full-text search, read-state tracking, and fires per-article local notifications. Built entirely with SwiftUI + SwiftData, it focuses on a smooth reading workflow without external dependencies.

## Features

- **Mehrere Feeds**: Nutzer:innen können beliebig viele RSS/Atom-Feeds hinterlegen, bearbeiten und entfernen.
- **Artikelverwaltung**: Neue Meldungen werden gruppiert dargestellt, lassen sich sortieren (neueste / älteste / alphabetisch) und als gelesen/ungelesen markieren.
- **Bookmarks & SwiftData**: Lieblingsartikel werden lokal via SwiftData gesichert und stehen in einem eigenen Tab bereit – inklusive Offline-Zugriff.
- **Suche**: Eine durchsuchbare Übersicht aller geladenen Artikel, inklusive Hervorhebung der Suchbegriffe in Titel und Zusammenfassung.
- **Hintergrundaktualisierung**: Über `BGAppRefreshTask` werden Feeds regelmäßig aktualisiert; neue Artikel werden auch im Hintergrund erkannt.
- **Theming**: Jeder Feed kann eine eigene Farbe erhalten; das globale Farbschema richtet sich nach `ThemeSettings`.

## Requirements

- Xcode 15.3 or newer (Swift 5.9, iOS 17 SDK – `IPHONEOS_DEPLOYMENT_TARGET = 17.0`).
- An iOS/iPadOS 17 device or simulator.

## Build & Run

1. Clone the repo and `cd` into it.
2. Open in Xcode via `open NotiFeeder.xcodeproj` or build via CLI:

   ```bash
   xcodebuild -scheme NotiFeeder -project NotiFeeder.xcodeproj
   ```

3. Select your target device/simulator and hit Run (`⌘R`). On first launch add or edit feeds in **Settings → Feeds**.

### Background refresh

- Uses `BGAppRefreshTask` with identifier `de.dyonisos.NotiFeeder.refresh`.
- iOS decides the actual schedule; the app re-requests roughly every 30 minutes via `scheduleNextFetch()`.

## Data storage

- **Feeds & articles** live in `UserDefaults` (`savedFeeds`, `savedArticles`).
- **Bookmarks** use SwiftData’s `FeedEntryModel` in the default local container.
- **Read state** persists as a JSON list (`readArticleIDs`) in `UserDefaults`.

## Contribution & Support

Pull requests welcome. Please follow typical SwiftLint-style conventions (no force unwraps without checks, well-structured SwiftUI layouts). Open an issue if you hit a bug or have ideas.

## License

No explicit license yet. Contact the author (Dyonisos Fergadiotis) if you want to reuse code.
