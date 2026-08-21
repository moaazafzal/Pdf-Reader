# AquaPDF

Free, native macOS PDF reader and editor with a Foxit-style ribbon interface.
SwiftUI + Apple PDFKit — no paid SDKs, no subscriptions, no accounts.

## Install

Download `AquaPDF-<version>.dmg`, open it, and drag AquaPDF onto the Applications folder.

**On first launch, right-click (or Control-click) AquaPDF and choose "Open"**, then click
"Open" in the dialog. This is needed only once. The app is signed ad-hoc rather than with a
paid Apple Developer certificate, so macOS blocks a plain double-click the first time.
If macOS claims the app "is damaged", clear the download quarantine flag:

```bash
xattr -cr /Applications/AquaPDF.app
```

## Build & Run

```bash
./make-app.sh          # universal .app in build/
./make-dmg.sh          # universal .app + build/AquaPDF-<version>.dmg
open build/AquaPDF.app
```

`make-app.sh` produces a **universal binary** (`arm64` + `x86_64`), so the same app runs
natively on Apple Silicon and on Intel Macs — no Rosetta.

**Runs on macOS 11 Big Sur and later.** That covers every Mac that can run Big Sur:
MacBook Air and MacBook Pro from late 2013, MacBook from 2015, iMac from 2014,
Mac mini from 2014, Mac Pro from 2013, iMac Pro, Mac Studio, and all Apple Silicon models.

Building requires Xcode (or Command Line Tools) with Swift 6+ on a recent macOS; the produced
app still deploys back to Big Sur. For development: `swift build && swift run`.

### Why not 2012 Macs?

2012 Macs cannot install anything newer than macOS 10.15 Catalina, and Catalina predates the
SwiftUI features this app is built on — no SF Symbols, no `Menu`, no `LazyVGrid`, no SwiftUI
app lifecycle. Supporting them would mean rewriting the entire interface in AppKit. Everything
from late 2013 onward is covered.

## Interface

- **Start dashboard** at launch: quick actions plus a recent-files grid with page thumbnails
- **Ribbon** with File, Home, Comment, Edit, Organize, Convert, Form, Protect, View and Help tabs
- **Command search** (⌥Q) finds any command by name, like Foxit's Alt+Q
- **Navigation pane**: Pages, Bookmarks, Comments, Attachments, Signatures, Search
- **Status bar**: editable page box (type a page number and press Return to jump), first/previous/next/last page, previous/next view, zoom slider and percentage
- Light / Dark / System theme, and Default / Night / Sepia / Eye Comfort visual modes

## Features

**Viewing**
- Single, Continuous, Facing and Continuous Facing layouts; view rotation; reverse page order
- Zoom in/out, Actual Size, Fit Page, Fit Width, marquee zoom, zoom slider
- Reflow (single-column reading), Text Viewer, Read Mode, Full Screen
- Split view (vertical or horizontal), Loupe magnifier, AutoScroll
- Read Out Loud (this page, from here, pause, stop) via AVSpeechSynthesizer
- Word count, full-document search with context snippets

**Comment**
- Text markup: Highlight, Underline, Squiggly, Strikeout, Replace Text, Insert Text, Area Highlight
- Notes, file attachments, text boxes, callouts with leader lines
- Drawing: Pencil, Eraser, Rectangle, Oval, Line, Arrow, Polygon, Polyline, Cloud, Arc
- Stamps palette: standard stamps, Sign Here stamps, dynamic stamps, stamps from clipboard or file
- Measure: Distance, Perimeter, Polygon Area, Circle Area, with unit selection
- Search & Highlight marks every occurrence of a phrase
- Comments panel: search, sort (page/type/author/date/status), filter by status, checkmarks,
  threaded replies, and review states (Accepted, Rejected, Cancelled, Completed)
- Import/export comments as XFDF or FDF; export highlighted text as CSV or TXT
- Summarize Comments builds a standalone summary PDF

**Edit**
- Edit Text: click any line to replace it in place (hover highlights the editable line)
- Add Text: click to place a draggable, resizable text box with a floating format bar
  (font, size, bold, italic, color) — re-editable at any time, even after saving and reopening
- Insert images and drawn signatures; move and resize them, burned into page content on save
- Full undo/redo for every operation

**Organize**
- Reorder, rotate, delete and extract pages; merge PDFs; split into single pages
- Insert page numbers: six positions, formats (1 · Page 1 · 1 of N · Page 1 of N · roman ·
  letters), custom prefix, start number, size, margin, color, all pages or a range, with a
  live preview. Numbers are written into page content, so they print and survive in any reader.

**Convert**
- Export to Word (.docx), PNG images, or plain text
- OCR via Apple Vision: searchable PDF with an invisible text layer, or recognized text
- Compress (recompresses embedded images)

