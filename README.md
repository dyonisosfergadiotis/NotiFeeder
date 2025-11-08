# NotiFeeder

NotiFeeder ist eine native iOS-/iPadOS-App zum Verwalten beliebiger RSS-Feeds. Die App sammelt neue Artikel, zeigt sie in einer kompakten Kartenansicht an, erlaubt Bookmarks, Volltextsuche, Lesestatus und verschickt lokale Benachrichtigungen pro Artikel. Das aktuelle Release trägt die Versionsnummer **1.2.3**.

## Features

- **Mehrere Feeds**: Nutzer:innen können beliebig viele RSS/Atom-Feeds hinterlegen, bearbeiten und entfernen.
- **Artikelverwaltung**: Neue Meldungen werden gruppiert dargestellt, lassen sich sortieren (neueste / älteste / alphabetisch) und als gelesen/ungelesen markieren.
- **Bookmarks & SwiftData**: Lieblingsartikel werden lokal via SwiftData gesichert und stehen in einem eigenen Tab bereit – inklusive Offline-Zugriff.
- **Benachrichtigungen**: Für jeden neuen Artikel wird (bei aktivierten Berechtigungen) eine lokale Notification mit Titel & kurzem Inhalt versendet. Die Herkunfts-Feeds können in den Einstellungen gefiltert werden.
- **Suche**: Eine durchsuchbare Übersicht aller geladenen Artikel, inklusive Hervorhebung der Suchbegriffe in Titel und Zusammenfassung.
- **Hintergrundaktualisierung**: Über `BGAppRefreshTask` werden Feeds regelmäßig aktualisiert; neue Artikel werden auch im Hintergrund erkannt.
- **Theming**: Jeder Feed kann eine eigene Farbe erhalten; das globale Farbschema richtet sich nach `ThemeSettings`.

## Anforderungen

- Xcode 15.3 oder neuer (Swift 5.9, iOS 17 SDK – `IPHONEOS_DEPLOYMENT_TARGET = 17.0`).
- Ein iOS-/iPadOS-Gerät oder Simulator mit iOS 17.
- Für Benachrichtigungen muss der Nutzer die entsprechenden Berechtigungen erlauben.

## Projektstruktur (Auszug)

```
NotiFeeder/
├─ ArticleStore.swift            # Persistenz für Artikel + Lesestatus (UserDefaults)
├─ NotificationScheduler.swift   # Erzeugt lokale Benachrichtigungen
├─ FeedBackgroundFetcher.swift   # Hintergrund-Refresh via BGTask
├─ Views/                        # UI (Feed, Suche, Bookmarks, Settings …)
├─ NotificationDeliveryTracker.swift # Hilfsklasse zur Duplikat-Vermeidung bei Notifications
└─ ReleaseNotes.swift            # What's-New-Flow für neue Versionen
```

## Build & Run

1. Projekt klonen und in das Verzeichnis wechseln.
2. In Xcode öffnen (`open NotiFeeder.xcodeproj`) oder via CLI bauen:

   ```bash
   xcodebuild -scheme NotiFeeder -project NotiFeeder.xcodeproj
   ```

3. Zielgerät/Simulator auswählen, Run (`⌘R`). Beim ersten Start nach Feeds gefragt werden (Einstellungen → Feeds).

### Hinweise zu Benachrichtigungen

- Beim ersten Start fordert `NotificationScheduler` die Berechtigung an.
- Welche Feeds Notifications senden dürfen, lässt sich im Tab „Einstellungen“ unter „Benachrichtigungen“ konfigurieren.
- Die App verschickt einzelne Notifications pro Artikel (kein Sammelbadge), inklusive Feed-Titel und kurzem AUSZUG.

### Hintergrundaktualisierung

- Die App registriert `BGAppRefreshTask` mit Identifier `de.dyonisos.NotiFeeder.refresh`.
- Die Intervall-Steuerung liegt bei iOS; standardmäßig wird alle 30 Minuten ein neuer Task angefragt (`scheduleNextFetch`).

## Datenhaltung

- **Feeds & Artikel**: werden in `UserDefaults` als JSON gespeichert (`savedFeeds`, `savedArticles`).
- **Bookmarks**: SwiftData `FeedEntryModel` in der Standard-Model-Container-Konfiguration (lokal auf dem Gerät).
- **Lesestatus**: separate ID-Liste (`readArticleIDs`) in `UserDefaults`.

## Contribution & Support

Pull-Requests werden willkommen geheißen. Bitte halte dich an SwiftLint-ähnliche Standards (keine force unwraps ohne Not, strukturierte SwiftUI-Layouts). Bei Fragen oder Bugreports einfach ein Issue anlegen.

## Lizenz

Kein offizieller Lizenztext vorhanden – falls du den Code verwenden möchtest, bitte den Autor (Dyonisos Fergadiotis) kontaktieren.
