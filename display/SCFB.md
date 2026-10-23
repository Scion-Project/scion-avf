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
| 0x24 | `u32 flags` | guest | bit 0 `READY`: header valid. Bit 1 `POLL`: frames aren't published (e.g. a text console), so the host copies periodically. Bit 2 `DAMAGE`: `dirty` is exact for every published frame; an empty rectangle (w or h = 0) means nothing changed |
| 0x28 | `u32 front` | guest | buffer holding frame `frame_seq` |
| 0x2c | `u32 drawing` | guest | one buffer drawn in place: 1 while a frame is being drawn (seqlock with `host_reading`) |
| 0x30 | `u64 frame_seq` | guest | frames published. Written last, after a barrier |
| 0x38 | `u64 input_seq` | guest | input reports consumed when this frame was drawn (0 if unknown); the host uses it to time input → pixels |
| 0x40 | `u64 guest_ns` | guest | guest monotonic time at publish |
| 0x48 | `u32 dirty[4]` | guest | x, y, w, h changed since the previous frame. Without `DAMAGE`, a hint that may cover more (HackiOS before patch 1204 always sent the whole screen) |
| 0x58 | `u64 host_seq` | host | last frame the host finished copying |
| 0x60 | `u64 host_reading` | host | frame being copied now, 0 when idle. A double-buffering guest doesn't draw into that frame's buffer |
| 0x68 | `u64 host_ns` | host | host time at the last copy. Set before boot, so a guest can confirm the memory really is shared |

## Protocol

**Two buffers (`nbufs` = 2).**

* Guest, per frame:
  1. Wait while `host_reading` is the frame in the back buffer (bounded).
  2. Draw into the back buffer.
  3. `dsb`, then set `dirty`, `input_seq`, `guest_ns` and `front`.
  4. `dmb`, then `frame_seq++`.
* Host: when `frame_seq` changes, set `host_reading`, copy `buf[front]`, set
  `host_seq`, clear `host_reading`, post.

**One buffer drawn in place (`nbufs` = 1, what XNU does).** This is a seqlock.

* Guest:
  1. Wait while `host_reading` ≠ 0 (4 ms at most).
  2. Set `drawing` = 1, then `dsb`. If `host_reading` became set in the
     meantime, clear `drawing` and wait again.
  3. Draw.
  4. `dsb`, clear `drawing`, `frame_seq++`.
* Host:
  1. Set `host_reading` and keep it set while waiting for `drawing` to clear
     (10 ms at most). Keeping it set means a guest that draws back to back
     lets the host in after its current frame.
  2. Copy.
  3. Recopy if `drawing` was set, or `frame_seq` moved, during the copy.

**Throughout.** The buffer queue is RGBX_8888 for `XB24` and BGRA_8888 (HAL
format 5) for `XR24`, so both copy with a plain `memcpy`. A guest that doesn't
publish (`POLL`) is copied at the refresh rate.

**Damage.** A frame that directly follows the last one the host showed (`frame_seq` = last + 1)
needs only its `dirty` rectangle copied. The Scion app (scion #123) locks the window to that
rectangle, and the buffer queue keeps the rest from the previous buffer. With `DAMAGE` set and an
empty rectangle, the frame isn't copied at all. Everything else is copied whole: the first frame,
skipped frames, `POLL` refreshes and torn frames.

HackiOS (patch 1204) finds the rectangle without reading the panel's write-combined memory. It
keeps a cached shadow of the panel and compares each row it draws with the shadow. It writes only
the changed span to both the shadow and the panel, and merges the bounds from all drawing threads
without locks. It sets `DAMAGE` from the second published frame on. The first frame after the
boot console goes out whole.

Pixel 10 (`display/run-on-device.sh --bufs N --fmt xr24`), with the guest
redrawing every pixel back to back:

| Mode | Presented | Frames mixing rows of two frames |
|---|---|---|
| `--bufs 0` (one buffer, no seqlock, like ramfb) | 69 fps | 128 of 345 |
| `--bufs 1` (seqlock) | 120 fps | 0 (2 recopies, 0 shown torn) |
| `--bufs 2` (flip) | 120 fps | 0 |

Memory attributes: the host maps the region cacheable. A Linux guest reaches
it through `/dev/mem` as Device memory, so it must avoid unaligned accesses
(`-mstrict-align`). XNU maps the boot framebuffer write-combined. On the
Pixel 10 the guest's writes were visible to the host without cache
maintenance (KVM's stage-2 forced write-back, FEAT_S2FWB).
