# Webapp M3 Redesign ("B + C") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the web app as a Material 3 sibling of the Flutter app (bottom navigation, reader card, Flutter-style fields) and replace the bare progress bar with a card-slot "stage" for writing and scanning, including a real Stop for archive writes.

**Architecture:** Presentation stays in one hand-written stylesheet inside `webapp/app/index.html`; panels keep binding to the same element ids. Two small pure modules are added (`app/ui/stage-view.ts` for the slot row, `app/source.ts` for File/Text source selection), both unit-tested with the existing stub-DOM pattern. The only logic change is an `AbortSignal` threaded through `ArchiveOrchestrator.run`, which now also returns its outcome.

**Tech Stack:** TypeScript 5, esbuild, `node --test`, no UI framework, no runtime dependency beyond `chameleon-ultra.js` (fenced to two files). Visual verification with the Windows host's headless Chrome driven from WSL.

**Spec:** `docs/superpowers/specs/2026-10-05-webapp-m3-redesign-design.md` — read it, **including its "Amendments" section at the end, which overrides the sections above it**. Design references (Superdesign drafts) are listed in the spec's table.

## Global Constraints

- Work on branch `design/webapp-m3-redesign` (already exists, holds the spec).
- Node ≥ 22: every command runs after `source ~/.nvm/nvm.sh && nvm use 22 >/dev/null` (the shell default is Node 14; `nvm use --lts` is broken on this machine).
- Test command, always from `webapp/`: `rm -rf dist && npm test` (the `tsc && node --test` chain does not clean stale compiled tests). Pass = `# fail 0`.
- **Every element id that TypeScript resolves must exist in `index.html`** — enforced by `test/markup-ids.test.ts`. Never rename an existing id; add new ones.
- `#tabs` must stay a `<div id="tabs" …>` whose `<button>` children carry `data-tab="archive|restore|files|log|about"`, and **no `<div>` may appear inside `#tabs`** (the test's regex stops at the first `</div>`).
- No author CSS rule may set `display` on a `dialog…` selector without `[open]`, and no dialog may be its own scroll container (`overflow: auto|scroll`).
- Every `<use href="#id">` written literally in HTML **or TypeScript** must have a matching `<symbol id="id">` in the sprite. Never write `<use href="#${…}">` in TypeScript — the sprite test's regex would read `${…}` as an icon id.
- Row skeleton for list rows stays `row.children = [icon tile, text column, control column]`; the existing view tests index into `children[1]` / `children[2]`.
- Button `textContent` must remain exactly its translated label (icon buttons hide the text visually with `font-size: 0`; the glyph is a CSS mask).
- Seven locales: `en.ts` is the schema; `ru, uk, be, pl, tr, ka` must have the identical key set and function arity (`test/i18n.test.ts`). Every `data-i18n*` attribute must name a **string** key.
- No webfont fetch: font stack `Roboto, system-ui, -apple-system, "Segoe UI", sans-serif`.
- Dependency fence: nothing new imports `chameleon-ultra.js`.
- Commit after every task with a Conventional Commit message ending in `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push.

## Review Focus

1. **Stop vs reader teardown** — a Web NFC teardown rejects the pending tap with an `AbortError` the user did not cause; the write must reconnect and finish, not stop. Pinned in Task 2 (`a reader teardown AbortError is not mistaken for Stop`).
2. **Auto-detect re-chunks mid-write** — `total` changes after the first tap; the slot row must grow/shrink in place, never duplicate or leave stale slots. Pinned in Task 4 (`follows a re-chunk`).
3. **Locale switch mid-write** — slot names/states and the "Archive another"/"Back" label must re-render in the new language. Pinned in Task 4 (`relabels after a locale switch`) and wired in Task 7 (`onLocaleChange`).
4. **Mode switch with a stale file** — a user who chose a file and then switched to Text with an empty field must get "Pick a file or type some text first", not a write of the hidden file. Pinned in Task 6 (`pickSource ignores a chosen file in Text mode`).
5. **Long translations at 360px** — nav labels and reader buttons must not wrap under icons or overflow. Pinned in Task 3 (`nav labels never wrap`) and checked visually in Task 12 at 360px in Russian.

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `webapp/app/i18n/{en,ru,uk,be,pl,tr,ka}.ts` | modify | new keys (Task 1), retired keys removed (Task 11) |
| `webapp/app/ui/archive-orchestrator.ts` | modify | `AbortSignal`, `ArchiveOutcome` (Task 2) |
| `webapp/app/index.html` | modify | tokens, stylesheet, sprite, all markup (Tasks 3, 5–10) |
| `webapp/app/ui/stage-view.ts` | **create** | card-slot row renderer (Task 4) |
| `webapp/app/ui/device.ts` | modify | reader card state (Task 5) |
| `webapp/app/source.ts` | **create** | `pickSource` (Task 6) |
| `webapp/app/ui/archive-panel.ts` | modify | source mode, estimate, hint, stage, Stop (Tasks 6–7) |
| `webapp/app/ui/restore-view.ts`, `restore-panel.ts` | modify | archive rows, scan stage (Task 8) |
| `webapp/app/ui/files-view.ts` | modify | file rows with icon buttons (Task 9) |
| `webapp/app/ui/about-panel.ts` | modify | about header block (Task 10) |
| `webapp/test/*.test.ts` | modify/create | as listed per task |
| `webapp/.visual/*` (git-excluded) | create | screenshot tooling (Task 3) |

---

### Task 1: New i18n keys in all seven catalogues

**Files:**
- Modify: `webapp/app/i18n/en.ts`, `ru.ts`, `uk.ts`, `be.ts`, `pl.ts`, `tr.ts`, `ka.ts` (append before the closing `};` of each catalogue object)
- Test: `webapp/test/i18n.test.ts`

**Interfaces:**
- Produces (on `Messages` / `t`): `readerConnectTitle`, `readerConnectBody`, `readerNamePhone`, `inspect`, `connectReaderFirst`, `sourceChooseFile`, `sourceTapToChange`, `tagTypeLabel`, `passwordLabel`, `saveAsLabel`, `estimateAuto`, `slotWritten`, `slotWriting`, `slotWaiting`, `slotHasData`, `archiveAgain`, `back`, `scanStageTitle`, `overwriteTitle`, `overwriteBody` (all `string`); `cardsNeeded(n: number)`, `slotCard(n: number)`, `cardOfTotal(i: number, n: number)`, `archiveStoppedPartial(written: number, total: number)`, `archiveRowStatus(received: number, total: number, complete: boolean)`, `fileRowMeta(size: string, totalChunks: number, when: string)` (all return `string`).

- [ ] **Step 1: Write the failing tests**

In `webapp/test/i18n.test.ts`, add after the test `'English catalogue function entries render'`:

```ts
test('redesign entries render in English', () => {
  setPluralLocale('en');
  assert.equal(en.cardsNeeded(1), '≈ 1 card needed');
  assert.equal(en.cardsNeeded(3), '≈ 3 cards needed');
  assert.equal(en.slotCard(2), 'Card 2');
  assert.equal(en.cardOfTotal(2, 5), 'Card 2 of 5');
  assert.equal(en.archiveStoppedPartial(2, 5), 'Stopped — 2 of 5 cards written. The archive is incomplete.');
  assert.equal(en.archiveRowStatus(3, 3, true), '3/3 cards · complete');
  assert.equal(en.archiveRowStatus(1, 1, false), '1/1 card');
  assert.equal(en.fileRowMeta('2.4 KB', 1, 'today'), '2.4 KB · 1 card · today');
});
```

In the test `'Slavic plurals select the right form at the boundaries'`, add one entry to the `entries` array (keep the existing three):

```ts
    ['cardsNeeded', (cat, n) => cat.cardsNeeded(n)],
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL at `tsc` — `Property 'cardsNeeded' does not exist on type …`.

- [ ] **Step 3: Add the English keys**

In `webapp/app/i18n/en.ts`, insert immediately before the final `};` of the `en` object:

```ts

  // — redesign 2026-10: reader card, source picker, stage —
  readerConnectTitle: 'Connect a reader',
  readerConnectBody: 'A Chameleon Ultra over Bluetooth, or this phone’s NFC (Chrome on Android, NTAG only).',
  readerNamePhone: 'Phone NFC',
  inspect: 'Inspect',
  connectReaderFirst: 'Connect a reader first',
  sourceChooseFile: 'Tap to choose a file',
  sourceTapToChange: 'Tap to change',
  tagTypeLabel: 'Tag type',
  passwordLabel: 'Password (optional)',
  saveAsLabel: 'Save as',
  cardsNeeded: (n: number) => `≈ ${n} ${pr(n, { one: 'card', other: 'cards' })} needed`,
  estimateAuto: 'Auto-detect · adapts to the tapped card',
  slotCard: (n: number) => `Card ${n}`,
  slotWritten: 'Written',
  slotWriting: 'Writing',
  slotWaiting: 'Waiting',
  slotHasData: 'Has data',
  cardOfTotal: (i: number, n: number) => `Card ${i} of ${n}`,
  archiveAgain: 'Archive another',
  back: 'Back',
  archiveStoppedPartial: (written: number, total: number) =>
    `Stopped — ${written} of ${total} ${pr(total, { one: 'card', other: 'cards' })} written. The archive is incomplete.`,
  scanStageTitle: 'Tap cards in any order',
  archiveRowStatus: (received: number, total: number, complete: boolean) =>
    `${received}/${total} ${pr(total, { one: 'card', other: 'cards' })}${complete ? ' · complete' : ''}`,
  fileRowMeta: (size: string, totalChunks: number, when: string) =>
    `${size} · ${totalChunks} ${pr(totalChunks, { one: 'card', other: 'cards' })} · ${when}`,
  overwriteTitle: 'Card already holds data',
  overwriteBody: 'Overwriting erases what is on it.',
```

- [ ] **Step 4: Add the six translations**

Each block goes immediately before the final `};` of its catalogue. `CARD` and `pr` are already defined/imported at the top of every one of these files.

`webapp/app/i18n/ru.ts`:

```ts

  // — redesign 2026-10 —
  readerConnectTitle: 'Подключите считыватель',
  readerConnectBody: 'Chameleon Ultra по Bluetooth или NFC этого телефона (Chrome на Android, только NTAG).',
  readerNamePhone: 'NFC телефона',
  inspect: 'Осмотреть',
  connectReaderFirst: 'Сначала подключите считыватель',
  sourceChooseFile: 'Нажмите, чтобы выбрать файл',
  sourceTapToChange: 'Нажмите, чтобы изменить',
  tagTypeLabel: 'Тип метки',
  passwordLabel: 'Пароль (необязательно)',
  saveAsLabel: 'Сохранить как',
  cardsNeeded: (n) => `≈ ${n} ${pr(n, CARD)} для записи`,
  estimateAuto: 'Автоопределение · подстроится под приложенную карту',
  slotCard: (n) => `Карта ${n}`,
  slotWritten: 'Записана',
  slotWriting: 'Запись',
  slotWaiting: 'Ожидает',
  slotHasData: 'Есть данные',
  cardOfTotal: (i, n) => `Карта ${i} из ${n}`,
  archiveAgain: 'Архивировать ещё',
  back: 'Назад',
  archiveStoppedPartial: (written, total) => `Остановлено — записано ${written} из ${total}. Архив неполный.`,
  scanStageTitle: 'Прикладывайте карты в любом порядке',
  archiveRowStatus: (received, total, complete) => `${received} из ${total}${complete ? ' · готово' : ''}`,
  fileRowMeta: (size, totalChunks, when) => `${size} · ${totalChunks} ${pr(totalChunks, CARD)} · ${when}`,
  overwriteTitle: 'На карте уже есть данные',
  overwriteBody: 'Перезапись сотрёт её содержимое.',
```

`webapp/app/i18n/uk.ts`:

```ts

  // — redesign 2026-10 —
  readerConnectTitle: 'Підключіть зчитувач',
  readerConnectBody: 'Chameleon Ultra через Bluetooth або NFC цього телефону (Chrome на Android, лише NTAG).',
  readerNamePhone: 'NFC телефону',
  inspect: 'Оглянути',
  connectReaderFirst: 'Спочатку підключіть зчитувач',
  sourceChooseFile: 'Натисніть, щоб вибрати файл',
  sourceTapToChange: 'Натисніть, щоб змінити',
  tagTypeLabel: 'Тип мітки',
  passwordLabel: 'Пароль (необовʼязково)',
  saveAsLabel: 'Зберегти як',
  cardsNeeded: (n) => `≈ ${n} ${pr(n, CARD)} для запису`,
  estimateAuto: 'Автовизначення · підлаштується під прикладену картку',
  slotCard: (n) => `Картка ${n}`,
  slotWritten: 'Записана',
  slotWriting: 'Запис',
  slotWaiting: 'Очікує',
  slotHasData: 'Є дані',
  cardOfTotal: (i, n) => `Картка ${i} з ${n}`,
  archiveAgain: 'Архівувати ще',
  back: 'Назад',
  archiveStoppedPartial: (written, total) => `Зупинено — записано ${written} з ${total}. Архів неповний.`,
  scanStageTitle: 'Прикладайте картки в будь-якому порядку',
  archiveRowStatus: (received, total, complete) => `${received} з ${total}${complete ? ' · готово' : ''}`,
  fileRowMeta: (size, totalChunks, when) => `${size} · ${totalChunks} ${pr(totalChunks, CARD)} · ${when}`,
  overwriteTitle: 'На картці вже є дані',
  overwriteBody: 'Перезапис зітре її вміст.',
```

`webapp/app/i18n/be.ts`:

```ts

  // — redesign 2026-10 —
  readerConnectTitle: 'Падключыце счытвальнік',
  readerConnectBody: 'Chameleon Ultra праз Bluetooth або NFC гэтага тэлефона (Chrome на Android, толькі NTAG).',
  readerNamePhone: 'NFC тэлефона',
  inspect: 'Агледзець',
  connectReaderFirst: 'Спачатку падключыце счытвальнік',
  sourceChooseFile: 'Націсніце, каб выбраць файл',
  sourceTapToChange: 'Націсніце, каб змяніць',
  tagTypeLabel: 'Тып меткі',
  passwordLabel: 'Пароль (неабавязкова)',
  saveAsLabel: 'Захаваць як',
  cardsNeeded: (n) => `≈ ${n} ${pr(n, CARD)} для запісу`,
  estimateAuto: 'Аўтавызначэнне · падладзіцца пад прыкладзеную карту',
  slotCard: (n) => `Карта ${n}`,
  slotWritten: 'Запісана',
  slotWriting: 'Запіс',
  slotWaiting: 'Чакае',
  slotHasData: 'Ёсць даныя',
  cardOfTotal: (i, n) => `Карта ${i} з ${n}`,
  archiveAgain: 'Архіваваць яшчэ',
  back: 'Назад',
  archiveStoppedPartial: (written, total) => `Спынена — запісана ${written} з ${total}. Архіў няпоўны.`,
  scanStageTitle: 'Прыкладвайце карты ў любым парадку',
  archiveRowStatus: (received, total, complete) => `${received} з ${total}${complete ? ' · гатова' : ''}`,
  fileRowMeta: (size, totalChunks, when) => `${size} · ${totalChunks} ${pr(totalChunks, CARD)} · ${when}`,
  overwriteTitle: 'На карце ўжо ёсць даныя',
  overwriteBody: 'Перазапіс сатрэ яе змесціва.',
```

`webapp/app/i18n/pl.ts`:

```ts

  // — redesign 2026-10 —
  readerConnectTitle: 'Podłącz czytnik',
  readerConnectBody: 'Chameleon Ultra przez Bluetooth lub NFC tego telefonu (Chrome na Androidzie, tylko NTAG).',
  readerNamePhone: 'NFC telefonu',
  inspect: 'Zbadaj',
  connectReaderFirst: 'Najpierw podłącz czytnik',
  sourceChooseFile: 'Dotknij, aby wybrać plik',
  sourceTapToChange: 'Dotknij, aby zmienić',
  tagTypeLabel: 'Typ tagu',
  passwordLabel: 'Hasło (opcjonalnie)',
  saveAsLabel: 'Zapisz jako',
  cardsNeeded: (n) => `≈ ${n} ${pr(n, CARD)} do zapisania`,
  estimateAuto: 'Autowykrywanie · dopasuje się do przyłożonej karty',
  slotCard: (n) => `Karta ${n}`,
  slotWritten: 'Zapisana',
  slotWriting: 'Zapis',
  slotWaiting: 'Czeka',
  slotHasData: 'Ma dane',
  cardOfTotal: (i, n) => `Karta ${i} z ${n}`,
  archiveAgain: 'Archiwizuj kolejny',
  back: 'Wstecz',
  archiveStoppedPartial: (written, total) => `Zatrzymano — zapisano ${written} z ${total}. Archiwum jest niekompletne.`,
  scanStageTitle: 'Przykładaj karty w dowolnej kolejności',
  archiveRowStatus: (received, total, complete) => `${received} z ${total}${complete ? ' · gotowe' : ''}`,
  fileRowMeta: (size, totalChunks, when) => `${size} · ${totalChunks} ${pr(totalChunks, CARD)} · ${when}`,
  overwriteTitle: 'Karta zawiera już dane',
  overwriteBody: 'Nadpisanie usunie jej zawartość.',
```

`webapp/app/i18n/tr.ts`:

```ts

  // — redesign 2026-10 —
  readerConnectTitle: 'Bir okuyucu bağlayın',
  readerConnectBody: "Bluetooth üzerinden bir Chameleon Ultra ya da bu telefonun NFC'si (Android'de Chrome, yalnızca NTAG).",
  readerNamePhone: "Telefonun NFC'si",
  inspect: 'İncele',
  connectReaderFirst: 'Önce bir okuyucu bağlayın',
  sourceChooseFile: 'Dosya seçmek için dokunun',
  sourceTapToChange: 'Değiştirmek için dokunun',
  tagTypeLabel: 'Etiket türü',
  passwordLabel: 'Şifre (isteğe bağlı)',
  saveAsLabel: 'Şu adla kaydet',
  cardsNeeded: (n) => `≈ ${n} ${pr(n, CARD)} gerekli`,
  estimateAuto: 'Otomatik algılama · okutulan karta uyum sağlar',
  slotCard: (n) => `Kart ${n}`,
  slotWritten: 'Yazıldı',
  slotWriting: 'Yazılıyor',
  slotWaiting: 'Bekliyor',
  slotHasData: 'Veri var',
  cardOfTotal: (i, n) => `Kart ${i} / ${n}`,
  archiveAgain: 'Yeni arşiv',
  back: 'Geri',
  archiveStoppedPartial: (written, total) => `Durduruldu — ${total} karttan ${written} tanesi yazıldı. Arşiv eksik.`,
  scanStageTitle: 'Kartları istediğiniz sırayla okutun',
  archiveRowStatus: (received, total, complete) => `${received}/${total} ${pr(total, CARD)}${complete ? ' · tamam' : ''}`,
  fileRowMeta: (size, totalChunks, when) => `${size} · ${totalChunks} ${pr(totalChunks, CARD)} · ${when}`,
  overwriteTitle: 'Kartta zaten veri var',
  overwriteBody: 'Üzerine yazmak içeriğini siler.',
```

`webapp/app/i18n/ka.ts`:

```ts

  // — redesign 2026-10 —
  readerConnectTitle: 'დააკავშირეთ წამკითხველი',
  readerConnectBody: 'Chameleon Ultra Bluetooth-ით, ან ამ ტელეფონის NFC (Chrome Android-ზე, მხოლოდ NTAG).',
  readerNamePhone: 'ტელეფონის NFC',
  inspect: 'დათვალიერება',
  connectReaderFirst: 'ჯერ დააკავშირეთ წამკითხველი',
  sourceChooseFile: 'შეეხეთ ფაილის ასარჩევად',
  sourceTapToChange: 'შეეხეთ შესაცვლელად',
  tagTypeLabel: 'ტეგის ტიპი',
  passwordLabel: 'პაროლი (არასავალდებულო)',
  saveAsLabel: 'შენახვა როგორც',
  cardsNeeded: (n) => `საჭიროა ≈ ${n} ${pr(n, CARD)}`,
  estimateAuto: 'ავტოამოცნობა · მოერგება მიდებულ ბარათს',
  slotCard: (n) => `ბარათი ${n}`,
  slotWritten: 'ჩაწერილია',
  slotWriting: 'იწერება',
  slotWaiting: 'ელოდება',
  slotHasData: 'შეიცავს მონაცემებს',
  cardOfTotal: (i, n) => `ბარათი ${i} / ${n}`,
  archiveAgain: 'ახალი არქივი',
  back: 'უკან',
  archiveStoppedPartial: (written, total) => `შეჩერდა — ჩაწერილია ${written} / ${total}. არქივი არასრულია.`,
  scanStageTitle: 'შეახეთ ბარათები ნებისმიერი თანმიმდევრობით',
  archiveRowStatus: (received, total, complete) => `${received}/${total} ${pr(total, CARD)}${complete ? ' · სრულია' : ''}`,
  fileRowMeta: (size, totalChunks, when) => `${size} · ${totalChunks} ${pr(totalChunks, CARD)} · ${when}`,
  overwriteTitle: 'ბარათი უკვე შეიცავს მონაცემებს',
  overwriteBody: 'გადაწერა წაშლის მის შიგთავსს.',
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0` (the key-set, arity, and Slavic-plural tests now cover `cardsNeeded`).

- [ ] **Step 6: Commit**

```bash
git add webapp/app/i18n webapp/test/i18n.test.ts
git commit -m "feat(webapp): i18n keys for the M3 redesign in all seven locales

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Archive Stop — thread an AbortSignal through the write loop

**Files:**
- Modify: `webapp/app/ui/archive-orchestrator.ts`
- Test: `webapp/test/archive-orchestrator.test.ts`

**Interfaces:**
- Consumes: `t.archiveStoppedPartial(written, total)` (Task 1).
- Produces: `export type ArchiveOutcome = 'done' | 'stopped' | 'failed'`; `ArchiveOrchestrator.run(transport: Transport, req: ArchiveRequest, signal?: AbortSignal): Promise<ArchiveOutcome>`; `ArchiveIO.awaitReconnect(signal?: AbortSignal): Promise<Transport>`.

- [ ] **Step 1: Write the failing tests**

In `webapp/test/archive-orchestrator.test.ts` change the orchestrator import line to:

```ts
import { ArchiveOrchestrator, type ArchiveIO } from '../app/ui/archive-orchestrator.js';
import { en } from '../app/i18n/en.js';
```

Append at the end of the file:

```ts
/** A tap that never comes — until the signal aborts. Without a signal it fails
 *  loudly after 200 ms instead of hanging the suite. */
class NeverTapTransport extends MockTransport {
  seenSignal: AbortSignal | undefined;
  override async awaitTag(opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<PresentedTag> {
    this.seenSignal = opts?.signal;
    return new Promise((_, reject) => {
      const s = opts?.signal;
      if (!s) { setTimeout(() => reject(new Error('run() did not pass an AbortSignal')), 200); return; }
      s.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
    });
  }
}

/** Phone NFC's stop() rejects the pending tap with its OWN AbortError when the
 *  reader is torn down. The user never pressed Stop. */
class TornDownTransport extends MockTransport {
  constructor(private readonly onTap: () => void) { super(); }
  override async awaitTag(): Promise<PresentedTag> {
    this.onTap();
    throw new DOMException('Aborted', 'AbortError');
  }
}

const threeCards = () => ({ data: multiCardData, fileName: 'blob.bin', compress: false, payloadSize: 720 });

test('Stop while waiting for a tap ends the run as stopped', async () => {
  const tr = new NeverTapTransport();
  const ac = new AbortController();
  const { io, statuses } = makeIO(tr);
  setTimeout(() => ac.abort(), 20);
  const outcome = await new ArchiveOrchestrator(io).run(tr, threeCards(), ac.signal);
  assert.equal(outcome, 'stopped');
  assert.equal(tr.seenSignal, ac.signal, 'the tap wait received the Stop signal');
  assert.equal(statuses.at(-1), en.archiveStoppedPartial(0, 3));
});

test('Stop during the overwrite prompt never writes the card', async () => {
  const inner = new MockTransport();
  const ac = new AbortController();
  const existing = encodeChunk({
    archiveId: new Uint8Array(16).fill(9), totalChunks: 1, chunkIndex: 0,
    payload: new Uint8Array([1]), crc32: 0, flags: 0,
  });
  inner.enqueueTag(uid(0), existing); // tap → OverwriteRequiredError → prompt
  inner.enqueueTag(uid(0), existing); // a re-tap an "overwrite" would consume
  const { io } = makeIO(inner, { confirmOverwrite: async () => { ac.abort(); return 'once'; } });
  const outcome = await new ArchiveOrchestrator(io).run(inner, threeCards(), ac.signal);
  assert.equal(outcome, 'stopped');
  await inner.awaitTag(); // presents the queued re-tap of uid(0)
  const onCard = await inner.readChunk();
  assert.deepEqual(Array.from(onCard.subarray(0, existing.length)), Array.from(existing), 'the old data is untouched');
});

test('Stop while waiting for the reader to reconnect ends the run', async () => {
  const tr = new MockTransport();
  const ac = new AbortController();
  let seen: AbortSignal | undefined;
  const { io } = makeIO(tr, {
    isConnected: () => false,
    activeTransport: () => null,
    awaitReconnect: (signal) => new Promise((_, reject) => {
      seen = signal;
      if (!signal) { setTimeout(() => reject(new Error('awaitReconnect got no AbortSignal')), 200); return; }
      signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
    }),
  });
  setTimeout(() => ac.abort(), 20);
  const outcome = await new ArchiveOrchestrator(io).run(tr, threeCards(), ac.signal);
  assert.equal(outcome, 'stopped');
  assert.equal(seen, ac.signal);
});

test('a reader teardown AbortError is not mistaken for Stop', async () => {
  let connected = true;
  const tA = new TornDownTransport(() => { connected = false; });
  const tB = new MockTransport();
  let active: Transport = tA;
  tB.enqueueTag(uid(0)); tB.enqueueTag(uid(1)); tB.enqueueTag(uid(2));
  const { io } = makeIO(tA, {
    isConnected: () => connected,
    activeTransport: () => (connected ? active : null),
    awaitReconnect: async () => { connected = true; active = tB; return tB; },
  });
  const outcome = await new ArchiveOrchestrator(io).run(tA, threeCards(), new AbortController().signal);
  assert.equal(outcome, 'done', 'the write resumed on the new reader and finished');
});

test('run reports done and failed outcomes', async () => {
  const inner = new MockTransport();
  for (let i = 0; i < 3; i++) inner.enqueueTag(uid(i));
  assert.equal(await new ArchiveOrchestrator(makeIO(inner).io).run(inner, threeCards()), 'done');

  const failing = {
    ...new MockTransport(),
    name: 'always-fails',
    async awaitTag() { throw new CardReadError('boom'); },
  } as unknown as Transport;
  const outcome = await new ArchiveOrchestrator(makeIO(failing).io).run(failing, {
    data: new Uint8Array(50), fileName: 'x.bin', compress: false, payloadSize: 100,
  });
  assert.equal(outcome, 'failed');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL at `tsc` — `Expected 2 arguments, but got 3` on `run(…, ac.signal)` and `Parameter 'signal' implicitly has an 'any' type` / type mismatch on `awaitReconnect: (signal) =>`.

- [ ] **Step 3: Implement**

All edits are in `webapp/app/ui/archive-orchestrator.ts`.

(a) After the `OverwriteChoice` type, add:

```ts
/** How a run ended: every card written, the user pressed Stop, or it gave up
 *  (prepare failed, or the failure breaker tripped). */
export type ArchiveOutcome = 'done' | 'stopped' | 'failed';
```

(b) In `interface ArchiveIO`, replace the `awaitReconnect(): Promise<Transport>;` line (keep its doc comment) with:

```ts
  awaitReconnect(signal?: AbortSignal): Promise<Transport>;
```

(c) Replace the `run` signature line with:

```ts
  async run(transport: Transport, req: ArchiveRequest, signal?: AbortSignal): Promise<ArchiveOutcome> {
```

and in the prepare `catch`, replace the bare `return;` with `return 'failed';`.

(d) Replace `let done = false;` with:

```ts
    let done = false;
    let written = 0;
    // Stop is decided by the signal, never by an error's type: tearing down a
    // Web NFC reader rejects the pending tap with its own AbortError, and that
    // must still take the reconnect path below.
    const stopped = (): ArchiveOutcome => {
      this.io.setStatus(t.archiveStoppedPartial(written, total));
      this.io.log.info('archive', 'Write cancelled', { written, total });
      return 'stopped';
    };
```

(e) Replace

```ts
    while (!done) {
      const iterationStart = Date.now();
```

with

```ts
    while (!done) {
      if (signal?.aborted) return stopped();
      const iterationStart = Date.now();
```

(f) Replace `inUse = await this.io.awaitReconnect();` with:

```ts
        try {
          inUse = await this.io.awaitReconnect(signal);
        } catch (e) {
          if (signal?.aborted) return stopped();
          throw e;
        }
```

(g) Replace the first `const res = await ctrl.writeNextCard(undefined, overwriteAll, onEvent);` and the `total = res.progress.total;` line after it with:

```ts
        const res = await ctrl.writeNextCard(signal, overwriteAll, onEvent);
        total = res.progress.total;
        written = res.progress.written;
```

(h) Replace the head of the outer `catch (e) {` block — from `if (!usable()) continue; // disconnect or reader swap — handled at the loop top` through the closing `}` of the `if (e instanceof DOMException && e.name === 'AbortError') { … return; }` branch — with:

```ts
        if (signal?.aborted) return stopped();
        if (!usable()) continue; // disconnect or reader swap — handled at the loop top
        // An AbortError the user did not ask for, on a reader that is still
        // live: nothing will ever resume it, so end the run instead of spinning.
        if (e instanceof DOMException && e.name === 'AbortError') return stopped();
```

(i) Directly after `this.io.log.info('archive', 'Overwrite prompt answered', { choice });` add:

```ts
          if (signal?.aborted) return stopped();
```

(j) In the overwrite retry, replace `const res = await ctrl.writeNextCard(undefined, true, onEvent);` and the `total = res.progress.total;` after it with:

```ts
            const res = await ctrl.writeNextCard(signal, true, onEvent);
            total = res.progress.total;
            written = res.progress.written;
```

and make the first line of its `catch (e2) {` block:

```ts
            if (signal?.aborted) return stopped();
```

(k) In the breaker branch, replace `return;` with `return 'failed';`.

(l) After the final `this.io.log.info('archive', 'Write complete', { cards: total });` add `return 'done';`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0`. `archive-panel.ts` still compiles: its `awaitReconnect: () => …` is assignable to the optional-parameter signature and it calls `run` without a signal.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/archive-orchestrator.ts webapp/test/archive-orchestrator.test.ts
git commit -m "feat(webapp): archive writes can be stopped via an AbortSignal

run() threads the signal into every tap and reconnect wait, checks it after
the overwrite prompt, and returns 'done' | 'stopped' | 'failed'. Stop is read
from signal.aborted, never from the error type, so a Web NFC teardown's own
AbortError still reconnects.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Tokens, stylesheet, icon sprite, app bar and navigation

**Files:**
- Modify: `webapp/app/index.html` — the whole `<style>` block (lines 7–288), the sprite (lines 291–300), the `<header>` (302–307), and the `#tabs` strip (327–333)
- Test: `webapp/test/markup-ids.test.ts`
- Create (git-excluded tooling): `webapp/.visual/serve.sh`, `webapp/.visual/stop.sh`, `webapp/.visual/shot.sh`, `webapp/.visual/_visual.html`

**Interfaces:**
- Produces CSS classes used by Tasks 5–10: `.app-bar .icon-btn .lang-picker .nav .nav-btn .nav-ind .nav-label .reader-card .reader-text .reader-title .reader-sub .reader-body .reader-status .reader-actions .reader-connect .glyph-bt .glyph-nfc .status-dot .card .row .row-stack .row-text .row-name .row-sub .row-control .row-status .icon-tile .ico .brand-ico .mono .dots .dot .section-label .field .field-label .field-help .with-icon select.compact .switch .switch-track .seg-button .file-pick .file-empty .file-chosen .file-change .text-source .estimate .estimate-title .estimate-sub .sticky-action .action-hint .status .btn .btn-primary .btn-outlined .btn-filled .btn-outlined-sm .btn-tonal .btn-tonal-wide .btn-text .btn-text-wide .btn-danger .btn-icon .tonal .icon-download .icon-trash .icon-link-off .icon-close .stage .slots .slot .slot-glyph .slot-name .slot-state .slot-counter .stage-headline .stage-progress .progress-meta .summary .pulse .pulse-core .restore-idle .empty-state .files-footer .log-actions .about-head .about-logo .about-card .dialog-title .dialog-actions .inspect-body .inspect-head .inspect-meta .inspect-card .sr-only`.
- Produces sprite symbols: existing `i-file i-pencil i-card i-archive i-lock i-save i-folder i-download` plus `i-upload i-nfc i-bluetooth i-check i-check-circle i-alert i-stop i-restore i-list i-info i-globe i-theme i-brand`.
- Produces state attributes the CSS reacts to: `#device-pill[data-connected][data-reader]`, `#panel-archive[data-state]`, `#panel-restore[data-scanning]`, `#file-pick[data-has-file]`, `.slots[data-dense]`, `.slot[data-state]`, `.row[data-encrypted="true"]`, `.row[data-complete="true"]`, `.status[data-tone="error"]`.

- [ ] **Step 1: Write the failing tests**

Append to `webapp/test/markup-ids.test.ts`:

```ts
function stylesheet(): string {
  const style = /<style>([\s\S]*?)<\/style>/.exec(html);
  assert.ok(style, 'no <style> block in index.html');
  return style[1]!;
}

test('every CSS custom property the stylesheet uses is defined', () => {
  const css = stylesheet();
  const defined = new Set([...css.matchAll(/(--[a-z0-9-]+)\s*:/g)].map((m) => m[1]!));
  const used = new Set([...css.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]!));
  const missing = [...used].filter((v) => !defined.has(v)).sort();
  assert.deepEqual(missing, [], `used but never defined: ${missing.join(', ')}`);
});

test('the manual dark theme redefines every token the manual light theme defines', () => {
  const css = stylesheet();
  const names = (sel: string): string[] => {
    const m = new RegExp(`:root\\[data-theme="${sel}"\\]\\s*\\{([^}]*)\\}`).exec(css);
    assert.ok(m, `no :root[data-theme="${sel}"] block`);
    return [...m[1]!.matchAll(/(--[a-z0-9-]+)\s*:/g)].map((x) => x[1]!).sort();
  };
  assert.deepEqual(names('dark'), names('light'));
});

test('nav labels never wrap under their icon', () => {
  // RU/KA tab labels are ~40% longer than English; at 360px a wrapped label
  // pushes the bar's height past --nav-h and the sticky Archive bar under it.
  const rule = /\.nav-label\s*\{([^}]*)\}/.exec(stylesheet());
  assert.ok(rule, 'no .nav-label rule');
  assert.match(rule[1]!, /white-space:\s*nowrap/);
  assert.match(rule[1]!, /text-overflow:\s*ellipsis/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL — `no .nav-label rule` (and the dark/light test passes or fails depending on the old token sets; the nav test is the one that must fail).

- [ ] **Step 3: Replace the stylesheet**

Replace everything between `<style>` and `</style>` in `webapp/app/index.html` with:

```css
      /* ---------- tokens ----------
         Material 3 roles from the Flutter app's seed #1976D2 (ColorScheme.fromSeed,
         tonal-spot) — see lib/shared/theme/app_theme.dart. Four colour blocks as
         before: light default, dark by media query, then the two manual overrides
         last so the toggle beats the media query. Non-colour tokens (icon masks,
         --nav-h) live only in the first block. */
      :root {
        --primary: #415F91; --on-primary: #FFFFFF;
        --primary-container: #D6E3FF; --on-primary-container: #001B3E;
        --secondary-container: #DAE2F9; --on-secondary-container: #121C2B;
        --surface: #F9F9FF; --surface-container-low: #F3F3FA;
        --surface-container: #EDEDF4; --surface-container-high: #E7E8EE;
        --on-surface: #191C20; --on-surface-variant: #44474E;
        --outline: #74777F; --outline-variant: #C4C6D0;
        --error: #BA1A1A; --error-container: #FFDAD6; --on-error-container: #410002;
        --success: #2E7D52; --success-container: #E6F4ED; --warning: #B76E00;
        --elev-1: 0 1px 2px rgba(0, 0, 0, 0.12), 0 1px 3px 1px rgba(0, 0, 0, 0.06);
        --scrim: rgba(0, 0, 0, 0.32);
        color-scheme: light;

        --nav-h: 80px;
        /* Glyphs for .btn-icon. A mask (not an <svg> child) keeps the button's
           textContent exactly its translated label — the view tests assert it,
           and it is the accessible name. */
        --icon-check: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M5 12l5 5L20 7'/%3E%3C/svg%3E");
        --icon-download: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4'/%3E%3Cpath d='M7 10l5 5 5-5'/%3E%3Cpath d='M12 15V3'/%3E%3C/svg%3E");
        --icon-trash: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M4 7h16'/%3E%3Cpath d='M10 11v6'/%3E%3Cpath d='M14 11v6'/%3E%3Cpath d='M6 7l1 13h10l1-13'/%3E%3Cpath d='M9 7V4h6v3'/%3E%3C/svg%3E");
        --icon-link-off: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M9 17H7a5 5 0 0 1 0-10h2'/%3E%3Cpath d='M15 7h2a5 5 0 0 1 3.5 8.5'/%3E%3Cpath d='M8 12h2'/%3E%3Cpath d='M3 3l18 18'/%3E%3C/svg%3E");
        --icon-close: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round'%3E%3Cpath d='M6 6l12 12'/%3E%3Cpath d='M18 6L6 18'/%3E%3C/svg%3E");
        --icon-lock: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Crect x='5' y='11' width='14' height='10' rx='2'/%3E%3Cpath d='M8 11V7a4 4 0 0 1 8 0v4'/%3E%3C/svg%3E");
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --primary: #AAC7FF; --on-primary: #0A305F;
          --primary-container: #284777; --on-primary-container: #D6E3FF;
          --secondary-container: #3E4759; --on-secondary-container: #DAE2F9;
          --surface: #111318; --surface-container-low: #191C20;
          --surface-container: #1D2024; --surface-container-high: #282A2F;
          --on-surface: #E2E2E9; --on-surface-variant: #C4C6D0;
          --outline: #8E9099; --outline-variant: #44474E;
          --error: #FFB4AB; --error-container: #93000A; --on-error-container: #FFDAD6;
          --success: #7FD8A4; --success-container: #10331F; --warning: #F0B357;
          --elev-1: none;
          --scrim: rgba(0, 0, 0, 0.5);
          color-scheme: dark;
        }
      }
      :root[data-theme="light"] {
        --primary: #415F91; --on-primary: #FFFFFF;
        --primary-container: #D6E3FF; --on-primary-container: #001B3E;
        --secondary-container: #DAE2F9; --on-secondary-container: #121C2B;
        --surface: #F9F9FF; --surface-container-low: #F3F3FA;
        --surface-container: #EDEDF4; --surface-container-high: #E7E8EE;
        --on-surface: #191C20; --on-surface-variant: #44474E;
        --outline: #74777F; --outline-variant: #C4C6D0;
        --error: #BA1A1A; --error-container: #FFDAD6; --on-error-container: #410002;
        --success: #2E7D52; --success-container: #E6F4ED; --warning: #B76E00;
        --elev-1: 0 1px 2px rgba(0, 0, 0, 0.12), 0 1px 3px 1px rgba(0, 0, 0, 0.06);
        --scrim: rgba(0, 0, 0, 0.32);
        color-scheme: light;
      }
      :root[data-theme="dark"] {
        --primary: #AAC7FF; --on-primary: #0A305F;
        --primary-container: #284777; --on-primary-container: #D6E3FF;
        --secondary-container: #3E4759; --on-secondary-container: #DAE2F9;
        --surface: #111318; --surface-container-low: #191C20;
        --surface-container: #1D2024; --surface-container-high: #282A2F;
        --on-surface: #E2E2E9; --on-surface-variant: #C4C6D0;
        --outline: #8E9099; --outline-variant: #44474E;
        --error: #FFB4AB; --error-container: #93000A; --on-error-container: #FFDAD6;
        --success: #7FD8A4; --success-container: #10331F; --warning: #F0B357;
        --elev-1: none;
        --scrim: rgba(0, 0, 0, 0.5);
        color-scheme: dark;
      }

      /* ---------- base ---------- */
      * { box-sizing: border-box; }
      html { -webkit-text-size-adjust: 100%; }
      body {
        margin: 0; background: var(--surface); color: var(--on-surface);
        font: 14px/20px Roboto, system-ui, -apple-system, "Segoe UI", sans-serif;
        -webkit-font-smoothing: antialiased;
      }
      button, input, select, textarea { font-family: inherit; }
      h1, h2, h3, h4 { margin: 0; }
      [hidden] { display: none !important; }
      :focus-visible { outline: 2px solid var(--primary); outline-offset: 2px; }
      .muted { color: var(--on-surface-variant); }
      .mono { font-family: ui-monospace, "Roboto Mono", monospace; }
      .sr-only {
        position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
        overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0;
      }
      .sprite { display: none; }
      .ico {
        width: 24px; height: 24px; flex-shrink: 0; stroke: currentColor; fill: none;
        stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round;
      }
      .brand-ico { fill: currentColor; stroke: none; }
      /* Static labels are lowercase in some catalogues (settings-list era);
         Flutter capitalises. Only static (data-i18n) text — never a filename. */
      .row-name[data-i18n]::first-letter, .field-label::first-letter, #conn::first-letter { text-transform: uppercase; }

      /* ---------- app bar ---------- */
      .app-bar {
        display: grid; grid-template-columns: 1fr auto 1fr; align-items: center;
        max-width: 36rem; margin: 0 auto; padding: 8px 4px;
      }
      .app-bar h1 { font-size: 22px; line-height: 28px; font-weight: 400; text-align: center; white-space: nowrap; }
      .lang-picker { justify-self: start; position: relative; display: inline-flex; align-items: center; color: var(--on-surface-variant); }
      .lang-picker .ico { position: absolute; left: 12px; pointer-events: none; }
      #lang {
        appearance: none; -webkit-appearance: none; height: 48px; max-width: 9rem;
        padding: 0 12px 0 44px; border: none; border-radius: 24px;
        background: transparent; color: inherit; font-size: 13px; cursor: pointer;
        text-overflow: ellipsis;
      }
      #lang:hover { background: color-mix(in srgb, var(--on-surface) 8%, transparent); }
      .icon-btn {
        width: 48px; height: 48px; display: inline-flex; align-items: center; justify-content: center;
        border: none; border-radius: 24px; background: none; color: var(--on-surface-variant); cursor: pointer;
      }
      .icon-btn:hover { background: color-mix(in srgb, var(--on-surface) 8%, transparent); }
      #theme-toggle { justify-self: end; }

      /* ---------- reader card ----------
         Which half shows is decided by the data-connected attribute device.ts
         already maintains — no extra TS state. */
      #device-bar { max-width: 36rem; margin: 0 auto; padding: 0 16px; }
      .reader-card {
        display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 12px;
        padding: 12px 12px 12px 16px; border-radius: 16px;
        background: var(--surface-container-high); color: var(--on-surface);
      }
      .reader-card[data-connected="true"] { background: var(--primary-container); color: var(--on-primary-container); }
      .reader-card .icon-tile { width: 40px; height: 40px; }
      .reader-card[data-connected="true"] .icon-tile { background: transparent; }
      .reader-title { font-size: 16px; line-height: 24px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .reader-sub { display: flex; align-items: center; gap: 6px; font-size: 12px; line-height: 16px; }
      #conn { display: inline-block; }
      .reader-body, .reader-status { font-size: 12px; line-height: 16px; color: var(--on-surface-variant); }
      .reader-card[data-connected="true"] .reader-status { color: inherit; }
      .reader-status:empty { display: none; }
      .reader-actions { display: flex; align-items: center; gap: 4px; }
      .reader-card[data-connected="true"] .btn-icon { color: inherit; }
      .reader-connect { grid-column: 1 / -1; display: flex; flex-wrap: wrap; gap: 8px; }
      .reader-connect .btn { flex: 1 1 12rem; }
      .reader-card[data-connected="true"] :is(.reader-cta, .reader-body, .reader-connect) { display: none; }
      .reader-card[data-connected="false"] :is(#reader-name, .reader-sub, .reader-actions) { display: none; }
      .reader-card .glyph-nfc { display: none; }
      .reader-card[data-reader="web-nfc"] .glyph-nfc { display: block; }
      .reader-card[data-reader="web-nfc"] .glyph-bt { display: none; }
      .status-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; background: var(--outline); }
      .reader-card[data-connected="true"] .status-dot { background: var(--success); }

      /* ---------- navigation ----------
         Bottom bar on phones; at >= 840px the same markup becomes a tab row above
         the panels. #tabs must stay a <div> with <span>s inside (markup-ids test). */
      .nav {
        position: fixed; z-index: 10; left: 0; right: 0; bottom: 0;
        height: calc(var(--nav-h) + env(safe-area-inset-bottom));
        display: flex; justify-content: center; align-items: flex-start;
        padding: 12px 8px env(safe-area-inset-bottom); background: var(--surface-container);
      }
      .nav-btn {
        flex: 1 1 0; max-width: 7rem; min-width: 0; display: flex; flex-direction: column; align-items: center; gap: 4px;
        padding: 0 2px; border: none; background: none; cursor: pointer; color: var(--on-surface-variant);
      }
      .nav-ind { width: 64px; height: 32px; border-radius: 16px; display: flex; align-items: center; justify-content: center; transition: background-color 0.2s; }
      .nav-label { max-width: 100%; font-size: 12px; line-height: 16px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .nav-btn[aria-selected="true"] { color: var(--on-surface); }
      .nav-btn[aria-selected="true"] .nav-ind { background: var(--secondary-container); color: var(--on-secondary-container); }
      .nav-btn[aria-selected="true"] .nav-label { font-weight: 700; }
      @media (min-width: 840px) {
        :root { --nav-h: 0px; }
        .nav {
          position: static; height: auto; padding: 0; margin: 8px 0 0; background: none;
          border-bottom: 1px solid var(--outline-variant);
        }
        .nav-btn { flex-direction: row; justify-content: center; gap: 8px; max-width: none; padding: 12px 8px; border-bottom: 3px solid transparent; }
        .nav-ind { width: auto; height: auto; background: none !important; }
        .nav-btn[aria-selected="true"] { color: var(--primary); border-bottom-color: var(--primary); }
      }

      /* ---------- layout ---------- */
      main { max-width: 36rem; margin: 0 auto; padding: 8px 16px calc(var(--nav-h) + env(safe-area-inset-bottom) + 16px); }
      section[role="tabpanel"] { padding-top: 8px; }
      .section-label {
        display: block; margin: 24px 4px 8px;
        font-size: 11px; line-height: 16px; font-weight: 500; letter-spacing: 0.08em;
        text-transform: uppercase; color: var(--on-surface-variant);
      }

      /* ---------- cards & rows ---------- */
      .card { background: var(--surface-container-low); border-radius: 16px; box-shadow: var(--elev-1); overflow: hidden; }
      .card:has(> :is(#files, #archives):empty) { display: none; }
      .row {
        display: flex; align-items: center; gap: 16px; min-height: 64px;
        padding: 12px 16px; border-bottom: 1px solid var(--outline-variant);
      }
      .row:last-child { border-bottom: none; }
      .row-stack { flex-direction: column; align-items: stretch; gap: 0; }
      .icon-tile {
        width: 48px; height: 48px; flex-shrink: 0; border-radius: 12px;
        display: flex; align-items: center; justify-content: center;
        background: var(--primary-container); color: var(--on-primary-container);
      }
      .row-text { flex: 1; min-width: 0; display: flex; flex-direction: column; }
      .row-name { font-size: 16px; line-height: 24px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .row-sub { font-size: 12px; line-height: 16px; color: var(--on-surface-variant); }
      .row-control { flex-shrink: 0; display: flex; align-items: center; gap: 4px; }
      .row[data-encrypted="true"] .row-name::after {
        content: ""; display: inline-block; width: 16px; height: 16px; margin-left: 6px; vertical-align: -2px;
        background: currentColor; -webkit-mask: var(--icon-lock) center / 16px no-repeat; mask: var(--icon-lock) center / 16px no-repeat;
      }
      .row[data-complete="true"] .row-status { color: var(--success); }
      .dots { display: inline-flex; gap: 3px; margin-right: 6px; vertical-align: middle; }
      .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--outline-variant); }
      .dot.on { background: var(--primary); }

      /* ---------- fields ---------- */
      .field { display: flex; flex-direction: column; gap: 6px; }
      .field-label, .field-help { font-size: 12px; line-height: 16px; color: var(--on-surface-variant); }
      .field :is(input[type="text"], input[type="password"], textarea, select), select.compact {
        width: 100%; min-height: 48px; padding: 12px 14px;
        background: var(--surface-container-high); color: var(--on-surface);
        border: 1px solid var(--outline); border-radius: 12px; outline: none;
        font-size: 16px; line-height: 24px; transition: border-color 0.15s, box-shadow 0.15s;
      }
      .field :is(input, textarea, select):focus, select.compact:focus { border-color: var(--primary); box-shadow: inset 0 0 0 1px var(--primary); }
      .field textarea { min-height: 96px; resize: vertical; }
      select.compact { width: auto; min-height: 40px; padding: 8px 12px; font-size: 14px; line-height: 20px; }
      .with-icon { position: relative; display: block; }
      .with-icon > .ico { position: absolute; left: 14px; top: 50%; transform: translateY(-50%); color: var(--on-surface-variant); pointer-events: none; }
      .with-icon > input { padding-left: 46px !important; }

      /* Switch: wraps a real checkbox, so focus, form semantics and
         screen-reader behaviour come for free. */
      .switch { position: relative; display: inline-block; width: 52px; height: 32px; flex-shrink: 0; }
      .switch input { position: absolute; opacity: 0; width: 0; height: 0; }
      .switch-track {
        position: absolute; inset: 0; cursor: pointer; border-radius: 16px;
        background: var(--surface-container-high); border: 2px solid var(--outline);
        transition: background-color 0.2s, border-color 0.2s;
      }
      .switch-track::before {
        content: ""; position: absolute; width: 16px; height: 16px; left: 6px; top: 6px; border-radius: 50%;
        background: var(--outline); transition: transform 0.2s, width 0.2s, height 0.2s, left 0.2s, top 0.2s;
      }
      .switch input:checked + .switch-track { background: var(--primary); border-color: var(--primary); }
      .switch input:checked + .switch-track::before { width: 24px; height: 24px; left: 2px; top: 2px; transform: translateX(20px); background: var(--on-primary); }
      .switch input:focus-visible + .switch-track { outline: 2px solid var(--primary); outline-offset: 2px; }

      /* M3 segmented button (File | Text). */
      .seg-button { display: flex; margin-top: 16px; min-height: 40px; border: 1px solid var(--outline); border-radius: 20px; overflow: hidden; }
      .seg-button button {
        flex: 1 1 0; min-width: 0; display: inline-flex; align-items: center; justify-content: center; gap: 8px;
        padding: 0 12px; border: none; background: none; color: var(--on-surface); font-size: 14px; font-weight: 500; cursor: pointer;
      }
      .seg-button button + button { border-left: 1px solid var(--outline); }
      .seg-button button[aria-pressed="true"] { background: var(--secondary-container); color: var(--on-secondary-container); }
      .seg-button button[aria-pressed="true"]::before {
        content: ""; width: 18px; height: 18px; flex-shrink: 0; background: currentColor;
        -webkit-mask: var(--icon-check) center / 18px no-repeat; mask: var(--icon-check) center / 18px no-repeat;
      }

      /* ---------- archive: source & estimate ---------- */
      .file-pick { display: block; margin-top: 12px; cursor: pointer; }
      .file-pick:focus-within { outline: 2px solid var(--primary); outline-offset: 2px; }
      .file-empty { display: flex; flex-direction: column; align-items: center; gap: 4px; padding: 28px 16px; text-align: center; }
      .file-empty .ico { width: 40px; height: 40px; margin-bottom: 8px; color: var(--primary); }
      .file-chosen { border-bottom: none; }
      .file-chosen .ok { color: var(--success); }
      .file-change { display: block; padding: 0 16px 14px; text-align: center; font-size: 14px; font-weight: 500; color: var(--primary); }
      .file-pick:not([data-has-file]) :is(.file-chosen, .file-change) { display: none; }
      .file-pick[data-has-file] .file-empty { display: none; }
      .text-source { margin-top: 12px; padding: 16px; }
      .estimate { margin: 0 16px 16px; padding: 12px 16px; border-radius: 12px; background: var(--primary-container); color: var(--on-primary-container); }
      .estimate:empty { display: none; }
      .estimate-title { font-size: 16px; line-height: 24px; font-weight: 500; }
      .estimate-sub { font-size: 12px; line-height: 16px; }

      /* The backing is OPAQUE on purpose: a disabled filled button is a
         12%-alpha fill by M3 spec, so a translucent bar scrolling over the form
         shows the content through the button (Superdesign draft 8 defect). */
      .sticky-action {
        position: sticky; bottom: calc(var(--nav-h) + env(safe-area-inset-bottom)); z-index: 5;
        margin: 16px -16px 0; padding: 12px 16px; background: var(--surface);
      }
      .action-hint { margin: 8px 4px 0; font-size: 12px; line-height: 16px; text-align: center; color: var(--on-surface-variant); }
      .action-hint:empty { display: none; }
      .status { margin: 8px 4px 0; font-size: 13px; line-height: 18px; text-align: center; color: var(--on-surface-variant); white-space: pre-wrap; }
      .status:empty { display: none; }
      .status[data-tone="error"] { padding: 10px 12px; border-radius: 12px; text-align: left; background: var(--error-container); color: var(--on-error-container); }

      /* ---------- buttons ---------- */
      .btn {
        display: inline-flex; align-items: center; justify-content: center; gap: 8px;
        border: none; cursor: pointer; font-size: 14px; line-height: 20px; font-weight: 500; letter-spacing: 0.1px;
        transition: background-color 0.15s, box-shadow 0.15s, filter 0.15s; -webkit-tap-highlight-color: transparent;
      }
      .btn:disabled { cursor: default; }
      .btn-primary {
        display: flex; width: 100%; min-height: 56px; padding: 0 24px; border-radius: 16px;
        background: var(--primary); color: var(--on-primary); font-size: 16px; box-shadow: var(--elev-1);
      }
      .btn-primary:hover:not(:disabled), .btn-filled:hover:not(:disabled) { filter: brightness(1.08); }
      .btn-outlined {
        display: flex; width: 100%; min-height: 56px; padding: 0 24px; border-radius: 16px;
        border: 1px solid var(--outline); background: transparent; color: var(--primary); font-size: 16px;
      }
      .btn-filled { min-height: 40px; padding: 0 20px; border-radius: 20px; background: var(--primary); color: var(--on-primary); }
      .btn-outlined-sm { min-height: 40px; padding: 0 20px; border-radius: 20px; border: 1px solid var(--outline); background: transparent; color: var(--primary); }
      .btn-tonal { min-height: 40px; padding: 0 16px; border-radius: 20px; background: var(--secondary-container); color: var(--on-secondary-container); }
      .btn-tonal-wide { display: flex; width: 100%; min-height: 48px; border-radius: 24px; background: var(--secondary-container); color: var(--on-secondary-container); }
      .btn-text { min-height: 40px; padding: 0 12px; border-radius: 20px; background: none; color: var(--primary); }
      .btn-text-wide { display: flex; width: 100%; min-height: 48px; border-radius: 24px; background: none; color: var(--primary); }
      .btn-danger { color: var(--error); }
      .btn-tonal:hover:not(:disabled), .btn-tonal-wide:hover:not(:disabled) { filter: brightness(0.96); }
      :is(.btn-outlined, .btn-outlined-sm, .btn-text, .btn-text-wide):hover:not(:disabled) { background: color-mix(in srgb, var(--primary) 8%, transparent); }
      .btn:disabled, .btn-icon:disabled { color: color-mix(in srgb, var(--on-surface) 38%, transparent); box-shadow: none; filter: none; }
      :is(.btn-primary, .btn-filled, .btn-tonal, .btn-tonal-wide):disabled { background: color-mix(in srgb, var(--on-surface) 12%, transparent); }
      :is(.btn-outlined, .btn-outlined-sm):disabled { border-color: color-mix(in srgb, var(--on-surface) 12%, transparent); }
      .btn .ico { width: 20px; height: 20px; }
      /* Icon buttons with a real text label: font-size 0 hides the text but
         keeps it as the accessible name; the glyph is a mask on ::before. */
      .btn-icon {
        position: relative; flex-shrink: 0; width: 48px; height: 48px; padding: 0;
        border: none; border-radius: 24px; background: none; color: var(--on-surface-variant);
        cursor: pointer; font-size: 0; overflow: hidden;
      }
      .btn-icon::before {
        content: ""; position: absolute; inset: 12px; background: currentColor;
        -webkit-mask: var(--icon) center / 24px no-repeat; mask: var(--icon) center / 24px no-repeat;
      }
      .btn-icon:hover:not(:disabled) { background: color-mix(in srgb, var(--on-surface) 8%, transparent); }
      .btn-icon.tonal { background: var(--secondary-container); color: var(--on-secondary-container); }
      .icon-download { --icon: var(--icon-download); }
      .icon-trash { --icon: var(--icon-trash); }
      .icon-link-off { --icon: var(--icon-link-off); }
      .icon-close { --icon: var(--icon-close); }

      /* ---------- stage (archive writing / restore scanning) ---------- */
      #panel-archive:not([data-state]) #archive-stage { display: none; }
      #panel-archive[data-state] :is(.archive-form, .sticky-action) { display: none; }
      #panel-restore:not([data-scanning]) #restore-stage { display: none; }
      #panel-restore[data-scanning] .restore-idle { display: none; }
      #archives-section:has(#archives:empty) { display: none; }
      .stage { padding-top: 16px; }
      .stage > .btn { margin-top: 8px; }
      .slots { display: flex; justify-content: center; gap: 12px; margin: 8px 0 20px; }
      .slots[data-dense] { gap: 6px; }
      .slot {
        flex: 0 1 84px; min-width: 0; height: 112px; padding: 6px 4px;
        display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px;
        border: 2px dashed var(--outline); border-radius: 12px; color: var(--on-surface-variant); text-align: center;
      }
      .slots[data-dense] .slot { height: 64px; }
      .slots[data-dense] :is(.slot-name, .slot-state) { display: none; }
      .slot[data-state="written"] { border: 2px solid var(--primary); background: var(--primary); color: var(--on-primary); }
      .slot[data-state="current"] {
        border: 2px solid var(--primary); background: var(--primary-container); color: var(--on-primary-container);
        animation: slot-pulse 1.6s ease-in-out infinite;
      }
      .slot[data-state="warning"] { border: 2px solid var(--error); background: var(--error-container); color: var(--on-error-container); }
      .slot-glyph { display: flex; }
      .slot-glyph .ico { width: 28px; height: 28px; }
      .slot-name { font-size: 12px; line-height: 16px; font-weight: 500; }
      .slot-state { max-width: 100%; font-size: 11px; line-height: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .slot-counter { font-size: 32px; line-height: 40px; color: var(--primary); text-align: center; }
      @keyframes slot-pulse { 50% { box-shadow: 0 0 0 6px color-mix(in srgb, var(--primary) 18%, transparent); } }
      .stage-headline { margin: 0 0 16px; font-size: 22px; line-height: 28px; font-weight: 400; text-align: center; }
      .stage-progress { margin-bottom: 16px; }
      .progress-meta { display: flex; justify-content: space-between; margin-bottom: 6px; font-size: 12px; line-height: 16px; color: var(--on-surface-variant); }
      /* Kept as a native <progress>: indeterminate state is expressed by removing
         the value attribute, which a div cannot. */
      progress { display: block; width: 100%; height: 4px; border: none; border-radius: 2px; background: var(--secondary-container); -webkit-appearance: none; appearance: none; }
      progress::-webkit-progress-bar { background: var(--secondary-container); border-radius: 2px; }
      progress::-webkit-progress-value { background: var(--primary); border-radius: 2px; transition: width 0.2s; }
      progress::-moz-progress-bar { background: var(--primary); border-radius: 2px; }
      .summary { margin-bottom: 8px; }
      .pulse { position: relative; width: 120px; height: 120px; margin: 8px auto 16px; display: flex; align-items: center; justify-content: center; }
      .pulse::before { content: ""; position: absolute; inset: 0; border-radius: 50%; border: 2px solid var(--primary); opacity: 0; animation: ring 2s ease-out infinite; }
      .pulse-core { width: 80px; height: 80px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: var(--primary-container); color: var(--on-primary-container); }
      .pulse-core .ico { width: 36px; height: 36px; }
      @keyframes ring { from { transform: scale(0.7); opacity: 0.8; } to { transform: scale(1.1); opacity: 0; } }
      .restore-idle { margin-top: 16px; }
      @media (prefers-reduced-motion: reduce) {
        .slot, .pulse::before { animation: none !important; }
        progress::-webkit-progress-value { transition: none; }
      }

      /* ---------- files / log / about ---------- */
      .empty-state { display: flex; flex-direction: column; align-items: center; gap: 12px; padding: 32px 16px; text-align: center; color: var(--on-surface-variant); }
      .empty-state .ico { width: 40px; height: 40px; }
      .empty-state p { margin: 0; }
      .files-footer { display: flex; align-items: center; gap: 8px; margin: 8px 4px 0; }
      #files-info { flex: 1; font-size: 13px; color: var(--on-surface-variant); }
      .log-actions { justify-content: flex-end; gap: 4px; min-height: 56px; }
      #log {
        margin-top: 16px; padding: 12px; border-radius: 12px; background: var(--surface-container-high);
        font: 12px/1.5 ui-monospace, "Roboto Mono", monospace; max-height: 60vh; overflow: auto; white-space: pre-wrap;
      }
      #log [data-level="debug"] { color: var(--on-surface-variant); }
      #log [data-level="warn"] { color: var(--warning); }
      #log [data-level="error"] { color: var(--error); }
      .about-head { display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 24px 8px 8px; text-align: center; }
      .about-logo { width: 64px; height: 64px; border-radius: 16px; }
      .about-logo .brand-ico { width: 36px; height: 36px; }
      .about-head h2 { font-size: 22px; line-height: 28px; font-weight: 400; }
      .about-head p { margin: 0; font-size: 13px; line-height: 18px; color: var(--on-surface-variant); }
      .about-card { padding: 16px; }
      .about-card p { margin: 0 0 8px; font-size: 14px; line-height: 20px; }
      .about-card p:last-child { margin-bottom: 0; }

      /* ---------- dialogs ---------- */
      dialog {
        border: none; border-radius: 28px; padding: 24px; width: calc(100% - 48px); max-width: 22rem;
        background: var(--surface-container-high); color: var(--on-surface); box-shadow: 0 8px 28px rgba(0, 0, 0, 0.25);
      }
      dialog::backdrop { background: var(--scrim); }
      dialog p { margin: 0; }
      .dialog-title { margin: 0 0 12px; font-size: 24px; line-height: 32px; font-weight: 400; }
      .dialog-actions { display: flex; flex-direction: column; gap: 8px; margin-top: 24px; }
      /* The dialog MUST NOT be the scroll container: a rounded box cannot clip
         its own scrollbar (Chromium paints the gutter outside the radius clip).
         The dialog stays overflow:hidden and .inspect-body scrolls.
         NEVER set `display` on a dialog here: author CSS beats the UA's
         `dialog:not([open]) { display: none }`, and the closed dialog then
         renders permanently as a ghost (PR #61). Both are enforced by
         test/markup-ids.test.ts. */
      dialog.inspect { width: calc(100% - 32px); max-width: min(96vw, 62rem); overflow: hidden; padding: 0; }
      .inspect-body { max-height: 88vh; overflow-y: auto; overflow-x: hidden; padding: 0 16px 16px; }
      .inspect-head { position: sticky; top: 0; z-index: 1; display: flex; align-items: center; gap: 4px; padding: 8px 0; background: var(--surface-container-high); }
      .inspect-head strong { flex: 1; min-width: 0; font-size: 20px; line-height: 28px; font-weight: 400; }
      .inspect-meta { margin: 0 0 4px; font-size: 13px; color: var(--on-surface-variant); }
      .inspect-card { padding: 12px 16px; }
      dialog.inspect pre { margin: 0; max-width: 100%; overflow-x: auto; white-space: pre; font: 12px/1.45 ui-monospace, "Roboto Mono", monospace; }
      @media (max-width: 599px) {
        dialog.inspect { width: 100%; max-width: 100%; height: 100dvh; max-height: 100dvh; margin: 0; border-radius: 0; }
        .inspect-body { max-height: 100dvh; }
      }
```

- [ ] **Step 4: Replace the icon sprite**

Replace the `<svg class="sprite" …>…</svg>` block with:

```html
    <svg class="sprite" aria-hidden="true">
      <symbol id="i-file" viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></symbol>
      <symbol id="i-pencil" viewBox="0 0 24 24"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z"/></symbol>
      <symbol id="i-card" viewBox="0 0 24 24"><rect x="2" y="5" width="20" height="14" rx="2"/><path d="M2 10h20"/></symbol>
      <symbol id="i-archive" viewBox="0 0 24 24"><path d="M21 8v13H3V8"/><rect x="1" y="3" width="22" height="5" rx="1"/><path d="M10 12h4"/></symbol>
      <symbol id="i-lock" viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></symbol>
      <symbol id="i-save" viewBox="0 0 24 24"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><path d="M17 21v-8H7v8"/><path d="M7 3v5h8"/></symbol>
      <symbol id="i-folder" viewBox="0 0 24 24"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></symbol>
      <symbol id="i-download" viewBox="0 0 24 24"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5"/><path d="M12 15V3"/></symbol>
      <symbol id="i-upload" viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M12 18v-6"/><path d="M9 15l3-3 3 3"/></symbol>
      <symbol id="i-nfc" viewBox="0 0 24 24"><path d="M6.5 8.5a5 5 0 0 1 0 7"/><path d="M10 6a9 9 0 0 1 0 12"/><path d="M13.5 3.5a13 13 0 0 1 0 17"/></symbol>
      <symbol id="i-bluetooth" viewBox="0 0 24 24"><path d="M7 7l10 10-5 5V2l5 5L7 17"/></symbol>
      <symbol id="i-check" viewBox="0 0 24 24"><path d="M5 12l5 5L20 7"/></symbol>
      <symbol id="i-check-circle" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M8 12l3 3 5-6"/></symbol>
      <symbol id="i-alert" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v6"/><path d="M12 16.5v.5"/></symbol>
      <symbol id="i-stop" viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor" stroke="none"/></symbol>
      <symbol id="i-restore" viewBox="0 0 24 24"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l3 2"/></symbol>
      <symbol id="i-list" viewBox="0 0 24 24"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8"/><path d="M8 12h8"/><path d="M8 16h5"/></symbol>
      <symbol id="i-info" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 7.5v.5"/></symbol>
      <symbol id="i-globe" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a14 14 0 0 1 0 18a14 14 0 0 1 0-18z"/></symbol>
      <symbol id="i-theme" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor"/></symbol>
      <symbol id="i-brand" viewBox="0 0 24 24"><path d="M20 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2zm-1 14H5V6h14v12zM7.5 9.5A1.5 1.5 0 0 1 9 8h6a1.5 1.5 0 0 1 1.5 1.5v5A1.5 1.5 0 0 1 15 16H9a1.5 1.5 0 0 1-1.5-1.5v-5zM9 9.5v5h6v-5H9z"/></symbol>
    </svg>
```

- [ ] **Step 5: Replace the header and the tab strip**

Replace the whole `<header>…</header>` with:

```html
    <header class="app-bar">
      <label class="lang-picker">
        <svg class="ico" aria-hidden="true"><use href="#i-globe"/></svg>
        <select id="lang" data-i18n-title="language" title="Language"></select>
      </label>
      <h1>NFC Archiver</h1>
      <button id="theme-toggle" class="icon-btn" type="button" data-i18n-title="themeToggle" title="Toggle light/dark"><svg class="ico" aria-hidden="true"><use href="#i-theme"/></svg></button>
    </header>
```

Replace the whole `<div id="tabs" …>…</div>` with (one `<button>` per line; spans only — no `<div>` inside):

```html
      <div id="tabs" class="nav" role="tablist">
        <button class="nav-btn" role="tab" data-tab="archive" aria-selected="true"><span class="nav-ind"><svg class="ico" aria-hidden="true"><use href="#i-archive"/></svg></span><span class="nav-label" data-i18n="tabArchive">Archive</span></button>
        <button class="nav-btn" role="tab" data-tab="restore" aria-selected="false"><span class="nav-ind"><svg class="ico" aria-hidden="true"><use href="#i-restore"/></svg></span><span class="nav-label" data-i18n="tabRestore">Restore</span></button>
        <button class="nav-btn" role="tab" data-tab="files" aria-selected="false"><span class="nav-ind"><svg class="ico" aria-hidden="true"><use href="#i-folder"/></svg></span><span class="nav-label" data-i18n="tabFiles">Files</span></button>
        <button class="nav-btn" role="tab" data-tab="log" aria-selected="false"><span class="nav-ind"><svg class="ico" aria-hidden="true"><use href="#i-list"/></svg></span><span class="nav-label" data-i18n="tabLog">Log</span></button>
        <button class="nav-btn" role="tab" data-tab="about" aria-selected="false"><span class="nav-ind"><svg class="ico" aria-hidden="true"><use href="#i-info"/></svg></span><span class="nav-label" data-i18n="tabAbout">About</span></button>
      </div>
```

(`data-i18n` moved from the button to the inner `.nav-label`: `applyStaticText()` replaces `textContent`, which would otherwise delete the icon.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0` (all three new CSS tests, plus the existing dialog and sprite invariants).

- [ ] **Step 7: Create the visual tooling (git-excluded)**

```bash
cd /home/mezinster/nfcarchiver
grep -qx '/webapp/.visual/' .git/info/exclude || printf '%s\n' '/webapp/.visual/' '/webapp/app/_visual.html' '/webapp/app/_draft-*.html' >> .git/info/exclude
mkdir -p webapp/.visual
```

`webapp/.visual/serve.sh`:

```bash
#!/bin/bash
# Serves webapp/app on :8123 with esbuild code splitting, so _visual.html can
# import the view modules into the SAME module graph as main.js (one i18n state).
# esbuild's server exits when stdin closes — hence the `sleep |` pipe.
cd "$(dirname "$0")/.." || exit 1
source ~/.nvm/nvm.sh >/dev/null && nvm use 22 >/dev/null
cp .visual/_visual.html app/_visual.html
ENTRIES="app/main.ts"
for f in app/ui/stage-view.ts app/ui/restore-view.ts app/ui/files-view.ts; do [ -f "$f" ] && ENTRIES="$ENTRIES $f"; done
(sleep 3600 | npx esbuild $ENTRIES --bundle --format=esm --splitting --outdir=app/dist --servedir=app --serve=localhost:8123 > .visual/serve.log 2>&1 &)
for i in $(seq 1 30); do
  curl -s -o /dev/null -f http://localhost:8123/dist/main.js && { echo "serving on :8123"; exit 0; }
  sleep 1
done
echo "server did not start — see webapp/.visual/serve.log"; exit 1
```

`webapp/.visual/stop.sh`:

```bash
#!/bin/bash
# `pkill -x` matches the process NAME only — `pkill -f esbuild` would also match
# (and kill) the calling shell, whose command line contains the word.
cd "$(dirname "$0")/.." || exit 1
pkill -x esbuild; pkill -f '^sleep 3600$'
rm -rf app/dist app/_visual.html app/_draft-*.html
echo stopped
```

`webapp/.visual/shot.sh`:

```bash
#!/bin/bash
# usage: shot.sh <name> "<query>" [width=390] [height=1100]
#   e.g. shot.sh writing-ru "state=writing&lang=ru"
# Headless Chrome on Windows clamps windows to ~500px, so phone widths are
# rendered as an iframe of exactly <width> inside a wider window.
cd "$(dirname "$0")" || exit 1
W=${3:-390}; H=${4:-1100}
WIN=$(( W < 500 ? 520 : W + 20 ))
WT=/mnt/c/Users/EvgenyMezin/AppData/Local/Temp/nfar-visual
mkdir -p "$WT" out
"/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" --headless=new --disable-gpu --hide-scrollbars \
  --window-size=$WIN,$H --virtual-time-budget=8000 \
  --screenshot="C:\\Users\\EvgenyMezin\\AppData\\Local\\Temp\\nfar-visual\\$1.png" \
  "http://localhost:8123/_visual.html?$2&w=$W&h=$H" >/dev/null 2>&1
cp "$WT/$1.png" "out/$1.png" && echo "webapp/.visual/out/$1.png"
```

If Chrome cannot reach `localhost:8123`, replace `localhost` in `shot.sh` with the address printed by `hostname -I | cut -d' ' -f1`.

`webapp/.visual/_visual.html`:

```html
<!doctype html>
<meta charset="utf-8">
<title>visual</title>
<body style="margin:0;background:#777">
<iframe id="f" style="border:0;display:block"></iframe>
<script type="module">
const q = new URLSearchParams(location.search);
const f = document.getElementById('f');
f.style.width = `${q.get('w') ?? 390}px`;
f.style.height = `${q.get('h') ?? 1100}px`;
const src = q.get('src') ?? 'index.html';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
f.addEventListener('load', async () => {
  if (src !== 'index.html') return; // a Superdesign draft: render as-is
  const w = f.contentWindow, d = f.contentDocument;
  const $ = (id) => d.getElementById(id);
  // Imported INSIDE the iframe's realm so they share main.js's module instances.
  const load = (p) => w.eval(`import('./dist/ui/${p}.js')`);
  await sleep(400);
  if (q.get('theme')) d.documentElement.setAttribute('data-theme', q.get('theme'));
  if (q.get('lang')) { const s = $('lang'); s.value = q.get('lang'); s.dispatchEvent(new w.Event('change')); }
  const tab = (n) => d.querySelector(`#tabs button[data-tab="${n}"]`).click();
  const connect = () => {
    const p = $('device-pill');
    p.setAttribute('data-connected', 'true'); p.setAttribute('data-reader', 'chameleon');
    if ($('reader-name')) $('reader-name').textContent = 'Chameleon Ultra';
    $('conn').textContent = 'connected';
    for (const id of ['inspect', 'disconnect', 'archive', 'scan']) { const b = $(id); if (b) b.disabled = false; }
    if ($('archive-hint')) $('archive-hint').textContent = '';
  };
  const chooseFile = async () => {
    const dt = new w.DataTransfer();
    dt.items.add(new w.File([new Uint8Array(2400)], 'backup-keys.txt'));
    $('file').files = dt.files;
    $('file').dispatchEvent(new w.Event('change'));
    await sleep(500);
  };
  const stage = async (written, total, opts = {}) => {
    const { renderSlots } = await load('stage-view');
    $('panel-archive').setAttribute('data-state', opts.state ?? 'writing');
    renderSlots($('archive-slots'), written, total, { warning: opts.warning === true });
    $('stage-headline').textContent = opts.headline ?? `Writing card ${written + 1} of ${total} — hold it still…`;
    $('archive-bar').max = total; $('archive-bar').value = written;
    $('archive-progress-label').textContent = `Card ${Math.min(written + 1, total)} of ${total}`;
    $('archive-progress-pct').textContent = `${Math.round((written / total) * 100)}%`;
    $('summary-name').textContent = 'backup-keys.txt';
    $('summary-meta').textContent = '2.3 KB · GZIP · AES-256 · Mifare Classic 1K — 752 B';
  };
  const states = {
    'none': async () => {},
    'no-reader': async () => {
      $('source-text-btn')?.click();
      $('text').value = 'Wi-Fi: home-5g / pass: correct-horse';
      $('text').dispatchEvent(new w.Event('input'));
      await sleep(600);
    },
    'idle': async () => { connect(); await chooseFile(); },
    'writing': async () => { connect(); await stage(1, 3); },
    'writing-many': async () => { connect(); await stage(6, 24); },
    'overwrite': async () => {
      connect();
      await stage(1, 3, { warning: true, headline: 'This card already holds data — waiting for your answer in the dialog…' });
      $('overwrite-dialog').showModal();
    },
    'done': async () => {
      connect();
      await stage(3, 3, { state: 'done', headline: 'Done — wrote and verified 3 cards.' });
      $('archive-stop').hidden = true;
      $('archive-again').textContent = 'Archive another';
      $('archive-again').hidden = false;
    },
    'scanning': async () => {
      tab('restore'); connect();
      const { renderArchiveList } = await load('restore-view');
      $('panel-restore').setAttribute('data-scanning', '');
      $('stop-scan').disabled = false;
      renderArchiveList($('archives'), [
        { archiveId: 'a', shortId: '3f2a91c0', totalChunks: 3, received: 3, isEncrypted: true, isCompressed: true, complete: true },
        { archiveId: 'b', shortId: 'a71c0e55', totalChunks: 5, received: 2, isEncrypted: false, isCompressed: true, complete: false },
      ], () => {});
      $('restore-status').textContent = 'Tap more cards, or Restore a complete one.';
    },
    'files': async () => {
      tab('files');
      const { renderFileList } = await load('files-view');
      renderFileList($('files'), [
        { id: '1', name: 'backup-keys-2026-10-05-final.txt', size: 2400, createdAt: Date.now(), isEncrypted: true, isCompressed: true, totalChunks: 3 },
        { id: '2', name: 'text_note.txt', size: 312, createdAt: Date.now() - 86400000, isEncrypted: false, isCompressed: false, totalChunks: 1 },
      ], { onDownload() {}, onDelete() {} });
      $('files-empty').hidden = true;
      $('files-info').textContent = '2 files · 2.7 KB stored';
    },
    'files-empty': async () => { tab('files'); await sleep(300); },
    'log': async () => { tab('log'); },
    'about': async () => { tab('about'); },
    'inspect': async () => {
      connect();
      $('inspect-identity').textContent = 'UID   B9 16 27 51\nSAK   08\nATQA  00 04\nType  Mifare Classic 1K';
      $('inspect-nfar').textContent = 'Magic    NFAR\nVersion  1\nFlags    GZIP · AES-256-GCM\nChunk    1 of 3\nCRC32    valid';
      $('inspect-raw').textContent = Array.from({ length: 16 }, (_, i) =>
        `Blk ${String(i).padStart(2, '0')}  4E 46 41 52 01 03 3F 2A 91 C0 7B 10 4A E9 8B 00  NFAR..?*..{.J...`).join('\n');
      $('inspect-progress').textContent = '64/64 read';
      $('inspect-dialog').showModal();
    },
  };
  try { await (states[q.get('state') ?? 'none'] ?? states.none)(); }
  catch (e) { d.body.insertAdjacentHTML('afterbegin', `<pre style="background:#fdd;color:#900;padding:8px">${String(e)}</pre>`); }
});
f.src = src;
</script>
```

Then: `chmod +x webapp/.visual/*.sh`.

- [ ] **Step 8: Visual check of the shell**

```bash
cd /home/mezinster/nfcarchiver/webapp
.visual/serve.sh
.visual/shot.sh t3-shell "state=none"
.visual/shot.sh t3-shell-wide "state=none" 1280 900
.visual/shot.sh t3-shell-ru "state=none&lang=ru" 360
.visual/stop.sh
```

Open the three PNGs (Read tool). Expected: centred "NFC Archiver" between a globe/language pill and the theme button; a five-item bottom bar with Archive's pill highlighted (390 and 360/RU, labels on one line); at 1280 the same five items as a tab row with an underline under Archive. The panels below still use old markup and will look unfinished — that is expected until Tasks 5–10.

- [ ] **Step 9: Commit**

```bash
git add webapp/app/index.html webapp/test/markup-ids.test.ts
git commit -m "feat(webapp): M3 tokens, stylesheet, sprite, app bar and navigation bar

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `stage-view.ts` — the card-slot row

**Files:**
- Create: `webapp/app/ui/stage-view.ts`
- Test: `webapp/test/stage-view.test.ts` (create)

**Interfaces:**
- Consumes: `t.slotCard`, `t.slotWritten`, `t.slotWriting`, `t.slotWaiting`, `t.slotHasData`, `t.cardOfTotal` (Task 1); sprite symbols `i-check`, `i-nfc`, `i-card`, `i-alert` (Task 3).
- Produces: `export const MAX_SLOTS = 10`; `export const DENSE_ABOVE = 5`; `export type SlotState = 'written' | 'current' | 'waiting' | 'warning'`; `export function slotState(index: number, written: number, total: number, warning: boolean): SlotState`; `export const SLOT_GLYPHS: readonly string[]`; `export function renderSlots(container: HTMLElement, written: number, total: number, opts?: { warning?: boolean }): void`.

- [ ] **Step 1: Write the failing tests**

Create `webapp/test/stage-view.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { renderSlots, slotState, SLOT_GLYPHS, MAX_SLOTS } from '../app/ui/stage-view.js';
import { setLocale } from '../app/i18n/index.js';
import { en } from '../app/i18n/en.js';
import { pl } from '../app/i18n/pl.js';

/** Minimal DOM stub — the surface renderSlots touches (same shape as restore-view.test.ts). */
interface StubEl {
  tagName: string; className: string; textContent: string; innerHTML: string;
  children: StubEl[]; parent: StubEl | null; ownerDocument: StubDoc; attrs: Record<string, string>;
  append(...kids: StubEl[]): void; appendChild(kid: StubEl): StubEl; remove(): void;
  setAttribute(name: string, value: string): void; getAttribute(name: string): string | null; removeAttribute(name: string): void;
}
interface StubDoc { createElement(tag: string): StubEl; }
function makeDoc(): StubDoc {
  const doc: StubDoc = {
    createElement(tag: string): StubEl {
      const el: StubEl = {
        tagName: tag.toUpperCase(), className: '', textContent: '', innerHTML: '',
        children: [], parent: null, ownerDocument: doc, attrs: {},
        append(...kids) { for (const k of kids) { k.parent = el; el.children.push(k); } },
        appendChild(kid) { kid.parent = el; el.children.push(kid); return kid; },
        remove() { if (el.parent) { el.parent.children.splice(el.parent.children.indexOf(el), 1); el.parent = null; } },
        setAttribute(name, value) { el.attrs[name] = value; },
        getAttribute(name) { return el.attrs[name] ?? null; },
        removeAttribute(name) { delete el.attrs[name]; },
      };
      return el;
    },
  };
  return doc;
}
const box = (): StubEl => makeDoc().createElement('div');
const render = (c: StubEl, w: number, n: number, warning = false) =>
  renderSlots(c as unknown as HTMLElement, w, n, { warning });
const states = (c: StubEl) => c.children.map((s) => s.getAttribute('data-state'));

test('slotState by position', () => {
  assert.equal(slotState(0, 1, 3, false), 'written');
  assert.equal(slotState(1, 1, 3, false), 'current');
  assert.equal(slotState(1, 1, 3, true), 'warning');
  assert.equal(slotState(2, 1, 3, true), 'waiting');
  assert.equal(slotState(2, 3, 3, false), 'written');
});

test('renders one slot per card, labelled, with states by position', () => {
  setLocale('en');
  const c = box();
  render(c, 1, 3);
  assert.deepEqual(states(c), ['written', 'current', 'waiting']);
  const [glyph, name, state] = c.children[1]!.children;
  assert.match(glyph!.innerHTML, /i-nfc/);
  assert.equal(name!.textContent, en.slotCard(2));
  assert.equal(state!.textContent, en.slotWriting);
  assert.equal(c.getAttribute('data-mode'), 'slots');
});

test('warning marks only the current slot', () => {
  const c = box();
  render(c, 1, 3, true);
  assert.deepEqual(states(c), ['written', 'warning', 'waiting']);
});

test('every slot is written when the archive is done', () => {
  const c = box();
  render(c, 3, 3);
  assert.deepEqual(states(c), ['written', 'written', 'written']);
});

test('reuses slots and follows a re-chunk in both directions', () => {
  const c = box();
  render(c, 0, 3);
  const first = c.children[0]!;
  render(c, 1, 5); // Auto-detect found a smaller card: more chunks
  assert.equal(c.children.length, 5);
  assert.strictEqual(c.children[0], first, 'slot 1 reconciled, not rebuilt');
  render(c, 1, 2); // …or a bigger one: fewer chunks
  assert.equal(c.children.length, 2);
  assert.deepEqual(states(c), ['written', 'current']);
});

test('marks rows above DENSE_ABOVE dense and switches to a counter above MAX_SLOTS', () => {
  setLocale('en');
  const c = box();
  render(c, 2, 6);
  assert.equal(c.getAttribute('data-dense'), '');
  render(c, 6, MAX_SLOTS + 14);
  assert.equal(c.children.length, 1);
  assert.equal(c.getAttribute('data-mode'), 'counter');
  assert.equal(c.children[0]!.textContent, en.cardOfTotal(7, 24));
  render(c, 0, 3);
  assert.equal(c.children.length, 3);
  assert.equal(c.getAttribute('data-mode'), 'slots');
  assert.equal(c.getAttribute('data-dense'), null);
});

test('relabels after a locale switch', () => {
  const c = box();
  setLocale('en');
  render(c, 0, 2);
  try {
    setLocale('pl');
    render(c, 0, 2);
    assert.equal(c.children[0]!.children[1]!.textContent, pl.slotCard(1));
    assert.equal(c.children[0]!.children[2]!.textContent, pl.slotWriting);
  } finally {
    setLocale('en');
  }
});

test('every slot glyph exists in the sprite', () => {
  const html = readFileSync(fileURLToPath(new URL('../../app/index.html', import.meta.url)), 'utf8');
  for (const id of SLOT_GLYPHS) assert.ok(html.includes(`<symbol id="${id}"`), `sprite has no ${id}`);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL at `tsc` — `Cannot find module '../app/ui/stage-view.js'`.

- [ ] **Step 3: Implement**

Create `webapp/app/ui/stage-view.ts`:

```ts
/**
 * The card-slot row of the archive write stage: one slot per card, showing
 * written / current / waiting (or warning while the overwrite prompt is open).
 *
 * Reconciles in place like restore-view.ts — slots are created or removed only
 * when `total` changes (Auto-detect re-chunks mid-write), and every label is
 * rewritten on each call so a language switch mid-write takes effect.
 */
import { t } from '../i18n/index.js';

/** Above this many cards the row would not fit a phone; a counter replaces it. */
export const MAX_SLOTS = 10;
/** Above this many cards slots show only their glyph. */
export const DENSE_ABOVE = 5;

export type SlotState = 'written' | 'current' | 'waiting' | 'warning';

export function slotState(index: number, written: number, total: number, warning: boolean): SlotState {
  if (index < written) return 'written';
  if (index === written && written < total) return warning ? 'warning' : 'current';
  return 'waiting';
}

const GLYPH: Record<SlotState, string> = {
  written: 'i-check', current: 'i-nfc', waiting: 'i-card', warning: 'i-alert',
};
/** Exported so a test can prove each id exists in index.html's sprite. The
 *  markup is built by concatenation (not a `<use href="#${…}">` template) so the
 *  sprite test's static scan never reads a template expression as an icon id. */
export const SLOT_GLYPHS: readonly string[] = Object.values(GLYPH);

function stateLabel(s: SlotState): string {
  switch (s) {
    case 'written': return t.slotWritten;
    case 'current': return t.slotWriting;
    case 'waiting': return t.slotWaiting;
    case 'warning': return t.slotHasData;
  }
}

function glyphHtml(id: string): string {
  return '<svg class="ico"><use href="' + '#' + id + '"/></svg>';
}

export function renderSlots(
  container: HTMLElement,
  written: number,
  total: number,
  opts: { warning?: boolean } = {},
): void {
  const doc = container.ownerDocument;
  const kids = (): HTMLElement[] => Array.from(container.children) as HTMLElement[];

  if (total > MAX_SLOTS) {
    let counter = kids()[0];
    if (counter === undefined || counter.getAttribute('data-counter') === null) {
      for (const k of kids()) k.remove();
      counter = doc.createElement('div');
      counter.className = 'slot-counter';
      counter.setAttribute('data-counter', '');
      container.appendChild(counter);
    }
    counter.textContent = t.cardOfTotal(Math.min(written + 1, total), total);
    container.setAttribute('data-mode', 'counter');
    container.removeAttribute('data-dense');
    return;
  }

  container.setAttribute('data-mode', 'slots');
  if (total > DENSE_ABOVE) container.setAttribute('data-dense', '');
  else container.removeAttribute('data-dense');
  if (kids().some((k) => k.getAttribute('data-counter') !== null)) for (const k of kids()) k.remove();
  while (kids().length > total) kids()[kids().length - 1]!.remove();
  while (kids().length < total) {
    const slot = doc.createElement('div');
    slot.className = 'slot';
    const glyph = doc.createElement('span');
    glyph.className = 'slot-glyph';
    const name = doc.createElement('span');
    name.className = 'slot-name';
    const state = doc.createElement('span');
    state.className = 'slot-state';
    slot.append(glyph, name, state);
    container.appendChild(slot);
  }

  const warning = opts.warning === true;
  kids().forEach((slot, i) => {
    const s = slotState(i, written, total, warning);
    slot.setAttribute('data-state', s);
    const [glyph, name, state] = Array.from(slot.children) as HTMLElement[];
    if (glyph!.getAttribute('data-glyph') !== GLYPH[s]) {
      glyph!.innerHTML = glyphHtml(GLYPH[s]);
      glyph!.setAttribute('data-glyph', GLYPH[s]);
    }
    name!.textContent = t.slotCard(i + 1);
    state!.textContent = stateLabel(s);
  });
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add webapp/app/ui/stage-view.ts webapp/test/stage-view.test.ts
git commit -m "feat(webapp): card-slot row renderer for the write stage

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Reader card

**Files:**
- Modify: `webapp/app/index.html` (the `#device-bar` block), `webapp/app/ui/device.ts`
- Test: `webapp/test/i18n.test.ts`

**Interfaces:**
- Consumes: `t.readerConnectTitle`, `t.readerConnectBody`, `t.readerNamePhone`, `t.inspect` (Task 1); `.reader-card` CSS (Task 3).
- Produces: element `#reader-name` (owned by `device.ts`, never `data-i18n`); `#device-pill` gains `data-reader="chameleon|web-nfc|"`.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/i18n.test.ts`:

```ts
// Like #conn: #reader-name shows the live reader, so applyStaticText() must
// never rewrite it — device.ts owns it.
test('the reader-name span is not statically translated', () => {
  const html = readFileSync(fileURLToPath(new URL('../../app/index.html', import.meta.url)), 'utf8');
  const el = /<span id="reader-name"[^>]*>/.exec(html);
  assert.ok(el, 'no #reader-name span in index.html');
  assert.ok(!el[0].includes('data-i18n'), `#reader-name must not be statically translated: ${el[0]}`);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL — `no #reader-name span in index.html`.

- [ ] **Step 3: Replace the device-bar markup**

Replace the whole `<div id="device-bar">…</div>` block (including its comment about `#conn`) with:

```html
    <div id="device-bar">
      <div id="device-pill" class="reader-card" data-connected="false" data-reader="">
        <span class="icon-tile" aria-hidden="true">
          <svg class="ico glyph-bt"><use href="#i-bluetooth"/></svg>
          <svg class="ico glyph-nfc"><use href="#i-nfc"/></svg>
        </span>
        <div class="reader-text">
          <div class="reader-title">
            <!-- #reader-name and #conn carry live state; device.ts owns and
                 re-renders them, so neither may be marked data-i18n. -->
            <span id="reader-name"></span><span class="reader-cta" data-i18n="readerConnectTitle">Connect a reader</span>
          </div>
          <div class="reader-sub"><span class="status-dot"></span><span id="conn">disconnected</span></div>
          <div class="reader-body" data-i18n="readerConnectBody">A Chameleon Ultra over Bluetooth, or this phone’s NFC (Chrome on Android, NTAG only).</div>
          <div id="device-status" class="reader-status" role="status"></div>
        </div>
        <div class="reader-actions">
          <button id="inspect" class="btn btn-tonal" type="button" disabled data-i18n="inspect">Inspect</button>
          <button id="disconnect" class="btn-icon icon-link-off" type="button" disabled data-i18n="disconnect">Disconnect</button>
        </div>
        <div class="reader-connect">
          <button id="connect" class="btn btn-filled" type="button" data-i18n="connect">Connect Chameleon</button>
          <button id="use-web-nfc" class="btn btn-outlined-sm" type="button" hidden data-i18n="usePhoneNfc">Use phone NFC</button>
        </div>
      </div>
    </div>
```

- [ ] **Step 4: Update `device.ts`**

In `webapp/app/ui/device.ts` replace the body of `renderConn()` with:

```ts
function renderConn(): void {
  $('conn').textContent = connected ? t.statusConnected : t.statusDisconnected;
  // The reader card's CSS keys off both attributes: data-connected picks the
  // connected/CTA half, data-reader picks the Bluetooth or NFC glyph.
  const card = $('device-pill');
  card.setAttribute('data-connected', String(connected));
  card.setAttribute('data-reader', reader ?? '');
  // "Chameleon Ultra" is a product name — only the phone reader is translated.
  $('reader-name').textContent =
    reader === 'chameleon' ? 'Chameleon Ultra' : reader === 'web-nfc' ? t.readerNamePhone : '';
}
```

Then make `#device-status` carry only messages, not the reader name: replace `deviceStatus.textContent = t.readerPhoneNfc;` with `deviceStatus.textContent = '';` and replace `deviceStatus.textContent = t.readerChameleon;` with `deviceStatus.textContent = '';`.

(`renderConn` already runs on locale change via the existing `onLocaleChange(() => { renderConn(); updateDeviceButtons(); })`, so `readerNamePhone` follows a language switch.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0`.

- [ ] **Step 6: Visual check**

```bash
cd /home/mezinster/nfcarchiver/webapp
.visual/serve.sh
.visual/shot.sh t5-noreader "state=none"
.visual/shot.sh t5-noreader-ru "state=none&lang=ru" 360
.visual/shot.sh t5-connected "state=idle"
.visual/stop.sh
```

Expected: disconnected → grey card, Bluetooth tile, "Connect a reader", body text, a filled "Connect Chameleon" button (and no phone-NFC button on desktop Chrome — `webNfcAvailable()` is false there). In RU at 360px the button text fits or wraps the button onto its own row — it must never break a word across two lines inside the button. Connected → primary-container card, "Chameleon Ultra", green dot + "Connected", "Inspect" and a link-off icon on one line.

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/device.ts webapp/test/i18n.test.ts
git commit -m "feat(webapp): reader card replaces the device bar

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Archive form — File | Text source, settings, estimate, sticky action

**Files:**
- Create: `webapp/app/source.ts`
- Modify: `webapp/app/index.html` (`#panel-archive`), `webapp/app/ui/archive-panel.ts`
- Test: `webapp/test/source.test.ts` (create), `webapp/test/markup-ids.test.ts`

**Interfaces:**
- Consumes: `t.cardsNeeded`, `t.estimateAuto`, `t.connectReaderFirst`, `t.tagTypeLabel`, `t.passwordLabel`, `t.sourceChooseFile`, `t.sourceTapToChange` (Task 1); `humanSize(bytes: number): string` from `app/ui/files-view.ts` (existing).
- Produces: `export type SourceMode = 'file' | 'text'`; `export interface Source { data: Uint8Array; fileName: string }`; `export const TEXT_FILE_NAME = 'text_note.txt'`; `export function pickSource(mode: SourceMode, file: { bytes: Uint8Array; name: string } | null, text: string): Source | null`. New ids `#source-file-btn #source-text-btn #file-pick #file-name #file-size #text-source #archive-hint`. In `archive-panel.ts`: `setStatus(msg: string, tone?: 'info' | 'error')`.

- [ ] **Step 1: Write the failing tests**

Create `webapp/test/source.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pickSource, TEXT_FILE_NAME } from '../app/source.js';

const file = { bytes: new Uint8Array([1, 2, 3]), name: 'keys.bin' };

test('pickSource returns the chosen file in File mode', () => {
  assert.deepEqual(pickSource('file', file, 'ignored'), { data: file.bytes, fileName: 'keys.bin' });
});

test('pickSource returns nothing in File mode without a file, even if text was typed', () => {
  assert.equal(pickSource('file', null, 'some text'), null);
});

test('pickSource ignores a chosen file in Text mode', () => {
  // The file input is hidden in Text mode; writing it would be invisible to the user.
  assert.equal(pickSource('text', file, ''), null);
  const src = pickSource('text', file, 'note');
  assert.equal(src?.fileName, TEXT_FILE_NAME);
  assert.deepEqual(Array.from(src!.data), Array.from(new TextEncoder().encode('note')));
});

test('pickSource encodes text as UTF-8', () => {
  assert.equal(pickSource('text', null, 'Привет')!.data.length, 12);
});
```

Append to `webapp/test/markup-ids.test.ts`:

```ts
test('the sticky action bar has an opaque backing', () => {
  // A disabled filled button is a 12%-alpha fill; over a translucent bar the
  // form shows through it (Superdesign draft 8). The backing must be --surface.
  const css = /<style>([\s\S]*?)<\/style>/.exec(html)![1]!;
  const rule = /\.sticky-action\s*\{([^}]*)\}/.exec(css);
  assert.ok(rule, 'no .sticky-action rule');
  assert.match(rule[1]!, /background:\s*var\(--surface\)/);
});

test('the file input stays inside its label card', () => {
  assert.match(html, /<label id="file-pick"[^>]*>[\s\S]*?<input type="file" id="file"/,
    '#file must be inside label#file-pick, or the whole card stops opening the picker');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL at `tsc` — `Cannot find module '../app/source.js'`.

- [ ] **Step 3: Create `webapp/app/source.ts`**

```ts
/**
 * Which bytes the Archive button would write. Pure, so the mode rule is unit
 * tested: in Text mode a previously chosen file is ignored (its input is
 * hidden), and in File mode typed text is ignored.
 */
export type SourceMode = 'file' | 'text';
export interface Source { data: Uint8Array; fileName: string }
export const TEXT_FILE_NAME = 'text_note.txt';

export function pickSource(
  mode: SourceMode,
  file: { bytes: Uint8Array; name: string } | null,
  text: string,
): Source | null {
  if (mode === 'file') return file ? { data: file.bytes, fileName: file.name } : null;
  return text.length > 0 ? { data: new TextEncoder().encode(text), fileName: TEXT_FILE_NAME } : null;
}
```

- [ ] **Step 4: Replace the archive panel markup**

Replace everything inside `<section id="panel-archive" role="tabpanel">…</section>` (keep the section element) with:

```html
        <div class="archive-form">
          <div class="seg-button" role="group" data-i18n-title="sectionSource" title="Source">
            <button id="source-file-btn" type="button" aria-pressed="true"><span data-i18n="sourceFile">File</span></button>
            <button id="source-text-btn" type="button" aria-pressed="false"><span data-i18n="sourceText">Text</span></button>
          </div>

          <label id="file-pick" class="card file-pick">
            <input type="file" id="file" class="sr-only" />
            <span class="file-empty">
              <svg class="ico" aria-hidden="true"><use href="#i-upload"/></svg>
              <span class="row-name" data-i18n="sourceChooseFile">Tap to choose a file</span>
              <span class="row-sub" data-i18n="subChooseFile">Any file, split across cards</span>
            </span>
            <span class="row file-chosen">
              <span class="icon-tile"><svg class="ico" aria-hidden="true"><use href="#i-file"/></svg></span>
              <span class="row-text"><span id="file-name" class="row-name"></span><span id="file-size" class="row-sub"></span></span>
              <svg class="ico ok" aria-hidden="true"><use href="#i-check-circle"/></svg>
            </span>
            <span class="file-change" data-i18n="sourceTapToChange">Tap to change</span>
          </label>

          <div id="text-source" class="card text-source" hidden>
            <label class="field">
              <textarea id="text" rows="4" data-i18n-placeholder="textPlaceholder" placeholder="Type text to archive as text_note.txt"></textarea>
              <span class="field-help" data-i18n="subTypeText">Saved as text_note.txt</span>
            </label>
          </div>

          <span class="section-label" data-i18n="sectionSettings">Settings</span>
          <div class="card">
            <div class="row row-stack">
              <label class="field">
                <span class="field-label" data-i18n="tagTypeLabel">Tag type</span>
                <select id="target-tag">
                  <option value="auto" selected data-i18n="targetAuto">Auto-detect (adapts to the card)</option>
                  <option value="720">Mifare Classic 1K — 752 B</option>
                  <option value="NTAG213">NTAG213 — 144 B</option>
                  <option value="NTAG215">NTAG215 — 504 B</option>
                  <option value="NTAG216">NTAG216 — 888 B</option>
                </select>
              </label>
            </div>
            <div class="row">
              <div class="row-text">
                <div class="row-name" data-i18n="compress">compress</div>
                <div class="row-sub" data-i18n="subCompress">GZIP before writing</div>
              </div>
              <label class="switch"><input type="checkbox" id="compress" checked /><span class="switch-track"></span></label>
            </div>
            <div class="row row-stack">
              <label class="field">
                <span class="field-label" data-i18n="passwordLabel">Password (optional)</span>
                <span class="with-icon"><svg class="ico" aria-hidden="true"><use href="#i-lock"/></svg><input type="password" id="apass" autocomplete="new-password" data-i18n-placeholder="subPassword" placeholder="AES-256-GCM, optional" /></span>
              </label>
            </div>
            <div id="cardcount" class="estimate" aria-live="polite"></div>
          </div>
        </div>

        <!-- Replaced by #archive-stage in the next task; kept so writing still works. -->
        <div class="card" id="archive-progress-row" hidden style="margin-top:12px;padding:16px">
          <progress id="archive-bar"></progress>
          <span id="archive-progress-label" class="row-sub"></span>
        </div>

        <div class="sticky-action">
          <button id="archive" class="btn btn-primary" type="button" disabled><svg class="ico" aria-hidden="true"><use href="#i-nfc"/></svg><span data-i18n="archiveToCards">Archive to cards</span></button>
          <p id="archive-hint" class="action-hint"></p>
          <div class="status" id="archive-status" role="status" data-i18n="archiveIdle">Connect a Chameleon, then choose a file or type text.</div>
        </div>
```

Note `#cardcount` has **no whitespace inside** — `.estimate:empty` hides it.

- [ ] **Step 5: Update `archive-panel.ts`**

(a) Add imports at the top of `webapp/app/ui/archive-panel.ts`:

```ts
import { pickSource, type SourceMode } from '../source.js';
import { humanSize } from './files-view.js';
```

(b) Replace `const setStatus = (msg: string) => { $('archive-status').textContent = msg; };` with:

```ts
  const setStatus = (msg: string, tone: 'info' | 'error' = 'info'): void => {
    const el = $('archive-status');
    el.textContent = msg;
    if (tone === 'error') el.setAttribute('data-tone', 'error');
    else el.removeAttribute('data-tone');
  };
```

(c) Replace the `currentSource` arrow function with:

```ts
  let mode: SourceMode = 'file';
  const currentSource = () => pickSource(
    mode,
    fileBytes ? { bytes: fileBytes, name: fileName } : null,
    ($('text') as HTMLTextAreaElement).value,
  );
```

(d) Replace the body of `updateCounter` with:

```ts
  const updateCounter = async (): Promise<void> => {
    const src = currentSource();
    const el = $('cardcount');
    if (!src) { el.replaceChildren(); return; }
    const compress = ($('compress') as HTMLInputElement).checked;
    const encrypted = ($('apass') as HTMLInputElement).value.length > 0;
    const count = await estimateCardCount(src.data, src.fileName, { compress, encrypted, payloadSize: selectedPayloadSize() });
    const sel = $('target-tag') as HTMLSelectElement;
    const title = document.createElement('div');
    title.className = 'estimate-title';
    title.textContent = t.cardsNeeded(count);
    const sub = document.createElement('div');
    sub.className = 'estimate-sub';
    sub.textContent = sel.value === 'auto' ? t.estimateAuto : (sel.selectedOptions[0]?.textContent ?? '');
    el.replaceChildren(title, sub);
  };
```

(e) Replace the `$('file').addEventListener('change', …)` handler with:

```ts
  $('file').addEventListener('change', async () => {
    const f = ($('file') as HTMLInputElement).files?.[0];
    fileBytes = f ? new Uint8Array(await f.arrayBuffer()) : null;
    fileName = f?.name ?? '';
    $('file-pick').toggleAttribute('data-has-file', f !== undefined);
    $('file-name').textContent = fileName;
    $('file-size').textContent = f ? humanSize(f.size) : '';
    void updateCounter();
  });

  const setMode = (m: SourceMode): void => {
    mode = m;
    $('source-file-btn').setAttribute('aria-pressed', String(m === 'file'));
    $('source-text-btn').setAttribute('aria-pressed', String(m === 'text'));
    $('file-pick').hidden = m !== 'file';
    $('text-source').hidden = m !== 'text';
    void updateCounter();
  };
  $('source-file-btn').addEventListener('click', () => setMode('file'));
  $('source-text-btn').addEventListener('click', () => setMode('text'));
  // The estimate's words come from `t`; re-render them on a language switch.
  onLocaleChange(() => { void updateCounter(); });
```

(f) In `syncArchiveButton`, add as its last line:

```ts
    $('archive-hint').textContent = isConnected() ? '' : t.connectReaderFirst;
```

and directly after the line `onLocaleChange(syncArchiveButton);` add `syncArchiveButton();` so the hint shows at startup.

(g) Mark the panel's own failures as errors: in the click handler change `setStatus(t.readerBusyElsewhere)` to `setStatus(t.readerBusyElsewhere, 'error')` and, in its `catch (e)`, `setStatus(humanError(e))` to `setStatus(humanError(e), 'error')`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0` (`markup-ids` now sees `#source-file-btn`, `#file-pick`, … in the markup).

- [ ] **Step 7: Visual check**

```bash
cd /home/mezinster/nfcarchiver/webapp
.visual/serve.sh
.visual/shot.sh t6-idle "state=idle"
.visual/shot.sh t6-noreader "state=no-reader"
.visual/shot.sh t6-idle-dark "state=idle&theme=dark"
.visual/shot.sh t6-idle-ru "state=idle&lang=ru" 360
.visual/stop.sh
```

Compare `t6-idle` with Superdesign draft **B+C · 1** and `t6-noreader` with **B+C · 8** (preview links in the spec's table). Expected: segmented File | Text with a check on the selected side; the chosen-file card "backup-keys.txt · 2.3 KB" with a green check and "Tap to change"; full-width Tag type select under its label (never a crushed label column); "≈ N cards needed" panel; the Archive button above the bottom bar on an opaque strip — in `t6-noreader` the disabled button must not show the form through it, and "Connect a reader first" sits under it.

- [ ] **Step 8: Commit**

```bash
git add webapp/app/source.ts webapp/app/index.html webapp/app/ui/archive-panel.ts webapp/test/source.test.ts webapp/test/markup-ids.test.ts
git commit -m "feat(webapp): File | Text source picker, M3 settings card and estimate panel

pickSource makes the mode explicit: a chosen file is no longer written from
Text mode.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Archive write stage, Stop, overwrite dialog

**Files:**
- Modify: `webapp/app/index.html` (replace `#archive-progress-row`; restyle `#overwrite-dialog`), `webapp/app/ui/archive-panel.ts`
- Test: `webapp/test/markup-ids.test.ts`

**Interfaces:**
- Consumes: `ArchiveOrchestrator.run(…, signal)` and `ArchiveOutcome` (Task 2); `renderSlots` (Task 4); `t.cardOfTotal`, `t.archiveAgain`, `t.back`, `t.overwriteTitle`, `t.overwriteBody` (Task 1); `humanSize` (existing); `setStatus(msg, tone)` (Task 6).
- Produces: ids `#archive-stage #archive-slots #stage-headline #archive-progress #archive-progress-pct #summary-name #summary-meta #archive-stop #archive-again`; `#panel-archive[data-state="writing|done|stopped|failed"]`.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/markup-ids.test.ts`:

```ts
test('the write stage holds its own controls and progress', () => {
  const stage = /<div id="archive-stage"[^>]*>([\s\S]*?)<\/section>/.exec(html);
  assert.ok(stage, 'no #archive-stage inside the archive panel');
  for (const id of ['archive-slots', 'stage-headline', 'archive-bar', 'archive-progress-label', 'archive-stop', 'archive-again']) {
    assert.ok(stage[1]!.includes(`id="${id}"`), `#${id} must live inside #archive-stage`);
  }
  assert.ok(!html.includes('id="archive-progress-row"'), 'the old progress card is gone');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL — `no #archive-stage inside the archive panel`.

- [ ] **Step 3: Replace the progress card with the stage**

In `#panel-archive`, replace the comment line `<!-- Replaced by #archive-stage in the next task; kept so writing still works. -->` and the `<div class="card" id="archive-progress-row" …>…</div>` block with:

```html
        <div id="archive-stage" class="stage">
          <div id="archive-slots" class="slots" aria-hidden="true"></div>
          <h2 id="stage-headline" class="stage-headline" aria-live="polite"></h2>
          <div id="archive-progress" class="stage-progress">
            <div class="progress-meta"><span id="archive-progress-label"></span><span id="archive-progress-pct"></span></div>
            <progress id="archive-bar"></progress>
          </div>
          <div class="card summary">
            <div class="row">
              <span class="icon-tile"><svg class="ico" aria-hidden="true"><use href="#i-file"/></svg></span>
              <div class="row-text"><div id="summary-name" class="row-name"></div><div id="summary-meta" class="row-sub"></div></div>
            </div>
          </div>
          <button id="archive-stop" class="btn btn-outlined" type="button"><svg class="ico" aria-hidden="true"><use href="#i-stop"/></svg><span data-i18n="stop">Stop</span></button>
          <button id="archive-again" class="btn btn-primary" type="button" hidden></button>
        </div>
```

Replace the whole `<dialog id="overwrite-dialog">…</dialog>` with:

```html
    <dialog id="overwrite-dialog">
      <h2 class="dialog-title" data-i18n="overwriteTitle">Card already holds data</h2>
      <p id="overwrite-message" data-i18n="overwriteBody">Overwriting erases what is on it.</p>
      <form method="dialog" class="dialog-actions">
        <button value="once" class="btn btn-primary" data-i18n="overwrite">Overwrite</button>
        <button value="all" class="btn btn-tonal-wide" data-i18n="overwriteAll">Overwrite all remaining</button>
        <button id="overwrite-skip" class="btn btn-text-wide" value="skip" data-i18n="skip">Skip</button>
      </form>
    </dialog>
```

- [ ] **Step 4: Wire the stage in `archive-panel.ts`**

(a) Change the orchestrator import to include the outcome type, and import the slot renderer:

```ts
import { ArchiveOrchestrator, type ArchiveIO, type ArchiveOutcome, type OverwriteChoice } from './archive-orchestrator.js';
import { renderSlots } from './stage-view.js';
```

(b) Make `setStatus` also drive the stage headline — add as its last line:

```ts
    $('stage-headline').textContent = msg;
```

(c) Replace the `bar` / `showProgress` / `hideProgress` declarations with:

```ts
  const bar = $('archive-bar') as HTMLProgressElement;
  let slotsWritten = 0;
  let slotsTotal = 0;
  let slotWarning = false;
  const drawSlots = (): void => {
    renderSlots($('archive-slots'), slotsWritten, slotsTotal, { warning: slotWarning });
  };
  const showProgress = (label: string, value: number | null, max: number): void => {
    $('archive-progress').hidden = false;
    bar.max = max;
    if (value === null) bar.removeAttribute('value'); else bar.value = value;
    const done = value !== null && value >= max;
    // The orchestrator's label is a sentence; the stage shows "Card n of N"
    // while writing and keeps the sentence ("✓ 3 of 3 … verified") once done.
    $('archive-progress-label').textContent = done ? label : t.cardOfTotal(Math.min((value ?? 0) + 1, max), max);
    $('archive-progress-pct').textContent = value === null || max === 0 ? '' : `${Math.round((value / max) * 100)}%`;
    // max changes mid-write when Auto-detect re-chunks, so redraw on every call.
    slotsWritten = value ?? 0;
    slotsTotal = max;
    drawSlots();
  };
  const hideProgress = (): void => { $('archive-progress').hidden = true; };
```

(d) Replace `confirmOverwrite` with (the current slot shows the warning state while the dialog is open):

```ts
  const confirmOverwrite = (): Promise<OverwriteChoice> => new Promise((resolve) => {
    overwriteDialog.returnValue = '';
    slotWarning = true;
    drawSlots();
    overwriteDialog.addEventListener('close', () => {
      slotWarning = false;
      drawSlots();
      const v = overwriteDialog.returnValue;
      resolve(v === 'all' ? 'all' : v === 'once' ? 'once' : 'skip');
    }, { once: true });
    overwriteDialog.showModal();
  });
```

(e) Directly before `$('archive').addEventListener('click', …)` add the stage helpers:

```ts
  let runAbort: AbortController | null = null;
  let lastOutcome: ArchiveOutcome | null = null;

  const againLabel = (): string => (lastOutcome === 'done' ? t.archiveAgain : t.back);

  const enterStage = (src: { data: Uint8Array; fileName: string }, compress: boolean, encrypted: boolean): void => {
    lastOutcome = null;
    $('panel-archive').setAttribute('data-state', 'writing');
    slotsWritten = 0; slotsTotal = 0; slotWarning = false;
    drawSlots();
    $('summary-name').textContent = src.fileName;
    const tag = ($('target-tag') as HTMLSelectElement).selectedOptions[0]?.textContent ?? '';
    $('summary-meta').textContent =
      [humanSize(src.data.length), compress ? 'GZIP' : '', encrypted ? 'AES-256' : '', tag].filter((x) => x !== '').join(' · ');
    $('archive-stop').hidden = false;
    $('archive-again').hidden = true;
  };

  const leaveStage = (outcome: ArchiveOutcome): void => {
    lastOutcome = outcome;
    $('panel-archive').setAttribute('data-state', outcome);
    $('archive-stop').hidden = true;
    const again = $('archive-again');
    again.textContent = againLabel();
    again.hidden = false;
  };

  $('archive-stop').addEventListener('click', () => { runAbort?.abort(); });
  $('archive-again').addEventListener('click', () => {
    lastOutcome = null;
    $('panel-archive').removeAttribute('data-state');
    setStatus(isConnected() ? t.archiveReady : t.archiveIdle);
  });
  onLocaleChange(() => {
    if (slotsTotal > 0) drawSlots();
    if (lastOutcome !== null) $('archive-again').textContent = againLabel();
  });
```

(The overwrite dialog is modal, so Stop cannot be pressed while it is open; the orchestrator still re-checks the signal after the prompt — spec amendment 8.)

(f) In the click handler, give `awaitReconnect` the signal — replace `awaitReconnect: () => new Promise<Transport>((resolve) => {` with:

```ts
      awaitReconnect: (signal) => new Promise<Transport>((resolve, reject) => {
        if (signal?.aborted) { reject(new DOMException('Aborted', 'AbortError')); return; }
```

and directly after the line `const off = onConnectionChange(() => {` block's closing `});` (still inside that Promise executor) add:

```ts
        signal?.addEventListener('abort', () => { off(); reject(new DOMException('Aborted', 'AbortError')); }, { once: true });
```

(g) Replace the tail of the click handler — from `if (!readerLock.acquire('archive')) …` to the end of its `finally` block — with:

```ts
    if (!readerLock.acquire('archive')) { setStatus(t.readerBusyElsewhere, 'error'); return; }
    runAbort = new AbortController();
    enterStage(src, compress, pass.length > 0);
    let outcome: ArchiveOutcome = 'failed';
    try {
      outcome = await new ArchiveOrchestrator(io).run(transport, {
        data: src.data, fileName: src.fileName, compress,
        password: pass || undefined, payloadSize: selectedPayloadSize(),
      }, runAbort.signal);
    } catch (e) {
      hideProgress();
      setStatus(humanError(e), 'error');
    } finally {
      runAbort = null;
      readerLock.release('archive');
      leaveStage(outcome);
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0`.

- [ ] **Step 6: Visual check**

```bash
cd /home/mezinster/nfcarchiver/webapp
.visual/serve.sh
.visual/shot.sh t7-writing "state=writing"
.visual/shot.sh t7-writing-many "state=writing-many"
.visual/shot.sh t7-overwrite "state=overwrite"
.visual/shot.sh t7-done "state=done"
.visual/shot.sh t7-writing-ru "state=writing&lang=ru" 360
.visual/stop.sh
```

Compare with drafts **B+C · 2** and **B+C · 3**. Expected: three slots (✓ written in primary, NFC current in primary-container, dashed waiting), headline, "Card 2 of 3 · 33%" bar, summary card, outlined Stop with a filled square; form and Archive button hidden. `writing-many` shows "Card 7 of 24" instead of slots. `overwrite`: the middle slot in error colours and the M3 dialog over a full scrim — no text peeking around it. `done`: three written slots and a filled "Archive another".

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/archive-panel.ts webapp/test/markup-ids.test.ts
git commit -m "feat(webapp): card-slot write stage with a working Stop

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Restore — scan stage and archive rows

**Files:**
- Modify: `webapp/app/index.html` (`#panel-restore`), `webapp/app/ui/restore-view.ts`, `webapp/app/ui/restore-panel.ts`
- Test: `webapp/test/restore-view.test.ts`

**Interfaces:**
- Consumes: `t.archiveRowStatus`, `t.scanStageTitle`, `t.saveAsLabel` (Task 1).
- Produces: archive row = `[icon tile, text column [name '#<shortId>', sub [dots, status]], control [Restore button]]`, row attributes `data-encrypted`/`data-complete` = `'true'|'false'`; `export const MAX_DOTS = 10` in `restore-view.ts`; ids `#restore-stage #archives-section`; `#panel-restore[data-scanning]`.

- [ ] **Step 1: Write the failing tests**

Append to `webapp/test/restore-view.test.ts`:

```ts
test('restore view renders the id, slot dots, status and flags', () => {
  setLocale('en');
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  renderArchiveList(container, [archive({ totalChunks: 5, received: 2, complete: false, isEncrypted: true })], () => {});
  const row = (container as unknown as StubEl).children[0]!;
  const text = row.children[1]!;
  assert.equal(text.children[0]!.textContent, '#16312c0b');
  const dots = text.children[1]!.children[0]!.innerHTML;
  assert.equal(dots.match(/class="dot/g)?.length, 5);
  assert.equal(dots.match(/class="dot on"/g)?.length, 2);
  assert.equal(text.children[1]!.children[1]!.textContent, en.archiveRowStatus(2, 5, false));
  assert.equal(row.getAttribute('data-encrypted'), 'true');
  assert.equal(row.getAttribute('data-complete'), 'false');
});

test('restore view omits dots for archives too long to draw', () => {
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  renderArchiveList(container, [archive({ totalChunks: 40, received: 3, complete: false })], () => {});
  const row = (container as unknown as StubEl).children[0]!;
  assert.equal(row.children[1]!.children[1]!.children[0]!.innerHTML, '');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL — the text column has one child, so `text.children[1]` is undefined (`TypeError: Cannot read properties of undefined`).

- [ ] **Step 3: Implement `restore-view.ts`**

Replace the `label` function with:

```ts
/** Above this many cards the dot row would not fit; the "k/N" text remains. */
export const MAX_DOTS = 10;

function dots(received: number, total: number): string {
  if (total > MAX_DOTS) return '';
  let html = '';
  for (let i = 0; i < total; i++) html += i < received ? '<i class="dot on"></i>' : '<i class="dot"></i>';
  return html;
}
```

In the row-creation block, replace the creation of `text`/`name` (from `const text = doc.createElement('div');` through `text.append(name);`) with:

```ts
      const text = doc.createElement('div');
      text.className = 'row-text';
      const name = doc.createElement('div');
      name.className = 'row-name mono';
      const sub = doc.createElement('div');
      sub.className = 'row-sub';
      const dotsEl = doc.createElement('span');
      dotsEl.className = 'dots';
      const status = doc.createElement('span');
      status.className = 'row-status';
      sub.append(dotsEl, status);
      text.append(name, sub);
```

Change `newBtn.className = 'btn-tonal';` to `newBtn.className = 'btn btn-tonal';`.

Replace the update block after row creation (from `const span = …` to `btn.disabled = !a.complete;`) with:

```ts
    const text = row.children[1] as HTMLElement;
    const sub = text.children[1] as HTMLElement;
    const btn = (row.children[2] as HTMLElement).children[0] as HTMLButtonElement;
    // Labels are rewritten on every render, not only at creation: rows outlive
    // a language switch, so text would otherwise stay in the boot language.
    (text.children[0] as HTMLElement).textContent = `#${a.shortId}`;
    (sub.children[0] as HTMLElement).innerHTML = dots(a.received, a.totalChunks);
    (sub.children[1] as HTMLElement).textContent = t.archiveRowStatus(a.received, a.totalChunks, a.complete);
    row.setAttribute('data-encrypted', String(a.isEncrypted));
    row.setAttribute('data-complete', String(a.complete));
    btn.textContent = t.restore;
    btn.disabled = !a.complete;
```

- [ ] **Step 4: Replace the restore panel markup**

Replace everything inside `<section id="panel-restore" role="tabpanel" hidden>…</section>` with:

```html
        <div class="restore-idle">
          <button id="scan" class="btn btn-primary" type="button" disabled><svg class="ico" aria-hidden="true"><use href="#i-nfc"/></svg><span data-i18n="scanCards">Scan cards</span></button>
        </div>
        <div id="restore-stage" class="stage">
          <div class="pulse" aria-hidden="true"><span class="pulse-core"><svg class="ico"><use href="#i-nfc"/></svg></span></div>
          <h2 class="stage-headline" data-i18n="scanStageTitle">Tap cards in any order</h2>
          <button id="stop-scan" class="btn btn-outlined" type="button" disabled><svg class="ico" aria-hidden="true"><use href="#i-stop"/></svg><span data-i18n="stop">Stop</span></button>
        </div>
        <p class="status" id="restore-status" role="status" data-i18n="restoreIdle">Connect a Chameleon, then scan a pile of cards.</p>

        <div id="archives-section">
          <span class="section-label" data-i18n="sectionArchives">Detected archives</span>
          <div class="card"><div id="archives"></div></div>
        </div>

        <span class="section-label" data-i18n="sectionSettings">Settings</span>
        <div class="card">
          <div class="row row-stack">
            <label class="field">
              <span class="field-label" data-i18n="saveAsLabel">Save as</span>
              <input type="text" id="fname" value="restored.bin" />
              <span class="field-help" data-i18n="subSaveAs">Only used if the archive carries no filename</span>
            </label>
          </div>
        </div>
```

(`#archives` must contain no whitespace: `#archives-section:has(#archives:empty)` hides the section until a card is scanned.)

- [ ] **Step 5: Drive the scan stage in `restore-panel.ts`**

In `syncButtons`, add after the `const owner = readerLock.current();` line:

```ts
    // The pulsing stage replaces the Scan button only while THIS loop scans.
    $('panel-restore').toggleAttribute('data-scanning', owner === 'scan');
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0` (the existing reuse/relabel tests still index `children[2].children[0]`).

- [ ] **Step 7: Visual check**

```bash
cd /home/mezinster/nfcarchiver/webapp
.visual/serve.sh
.visual/shot.sh t8-scanning "state=scanning"
.visual/shot.sh t8-scanning-ru "state=scanning&lang=ru" 360
.visual/stop.sh
```

Compare with draft **B+C · 4**. Expected: pulsing reader circle, "Tap cards in any order", outlined Stop; "Detected archives" with `#3f2a91c0` + lock, three filled dots, "3/3 cards · complete" in green, enabled Restore; `#a71c0e55` with 2 of 5 dots and a disabled Restore; the Save as field.

- [ ] **Step 8: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/restore-view.ts webapp/app/ui/restore-panel.ts webapp/test/restore-view.test.ts
git commit -m "feat(webapp): restore scan stage and archive rows with slot dots

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Files — rows with icon buttons and an empty state

**Files:**
- Modify: `webapp/app/index.html` (`#panel-files`), `webapp/app/ui/files-view.ts`
- Test: `webapp/test/files-view.test.ts`

**Interfaces:**
- Consumes: `t.fileRowMeta` (Task 1); `.btn-icon .tonal .icon-download .icon-trash .empty-state .files-footer` (Task 3).
- Produces: file row = `[icon tile, text column [name, meta], control [Download, Delete]]`, row attribute `data-encrypted`.

- [ ] **Step 1: Write the failing test**

Append to `webapp/test/files-view.test.ts` (add `setLocale` to the existing `../app/i18n/index.js` import if it is not already imported there):

```ts
test('renderFileList shows the name, meta line and encrypted flag', () => {
  setLocale('en');
  const doc = makeDoc();
  const container = doc.createElement('div') as unknown as HTMLElement;
  renderFileList(container, [item({ name: 'keys.txt', size: 2048, totalChunks: 3, isEncrypted: true })],
    { onDownload: () => {}, onDelete: () => {} });
  const row = (container as unknown as StubEl).children[0]!;
  assert.equal(row.children[1]!.children[0]!.textContent, 'keys.txt');
  assert.ok(row.children[1]!.children[1]!.textContent.startsWith('2.0 KB · 3 cards · '));
  assert.equal(row.getAttribute('data-encrypted'), 'true');
  assert.equal(row.children[2]!.children[0]!.getAttribute('title'), en.download);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: FAIL — `text.children[1]` is undefined (`TypeError`).

- [ ] **Step 3: Implement `files-view.ts`**

Delete the `label` function. In the row-creation block:
- change `tile.innerHTML = '<svg class="ico"><use href="#i-folder"/></svg>';` to `tile.innerHTML = '<svg class="ico"><use href="#i-file"/></svg>';`
- after `name.className = 'row-name';` add:

```ts
      const meta = doc.createElement('div');
      meta.className = 'row-sub';
```

  and change `text.append(name);` to `text.append(name, meta);`
- change `dl.className = 'btn-tonal';` to `dl.className = 'btn-icon tonal icon-download';` and `del.className = 'btn-text';` to `del.className = 'btn-icon icon-trash';`.

Replace the update block after row creation (from `const controls = row.children[2] as HTMLElement;` to the end of the loop body) with:

```ts
    // Every label is rewritten on each render, not just at row creation: rows
    // outlive a language switch. Button textContent stays the plain label — it
    // is the accessible name, the glyph is a CSS mask (see .btn-icon).
    const text = row.children[1] as HTMLElement;
    const controls = row.children[2] as HTMLElement;
    (text.children[0] as HTMLElement).textContent = f.name;
    (text.children[1] as HTMLElement).textContent =
      t.fileRowMeta(humanSize(f.size), f.totalChunks, new Date(f.createdAt).toLocaleString());
    row.setAttribute('data-encrypted', String(f.isEncrypted));
    const dlBtn = controls.children[0] as HTMLElement;
    const delBtn = controls.children[1] as HTMLElement;
    dlBtn.textContent = t.download;
    dlBtn.setAttribute('title', t.download);
    delBtn.textContent = t.deleteBtn;
    delBtn.setAttribute('title', t.deleteBtn);
```

- [ ] **Step 4: Replace the files panel markup**

Replace everything inside `<section id="panel-files" role="tabpanel" hidden>…</section>` with:

```html
        <span class="section-label" data-i18n="sectionRestoredFiles">Restored files</span>
        <div class="card"><div id="files"></div></div>
        <div id="files-empty" class="card empty-state">
          <svg class="ico" aria-hidden="true"><use href="#i-folder"/></svg>
          <p data-i18n="filesEmpty">No restored files yet. Restore an archive and it'll appear here.</p>
        </div>
        <div class="files-footer">
          <span id="files-info"></span>
          <button id="files-clear" class="btn btn-text btn-danger" type="button" data-i18n="clearAll">Clear all</button>
        </div>
        <p id="files-status" class="status"></p>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0` (the existing Download/Delete `textContent` assertions still hold).

- [ ] **Step 6: Visual check**

```bash
cd /home/mezinster/nfcarchiver/webapp
.visual/serve.sh
.visual/shot.sh t9-files "state=files"
.visual/shot.sh t9-files-empty "state=files-empty"
.visual/shot.sh t9-files-ru "state=files&lang=ru" 360
.visual/stop.sh
```

Compare with draft **B+C · 5**. Expected: the long name `backup-keys-2026-10-05-final.txt` ellipsizes but is not crowded out — the two 48px icon buttons (tonal download, plain trash) take a fixed width; a lock follows the encrypted name; footer "2 files · 2.7 KB stored" with a red "Clear all"; the empty state is a card with a folder glyph and no empty list card above it.

- [ ] **Step 7: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/files-view.ts webapp/test/files-view.test.ts
git commit -m "feat(webapp): files list with icon buttons, meta line and empty state

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Log, About, Inspect

**Files:**
- Modify: `webapp/app/index.html` (`#panel-log`, `#inspect-dialog`), `webapp/app/ui/about-panel.ts`
- Test: `webapp/test/markup-ids.test.ts` (existing dialog invariants must stay green; no new test — the About header is DOM-only and is verified visually)

**Interfaces:**
- Consumes: `.log-actions select.compact .about-head .about-logo .about-card .inspect-* .btn-icon .icon-close` (Task 3); sprite `i-brand` (Task 3).

- [ ] **Step 1: Replace the log panel markup**

Replace everything inside `<section id="panel-log" role="tabpanel" hidden>…</section>` with:

```html
        <span class="section-label" data-i18n="sectionLogOptions">Log options</span>
        <div class="card">
          <div class="row">
            <div class="row-text"><div class="row-name" data-i18n="logLevel">level</div></div>
            <select id="log-level" class="compact">
              <option value="debug">debug</option>
              <option value="info" selected>info</option>
              <option value="warn">warn</option>
              <option value="error">error</option>
            </select>
          </div>
          <div class="row">
            <div class="row-text"><div class="row-name" data-i18n="autoScroll">auto-scroll</div></div>
            <label class="switch"><input type="checkbox" id="log-autoscroll" checked /><span class="switch-track"></span></label>
          </div>
          <div class="row">
            <div class="row-text"><div class="row-name" data-i18n="mirrorToConsole">mirror to console</div></div>
            <label class="switch"><input type="checkbox" id="log-console" /><span class="switch-track"></span></label>
          </div>
          <div class="row log-actions">
            <button id="log-clear" class="btn btn-text" type="button" data-i18n="clear">Clear</button>
            <button id="log-copy" class="btn btn-text" type="button" data-i18n="copy">Copy</button>
            <button id="log-download" class="btn btn-text" type="button" data-i18n="download">Download</button>
          </div>
        </div>
        <div id="log"></div>
```

- [ ] **Step 2: Replace the inspect dialog markup**

Replace the whole `<dialog id="inspect-dialog" class="inspect">…</dialog>` with:

```html
    <dialog id="inspect-dialog" class="inspect">
      <div class="inspect-body">
        <div class="inspect-head">
          <button id="inspect-close" class="btn-icon icon-close" type="button" data-i18n="close">Close</button>
          <strong data-i18n="inspectCard">Inspect card</strong>
          <button id="inspect-copy" class="btn btn-text" type="button" data-i18n="copy">Copy</button>
          <button id="inspect-download" class="btn btn-text" type="button" data-i18n="download">Download</button>
        </div>
        <p class="inspect-meta"><span id="inspect-progress"></span> <span id="inspect-status"></span></p>
        <span class="section-label" data-i18n="inspectIdentity">Identity</span>
        <div class="card inspect-card"><pre id="inspect-identity"></pre></div>
        <span class="section-label" data-i18n="inspectNfar">NFAR chunk</span>
        <div class="card inspect-card"><pre id="inspect-nfar"></pre></div>
        <span class="section-label" data-i18n="inspectRaw">Raw</span>
        <div class="card inspect-card"><pre id="inspect-raw"></pre></div>
      </div>
    </dialog>
```

- [ ] **Step 3: About header in `about-panel.ts`**

Remove the first entry (`{ h: 'NFC Archiver', body: [...] }`) from the array returned by `sections()`, and replace the start of `render()` (from `const container = …` through `container.innerHTML = '';`) with:

```ts
  const container = document.getElementById('about-content')!;
  container.innerHTML = '';
  // Header block (draft 7): logo tile, name, version, one-line description.
  const head = document.createElement('div');
  head.className = 'about-head';
  head.innerHTML = '<span class="icon-tile about-logo"><svg class="brand-ico" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-brand"/></svg></span>';
  const name = document.createElement('h2');
  name.textContent = 'NFC Archiver';
  const version = document.createElement('p');
  version.textContent = t.aboutWebVersion(APP_VERSION, BUILD_SHA);
  const description = document.createElement('p');
  description.textContent = t.aboutDescription;
  head.append(name, version, description);
  container.appendChild(head);
```

(the existing `for (const s of sections())` loop that follows stays unchanged).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0` (`no author rule sets display on a dialog…` and `a dialog is never its own scroll container` included).

- [ ] **Step 5: Visual check**

```bash
cd /home/mezinster/nfcarchiver/webapp
.visual/serve.sh
.visual/shot.sh t10-log "state=log"
.visual/shot.sh t10-about "state=about"
.visual/shot.sh t10-inspect "state=inspect"
.visual/shot.sh t10-inspect-wide "state=inspect" 1280 900
.visual/stop.sh
```

Compare with drafts **B+C · 6, 7, 9**. Expected: log options card with a compact level select and M3 switches, monospace log below; About header with the brand tile, name, "Web version … (dev)", description, then Supported tags / Privacy / Open-source licenses cards; Inspect full-screen at 390 (no rounded corners, ✕ at top-left, Copy/Download right) with three cards, and a centred rounded modal at 1280 whose corners stay rounded while the hex dump scrolls.

- [ ] **Step 6: Commit**

```bash
git add webapp/app/index.html webapp/app/ui/about-panel.ts
git commit -m "feat(webapp): restyle log, about header and the inspect dialog

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Retire obsolete i18n keys

**Files:**
- Modify: `webapp/app/i18n/{en,ru,uk,be,pl,tr,ka}.ts`, `webapp/test/i18n.test.ts`

**Interfaces:**
- Removes: `cardEstimate`, `archiveRow`, `fileRow`, `readerChameleon`, `readerPhoneNfc`, `orSeparator`, `targetTag`, `password`, `saveAs`, `optionalPlaceholder`, `subTargetTag`.

- [ ] **Step 1: Prove nothing still uses them**

```bash
cd /home/mezinster/nfcarchiver/webapp
grep -rnE "\bt\.(cardEstimate|archiveRow|fileRow|readerChameleon|readerPhoneNfc|orSeparator|targetTag|password|saveAs|optionalPlaceholder|subTargetTag)\b|data-i18n(-placeholder|-title)?=\"(cardEstimate|archiveRow|fileRow|readerChameleon|readerPhoneNfc|orSeparator|targetTag|password|saveAs|optionalPlaceholder|subTargetTag)\"" app
```

Expected: no output. If anything prints, the task that should have replaced it is incomplete — fix that first.

- [ ] **Step 2: Update the tests that mention a retired key**

In `webapp/test/i18n.test.ts`:
- in `'English catalogue function entries render'`, delete the two `en.cardEstimate(…)` assertions;
- in `'Slavic plurals select the right form at the boundaries'`, delete the `['cardEstimate', (cat, n) => cat.cardEstimate(n, false)],` entry (`cardsNeeded`, added in Task 1, keeps the CARD table covered).

- [ ] **Step 3: Remove the keys from all seven catalogues**

Run this from `webapp/` (it removes each `key: …` property, including multi-line arrow functions, up to the next property, comment, or the closing `};`):

```bash
python3 - <<'EOF'
import re, pathlib
keys = ['cardEstimate', 'archiveRow', 'fileRow', 'readerChameleon', 'readerPhoneNfc', 'orSeparator',
        'targetTag', 'password', 'saveAs', 'optionalPlaceholder', 'subTargetTag']
for loc in ['en', 'ru', 'uk', 'be', 'pl', 'tr', 'ka']:
    p = pathlib.Path(f'app/i18n/{loc}.ts')
    src = p.read_text()
    for k in keys:
        pat = re.compile(r'^  ' + k + r':.*?(?=^  [A-Za-z_]+:|^  //|^};)', re.M | re.S)
        src, n = pat.subn('', src)
        assert n == 1, f'{loc}.{k}: expected exactly one match, got {n}'
    p.write_text(src)
print('removed', len(keys), 'keys from 7 catalogues')
EOF
git diff --stat
```

Expected: `removed 11 keys from 7 catalogues`, and the diff touches only the eight files above.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && rm -rf dist && npm test`
Expected: PASS, `# fail 0` (`tsc` proves no caller remains; the key-set test proves all seven catalogues match).

- [ ] **Step 5: Commit**

```bash
git add webapp/app/i18n webapp/test/i18n.test.ts
git commit -m "refactor(webapp): retire i18n keys the redesign no longer uses

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Final verification

**Files:** none modified unless a check fails (then fix in the task that owns the code and re-run this task).

- [ ] **Step 1: Full suite and the deploy build**

```bash
cd /home/mezinster/nfcarchiver/webapp && source ~/.nvm/nvm.sh && nvm use 22 >/dev/null
rm -rf dist && npm test 2>&1 | tail -5
npm run build:site 2>&1 | tail -3
```

Expected: `# fail 0`; `build:site` exits 0 and prints `site/ built and verified — /* nfar-build:… */` (the script itself checks the bundle carries the marker).

- [ ] **Step 2: Dependency fence and dead references**

```bash
cd /home/mezinster/nfcarchiver/webapp
grep -rlnE "from ['\"]chameleon-ultra\.js" app src | sort
grep -rn "archive-progress-row\|seg-btn\|or-divider\|status-pill" app
```

Expected: the first command prints exactly `app/ui/device.ts` and `src/transport/sdk-chameleon-device.ts` (it matches import statements only — the About page's license string also contains the package name); the second prints nothing.

- [ ] **Step 3: Visual matrix**

```bash
cd /home/mezinster/nfcarchiver/webapp
.visual/serve.sh
for s in idle no-reader writing writing-many overwrite done scanning files files-empty log about inspect; do
  .visual/shot.sh "f-$s" "state=$s"
  .visual/shot.sh "f-$s-dark" "state=$s&theme=dark"
  .visual/shot.sh "f-$s-ru360" "state=$s&lang=ru" 360
  .visual/shot.sh "f-$s-ka360" "state=$s&lang=ka" 360
done
for s in idle writing scanning files inspect; do .visual/shot.sh "f-$s-wide" "state=$s" 1280 900; done
```

Then render the reference drafts with the same harness (Tailwind loads from its CDN, so this needs network):

```bash
for pair in "1:09bb8167-470d-4aee-8ef6-d502e1f4c791" "2:9ddf7f45-f523-429d-83e9-4b79dda61f3e" "3:f7d828f8-9597-48e9-bbab-826fe9e9f932" "4:c5761880-332c-4ac6-9efc-499cb78e6808" "5:03e3f0cd-dcd6-41aa-b313-36cffe1509e5" "6:f129e8e0-d946-4e96-910f-c9ef5feb4a1c" "7:73456e05-beae-4ec5-9783-f77794913bf5" "8:c9095f99-b545-4e2c-bd35-130d95e8a2ff" "9:4ad60c49-4bb2-4dcc-9178-6a2df8c05138" "10:7c3fac0f-072e-4c03-8adc-85c39ad49c2b"; do
  n=${pair%%:*}; id=${pair#*:}
  npx --yes @superdesign/cli@latest get-design --draft-id "$id" --output "app/_draft-$n.html" >/dev/null 2>&1
  .visual/shot.sh "draft-$n" "src=_draft-$n.html"
done
.visual/stop.sh
```

Read each `f-*.png` next to its draft (`idle`↔1, `writing`↔2, `overwrite`↔3, `scanning`↔4, `files`↔5, `log`↔6, `about`↔7, `no-reader`↔8, `inspect`↔9, `idle-dark`↔10). Check, and fix any failure in the owning task:
- nothing overflows horizontally at 360px in RU or KA; no button label breaks mid-word; nav labels stay on one line;
- dark screenshots use the dark roles (no white cards, the filled button is light blue with dark text);
- the sticky Archive bar never shows content through itself, and never hides under the bottom bar;
- in `overwrite`, nothing outside the dialog is legible through the scrim;
- the inspect dialog keeps rounded corners at 1280 and is edge-to-edge at 390;
- any intentional difference from a draft is one of the spec's documented deviations (amendments 1–11, or the "draft defects" named in the spec).

- [ ] **Step 4: Report**

Summarise for the owner: test count, build result, the screenshots reviewed with any deviations found and fixed, and the one remaining manual step — **a hardware smoke on a Chameleon before merge**: write a 3-card archive including one overwrite prompt, press Stop mid-write on a second run (status must read "Stopped — n of N cards written…"), then scan the cards back and restore. Do not merge or push.
