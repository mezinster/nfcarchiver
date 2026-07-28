/** Entry point: initialize the shell, device bar, and panels. */
import { initShell } from './ui/shell.js';
import { initDeviceBar } from './ui/device.js';
import { initArchivePanel } from './ui/archive-panel.js';

initShell();
initDeviceBar();
initArchivePanel();
