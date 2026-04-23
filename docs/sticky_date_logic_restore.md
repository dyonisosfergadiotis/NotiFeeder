# Sticky Date Logic (Archived)

This file documents the removed sticky-date behavior from `NotiFeeder/Views/Feed/ContentView.swift` so it can be reintroduced later.

## What Was Removed

The UI previously showed a sticky date pill in the top-right pill bar and tried to synchronize it with date dividers in the feed list.

Removed parts:
- Per-section anchor tracking (`DaySectionAnchor`, `DaySectionAnchorPreferenceKey`)
- Sticky target frame tracking (`StickyDayTargetFramePreferenceKey`)
- Sticky state in `FeedListView` (`pinnedDaySectionID`, `pinnedDaySectionTitle`, `stickyDayLabelYOffset`, etc.)
- Sticky update algorithm (`updatePinnedDaySectionTitle(...)`)
- Sticky date pill rendering in `segmentedPickerFeeds`
- Divider hiding tied to sticky state

## Previous Architecture

1. Build day sections from visible entries (`daySections(for:)`), each with an inline date divider row.
2. Collect divider `minY` values via a preference key in list coordinate space.
3. Collect sticky target frame (pill position) via a second preference key.
4. On every preference update:
   - resolve a takeover threshold (usually lower edge of sticky pill)
   - derive active section index from divider positions
   - set current sticky title/id
   - compute an upward offset so the old sticky label moves out when next date approaches

## Core Algorithm (Pseudo)

```swift
let thresholdY = stickyPillFrame.maxY // takeover line

let nearestYBySection = dedupeAnchorsNearestToThreshold(anchors, thresholdY)

activeIndex = keepPreviousOrInfer(sections, nearestYBySection, thresholdY)

while nextSectionY <= thresholdY { activeIndex += 1 }
while currentSectionY > thresholdY { activeIndex -= 1 }

pinnedTitle = sections[activeIndex].title

if let nextY = yOfSection(activeIndex + 1) {
  let pushStart = thresholdY + stickyLabelHeight
  stickyOffset = min(0, nextY - pushStart)
} else {
  stickyOffset = 0
}
```

## Reintroducing It Later

If you want this back, re-add in `FeedListView`:

1. Types:
- `DaySectionAnchor`
- `DaySectionAnchorPreferenceKey`
- `StickyDayTargetFramePreferenceKey`

2. State:
- `pinnedDaySectionID`
- `pinnedDaySectionTitle`
- `stickyDayLabelYOffset`
- `stickyDayTargetFrame`
- `latestDaySectionAnchors`

3. Hooks on the list:
- `.onPreferenceChange(DaySectionAnchorPreferenceKey.self)`
- `.onPreferenceChange(StickyDayTargetFramePreferenceKey.self)`

4. Divider row instrumentation:
- `GeometryReader` background that emits each divider `minY`

5. Sticky pill rendering:
- add the sticky date pill in `segmentedPickerFeeds`
- render with `offset(y: stickyDayLabelYOffset)`

6. Update function:
- re-add `updatePinnedDaySectionTitle(from:sections:)` and call it from preference handlers

## Notes

- Keep all Y values in the same coordinate space.
- Avoid hardcoded screen cutoffs when possible.
- The most fragile part is threshold calibration between divider anchors and sticky target frame.
