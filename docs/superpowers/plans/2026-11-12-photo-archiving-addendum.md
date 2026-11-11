# Photo Archiving — Addendum Plan (device feedback + web app optimiser)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the Optimise photo screen issues found on the maintainer's iPhone, and bring the photo optimiser to the web app.

**Spec:** `docs/superpowers/specs/2026-11-11-photo-archiving-design.md`, plus the maintainer's requests of 2026-11-11 recorded below. The spec originally listed "Web app changes" as a non-goal; the maintainer has since asked that the image optimiser also be part of the web app, which overrides that non-goal for the optimiser only. Web share-in stays out of scope.

## Maintainer requests (2026-11-11, from device testing)

1. "Continue is not there AT ALL." Root cause, reproduced at 390×844: the Skip/Continue `Row` (`photo_optimiser_screen.dart:116`) overflows by 109 px, so Continue is clipped off-screen.
2. "Would be good to have a Button to proceed with accepted parameters."
3. "Hold the + or − and experience a variable speed change from slow to fast."
4. "Make sure that Image optimizer code is part of a web-app as well."

## Controller decisions (made while the maintainer was away; all reversible)

- Skip and Continue move into a bottom bar pinned outside the scroll view (`Scaffold.bottomNavigationBar` in a `SafeArea`). Continue is a full-width `FilledButton`, and Skip is a full-width `TextButton` below it. Neither can overflow at any width or text scale.
- Hold-to-repeat on −/+:
  - a tap is 1 step;
  - holding waits 400 ms, then repeats every 300 ms;
  - after 1 s it repeats every 100 ms;
  - after 2 s it repeats every 50 ms;
  - after 3 s each step is 10 tags.
  
  It stops at the bounds [1, cap]. While held, the count updates on screen without re-fitting; the existing 250 ms debounce means the fit runs once after release.
- Tapping the count opens a small dialog with a numeric field, clamped to [1, cap].
- Web encoder: `createImageBitmap(blob, { imageOrientation: 'from-image' })`, drawn onto white, `canvas.toBlob('image/jpeg', q)`. Canvas output carries no EXIF/GPS, and `stripJpegMetadata` (TS port) runs as a second safeguard, as in the app.
- HEIC on the web: only where the browser decodes it natively (Safari). Elsewhere the page shows the "can't be read here" message and offers Skip. No libheif: the web app's dependency fence allows only `chameleon-ultra.js`.
- The web fit uses the same presets, the same auto-fit rule and the same budget (`tags × payloadSize − filename wrapper − 44 B`) as the app, sourced from the web app's own `wrapWithFilename` and `ENCRYPTION_OVERHEAD`, so the estimate shown and the real archive agree.

## Delivery

- Task 10 goes on `feat/share-in` (PR 3), because it fixes the app screen.
- Tasks 11–12 go on a new branch `feat/webapp-photo-optimiser` from `feat/share-in` (PR 4).

---

### Task 10: Optimise photo screen — pinned actions, hold-to-repeat, type the count (Flutter)

**Files:** `lib/features/photo/presentation/photo_optimiser_screen.dart`, a new `lib/shared/widgets/repeat_button.dart`, `lib/l10n/app_*.arb`, `test/photo_optimiser_test.dart`, a new `test/repeat_button_test.dart`

- [ ] **Test (phone size):** pump the screen at `Size(390, 844)` and at `Size(320, 568)`, with text scale 1.0 and 2.0. Assert:
  - `tester.takeException()` is null (no overflow);
  - `find.text('Continue')` hits and is fully inside the screen rect without scrolling;
  - tapping it runs Continue.
  
  This must fail on the current code (the 109 px overflow).
- [ ] **Move Skip/Continue** into a `bottomNavigationBar` as described in the decisions above. Keep `canContinue` gating, and update existing tests that find the buttons.
- [ ] **`RepeatButton` widget** (icon, `onStep(int delta)`): a tap calls `onStep(±1)`, and a long press follows the hold-to-repeat schedule in the decisions above. Write fake-async tests for:
  - one tap = 1 step;
  - steps counted at 0.5 s, 1.5 s, 2.5 s and 3.5 s of holding;
  - stops on release;
  - stops when the widget is disposed mid-hold.
- [ ] **Use it for −/+** with clamping. Test: holding "+" for 3.5 s from 6 with cap 40 ends at 40, and the fit runs once (one new encode sequence) after release.
- [ ] **Tap the count:** a dialog with a numeric `TextField`, plus OK and Cancel. Values outside the range are clamped to [1, cap]; empty or invalid input does nothing. New l10n keys go in all 7 ARBs:

  | Key | English |
  |---|---|
  | `tagsToUseDialogTitle` | "Tags to use" (reuse `tagsToUse` if it fits) |
  | `ok` | "OK" (reuse if one exists) |

  Test: enter 25 → count 25 and a re-fit; enter 0 → 1.
- [ ] **Hint when the optimised photo is larger than the original file.** The maintainer's screenshot shows the case: a 270×480 source re-encoded to 75.8 KB. When the result's byte length is ≥ the original file size, show a line under the label, with a new key `photoLargerThanOriginal` = "The original file is smaller — Skip keeps it." in all 7 languages. Test it with the fake session.
- [ ] Run `flutter analyze` and `flutter test`, then commit.

