# NotiFeeder: Article Morph, Sheet und Reader Bottom Bar

## Auftrag

Analysiere und ueberarbeite den Article-Reader-Flow technisch und visuell. Vorhandene lokale
Aenderungen nicht verwerfen. Erst Konzept/Validierung, dann Implementierung, Build und Test.

Ziel:

- Artikelkarte morpht in einen grossen Reader.
- Reader minimiert zu einer kompakten "Now Reading"-Leiste; Feed bleibt bedienbar.
- Aktive Listenkarte bleibt sichtbar und wird dezent hervorgehoben.
- Down-Swipe minimiert statt zu schliessen.
- Bottom Bar erhaelt klare Hierarchie und ein stimmiges Design.
- Bestehende Reader-Funktionen bleiben erhalten.

## Relevante Dateien

- `NotiFeeder/Views/Feed/ContentView.swift`: Feed, Auswahl, Sheet/Detents, Morphing
- `NotiFeeder/Views/Feed/FeedDetailView.swift`: Reader, Mini-Reader, Bottom Bar, Sub-Sheets
- `NotiFeeder/Views/Shared/ArticleCardView.swift`: Artikelkarte
- `NotiFeeder/AccessibilitySupport.swift`: `.minimumHitTarget()` = 44 pt
- `NotiFeeder/UIStylePolicy.swift`: Design-/Motion-Tokens

## Ist-Zustand

`FeedListView`:

```swift
@State private var activeArticle: FeedEntry?
@State private var articleViewerDetent: PresentationDetent = .large
@Namespace private var articleTransitionNamespace
```

`activeArticle != nil` praesentiert:

```swift
.sheet(isPresented: articleViewerPresentedBinding) {
    articleViewerCover
        .presentationDetents(
            [FeedDetailView.compactPresentationDetent, .large],
            selection: $articleViewerDetent
        )
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(.clear)
        .presentationBackgroundInteraction(
            .enabled(upThrough: FeedDetailView.compactPresentationDetent)
        )
}
```

- Compact-Detent: feste Hoehe `96`.
- Karte: `.matchedTransitionSource(id: entry.id, in: articleTransitionNamespace)`.
- Sheet: `.navigationTransition(.zoom(sourceID: entry.id, in: articleTransitionNamespace))`.
- Dismiss-Binding setzt `activeArticle = nil` und Detent auf `.large`.
- Compact View zeigt Quelle, Titel (max. 2 Zeilen), Lesefortschritt; Tap setzt `.large`.
- Detail/Compact werden anhand gemessener Sheet-Hoehe ueberblendet.
- Background-Interaktion ist nur im Compact-Detent aktiv.
- Tap auf andere Karte ersetzt `activeArticle` und expandiert.

Reader:

- Feed-Farbverlauf als Hintergrund
- persistente `WKWebView`
- Header: Titel, Quelle, Datum, Lesezeit
- kollabierender Navigationstitel und Lesefortschritt
- horizontal: links naechster, rechts vorheriger Artikel
- Artikelwechsel aktualisiert Read-State und scrollt nach oben
- Sub-Presentations: Reader-Einstellungen, Share Sheet, Summary-Popover

## Fehler und Sollverhalten

### 1. Minimierungs-Drag zu klein

Aktuell gelingt Minimieren praktisch nur ueber den schwer treffbaren Drag Indicator.

Soll:

- Grosszuegiger oberer Drag-Bereich, mindestens 44 pt, bevorzugt 56-64 pt.
- Sichtbarer Indicator darf klein bleiben; interaktive Flaeche ist groesser.
- Klare Gesture-Prioritaet gegenueber `WKWebView`-Scroll.
- Normales Artikel-Scrollen darf nicht versehentlich minimieren.

Umsetzung pruefen:

- Native Detent-Geste moeglichst behalten.
- Falls unzureichend: eigener oberer Drag-Bereich; Distanz/Geschwindigkeit setzen `.large` oder
  Compact-Detent.

### 2. Aktive Listenkarte wird leer

Nach Zoom-Presentation und Minimierung bleibt ein leerer Listeneintrag. Wahrscheinliche Ursache:
Die echte Karte bleibt `matchedTransitionSource`, waehrend die Destination weiterhin praesentiert
ist; SwiftUI versteckt die Quelle als Teil der aktiven Transition.

Soll:

- Quellkarte nach Oeffnungsanimation und im Compact-Zustand voll sichtbar.
- Active-State aus `activeArticle?.link == entry.link`, unabhaengig von Read/Bookmark.
- Ruhige Hervorhebung: z. B. 2-pt-Akzentrahmen, leichter Feed-Tint und kleines
  "Wird gelesen"-Badge/Icon; keine starke Daueranimation.
- Artikelwechsel verschiebt Active-State atomar.

Empfehlung:

- Produkt-State und Transition-Lebenszyklus trennen.
- Separaten `transitionSourceArticleID`/Transition-State nur fuer Present/Close verwenden.
- `matchedTransitionSource` nicht dauerhaft an die echte aktive Karte binden.
- Falls bedingtes Entfernen instabil ist: kurzlebige Snapshot-/Overlay-Kopie fuer die Transition;
  echte Karte normal rendern.

### 3. Down-Swipe dismissiert

Native Dismiss-Geste loescht ueber das Binding `activeArticle`; erwartet ist zuerst Minimieren.

Soll:

- `.large` Down-Swipe -> Compact, niemals direkt geschlossen.
- Compact bleibt bestehen, bis explizit geschlossen wird.
- Close z. B. per `xmark` in Mini-Leiste oder eindeutigem Kontextmenue; optional bewusster zweiter
  Down-Swipe aus Compact.

