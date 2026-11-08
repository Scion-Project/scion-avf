#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build-system edits that let an open-source xnu-12377 tree build without Apple's Kernel Debug Kit:
# paths into the fake SDK root, the KDK's binary support archive (lib<MACHINE>.os.<CONFIG>.a) linked
# only if present, the arm64 machine layer compiled from source (nos_arm_asm/nos_arm_pmap), opaque CoreEntitlements V2 types, four entitlement names, and the TrustCache API headers of xnu-8796.101.5.
# No kernel behaviour changes here. Idempotent.
#
#   buildfix.sh XNU_TREE FAKEROOT TRUSTCACHE_HEADERS_DIR
set -euo pipefail
X=$1 FR=$2 TC=$3
cd "$X"
sed -i '' "s|^AVAILABILITY_PL=\"\${SDKROOT}/\${DRIVERKITROOT}/usr/local/libexec/availability.pl\"|AVAILABILITY_PL=\"$FR/usr/local/libexec/availability.pl\"|" \
	bsd/sys/make_symbol_aliasing.sh
sed -i '' "s|^LDFLAGS_KERNEL_SDK	= -L\$(SDKROOT)/usr/local/lib/kernel |LDFLAGS_KERNEL_SDK	= -L$FR/usr/local/lib/kernel -L\$(SDKROOT)/usr/local/lib/kernel |" makedefs/MakeInc.def
sed -i '' "s|^INCFLAGS_SDK    = -I\$(SDKROOT)/usr/local/include/kernel |INCFLAGS_SDK    = -I$FR/usr/local/include/kernel -I$FR/usr/local/include -I\$(SDKROOT)/usr/local/include/kernel |" makedefs/MakeInc.def
python3 - <<'PY'
import pathlib
p = pathlib.Path("makedefs/MakeInc.def"); s = p.read_text()
old = "        LDFLAGS_KERNEL_ONLY += -rdynamic -Wl,-force_load,$(KDKROOT)/System/Library/KernelSupport/lib$(CURRENT_MACHINE_CONFIG).os.$(CURRENT_KERNEL_CONFIG).a\n"
new = "ifneq ($(wildcard $(KDKROOT)/System/Library/KernelSupport/lib$(CURRENT_MACHINE_CONFIG).os.$(CURRENT_KERNEL_CONFIG).a),)\n" + old + "endif\n"
if old in s and new not in s:
    p.write_text(s.replace(old, new))
PY
mkdir -p EXTERNAL_HEADERS/CoreEntitlements/V2
[ -f EXTERNAL_HEADERS/CoreEntitlements/V2/API.h ] || cat > EXTERNAL_HEADERS/CoreEntitlements/V2/API.h <<'H'
/* Scion: opaque stand-ins for the CoreEntitlements V2 types the open-source kernel names. */
#ifndef SCION_CE_V2_API_H
#define SCION_CE_V2_API_H
typedef struct CEKernelAPI CEKernelAPI_t;
typedef struct CEContext CEContext_t;
#endif
H
[ -f EXTERNAL_HEADERS/CoreEntitlements/V2/Kernel.h ] || printf '#include <CoreEntitlements/V2/API.h>\n' > EXTERNAL_HEADERS/CoreEntitlements/V2/Kernel.h
mkdir -p EXTERNAL_HEADERS/CodeSignature
[ -f EXTERNAL_HEADERS/CodeSignature/Entitlements.h ] || cat > EXTERNAL_HEADERS/CodeSignature/Entitlements.h <<'H'
/* Scion: the entitlement names the open-source kernel refers to (the real header is KDK-only). */
#ifndef SCION_CODESIGNATURE_ENTITLEMENTS_H
#define SCION_CODESIGNATURE_ENTITLEMENTS_H
#define kCSWebBrowserNetworkEntitlement    "com.apple.developer.web-browser-engine.networking"
#define kCSWebBrowserWebContentEntitlement "com.apple.developer.web-browser-engine.webcontent"
#define kCSWebBrowserGPUEntitlement        "com.apple.developer.web-browser-engine.rendering"
#define kCSWebBrowserHostEntitlement       "com.apple.developer.web-browser-engine.host"
#endif
H
[ -d EXTERNAL_HEADERS/TrustCache ] || cp -R "$TC" EXTERNAL_HEADERS/TrustCache
# The arm64 machine layer (start.s, locore.s, cswitch.s, caches, pmap, ...) is in the open tree but
# marked nos_arm_asm / nos_arm_pmap, which Apple links from the KDK archive instead: compile it here.
grep -q 'nos_arm_asm nos_arm_pmap' config/MASTER.arm64.MacOSX ||
	sed -i '' 's|^#  KERNEL_BASE =    \[ arm64 |#  KERNEL_BASE =    [ arm64 nos_arm_asm nos_arm_pmap |' config/MASTER.arm64.MacOSX
# arm64/ppl/sart.h and uat.h are not in the open release: a VM has no SART DMA filter and no UAT.
mkdir -p osfmk/arm64/ppl
[ -f osfmk/arm64/ppl/sart.h ] || printf '/* Scion: no SART DMA filter on a VM. */\n#pragma once\nstatic inline void sart_bootstrap(void) { }\n' > osfmk/arm64/ppl/sart.h
[ -f osfmk/arm64/ppl/uat.h ] || printf '/* Scion: no UAT on a VM. */\n#pragma once\n' > osfmk/arm64/ppl/uat.h
# arm64/tunables/tunables.s (Apple's per-SoC CPU tunables) is not in the open release: none on a VM.
mkdir -p osfmk/arm64/tunables
[ -f osfmk/arm64/tunables/tunables.s ] || printf '/* Scion: no CPU tunables on a VM. */\n.macro APPLY_TUNABLES midr, tmp1, tmp2\n.endmacro\n' > osfmk/arm64/tunables/tunables.s
echo "buildfix: done"
