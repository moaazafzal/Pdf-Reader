# AquaPDF

Free, native macOS PDF reader and editor. SwiftUI + Apple PDFKit — no paid SDKs, no subscriptions.

## Build & Run

```bash
./make-app.sh
open build/AquaPDF.app
```

Requires Xcode (or Command Line Tools with Swift 6+) and macOS 14+.

For development: `swift build && swift run` from the project root.

## Features (v1)

**Viewing**
- Open/save PDFs with native document handling (recents, autosave, native macOS window tabs)
- Continuous scrolling, zoom, page indicator
- Sidebar: page thumbnails, outline (table of contents), annotation list, full-document search with context snippets

**Annotation** (toolbar tool picker)
- Highlight / underline / strikeout — drag over text
- Freehand draw (ink), rectangle, ellipse, line, arrow
- Text box (typewriter) and sticky notes
- Select tool: click an annotation to edit color/note in the inspector, Delete key removes it
- Form filling: AcroForm fields work natively — click and type

**Signatures & images**
- Draw a signature (saved for reuse), click to place — burned into real page content, so it survives in every PDF reader
- Insert any image the same way

**Page organization** (Organize Pages toolbar button)
- Reorder (arrow buttons), rotate, delete, extract selection to a new PDF

**Document tools** (Tools menu in toolbar)
- Merge PDFs into current document
- Split into single-page PDFs
- Save compressed copy (recompresses images)
- Password-protect a copy (AES encryption via PDFKit)
- Flatten annotations into a copy
- OCR via Apple Vision: produce a searchable PDF (invisible text layer over scanned pages) or export recognized text
- Export pages as PNG, export document text

## Known limitations (roadmap)

- **True text/image content editing** (edit existing PDF text in place) — phase 2; requires content-stream rewriting
- No undo for annotations yet (delete works; page organizer resets undo stack)
- PDF-to-Word export not implemented (text export only)
- Signature/image placement is click-to-place at fixed max width (no resize handles yet)
- No dedicated redaction tool — "Flatten Annotations" + a filled rectangle hides content visually but does **not** remove the underlying text; do not use it for sensitive redaction

## Architecture

```
Sources/AquaPDF/
  App/AquaPDFApp.swift          DocumentGroup entry point
  Models/PDFFileDocument.swift  ReferenceFileDocument wrapping PDFDocument
  Models/DocViewModel.swift     Per-window UI state (tool, selection, search)
  Models/Tool.swift             Tool + style definitions
  PDF/AnnotatingPDFView.swift   PDFView subclass: mouse-drag annotation creation
  Views/                        SwiftUI: content, sidebar, inspector, organizer, signatures
  Operations/PDFOperations.swift  Merge/split/extract/compress/protect/flatten/export/image burn-in
  Operations/OCRService.swift     Vision OCR + searchable-PDF generation
  Operations/SignatureStore.swift Signature persistence (Application Support)
```