**Form**
- Fill AcroForm fields; reset form; highlight fields
- Import/export field data as FDF; export to CSV (append to an existing sheet supported)

**Protect**
- True redaction: mark areas, then apply — marked pages are re-rendered with the content
  destroyed, not merely covered
- Password protection (AES via PDFKit), annotation flattening
- Action Inspector warns about JavaScript, launch, submit and embedded-file actions

**File**
- Open, Save, Save As, Print, Batch Print, Email, Document Properties
  (description, security, fonts), Preferences

## Keyboard & mouse

Shortcuts follow Foxit's scheme. Foxit is Windows software and uses Ctrl; on macOS those map
to ⌘, since literal Ctrl would collide with system behavior.

| | |
|---|---|
| Zoom | `⌘=` in · `⌘-` out · `⌘1` actual size · `⌘0` fit page · `⌘2` fit width · `⌘3` fit visible |
| View | `⌘4` reflow · `⌘H` read mode · `⌘6` text viewer · `F11` full screen · `⇧⌘H` autoscroll |
| Panels | `F4` navigation pane · `⌥⌘I` properties panel |
| Navigate | `⌘↑`/`⌘↓` page · `Page Up`/`Page Down` · `⌘Home`/`⌘End` · `⇧⌘N` go to page · `⌥←`/`⌥→` previous/next view · `Space`/`⇧Space` scroll |
| Search | `⌘F` find · `⌘G` next · `⇧⌘G` previous · `⇧⌘F` search panel |
| Document | `⇧⌘T` organize · `⌘D` properties · `⌘K` preferences · `⌥Q` command search |

**Single-key tool accelerators** (toggle in Preferences ▸ Keys & Mouse): `H` hand · `V` select ·
`Z` marquee · `G` snapshot · `U` highlight · `T` text · `S` note · `P` pencil · `K` callout ·
`R` rectangle · `O` oval · `L` line · `A` arrow · `E` eraser · `D` distance · `X` redact.
They are suppressed while typing, so form fields and text boxes are unaffected.

**Mouse**: `⌘`/`Control` + wheel zooms about the pointer · `Shift` + wheel scrolls sideways ·
middle button toggles AutoScroll · right-click opens a context menu (delete, edit text, copy,
highlight, zoom) · double-clicking text you added reopens it for editing. Optionally the Hand
tool can zoom with a plain wheel, as in Foxit.

## Performance

Measured on a 200-page text-heavy PDF:

| | Before | After |
|---|---|---|
| Idle CPU | ~144% (never settled) | 0.0% |
| Memory | 285 MB and climbing | ~120 MB |
| After scrolling | stayed pegged | settles to ~1% |

The window was pinned at full CPU while doing nothing because `updateNSView` repainted the
whole PDF view on every SwiftUI pass and the page-thumbnail sidebar rendered every thumbnail
synchronously inside the list body. Thumbnails now render off the main thread through a
bounded, size-capped cache, repaints are limited to the regions that actually changed, and
redundant published updates no longer retrigger the render loop.

## Known limitations

- Edit Text on original PDF content repaints the line in the chosen font rather than matching the
  original font metrics — best on plain, light backgrounds. Text you add is a real annotation and
  re-edits cleanly.
- Word export is text-level: paragraphs and page breaks, no images, tables or layout.
- Redaction rasterizes affected pages by design; run OCR afterwards to restore searchable text.
- Not implemented (service- or platform-dependent in Foxit): eSign, DocuSign, Microsoft AIP and
  Double Key Encryption, SharePoint/Evernote/OneNote connectors, shared-review servers, AI
  Assistant, 3D PDF, XFA forms, PDF portfolios.

## Architecture

```
Sources/AquaPDF/
  App/AquaPDFApp.swift            Start window + DocumentGroup
  Models/PDFFileDocument.swift    ReferenceFileDocument wrapping PDFDocument, undo snapshots
  Models/DocViewModel.swift       Per-window UI state
  Models/Tool.swift               Tool set, annotation style, measurement scale
  Models/CommentMeta.swift        Review status/replies stored on the annotation
  PDF/AnnotatingPDFView.swift     PDFView subclass: all tools, undo, handles, in-place editing
  PDF/ShapeAnnotations.swift      Polygon/polyline/cloud/arc, measurements, callouts
  PDF/InlineTextBox.swift         Draggable, resizable in-place text editor
  PDF/ImageStampAnnotation.swift  Interactive image/signature annotation
  PDF/PDFPage+TextLine.swift      Reliable line-at-point finder built on glyph bounds
  Views/                          Ribbon, sidebar, comments panel, reading views, dialogs
  Operations/                     Page ops, OCR, DOCX, comment exchange, forms, signatures
```
