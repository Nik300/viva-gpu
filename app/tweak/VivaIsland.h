// VivaIsland: names shared by the SpringBoard tweak (VivaIsland.m) and Viva Manager (Sources/VMIsland.m).
// Research and design: ../../docs/DYNAMIC-ISLAND.md
#pragma once

// Preferences: /var/mobile/Library/Preferences/it.viva.island.plist (CFPreferences, user mobile).
#define VI_DOMAIN               "it.viva.island"
#define VI_KEY_ENABLED          "Enabled"          // bool, default YES: Viva Link notice in the island
#define VI_KEY_STANDARD         "StandardNotice"   // bool, default NO: brief notice for a plain computer (state 1)
#define VI_KEY_FORCE_OVERLAY    "ForceOverlay"     // bool, default NO: skip the system aperture element, draw the overlay

// Darwin notifications.
#define VI_NOTIFY_TEST          "it.viva.island.test"     // app -> SpringBoard: show the notice now
#define VI_NOTIFY_PREFS         "it.viva.island.prefs"    // app -> SpringBoard: preferences changed
#define VI_NOTIFY_STATUS        "it.viva.island.status"   // SpringBoard keeps its state here (notify_set_state)

// kern.viva_linkstate (kernel patch 0182): 0 no USB host, 1 host configured (standard mode), 2 Viva Link active.
// Missing sysctl = 0.
#define VI_SYSCTL               "kern.viva_linkstate"

#define VI_DYLIB_PATH           "/var/jb/usr/lib/VivaIsland.dylib"
#define VI_SPRINGBOARD_PATH     "/System/Library/CoreServices/SpringBoard.app/SpringBoard"

// Crash guard: written (count + 1) before a system aperture element is registered, removed once SpringBoard survived
// it. At VI_SAFETY_LIMIT the tweak stops using the system path and draws the overlay. Deleting the file re-enables it.
#define VI_SAFETY_FILE          "/var/mobile/Library/Caches/VivaIsland/pending"
#define VI_SAFETY_LIMIT         2

// Status word (notify state of VI_NOTIFY_STATUS): bits 0-7 mode, 8-15 last link state, 16-23 flags, 32-63 pid.
enum { VI_MODE_STARTING = 0, VI_MODE_ELEMENT = 1, VI_MODE_OVERLAY = 2, VI_MODE_OFF = 3 };
#define VI_FLAG_SAFETY          0x1     // system path disabled by the crash guard
#define VI_FLAG_ELEMENT_FAILED  0x2     // classes/selectors missing or registerElement: failed: overlay in use
#define VI_FLAG_NO_SYSCTL       0x4     // kern.viva_linkstate missing (kernel without 0182)
#define VI_STATUS(mode, link, flags, pid) \
    ((uint64_t)(mode) | ((uint64_t)((link) & 0xff) << 8) | ((uint64_t)((flags) & 0xff) << 16) | ((uint64_t)(uint32_t)(pid) << 32))
#define VI_STATUS_MODE(s)       ((int)((s) & 0xff))
#define VI_STATUS_LINK(s)       ((int)(((s) >> 8) & 0xff))
#define VI_STATUS_FLAGS(s)      ((int)(((s) >> 16) & 0xff))
#define VI_STATUS_PID(s)        ((int)((s) >> 32))