### Task 11: Web core — photo fit, metadata stripper, budget (TypeScript, dependency-free)

**Files:** a new `webapp/src/photo/fit.ts`, a new `webapp/src/photo/jpeg-metadata.ts`, a new `webapp/src/photo/budget.ts`, and new tests `webapp/test/photo-fit.test.ts`, `webapp/test/jpeg-metadata.test.ts` and `webapp/test/photo-budget.test.ts`

**Interfaces (mirror the Dart ones):**
- `PHOTO_PRESETS: readonly number[]`;
- `interface JpegEncoderSession { width: number; height: number; encode(maxSide: number, quality: number): Promise<Uint8Array>; close(): void }`;
- `candidateSides(longest: number): number[]`;
- `interface PhotoFitResult { maxSide: number; quality: number; bytes: Uint8Array; fits: boolean }`;
- `fitToBudget(s, budget): Promise<PhotoFitResult>`;
- `encodeManual(s, { maxSide, quality, budget }): Promise<PhotoFitResult>`;
- `stripJpegMetadata(jpeg: Uint8Array): Uint8Array` (drops APP1–APP15/COM and everything after the first EOI; throws on non-JPEG);
- `filenameWrapperBytes(name)`;
- `photoByteBudget({ tags, payloadSize, fileName })`;
- `tagsNeeded(bytes, payloadSize)`;
- `optimisedFileName(original: string | undefined, now: Date)`.

- [ ] **Port the Dart tests** (`test/photo_fit_test.dart`, `test/jpeg_metadata_test.dart`, `test/optimised_file_name_test.dart`) to `node:test` with the same cases and numbers, so the two implementations are held to identical behaviour.
- [ ] **Budget test:** for NTAG213/215/216 and 1K payload sizes and a few names, `photoByteBudget` bytes plus the wrapper and 44 B never exceed `tags × payload`, and `estimateCardCount(bytes, name, { compress: false, encrypted: true, payloadSize })` is ≤ tags for data of exactly the budget size.
- [ ] Implement, keeping `src/` dependency-free (no DOM types in `src/photo`).
- [ ] Run `rm -rf dist && npm test` with Node ≥ 22. The portable Node is at `$(cat /private/tmp/claude-501/-Users-topol-nfcarchiver/0c9231c0-e823-48a0-9d44-0b2f398637bb/scratchpad/node/BIN)`. Then commit.

### Task 12: Web UI — canvas encoder and the optimiser in the Archive tab

**Files:** a new `webapp/app/ui/canvas-jpeg.ts` (the only DOM-touching encoder), a new `webapp/app/ui/photo-optimiser.ts` (UI logic behind a testable seam, like `InspectIO`), `webapp/app/ui/archive-panel.ts`, `webapp/app/index.html`, `webapp/app/i18n/*.ts`, a new `webapp/test/photo-optimiser.test.ts`, `webapp/README.md`, `CLAUDE.md`

- [ ] **`CanvasJpegSession`:**
  - `open(blob)` uses `createImageBitmap(blob, { imageOrientation: 'from-image' })` and throws a `PhotoDecodeError` if decoding fails;
  - `encode` caches a scaled canvas per maxSide, fills white, then `toBlob('image/jpeg', q/100)`, then `stripJpegMetadata`;
  - never upscales.
- [ ] **Archive tab:** when the picked file is an image (by type `image/*` or extension jpg/jpeg/png/heic/heif/webp/gif), show an "Optimise photo" section above the estimate. It has:
  - a preview (an object URL of the result) with the label `{w}×{h} · q{q} · {KB}`;
  - a Tags to use stepper with hold-to-repeat (same schedule as Task 10), re-fitting after 250 ms;
  - a Manual section with size chips (Original + presets) and a quality slider, plus Back to auto;
  - **Use optimised photo** and **Keep original** buttons.
  
  Using the result replaces `fileBytes` and `fileName` (with a `.jpg` name) and turns compression off. Keep original leaves the file as picked. The tag type comes from the existing `#target-tag` select through `selectedPayloadSize()`. With "auto", use the nominal `CARD_PAYLOAD_SIZE`, exactly as the estimate does. A decode failure shows the localized "can't be read here — use Keep original" message.
- [ ] **Logic behind a seam** (`PhotoOptimiserIO`: an encoder-session factory plus a clock), so `node --test` covers:
  - auto fit on open;
  - +/- re-fit;
  - manual, then back to auto;
  - Use (bytes, name and compression off);
  - Keep original;
  - decode failure;
  - stale results dropped.
- [ ] **i18n:** new keys in `en.ts` plus all 6 catalogues (tsc enforces it), with `data-i18n` on the static markup. `test/i18n.test.ts` must pass.
- [ ] **Docs:** add an optimiser paragraph to `webapp/README.md`, and one line in CLAUDE.md's Web App section (`src/photo/` is a port of `lib/features/photo/domain`; canvas encoder; HEIC Safari-only; no new deps).
- [ ] Run `rm -rf dist && npm test`, check that the app bundle builds (`npx esbuild app/main.ts --bundle --format=esm --outdir=/tmp/x` or `npm run build:site`), then commit.
