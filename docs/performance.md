# Measured performance, Folio 0.2.0

Measured October 11, 2026 on Apple M3 Pro, 18 GB RAM, macOS 27.0.1, Swift 6.4, optimized arm64. These are local development measurements on one machine.

## Conditions

10,000 deterministic synthetic JPEG illustrations: 99% 640px wide, 1% 2,560px; square and landscape. The files were fully local inside the selected iCloud Drive project folder. OS filesystem caches were warm, and other workload was not controlled. These simple illustrations are not representative photographs, RAW files, or videos.

The core test repeats 30 metadata loads and 210 queries across seven fixed terms. Queries include broad 2,000-result matches, a missing term, and a single-file query. Search includes SQL execution, ranking, and result materialization; it excludes the 25ms typing debounce and display.

The new masonry grid uses a 1,168 × 719 point viewport and 190 point nominal tile width. Each native run scrolls out and back over 7,200 points at 2,400 points/second, with 360 nominal 60Hz ticks. Automatic tagging is disabled. The development background-check mode uses real AppKit views, layer updates, previews, and native run-loop timers without foregrounding the window. It does not test on-screen compositor presentation. The cold run begins with an empty app preview cache; the warm run starts a fresh process with disk previews retained. Neither clears OS caches.

## Results

| Measurement | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Load 10,000 metadata rows | 6.562 ms | 7.330 ms | 7.639 ms |
| FTS query, including results | 3.395 ms | 3.683 ms | 3.931 ms |
| 512px decode, bypassing app caches | 1.992 ms | 2.712 ms | 3.488 ms |
| Grid CPU, cold app preview cache | 0.504 ms | 1.840 ms | 3.180 ms |
| Grid CPU, warm app preview cache | 0.651 ms | 1.473 ms | 2.140 ms |
| Run-loop interval, cold | 16.669 ms | 17.257 ms | 17.713 ms |
| Run-loop interval, warm | 16.668 ms | 17.225 ms | 19.286 ms |

Metadata became ready 253.6ms after Swift's top-level entry in the cold-preview run and 210.8ms warm. This omits OS/dynamic-loader startup. The remaining first-screen preview wait was about 105ms, sampled every 50ms after a 100ms initial delay. Both runs had all visible previews ready at every sampled timer tick. This does not prove that a newly entering tile never showed a placeholder between samples.

The grid retained at most 68 active tile roots for 10,000 items. It reuses layers within a small offscreen margin; its reuse pool is bounded separately. Initial media scanning, now including dimensions, took 2846.6ms; initial insertion took 160.9ms. Scanning runs off the UI thread.

CPU work and timer intervals are not GPU frame times and cannot prove locked 60fps. Total process RAM, power, RAW/video workloads, and long-term disk-cache growth were not measured. That grid had a smaller viewport and fewer retained tiles, so this redesign is not a controlled same-layout speed comparison.

## Classifier and integration

The real Folio app imported and analyzed 32 original vector studies plus one CC0 cat photograph, with zero failures. Analysis and automatic tags were persisted for all 33 images; every automatically applied tag returned its item through an FTS query. See `automatic-tagging-integration.json`. This verifies wiring and persistence, not general classification precision.

The neutral-named cat photograph received `cat`, `textile`, and `gray`; classification plus OCR took about 299ms in that app run. The photo has no readable text. Posters and interface studies received detected image text, typography, and color tags. General scene/object labels on abstract artwork can be wrong. The earlier standalone photo classification measured approximately 267ms without OCR; that is a one-image diagnostic, not a throughput distribution.

Twelve core tests passed. Mozilla web-ext 10.7.0 reports zero errors, notices, or warnings. Capture integration uses the real extension background code and native service with mocked browser APIs; the JSON report records its actual checks. Firefox installation and toolbar UI are not tested by that harness.

