# CoreDevice HID Helper

`idb_coredevice_hid_helper` is a private Xcode 27-only helper for simulator HID input.

The main IDB frameworks keep `MACOSX_DEPLOYMENT_TARGET=11.0` and do not import or link `CoreDevice` or `UniversalHID`. On Xcode 27, `FBSimulatorHID` routes semantic touch and keyboard events to this helper process. Older Xcodes continue using the Indigo `SimDeviceLegacyHIDClient` path.

Touch events use the Xcode 27 `UniversalHIDService` transport. Keyboard events intentionally use CoreDevice's higher-level `HIDKeyboard` capability instead of raw `UniversalHID.KeyboardReport` sends to service `0x200`, because raw keyboard reports deliver plain keys but do not reliably apply modifier semantics such as Shift on iOS 27 simulators.

For local development, `./build.sh build FBSimulatorControl` and
`./build.sh build idb_companion` build the helper with Xcode 27 and bundle it
inside `FBSimulatorControl.framework/Resources`.

To run a locally built helper directly, or to override the bundled helper:

```sh
./build.sh build CoreDeviceHIDHelper
export IDB_COREDEVICE_HID_HELPER="$PWD/Shims/CoreDeviceHID/Build/Products/Release/idb_coredevice_hid_helper"
```

For packaging, bundle the signed helper as `idb_coredevice_hid_helper` inside `FBSimulatorControl.framework/Resources`.
