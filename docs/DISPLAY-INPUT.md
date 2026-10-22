# Display and touch for a Scion AVF VM

Status: **draft.** Sections marked **[src]** are read from AOSP
`packages/modules/Virtualization` and `system/sepolicy` at `android17-release`
(April 2026) and crosvm at the same branch. Sections marked **[pixel]** were
measured on the Pixel 10 (`frankel`, Android 17, `DP11.260918.006`, user build).
Anything else is a plan.

## 1. Short answer

AVF ships three display/input mechanisms for custom VMs. A sideloaded app can
use two of them:

| Mechanism | What it is | Sideloaded app? |
|---|---|---|
| **virtio-input** (touch, keyboard, mouse, trackpad, switches) | `VirtualMachineCustomImageConfig.Builder.useTouch(true)` etc. The framework makes a socketpair per device, passes one end to crosvm (`--input multi-touch[path=/proc/self/fd/N,width,height]`) and writes `struct input_event`s into the other from `VirtualMachine.sendMultiTouchEvent(MotionEvent)` | **yes**, with a hidden-API exemption. The sockets stay inside the app → virtmgr → crosvm chain the AVF client policy already allows [src] |
| **virtio-gpu + Android display backend** (`setDisplayConfig`, `setGpuConfig`) | crosvm gets `--gpu=...,displays=[[mode=windowed[w,h],dpi=[x,y],refresh-rate=r]]` and `--android-display-service=<vm name>`. crosvm registers an `ICrosvmAndroidDisplayService` binder with virtualizationservice, and the Terminal app fetches it (`IVirtualizationServiceInternal.waitDisplayService`) and hands it a `Surface` from its SurfaceView | **no** (SELinux). Only the `vmlauncher_app` domain (the Terminal priv-app) may look up `virtualization_service`, call `virtualizationservice`, and exchange binders with `crosvm_domain`. An `untrusted_app` is refused at the service lookup, and crosvm couldn't call back into the app's buffer queue either [src] |
| **Guest RAM shared with the app** (`VirtualMachineRawConfig.customMemoryBackingFiles`, crosvm `--file-backed-mapping`) | An app-supplied fd is mapped into the guest's RAM at a chosen IPA. If the app maps the same fd, the guest's framebuffer is visible to the app with no copy and no device model | **likely yes**, see section 4. The Java API never fills the field, so the app has to add it to the parcel itself |

So the plan for Scion is:

* **Touch**: virtio-input multi-touch, the stock way.
* **Display**: a linear framebuffer in a region of guest RAM that the app also
  maps (an ashmem region passed as a `CustomMemoryBackingFile`). The guest
  writes pixels there and the app copies them into its SurfaceView. This is
  the AVF equivalent of QEMU's `ramfb`, which is what HackiOS already uses.
* virtio-gpu stays useful for a Linux guest and for a future where the display
  service becomes reachable (a binder-RPC display service is a TODO in AOSP,
  b/330257000), so the XNU side keeps virtio-gpu 2D as an optional path.

## 2. What the custom-image config offers [src]

All of these are `@hide` and need the hidden-API exemption (section 5).

* `VirtualMachineCustomImageConfig.DisplayConfig.Builder`: `setWidth`,
  `setHeight`, `setHorizontalDpi`, `setVerticalDpi`, `setRefreshRate`. All five
  must be non-zero.
* `GpuConfig.Builder`: `setBackend` (`2d`, `virglrenderer`, `gfxstream`),
  `setContextTypes`, `setPciAddress`, `setRendererFeatures`, `setRendererUse{Egl,Gles,Glx,Surfaceless,Vulkan}`.
  The Terminal app sets gfxstream + Vulkan when available, otherwise nothing.
  Without a `GpuConfig`, a `DisplayConfig` alone still adds `--gpu` with the
  default backend.
* `Builder.useTouch/useKeyboard/useMouse/useTrackpad/useSwitches(boolean)`.
* `AudioConfig` (`setUseSpeaker`, `setUseMicrophone`) → virtio-snd with the
  `aaudio` backend. `UsbConfig` → xHCI controller.
* `VirtualMachine` (running VM): `sendMultiTouchEvent(MotionEvent)` (queued and
  written by a framework thread; x/y are multiplied by `setTouchScale`),
  `sendKeyEvent(short evdevKeyCode, boolean down)`, `sendMouseEvent`,
  `sendTrackpadEvent`, `sendLidEvent`, `sendTabletModeEvent`, plus
  `addDisplay/removeDisplay/getDisplays` (hot-plug via crosvm's control socket,
  new in 17).
* virtmgr only honours GPU/display/input when it was built with
  `RELEASE_AVF_SUPPORT_CUSTOM_VM_WITH_PARAVIRTUALIZED_DEVICES`; otherwise it
  logs `... not supported. Ignoring` and drops them. The Pixel ships the
  Terminal app's GUI, so it's expected on; the run confirms it.

