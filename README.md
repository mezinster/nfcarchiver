# NFC Archiver

[🇷🇺 Русский](#русский) | [🇬🇧 English](#english)

---

## English

Distributed data archive on NFC tags. A mobile application for Android and iOS that allows storing files across multiple NFC tags and restoring them when all parts are available.

### Features

- **File archiving** — splitting any file into parts for writing to NFC tags
- **Restoration** — scanning tags in any order and assembling the original file
- **Compression** — optional GZIP compression to reduce the number of tags needed
- **Encryption** — AES-256-GCM encryption with password (PBKDF2 for key derivation)
- **Offline operation** — no network connection required
- **Chameleon Ultra reader** — drive a [Chameleon Ultra](https://github.com/RfidResearchGroup/ChameleonUltra) over Bluetooth instead of the phone's NFC radio ([guide](docs/CHAMELEON.md))
- **MIFARE Classic 1K** — 752 usable bytes per card, on any phone when using a Chameleon
- **Card inspector** — read-only block-by-block dump with a decoded NFAR header and CRC check (requires a Chameleon)

### Readers

The app can drive two different readers, chosen from the reader icon in the top bar:

| | Phone NFC | Chameleon Ultra |
|---|---|---|
| NTAG213/215/216 | ✅ | ✅ |
| MIFARE Classic 1K | Only on phones whose NFC chipset supports CRYPTO1 | ✅ always |
| Card inspector | ❌ not possible on Android's NFC API | ✅ |
| Extra hardware | None | A Chameleon Ultra |

Only one reader is active at a time; switching disconnects the previous one. Cards written by either reader — or by the [web app](webapp/) — are byte-identical and interchangeable. See **[docs/CHAMELEON.md](docs/CHAMELEON.md)** for setup, the card inspector, and limits.

### Supported NFC Tags

| Tag Type | Capacity | Useful Payload* |
|----------|----------|-----------------|
| NTAG213 | 144 bytes | ~106 bytes |
| NTAG215 | 504 bytes | ~466 bytes |
| NTAG216 | 888 bytes | ~850 bytes |
| MIFARE Ultralight | 48 bytes | ~10 bytes |
| MIFARE Ultralight C | 144 bytes | ~106 bytes |
| MIFARE Classic 1K | 1 KB (752 usable) | ~720 bytes† |

*After subtracting NFAR header (28 bytes) and NDEF overhead (~10 bytes)  
†MIFARE Classic 1K holds raw 16-byte blocks (47 usable = 752 bytes) with no NDEF layer, so only the 28-byte NFAR header and 4-byte CRC are deducted. Available in the Android app on phones whose NFC chipset supports CRYPTO1, and on **any** phone when using a Chameleon Ultra. Block 0 and every sector trailer are never written, so keys and access bits are left untouched.

> **Note:** This list is not exhaustive — more tag types are supported than shown here, and coverage continues to grow.

### NFAR v1 Data Format

```
┌─────────────────────────────────────────────────────┐
│ Magic (4 bytes): "NFAR" = 0x4E464152               │
├─────────────────────────────────────────────────────┤
│ Version (1 byte): 0x01                              │
├─────────────────────────────────────────────────────┤
│ Flags (1 byte): compression | encryption            │
├─────────────────────────────────────────────────────┤
│ Archive ID (16 bytes): UUID v4                      │
├─────────────────────────────────────────────────────┤
│ Total Chunks (2 bytes): uint16 big-endian           │
├─────────────────────────────────────────────────────┤
│ Chunk Index (2 bytes): uint16 big-endian            │
├─────────────────────────────────────────────────────┤
│ Payload Size (2 bytes): uint16 big-endian           │
├─────────────────────────────────────────────────────┤
│ Payload (N bytes): data                             │
├─────────────────────────────────────────────────────┤
│ CRC32 (4 bytes): checksum                           │
└─────────────────────────────────────────────────────┘
```

### Installation

#### Requirements

- Flutter SDK 3.5+
- Android SDK (API 26+) for Android
- Xcode 16+ and iOS 13+ for iOS
- Device with NFC support, or a Chameleon Ultra reader over Bluetooth

#### Building

```bash
# Clone
git clone https://github.com/mezinster/nfcarchiver.git
cd nfcarchiver

# Install dependencies
flutter pub get

# Run on device
flutter run
```

#### iOS

Which setup you need depends on which radio you want.

**Using the phone's own NFC** — requires paid Apple Developer Program membership:

1. Open `ios/Runner.xcworkspace` in Xcode
2. Select Runner → Signing & Capabilities
3. Add "Near Field Communication Tag Reading"

Note this route cannot read Mifare Classic on iOS at all: Core NFC does not implement CRYPTO1.

**Using a Chameleon Ultra over Bluetooth** — works on a **free** Apple ID, and is the only way to reach Mifare Classic on iOS. Core Bluetooth needs no entitlement, but a Personal Team cannot sign the NFC entitlement the project declares, so blank it locally:

```bash
echo 'NFAR_CODE_SIGN_ENTITLEMENTS =' > ios/Flutter/LocalOverrides.xcconfig
```

That file is gitignored and only applies to debug builds. See `CLAUDE.md` → "Signing on a free Apple ID".

### Architecture

```
lib/
├── core/                    # Core system
│   ├── constants/           # NFAR format
│   ├── models/              # Chunk, ArchiveMetadata, NfcTagInfo
│   ├── services/            # Chunker, Compression, Encryption, CRC32
│   └── utils/               # Binary Reader/Writer
│
├── features/
│   ├── archive/             # Archive creation
│   ├── restore/             # Restoration
│   └── nfc/                 # NFC abstraction
│
└── shared/                  # Theme, shared widgets
```

### Technology Stack

- **Flutter** — cross-platform UI
- **Riverpod** — state management
- **nfc_manager** — phone NFC operations
- **flutter_reactive_ble** — Bluetooth LE, for the Chameleon Ultra reader (BSD-3-Clause)
- **pointycastle** — cryptography (AES-256-GCM, PBKDF2)
- **go_router** — navigation

### Web version (`webapp/`)

A browser port of NFC Archiver lives in [`webapp/`](webapp/). It runs entirely
client-side (no server) and drives a **Chameleon Ultra** reader/writer over **Web
Bluetooth** to read and write physical cards from Chromium browsers on desktop and
Android.

- **Media:** Mifare Classic 1K (720 B payload/card) and NTAG213/215/216 (Type-2 /
  NDEF). Tag type is auto-detected on tap.
- **Cross-compatible with this app:** the on-tag bytes match exactly — the same
  NFAR chunk format, the same filename wrapper, and, for NTAG, the same NDEF MIME
  record (`application/vnd.nfcarchiver.chunk`). A tag written on the phone restores
  in the browser and vice versa; an NTAG written in the browser is a standard NDEF
  tag readable by any NFC phone.
- **Features:** file **and** text archiving, GZIP compression, AES-256-GCM
  encryption, filename preservation, a live "≈ N cards" estimate, multi-archive
  scan-then-pick restore, and a Chameleon "Diagnose card" tool. The UI is a
  branded, themed, tabbed shell.

```bash
cd webapp
source ~/.nvm/nvm.sh && nvm use --lts   # Node ≥ 22 (crypto.subtle, CompressionStream)
npm install
npm test        # dependency-free NFAR core + transports, tested against a fake device
npm run app     # serves http://localhost:8000 — open in Chrome/Edge on the Bluetooth host
```

Web Bluetooth is Chromium-only (not Firefox or iOS Safari), and — inside WSL — the
browser must run on the Windows host. Status: a working prototype; the archive →
cards → restore round trip is validated on real hardware. See
[`webapp/README.md`](webapp/README.md) for architecture, the SDK/hardware notes,
and the parity roadmap (localization, an offline file manager, and phone-native
Web NFC writing are still to come).

### F-Droid Publishing

This app went through 13 iterations of its [F-Droid metadata MR](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/32729) before acceptance. Here are the key challenges encountered:

1. **Invalid metadata categories** — `Utility` is not a valid F-Droid category. Had to use `Connectivity` instead, which is the closest match for an NFC-based app.

2. **Missing required fields** — F-Droid's linting requires `AutoName` (human-readable app name) and `UpdateCheckData` (regex to extract version from the repo). Without these, the `checkupdates` pipeline fails.

3. **Flutter version pinning** — F-Droid's `flutter@stable` srclib doesn't guarantee a specific Flutter version. The solution was to extract `FLUTTER_VERSION` from the GitHub release workflow using `sed` and explicitly `git checkout` that version in `prebuild`:
   ```yaml
   prebuild:
     - flutterVersion=$(sed -n -E "s/.*FLUTTER_VERSION:\ '(.*)'/\1/p" .github/workflows/release.yml)
     - git -C $$flutter$$ checkout -f $flutterVersion
   ```

4. **Package scanning (`scandelete`)** — F-Droid scans all dependencies for proprietary code between `prebuild` and `build`. This means `flutter pub get` must run in `prebuild` (not `build`), and `.pub-cache` must be listed in `scandelete` since it contains pre-compiled binaries.

5. **compileSdk 35 vs JDK 21 incompatibility** — F-Droid's build server uses JDK 21, which has a `jlink`/`JdkImageTransform` bug with Android SDK 35. Multiple approaches failed:
   - `sed`-patching `.pub-cache` plugin files — failed because `scandelete` removes `.pub-cache` before build
   - Gradle `afterEvaluate` override — failed with "project already evaluated" due to Flutter's `evaluationDependsOn`
   - Gradle init script — worked but was overly complex
   - **Final solution**: lower `compileSdk` to 34 in the source repo itself, plus an `afterEvaluate` block for plugin subprojects

6. **JDK 17 installation** — Even with `compileSdk` 34, JDK 21 still caused issues. The fix required installing JDK 17 via `sudo`, but F-Droid's build server runs Debian Trixie which doesn't have JDK 17 in its repos. Solution: add the Debian Bookworm repo first:
   ```yaml
   sudo:
     - echo 'deb http://deb.debian.org/debian bookworm main' > /etc/apt/sources.list.d/bookworm.list
     - apt-get update
     - apt-get install -y openjdk-17-jdk-headless
   ```

7. **`rewritemeta` formatting** — F-Droid's linter (`rewritemeta`) enforces strict field ordering (e.g., `sudo:` must come after `commit:`) and formatting rules (multi-part shell commands like `echo` must stay on a single line).

8. **Commit hash requirement** — The reviewer required a full commit SHA (`97f2567c...`) instead of a tag reference (`v1.0.6`) for build reproducibility.

### License

MIT

### Author

Built by [Evgeny Mezin](https://github.com/mezinster), directing Claude Code as a
coding assistant throughout.

---

## Русский

Распределённый архив данных на NFC-метках. Мобильное приложение для Android и iOS, позволяющее хранить файлы на множестве NFC-меток и восстанавливать их при наличии всех частей.

### Возможности

- **Архивация файлов** — разбиение любого файла на части для записи на NFC-метки
- **Восстановление** — сканирование меток в произвольном порядке и сборка исходного файла
- **Сжатие** — опциональное GZIP сжатие для уменьшения количества меток
- **Шифрование** — AES-256-GCM шифрование с паролем (PBKDF2 для ключа)
- **Офлайн работа** — не требует подключения к сети
- **Считыватель Chameleon Ultra** — работа через [Chameleon Ultra](https://github.com/RfidResearchGroup/ChameleonUltra) по Bluetooth вместо NFC телефона ([руководство](docs/CHAMELEON.md))
- **MIFARE Classic 1K** — 752 полезных байта на карту, на любом телефоне при использовании Chameleon
- **Осмотр карты** — побайтовый дамп только для чтения с разбором заголовка NFAR и проверкой CRC (нужен Chameleon)

### Считыватели

Приложение работает с двумя считывателями, выбор — по значку в верхней панели:

| | NFC телефона | Chameleon Ultra |
|---|---|---|
| NTAG213/215/216 | ✅ | ✅ |
| MIFARE Classic 1K | Только на телефонах с поддержкой CRYPTO1 | ✅ всегда |
| Осмотр карты | ❌ невозможен через NFC API Android | ✅ |
| Доп. оборудование | Не нужно | Chameleon Ultra |

Одновременно активен только один считыватель; переключение отключает предыдущий. Карты, записанные любым считывателем — или [веб-приложением](webapp/) — побайтово совместимы. Подробности: **[docs/CHAMELEON.md](docs/CHAMELEON.md)**.

### Поддерживаемые NFC-метки

| Тип метки | Ёмкость | Полезная нагрузка* |
|-----------|---------|-------------------|
| NTAG213 | 144 байт | ~106 байт |
| NTAG215 | 504 байт | ~466 байт |
| NTAG216 | 888 байт | ~850 байт |
| MIFARE Ultralight | 48 байт | ~10 байт |
| MIFARE Ultralight C | 144 байт | ~106 байт |
| MIFARE Classic 1K | 1 КБ (752 доступно) | ~720 байт† |

*После вычета заголовка NFAR (28 байт) и NDEF overhead (~10 байт)  
†Карты MIFARE Classic 1K хранят необработанные 16-байтные блоки (47 доступных = 752 байта) без слоя NDEF, поэтому вычитаются только 28-байтный заголовок NFAR и 4-байтный CRC. Доступны в Android-приложении на телефонах с поддержкой CRYPTO1 в NFC-чипе и на **любом** телефоне при использовании Chameleon Ultra. Блок 0 и трейлеры секторов никогда не записываются, поэтому ключи и биты доступа остаются нетронутыми.

> **Примечание:** список неполный — поддерживается больше типов меток, чем показано здесь, и охват продолжает расширяться.

### Формат данных NFAR v1

```
┌─────────────────────────────────────────────────────┐
│ Magic (4 bytes): "NFAR" = 0x4E464152               │
├─────────────────────────────────────────────────────┤
│ Version (1 byte): 0x01                              │
├─────────────────────────────────────────────────────┤
│ Flags (1 byte): compression | encryption            │
├─────────────────────────────────────────────────────┤
│ Archive ID (16 bytes): UUID v4                      │
├─────────────────────────────────────────────────────┤
│ Total Chunks (2 bytes): uint16 big-endian           │
├─────────────────────────────────────────────────────┤
│ Chunk Index (2 bytes): uint16 big-endian            │
├─────────────────────────────────────────────────────┤
│ Payload Size (2 bytes): uint16 big-endian           │
├─────────────────────────────────────────────────────┤
│ Payload (N bytes): data                             │
├─────────────────────────────────────────────────────┤
│ CRC32 (4 bytes): checksum                           │
└─────────────────────────────────────────────────────┘
```

### Установка

#### Требования

- Flutter SDK 3.5+
- Android SDK (API 26+) для Android
- Xcode 15+ для iOS
- Устройство с NFC

#### Сборка

```bash
# Клонирование
git clone https://github.com/mezinster/nfcarchiver.git
cd nfcarchiver

# Установка зависимостей
flutter pub get

# Запуск на устройстве
flutter run
```

#### iOS

Для iOS требуется настройка NFC entitlements в Xcode:

1. Откройте `ios/Runner.xcworkspace` в Xcode
2. Выберите Runner → Signing & Capabilities
3. Добавьте "Near Field Communication Tag Reading"
4. Требуется Apple Developer Program

### Архитектура

```
lib/
├── core/                    # Ядро системы
│   ├── constants/           # Формат NFAR
│   ├── models/              # Chunk, ArchiveMetadata, NfcTagInfo
│   ├── services/            # Chunker, Compression, Encryption, CRC32
│   └── utils/               # Binary Reader/Writer
│
├── features/
│   ├── archive/             # Создание архива
│   ├── restore/             # Восстановление
│   └── nfc/                 # NFC абстракция
│
└── shared/                  # Тема, общие виджеты
```

### Стек технологий

- **Flutter** — кроссплатформенный UI
- **Riverpod** — управление состоянием
- **nfc_manager** — работа с NFC телефона
- **flutter_reactive_ble** — Bluetooth LE для считывателя Chameleon Ultra (BSD-3-Clause)
- **pointycastle** — криптография (AES-256-GCM, PBKDF2)
- **go_router** — навигация

### Веб-версия (`webapp/`)

Браузерный порт NFC Archiver находится в [`webapp/`](webapp/). Работает полностью
на стороне клиента (без сервера) и управляет ридером/райтером **Chameleon Ultra**
через **Web Bluetooth**, читая и записывая физические карты из браузеров на базе
Chromium на десктопе и Android.

- **Носители:** Mifare Classic 1K (720 Б полезной нагрузки на карту) и
  NTAG213/215/216 (Type-2 / NDEF). Тип метки определяется автоматически при
  касании.
- **Совместимость с этим приложением:** байты на метке полностью совпадают — тот
  же формат чанка NFAR, та же обёртка имени файла и, для NTAG, та же запись NDEF
  MIME (`application/vnd.nfcarchiver.chunk`). Метка, записанная на телефоне,
  восстанавливается в браузере и наоборот; NTAG, записанный в браузере — обычная
  NDEF-метка, читаемая любым NFC-телефоном.
- **Возможности:** архивация файлов **и** текста, GZIP-сжатие, шифрование
  AES-256-GCM, сохранение имени файла, живая оценка «≈ N карт», восстановление
  нескольких архивов (скан → выбор), инструмент «Diagnose card». Интерфейс —
  брендированная вкладочная оболочка с темой.

```bash
cd webapp
source ~/.nvm/nvm.sh && nvm use --lts   # Node ≥ 22 (crypto.subtle, CompressionStream)
npm install
npm test        # ядро NFAR без зависимостей + транспорты, тесты против фейкового устройства
npm run app     # http://localhost:8000 — открыть в Chrome/Edge на хосте с Bluetooth
```

Web Bluetooth работает только в Chromium (не Firefox и не iOS Safari), а внутри
WSL браузер должен запускаться на Windows-хосте. Статус: рабочий прототип; цикл
архивация → карты → восстановление проверен на реальном железе. Подробности —
архитектура, заметки по SDK/железу и план паритета (локализация, офлайн
файловый менеджер и запись через Web NFC с телефона ещё впереди) — в
[`webapp/README.md`](webapp/README.md).

### Публикация в F-Droid

Приложение прошло через 13 итераций [MR в fdroiddata](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/32729) до принятия. Основные трудности:

1. **Невалидные категории метаданных** — `Utility` не является допустимой категорией F-Droid. Пришлось использовать `Connectivity` как наиболее подходящую для NFC-приложения.

2. **Отсутствующие обязательные поля** — линтер F-Droid требует `AutoName` (человекочитаемое имя) и `UpdateCheckData` (регулярное выражение для извлечения версии из репозитория). Без них пайплайн `checkupdates` падает.

3. **Привязка версии Flutter** — srclib `flutter@stable` в F-Droid не гарантирует конкретную версию Flutter. Решение — извлекать `FLUTTER_VERSION` из workflow релиза через `sed` и явно делать `git checkout` нужной версии в `prebuild`:
   ```yaml
   prebuild:
     - flutterVersion=$(sed -n -E "s/.*FLUTTER_VERSION:\ '(.*)'/\1/p" .github/workflows/release.yml)
     - git -C $$flutter$$ checkout -f $flutterVersion
   ```

4. **Сканирование пакетов (`scandelete`)** — F-Droid сканирует все зависимости на проприетарный код между `prebuild` и `build`. Поэтому `flutter pub get` должен выполняться в `prebuild` (не в `build`), а `.pub-cache` нужно указать в `scandelete`, так как он содержит прекомпилированные бинарники.

5. **Несовместимость compileSdk 35 и JDK 21** — сервер сборки F-Droid использует JDK 21, в котором есть баг `jlink`/`JdkImageTransform` с Android SDK 35. Несколько подходов не сработали:
   - Патчинг файлов плагинов в `.pub-cache` через `sed` — не работает, т.к. `scandelete` удаляет `.pub-cache` перед сборкой
   - Gradle `afterEvaluate` override — ошибка "project already evaluated" из-за `evaluationDependsOn` во Flutter
   - Gradle init script — работал, но слишком сложный
   - **Итоговое решение**: понижение `compileSdk` до 34 в самом репозитории + блок `afterEvaluate` для субпроектов плагинов

6. **Установка JDK 17** — даже с `compileSdk` 34 у JDK 21 оставались проблемы. Потребовалась установка JDK 17 через `sudo`, но на сервере F-Droid стоит Debian Trixie, где нет JDK 17 в репозиториях. Решение — подключить репозиторий Debian Bookworm:
   ```yaml
   sudo:
     - echo 'deb http://deb.debian.org/debian bookworm main' > /etc/apt/sources.list.d/bookworm.list
     - apt-get update
     - apt-get install -y openjdk-17-jdk-headless
   ```

7. **Форматирование `rewritemeta`** — линтер F-Droid (`rewritemeta`) требует строгого порядка полей (например, `sudo:` должен идти после `commit:`) и правил форматирования (составные shell-команды вроде `echo` должны быть на одной строке).

8. **Требование хеша коммита** — ревьюер потребовал полный SHA коммита (`97f2567c...`) вместо ссылки на тег (`v1.0.6`) для воспроизводимости сборки.

### Лицензия

MIT

### Автор

Разработано [Евгением Мезиным](https://github.com/mezinster) — при участии Claude Code
в роли ассистента, под руководством автора на всех этапах.
