# AquaPDF

Free, native macOS PDF reader and editor. SwiftUI + Apple PDFKit — no paid SDKs, no subscriptions.

## Build & Run

```bash
./make-app.sh
open build/AquaPDF.app
```

Requires Xcode (or Command Line Tools with Swift 6+) and macOS 14+.

For development: `swift build && swift run` from the project root.

## Features (v0.2)

**Viewing**
- Open/save PDFs with native document handling (recents, autosave, native macOS window tabs)
- Continuous scrolling, zoom, page indicator
- Sidebar: page thumbnails, outline (table of contents), annotation list, full-document search with context snippets

**Annotation** (toolbar tool picker)
- Highlight / underline / strikeout — drag over text
- Freehand draw (ink), rectangle, ellipse, line, arrow
- Text box (typewriter) and sticky notes
- Select tool: click to select, drag to move, corner handles to resize (stamps, rectangles, ellipses, text boxes); edit color/note in the inspector; Delete key removes
- Full undo/redo (⌘Z / ⇧⌘Z) for annotations, moves, resizes, merges, page organization, redaction, and text edits
- Form filling: AcroForm fields work natively — click and type

**Signatures & images**
- Draw a signature (saved for reuse), click to place, then move/resize freely
- On save they are burned into real page content, so they survive in every PDF reader
- Insert any image the same way

**Edit Text (beta)**
- Click a line of text with the Edit Text tool, type the replacement — the original line is painted over and the new text is written into the page content
- Works best on plain, light backgrounds; full content-stream editing (mixed fonts/colors, reflow) remains on the roadmap

**Redaction (true)**
- Mark areas with the Redact tool, then Tools ▸ Apply Redactions
- Marked pages are re-rendered as 300 dpi images with the areas removed — text/graphics underneath are permanently destroyed, not just covered
- Redacted pages lose selectable text: run OCR ▸ Make Searchable PDF afterwards if needed

**Page organization** (Organize Pages toolbar button)
- Reorder (arrow buttons), rotate, delete, extract selection to a new PDF

**Document tools** (Tools menu in toolbar)
- Merge PDFs into current document
- Split into single-page PDFs
- Save compressed copy (recompresses images)
- Password-protect a copy (AES encryption via PDFKit)
- Flatten annotations into a copy
- OCR via Apple Vision: produce a searchable PDF (invisible text layer over scanned pages) or export recognized text
- Export as Word (.docx, text-level), pages as PNG, document text

## Known limitations (roadmap)

- **Edit Text is beta**: single-line replacement drawn in Helvetica over a painted background — it does not match original fonts or reflow paragraphs (full content-stream editing is the phase-3 goal)
- Word export is text-level: paragraphs and page breaks, no images/tables/layout
- Redaction rasterizes affected pages (by design — that is what guarantees removal), so those pages lose vector text/graphics
- Line/arrow/ink annotations can be moved but not resized

## Architecture

```
Sources/AquaPDF/
  App/AquaPDFApp.swift          DocumentGroup entry point
  Models/PDFFileDocument.swift  ReferenceFileDocument wrapping PDFDocument
  Models/DocViewModel.swift     Per-window UI state (tool, selection, search)
  Models/Tool.swift             Tool + style definitions
  PDF/AnnotatingPDFView.swift   PDFView subclass: tools, undo, move/resize handles
  PDF/ImageStampAnnotation.swift  Interactive image/signature annotation (burned on save)
  Views/                        SwiftUI: content, sidebar, inspector, organizer, signatures
  Operations/PDFOperations.swift  Merge/split/extract/compress/protect/redact/edit-text/burn-in
  Operations/OCRService.swift     Vision OCR + searchable-PDF generation
  Operations/DocxExporter.swift   Word export (minimal OOXML + zip writer)
  Operations/SignatureStore.swift Signature persistence (Application Support)
  Resources/AppIcon.icns          App icon (generated)
```
