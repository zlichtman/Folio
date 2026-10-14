# Folio architecture

Folio uses Swift, AppKit, Core Animation, ImageIO, AVFoundation, Vision, and system SQLite. Native frameworks and bounded work supply its speed; Rust is not necessary for this implementation.

## Browsing

`MasonryLayout` computes aspect-ratio frames when the dataset, viewport width, or zoom changes. Its greedy shortest-column placement produces monotonically increasing frame start positions. Binary search finds the candidate range for a viewport. Scrolling processes that bounded range, rather than the full library. Extremely tall and wide images fit in bounded tile frames while retaining uncropped image contents.

`ShelfGridView` reuses CALayer tiles, disables implicit animations, and prevents stale decode callbacks from painting a recycled tile. Offscreen requests are canceled when queued. A bounded recycle pool and a 128 MB decoded-image cache avoid creating one view or full-size image per item. This cache budget is not a total RAM limit.

ImageIO downsamples into 256, 512, or 1,024 pixel buckets based on displayed dimensions and Retina scale. Three workers decode previews. Requests for the same file and bucket coalesce. Atomic PNG disk caches are keyed by file path, size, modification time, and size bucket. There is currently no disk-cache eviction policy.

The native interface has a compact library rail, search toolbar, hidden filename captions, adjustable grid density, optional details, tag chips, and an image preview panel. Preview decoding is asynchronous. Video poster frames come from AVFoundation; playback opens the original externally.

## Index and capture

SQLite WAL stores metadata separately from media. A serialized database queue coordinates reads and writes. FTS5 indexes names, tags, notes, OCR, and source URLs; triggers maintain search consistency. Reads reuse stored SHA-256 IDs. Query input becomes quoted literal prefix terms. Result materialization costs scale with match count, while preview work scales with the viewport.

The Firefox and Chrome extensions (one shared code base in `Extensions/shared`) send selected media URLs, link targets with their page, or active-tab snapshots to the authenticated loopback service. Request parsing and every trust decision live in `ShelfCore/CaptureProtocol.swift` so they are unit tested: host names (against DNS rebinding), extension-only origins, a constant-time key check, http(s)-only URLs, public-only download addresses on every redirect hop, and content sniffing that keeps only real images and videos and refuses executables, archives and disk images. Downloaded media and metadata are committed before success, and saved files carry the quarantine attribute. Captures store image dimensions immediately. Browser page snapshots avoid needing a browser renderer inside Folio. The service limits request and download sizes, has timeouts, binds only to IPv4 loopback, and reports its state instead of failing when the port is taken. Library keys are written owner-only and kept outside this source tree and export archives.

## Actual local image analysis

`ImageClassifier` downsamples image pixels to 768px and runs Apple's `VNClassifyImageRequest` revision 2. It filters generic categories, normalizes labels, removes duplicates, and retains model scores. A 48×48 RGB sample supplies dominant color names and four palette swatches. Vision OCR reads text from a separate larger thumbnail. Substantial text supplies a typography tag. Neither filenames nor preset demo labels generate object classifications.

The app owns one utility-priority indexing worker. Classification and OCR have independent CPU fallback preferences when an accelerated request fails. The scrolling loop does not perform model inference. Analysis JSON, fingerprint, dimensions, OCR, and accepted automatic tags are saved in a transaction; existing manual tags are merged case-insensitively and notes are untouched. FTS update triggers make newly stored tags and text searchable. The fingerprint includes analysis version, file path, size, and modification timestamp. Completed fingerprints make indexing resumable across launches. New captures arriving during indexing trigger another pass. Pausing prevents further commits after the current inference completes.

The local classifier supplies general object/scene labels. It is not a substitute for a language model or a semantic retrieval model, and low model scores can be wrong. Thresholds reduce automatic noise but are not a measured precision guarantee. Suggestions expose provenance and model score in their tooltip. Core tests verify persistence, FTS updates, threshold logic, metadata preservation, migration, and actual masonry viewport coverage. Real-model integration uses 32 original vector studies and a CC0 photo named without a category clue; this is a smoke test, not a classification accuracy benchmark.

## Further work

A separately licensed image/text encoder such as [Google SigLIP2](https://huggingface.co/google/siglip2-base-patch16-256) is a possible next step for semantic search. It is not shipped here. Conversion, preprocessing, tokenizer parity, accuracy, model notices, and native latency need verification before making retrieval claims. Start with a simple normalized-vector scan and measure recall and latency before adding ANN infrastructure.

Also pending: folder watching, reliable original-file moves, inline video, multiselection and undo, accessible tile children, disk-cache eviction, representative photographic/RAW/video benchmarks, Mozilla signing, and notarization.

