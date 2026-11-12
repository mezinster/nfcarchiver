/** Whether this browser can talk to a Chameleon Ultra over Web Bluetooth.
 *  Dependency-free so it runs under `node --test`.
 *
 *  Both globals are required: the SDK's WebbleAdapter needs navigator.bluetooth
 *  to connect, and calls BluetoothUUID.canonicalUUID() the moment it is
 *  evaluated. Every iOS browser (all WebKit) has neither, as do desktop
 *  Firefox and Safari. */
export function webBluetoothAvailable(
  g: { navigator?: { bluetooth?: unknown }; BluetoothUUID?: unknown } = globalThis as never,
): boolean {
  return g.navigator?.bluetooth != null && g.BluetoothUUID != null;
}
