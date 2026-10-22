# SCFB: the Scion shared framebuffer

A linear framebuffer in a slice of guest RAM that the Android app maps too.
It is the AVF stand-in for QEMU's `ramfb`: crosvm has no ramfb, and a
sideloaded app can't take crosvm's virtio-gpu display (docs/DISPLAY-INPUT.md).

## Plumbing

* The app creates an **ashmem** region (`SharedMemory.create`, which is ashmem
  on the Pixel 10; crosvm may `mmap` ashmem but not an app's memfd or data
  file) and maps it.
* It adds `CustomMemoryBackingFile{fd, rangeStart = IPA, size}` to the VM's
  raw config. crosvm runs `--file-backed-mapping /proc/self/fd/N,addr=IPA,size=N,rw,ram`
  and backs that part of guest RAM with the region. The IPA must lie inside
  guest RAM (`0x8000_0000 + memory size`). The display app puts it 4 MiB below
  the top, clear of the FDT crosvm writes into the last 2 MiB.
* The guest kernel is told where it is on its command line:
  `scfb.addr=IPA scfb.size=N scfb.w=W scfb.h=H`. It must not use that memory
  itself: `mem=` for Linux, and avfboot's memory window for XNU.

## Layout

All fields are little-endian and live in the first 4 KiB of the region. Pixel
buffers start at `buf_offset[i]` from the region start, 64 KiB aligned.

| Offset | Field | Written by | Meaning |
|---|---|---|---|
| 0x00 | `u32 magic` | guest | `0x42464353` ("SCFB") |
| 0x04 | `u32 version` | guest | 1 |
| 0x08 | `u32 width, height` | guest | pixels |
| 0x10 | `u32 stride` | guest | bytes per row |
| 0x14 | `u32 format` | guest | DRM fourcc: `XB24` (bytes R,G,B,X) or `XR24` (bytes B,G,R,X, what iOS draws) |
| 0x18 | `u32 buf_offset[2]` | guest | buffer offsets; equal when `nbufs` = 1 |
| 0x20 | `u32 nbufs` | guest | 1 (draw in place, like ramfb) or 2 (flip) |
| 0x24 | `u32 flags` | guest | bit 0 `READY`: header valid. Bit 1 `POLL`: frames aren't published (e.g. a text console), so the host copies periodically |
| 0x28 | `u32 front` | guest | buffer holding frame `frame_seq` |
| 0x30 | `u64 frame_seq` | guest | frames published. Written last, after a barrier |
| 0x38 | `u64 input_seq` | guest | input reports consumed when this frame was drawn (0 if unknown); the host uses it to time input → pixels |
| 0x40 | `u64 guest_ns` | guest | guest monotonic time at publish |
| 0x48 | `u32 dirty[4]` | guest | x, y, w, h changed since the previous frame |
| 0x58 | `u64 host_seq` | host | last frame the host finished copying |
| 0x60 | `u64 host_reading` | host | frame being copied now, 0 when idle. A double-buffering guest doesn't draw into that frame's buffer |
| 0x68 | `u64 host_ns` | host | host time at the last copy. Set before boot, so a guest can confirm the memory really is shared |

## Protocol

Guest, per frame: draw into the back buffer (or in place), then `dsb`, set
`dirty`, `input_seq` and `guest_ns`, set `front`, `dmb`, `frame_seq++`.

Host: poll `frame_seq` (the test app sleeps 250 µs between looks). When it
changes, set `host_reading`, copy `buf[front]` into the SurfaceView's
`ANativeWindow`, set `host_seq` and clear `host_reading`, then post. The
buffer queue is RGBX_8888 for `XB24` and BGRA_8888 (HAL format 5) for `XR24`,
so both copy with a plain `memcpy`. A guest that doesn't publish (`POLL`)
gets copied at the refresh rate.

Memory attributes: the host maps the region cacheable. A Linux guest reaches
it through `/dev/mem` as Device memory, so it must avoid unaligned accesses
(`-mstrict-align`). XNU maps the boot framebuffer write-combined. On the
Pixel 10 the guest's writes were visible to the host without cache
maintenance (KVM's stage-2 forced write-back, FEAT_S2FWB).