The multi-touch device crosvm creates reports `ABS_MT_SLOT`,
`ABS_MT_TRACKING_ID`, `ABS_MT_POSITION_X/Y`, `ABS_X/Y` and `BTN_TOUCH`, with the
range set by the `width`/`height` the framework passes (the display size when
there is a display, otherwise the default).

## 3. Why the stock display path is closed to a sideloaded app [src]

From `system/sepolicy` (android17-release), all inside
`is_flag_enabled(RELEASE_AVF_SUPPORT_CUSTOM_VM_WITH_PARAVIRTUALIZED_DEVICES)`:

```
# private/vmlauncher_app.te
allow vmlauncher_app virtualization_service:service_manager find;
allow vmlauncher_app virtualizationservice:binder call;
allow vmlauncher_app crosvm_domain:binder { call transfer };
# private/crosvm.te
allow crosvm_domain vmlauncher_app:binder { transfer call };
```

`untrusted_app_all` gets only `virtualizationservice_use(untrusted_app_all)`,
which covers the client ↔ virtmgr ↔ crosvm sockets, fds and pipes, not these
binder edges. So for our app:

1. `ServiceManager.getService("android.system.virtualizationservice")` is denied
   (`avc: denied { find }`), so `waitDisplayService()` can't be reached;
2. even with the display-service binder, `setSurface()` is an
   `untrusted_app → crosvm_domain` binder call, which is not allowed;
3. crosvm then queues buffers into the app's `BLASTBufferQueue`, a
   `crosvm_domain → untrusted_app` binder call, which is not allowed either.

None of this is a hidden-API matter, so no exemption helps. The guest still
gets its virtio-gpu device, but its scanout goes nowhere.

## 4. Shared-memory framebuffer [src, pending pixel]

`VirtualMachineRawConfig.customMemoryBackingFiles` is a list of
`{ParcelFileDescriptor file, long rangeStart, long size}`. virtmgr passes each
one straight to crosvm as
`--file-backed-mapping /proc/self/fd/N,addr=..,size=..,rw,ram` (no validation
in virtmgr). crosvm dups the fd (`open_file_or_duplicate`), mmaps it
`MAP_SHARED`, and uses it as the backing of that slice of guest RAM. The range
must sit inside a RAM region (`0x8000_0000` + guest memory size).

SELinux for each hop:

* app → virtmgr → crosvm fd passing: `virtualizationservice_use` grants
  `fd use` on the client domain;
* crosvm `mmap`: crosvm may `map` an fd on `ashmem_device` /
  `ashmem_libcutils_device` (every domain may, `private/domain.te`). It may
  **not** map an app's `memfd_file` (only `self`), or an `app_data_file`
  (read/write/getattr only). So the region has to be **ashmem**, not memfd.
  On this phone `sys.use_memfd` is unset and `/dev/ashmem<boot-id>` exists, so
  `SharedMemory.create()` should still hand out ashmem; the probe checks by
  reading `/proc/self/fd/N`.

The Java framework always sends an empty list, so the app adds the entry
itself: `VirtualMachine.run()` gets its `IVirtualizationService` from the
`VirtualizationService` singleton, and the app wraps that binder in a proxy
that appends the backing file to the raw config in `createVm`. Everything else
(console, callbacks, input sockets) stays the stock Java path.

Guest side, the region is outside the guest kernel's memory map (`mem=` for
Linux, the loader's memory map for XNU) and the guest draws into it as a
linear XRGB8888 framebuffer. For a doorbell, the guest can poll-free signal a
frame over virtio-vsock, or the app can sample at the display refresh rate
(a frame counter in a header word tells it whether anything changed).

## 5. Hidden-API exemption

`hidden_api_blacklist_exemptions` takes comma-separated member-signature
prefixes. On top of spike 1's two prefixes, display/touch needs:

| Prefix | For |
|---|---|
| `Landroid/system/virtualmachine/VirtualMachineCustomImageConfig` | whole class tree: `Builder` (incl. `setDisplayConfig`, `setGpuConfig`, `useTouch`, ...), `DisplayConfig$Builder`, `GpuConfig$Builder` |
| `Landroid/system/virtualmachine/VirtualMachineConfig$Builder;->setCustomImageConfig(` | as in spike 1 |
| `Landroid/system/virtualmachine/VirtualMachine;->send` | `sendMultiTouchEvent`, `sendKeyEvent`, ... |
| `Landroid/system/virtualmachine/VirtualMachine;->setTouchScale(` | touch scaling |
| `Landroid/system/virtualmachine/VirtualizationService;` and `Landroid/system/virtualmachine/VirtualMachine;->mVirtualizationService` | shared-memory hook (section 4) |
| `Landroid/system/virtualizationservice/` | the AIDL parcelables (`VirtualMachineConfig`, `VirtualMachineRawConfig`, `CustomMemoryBackingFile`) and `IVirtualizationService` for the hook |

The final list is in `display/run-on-device.sh`; it is reverted on exit.
Grants are unchanged from spike 1: `MANAGE_VIRTUAL_MACHINE` and
`USE_CUSTOM_VIRTUAL_MACHINE`.

## 6. Pixel results

Pending: the display test app (`display/`) is being built.