Empfehlung:

- `.interactiveDismissDisabled(true)` pruefen.
- `onCloseArticle` als einzige Aktion, die Selection loescht.
- Native Detents fuer `.large <-> compact`; eigener Drag nur falls erforderlich.

## Empfohlenes Zustandsmodell

```swift
enum ArticleViewerMode { case closed, expanded, compact }

@State private var activeArticle: FeedEntry?
@State private var articleViewerMode: ArticleViewerMode = .closed
@State private var transitionSourceArticleID: FeedEntry.ID?
```

Invarianten:

- `closed`: kein aktiver Artikel
- `expanded`: Reader gross, Feed nicht interaktiv
- `compact`: Artikel aktiv, Mini-Reader sichtbar, Feed interaktiv
- Transition-Source lebt nur waehrend Present/Close
- Listen-Active-State stammt nur aus `activeArticle`

Transitions:

```text
Karte: closed -> expanded
Down: expanded -> compact
Mini-Leiste Tap/Up: compact -> expanded
Andere Karte: compact(A) -> expanded(B)
Explizites Close: compact|expanded -> closed
```

## Compact Reader

Muss wie ein eigenstaendiger aktiver Reader wirken, nicht wie abgeschnittenes Sheet:

- Quellen-/Feed-Akzent
- Quelle, Titel max. 2 Zeilen, Lesefortschritt
- erkennbare Expand-Affordance
- explizites Close
- optional Thumbnail oder Bookmark, nur falls 96 pt nicht ueberladen werden
- gesamte freie Flaeche expandiert; Buttons konsumieren ihren Tap selbst

## Bottom Bar: Ist-Zustand

Native SwiftUI-Toolbar mit zwei Dreiergruppen und flexiblem Spacer.

Links:

- `textformat.size`: Reader-Einstellungen (Groesse, Familie, Ausrichtung, Zeilenhoehe)
- `safari`: Original-URL
- `square.and.arrow.up`: System Share Sheet

Rechts:

- `eye`/`eye.slash`: gelesen/ungelesen
- `bookmark`/`bookmark.fill`: Lesezeichen
- `text.line.3.summary`: On-device-Summary-Popover

Hit Targets aktuell 40 pt.

Probleme:

- Sechs gleich gewichtete Icons ohne klare Hierarchie.
- Seltene und zentrale Aktionen stehen gleichwertig nebeneinander.
- Zwei Dreiergruppen wirken je nach Breite auseinandergezogen.
- Feed-Farbe/Neutralfarbe bilden kein konsistentes Active-Modell.
- Vorhandene Collapse-Logik ist unvollstaendig/tot:
  - `isBottomToolbarExpanded` wird durch Scroll-Callbacks geaendert,
  - `bottomToolbarExpansionButton` existiert, wird aber nicht gerendert,
  - Action-Gruppen reagieren nicht auf den State.
- Native Toolbar begrenzt Layout, Material und Animation.

## Bottom Bar: Empfehlung

Hierarchie:

- Primaer sichtbar: Bookmark, Summary
- Status sichtbar: Read/Unread
- Sekundaer gebuendelt: Darstellung, Safari, Share

Design:

- Bevorzugt eigene schwebende Material-Leiste via `safeAreaInset(edge: .bottom)`.
- Drei Hauptaktionen direkt; Sekundaeres in `ellipsis`-Menue oder expandierbarer Gruppe.
- Optional Prev/Next, wenn horizontale Gesten zu wenig auffindbar sind.
- Aktive States als leicht getoente Feed-Farb-Capsule/Circle; inaktive neutral.
- Mindestens 44-pt-Hit-Targets.
- Beim Lesen dezent kompakt werden, aber Hauptaktionen nicht komplett verstecken.
- Bestehende Collapse-Logik entweder voll integrieren oder entfernen.

## Akzeptanzkriterien

1. Karte morpht sauber in den grossen Reader.
2. Quellkarte ist danach und in Compact nie leer.
3. Aktive Karte ist sichtbar und eindeutig, aber ruhig hervorgehoben.
4. Down-Swipe aus gross minimiert, schliesst nicht.
5. Minimierungs-Drag startet aus grosszuegigem oberen Bereich.
6. Artikel-Scrollen bleibt fluessig und loest nicht versehentlich Minimieren aus.
7. Mini-Leiste expandiert per Tap/Up-Swipe.
8. Nur explizites Close entfernt den aktiven Artikel.
9. Andere Karte bei Compact oeffnet gross und uebernimmt Active-State.
10. Read, Bookmark, Summary, Einstellungen, Safari, Share bleiben funktionsfaehig.
11. Vorheriger/naechster Artikel per horizontalem Swipe bleibt funktionsfaehig.
12. VoiceOver benennt Active-State, Expand, Close und Aktionen eindeutig.
13. Reduce Motion nutzt Fade/Scale statt erzwungenem Zoom.
14. Keine Leerstellen, Transparenzblitze oder Listenspruenge bei Open/Compact/Switch/Close.

## Gewuenschte Ausfuehrung

1. Ursachen im Code validieren.
2. Ein konsistentes Visual-/Interaction-Konzept fuer Morph, Reader, Compact, Active Card und Bottom
   Bar festlegen.
3. Mit kleinem, strukturiertem Eingriff implementieren; lokale Aenderungen bewahren.
4. Tote Collapse-Logik integrieren oder entfernen.
5. Build und alle Akzeptanzpfade testen.
