# NotiFeeder

NotiFeeder ist ein natives RSS-Reader-Projekt für iOS mit Widget und Apple-Watch-Begleitapp.  
Die App ist vollständig in Swift/SwiftUI gebaut und fokussiert auf schnelles Lesen, lokale Speicherung und saubere Synchronisierung zwischen iPhone, Widget und Watch.

## Features

- Mehrere RSS/Atom-Feeds anlegen, bearbeiten, löschen
- Artikel-Feed mit Suche, Sortierung und Schnellfiltern (z. B. ungelesen, Lesezeichen)
- Persistenter Lesestatus pro Artikel
- Lesezeichen via SwiftData (`FeedEntryModel`)
- Homescreen-Widget (Small/Medium/Large) mit optional transparentem Hintergrund
- Deep Links auf Artikel (`notifeeder://article?...`) aus dem Widget in die App
- Apple-Watch-Sync über `WatchConnectivity` (Snapshot der Feeds + Öffnen auf dem iPhone)
- Onboarding-Flow zum initialen Feed-Setup

## Tech Stack

- Swift 5
- SwiftUI
- SwiftData
- WidgetKit + AppIntents
- WatchConnectivity
- UserDefaults (inkl. App Group `group.notiFeeder`)

## Targets / Schemes

Verfügbare Schemes (laut `xcodebuild -list`):

- `NotiFeeder` (iOS App)
- `NotiFeeder WidgetExtension` (Widget)
- `NotiFeeder Watch App` (watchOS App)
- `NotiFeeder WidgetExtension AWExtension` (watchOS Widget)

## Voraussetzungen

- Aktuelles Xcode mit iOS- und watchOS-SDK passend zu den Deployment Targets
- Deployment Targets im Projekt:
  - iOS App: `IPHONEOS_DEPLOYMENT_TARGET = 26.0`
  - Widget: `IPHONEOS_DEPLOYMENT_TARGET = 26.2`
  - Watch: `WATCHOS_DEPLOYMENT_TARGET = 26.4`

## Setup (lokal)

1. Repository klonen:

   ```bash
   git clone <repo-url>
   cd NotiFeeder
   ```

2. Projekt öffnen:

   ```bash
   open NotiFeeder.xcodeproj
   ```

3. In Xcode für alle Targets Signing konfigurieren (Team, Bundle IDs).
4. Falls Bundle IDs geändert werden: App Group `group.notiFeeder` in Capabilities/Entitlements konsistent anpassen.
5. `NotiFeeder` Scheme auswählen und auf Simulator oder Gerät starten.

## Build per CLI

```bash
# iOS App
xcodebuild -project NotiFeeder.xcodeproj -scheme "NotiFeeder" build

# Widget
xcodebuild -project NotiFeeder.xcodeproj -scheme "NotiFeeder WidgetExtension" build

# Watch
xcodebuild -project NotiFeeder.xcodeproj -scheme "NotiFeeder Watch App" build
```

## Projektstruktur

- `NotiFeeder/` - iOS Haupt-App
- `NotiFeeder Widget/` - Widget Extension
- `NotiFeeder AW/` - watchOS App
- `Shared/` - gemeinsame Bausteine zwischen Targets

## Datenhaltung

- Feeds + gecachte Artikel: `UserDefaults` (Keys: `savedFeeds`, `cachedEntries`, via `FeedStorage`)
- Lesestatus + Artikelindex: `UserDefaults` (Keys: `readArticleIDs`, `savedArticles`, via `ArticleStore`)
- Lesezeichen: SwiftData (`FeedEntryModel`)
- Widget-Einstellungen (Transparenz, Offset, etc.): App-Group-Defaults (`group.notiFeeder`)

## Bekannte Grenzen

- Es gibt aktuell keine automatisierten Unit/UI-Tests im Repository.

## Lizenz

Aktuell ist keine Lizenzdatei hinterlegt. Bei externer Weiterverwendung bitte vorher klären.
