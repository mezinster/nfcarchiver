/** Entry point: initialize the shell, device bar, and panels. */
import { initShell } from './ui/shell.js';
import { initDeviceBar } from './ui/device.js';
import { initArchivePanel } from './ui/archive-panel.js';
import { initRestorePanel } from './ui/restore-panel.js';
import { initAboutPanel } from './ui/about-panel.js';

initShell();
initDeviceBar();
initArchivePanel();
initRestorePanel();
initAboutPanel();
