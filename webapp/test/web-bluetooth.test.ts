import { test } from 'node:test';
import assert from 'node:assert/strict';
import { webBluetoothAvailable } from '../app/ui/web-bluetooth.js';

// Every iOS browser is WebKit: no navigator.bluetooth and no BluetoothUUID.
test('no Web Bluetooth when navigator.bluetooth is missing (iOS WebKit)', () => {
  assert.equal(webBluetoothAvailable({ navigator: {} }), false);
  assert.equal(webBluetoothAvailable({}), false);
});

// The Chameleon adapter calls BluetoothUUID.canonicalUUID() as it loads, so a
// navigator.bluetooth without the BluetoothUUID global is not enough.
test('no Web Bluetooth when BluetoothUUID is missing', () => {
  assert.equal(webBluetoothAvailable({ navigator: { bluetooth: {} } }), false);
});

test('Web Bluetooth when both are present (Chrome on Android / desktop)', () => {
  assert.equal(
    webBluetoothAvailable({ navigator: { bluetooth: {} }, BluetoothUUID: { canonicalUUID: () => '' } }),
    true,
  );
});

test('defaults to the real globals — Node has neither', () => {
  assert.equal(webBluetoothAvailable(), false);
});
