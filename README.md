# ios-on-pixel-avf

Experimental **hardware-virtualization backend** for
[ios-on-pixel](https://github.com/dylanneve1/ios-on-pixel): run the emulated
iPhone 11 on the Pixel's own virtualization (Android Virtualization Framework,
pKVM, crosvm) instead of QEMU's software CPU emulation.

> **Status: feasibility spike.** Nothing here boots anything yet. The main app
> keeps using the QEMU backend; this one becomes a selectable option in the app
> once it works.

## Why a separate repo

The QEMU backend builds on our fork of [Inferno](https://github.com/dylanneve1/Inferno).
This backend is a different engine (crosvm-based, Rust) and moves at a
different pace, so it lives here. The app talks to either backend through one
interface.

## The first question: where can our device models run?

On a Pixel, AVF launches VMs with the crosvm inside a **signed system module**,
and an app can't replace it. Before any porting work, issue #1 has to establish:

1. whether our app can start a custom VM on a Pixel 10 at all (with the
   adb-granted development permissions), and what that VM provides;
2. whether the phone's crosvm offers any extension point for devices it
   doesn't ship (such as vhost-user backends), or whether Apple device models
   must live elsewhere.

If the phone's crosvm can't host them, the porting work can still be developed
and measured on a Linux ARM64 host with KVM, where we control crosvm, while
the phone question stays open.

## Spike #1 results

[docs/SPIKE-1-AVF-LAUNCH.md](docs/SPIKE-1-AVF-LAUNCH.md) covers what a
sideloaded app needs to boot a custom VM: two `pm grant`s plus a hidden-API
exemption. It also covers what crosvm exposes and the copy-paste steps for the
(still pending) Pixel 10 run. The tooling is in [probe/](probe): a Kotlin probe
app, a tiny Linux guest, and `run-on-device.sh`.

## Measuring what the phone gives us

[docs/AVF-BENCH.md](docs/AVF-BENCH.md) describes the one command
(`tools/run-all.sh`) that answers, on a real Pixel 10, what a sideloaded custom
VM gets (RAM, vCPUs, 4 KiB vs 16 KiB pages, virtio devices, boot time) and how
much faster native-under-pKVM is than QEMU TCG on the same phone
([bench/](bench): a tiny Linux guest with int/mem/chase/syscall/page-fault
microbenchmarks, run natively, in an AVF VM and under a static QEMU).

## Ground rules

Same as the main project ([ETHICS.md](https://github.com/dylanneve1/ios-on-pixel/blob/main/docs/ETHICS.md)):
no Apple software, keys or instructions for obtaining them in this repo; and any
changes to guest code under the hypervisor must **preserve behaviour**. Security
monitors (SPTM/TXM) keep running and enforcing; only the way calls reach them may
change.

## Work items

Tracked as issues in this repo (moved from ios-on-pixel #15–#18).
