/** Entry point: pick a language, then initialize the shell, device bar, and panels. */
import { initI18n } from './i18n/index.js';
import { initShell } from './ui/shell.js';
import { initDeviceBar } from './ui/device.js';
import { initArchivePanel } from './ui/archive-panel.js';
import { initRestorePanel } from './ui/restore-panel.js';
import { initFilesPanel } from './ui/files-panel.js';
import { initLogPanel } from './ui/log-panel.js';
import { initAboutPanel } from './ui/about-panel.js';

initI18n();
initShell();
initDeviceBar();
initArchivePanel();
initRestorePanel();
initFilesPanel();
initLogPanel();
initAboutPanel();
