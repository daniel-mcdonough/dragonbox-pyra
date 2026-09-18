# Pegasus on the Pyra, and custom menus for the hardware

Scoped 2026-09-18 against the running unit and against Pegasus at commit
`83fd27f` (2026-09-15). Nothing here is installed on the device yet. The one
thing that could have made the whole idea impossible has been tested and does
not: see `docs/qt-gles.md`.

Pegasus Frontend is a QML launcher — it lists games and runs them, and does not
emulate anything itself. It is ~20k lines of C++ plus QML, GPLv3, and it is
actively developed rather than a dormant project. The reason to want it here is
that it is a controller-driven fullscreen shell for a handheld, and the reason
it is worth writing down before starting is that **the part you actually want —
a brightness, thermals and battery menu — is the part its theme API cannot
do.**

---

## What is already established

| Question | Answer | How |
| --- | --- | --- |
| Does Qt Quick run on the SGX at all? | Yes, after one symlink | `docs/qt-gles.md` |
| Fast enough? | 117 fps on a busy 1280x720 scene, 171 fps on a light one | `QSG_RENDER_TIMING` frame counts |
| Are the build dependencies in trixie? | All of them | `apt-cache policy` on the device |
| Qt Gamepad? | **Not in trixie.** `qtgamepad5-dev` has no candidate | ditto |
| So gamepad support? | SDL2, which upstream prefers anyway. `libsdl2 2.32.4` is installed | ditto |
| Will it see the controls? | `pyraInput Gamepad` is `js2`, plus `pyra-game-buttons` and the built-in keyboard | `/proc/bus/input/devices` |
| Battery in the theme API? | Percent and charging state work; **seconds remaining never will** | `api.device` uses SDL power, which reads `capacity` and `status`; the `bq27421-0` gauge exposes no `time_to_empty_now` |
| Video previews in themes? | Software decode only — there is no `/dev/video*` on this machine | device |
| Screen | 1280x720, panel rotated | `xrandr` |

## The thing that costs money: themes cannot touch the hardware

The theme QML API is `api.collections`, `api.allGames`, `api.keys`,
`api.memory` and `api.device`. `api.device` is battery and nothing else. There
is no process execution, no file access and no sysfs. Themes are sandboxed by
omission, and that is a deliberate upstream choice.

There is a second constraint that rules out the obvious workaround.
`ProcessLauncher` does not merely start a program: `FrontendLayer::teardown()`
**deletes the whole `QQmlApplicationEngine`** before the game runs and rebuilds
it afterwards. So a "System" collection whose games are shell commands does
work — but every press tears the theme down and reloads it, which on this
hardware is seconds, and there is no way to show a value that changes while you
look at it.

Three routes, then:

**A. Metadata entries, no code.** A collection in `metadata.pegasus.txt` whose
entries are commands: keyboard light on/off, reboot to MATE, run a thermal
probe. Two hours of work, no build, no fork. Correct for one-shot actions,
useless for a slider or a live reading.

**B. Patch the backend.** The extension point is clean and small.
`src/backend/model/device/DeviceInfo.h` is an ordinary `QObject` with
`Q_PROPERTY` declarations and a `QTimer` poll, and it reaches QML through a
single line in `src/backend/model/Api.h`:

    QML_CONST_PROPERTY(model::DeviceInfo, device)

A `PyraDevice` sibling registered the same way puts the backlights, the five
thermal zones, cpufreq and the real fuel-gauge numbers in front of a QML page
in a custom theme. ~250–350 lines of C++ and a header, plus the theme.

**C. A local helper daemon the theme talks to over HTTP.** Rejected without
testing it. QML's `XMLHttpRequest` should reach a loopback port, so it would
probably work without touching Pegasus at all — and it would mean any theme
anyone ever installs can drive that daemon, on a machine where themes are
downloaded QML.
All of B's cost with none of its containment.

**Take B**, and keep A as the escape hatch for anything that genuinely wants to
leave the UI (reboot to the desktop, run a probe script).

## What to expose, and what to refuse

| Item | Read from | Written how |
| --- | --- | --- |
| Screen brightness | `/sys/class/backlight/backlight` — note `max_brightness` is **15**, so sixteen steps and no more | logind `SetBrightness` on D-Bus |
| Keyboard backlight | `/sys/class/backlight/keyboard-backlight`, max 8 | the same call with the device named — `pyra-idle-dim` already takes the device as a parameter |
| Battery | `bq27421-0`: `capacity`, `status`, `current_now`, `voltage_now`, `temp` | read-only |
| Charger | `bq24297`: `online`, `status`, and the input current limit fix 8 installs | read-only in the UI |
| Temperatures | the five zones: `cpu_thermal`, `gpu_thermal`, `core_thermal`, and the two gauge dies | read-only |
| CPU | `scaling_cur_freq`, `scaling_max_freq`, governor | **read-only** |
| LEDs | `/sys/class/leds`, eighteen of them | optional, and only as named presets |

Three rules that matter more than the feature list:

1. **No generic "write this path" invokable.** Themes are third-party QML
   running in the same engine as the API object. Whatever `PyraDevice` exposes,
   every theme the user ever installs can call. Enumerated actions, clamped
   ranges, no path parameter.
2. **Backlight goes through logind, not root.** `device/pyra-idle-dim` already
   proves the session owner can call `org.freedesktop.login1`'s `SetBrightness`
   for its own seat, which is why it needs no privilege and no setuid helper —
   it even takes the device name as a parameter, so the keyboard light is the
   same call. Reuse it, with `QT += dbus`. The one condition is that the caller
   has to be in the active graphical session, which a launcher is and an ssh
   shell is not.
3. **The thermal page is a display, not a control.** `pyra-thermal.service` now
   decides a frequency cap every few seconds and, since fix 6, can actually
   apply it. A slider writing `scaling_max_freq` from the launcher would be
   overwritten within one poll and would fight the one piece of thermal
   protection this machine has. If profiles are wanted later, they go through
   the daemon's configuration, not around it.

## Building it: cross, on the PC

Native building on the device was considered and dropped: 20k lines of C++ and
Qt on two Cortex-A15s means a long build at exactly the moment the thermal
daemon starts capping frequency, so it is both slow and self-slowing. The
existing pattern in `pc/pyra-crossbuild.sh` — a throwaway Debian container,
a real cross-compile, nothing installed on the host — applies directly.

**Debian's Qt 5 cross-builds without qemu**, which is the part worth knowing
before starting. Asking a trixie container for `qtbase5-dev:armhf` resolves the
libraries as armhf and the build tools as **amd64**:

    Conf qt5-qmake-bin           (amd64)
    Conf qtbase5-dev-tools       (amd64)
    Conf qtdeclarative5-dev-tools(amd64)
    Conf qtbase5-dev:armhf       (armhf)
    Conf qtdeclarative5-dev:armhf(armhf)

so `moc`, `rcc` and `qmlcachegen` run at host speed while everything they
generate is compiled for the device. No binfmt registration is needed — and
none exists on this workstation, which would otherwise have been the first
thing to trip over.

Packages: `crossbuild-essential-armhf cmake ninja-build pkg-config
qtbase5-dev:armhf qtdeclarative5-dev:armhf qtmultimedia5-dev:armhf
libqt5svg5-dev:armhf libsdl2-dev:armhf qttools5-dev-tools
libqt5sql5-sqlite:armhf`.

The toolchain file is four lines of substance, and one of them is the one that
matters:

    set(CMAKE_SYSTEM_NAME Linux)
    set(CMAKE_SYSTEM_PROCESSOR arm)
    set(CMAKE_C_COMPILER   arm-linux-gnueabihf-gcc)
    set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)
    set(CMAKE_LIBRARY_ARCHITECTURE arm-linux-gnueabihf)

`CMAKE_LIBRARY_ARCHITECTURE` is what lets `find_package(Qt5)` find
`/usr/lib/arm-linux-gnueabihf/cmake/Qt5`. A toolchain that instead sets
`CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY` with the multiarch directory as the
root fails at the first `find_package(Qt5)`, in the vendored
`SortFilterProxyModel`, which is a confusing place to meet the error.

Configure options: `-DPEGASUS_USE_SDL2_GAMEPAD=ON` (mandatory here — there is
no Qt Gamepad to fall back to), `-DPEGASUS_USE_SDL2_POWER=ON` (this is what
makes `api.device.batteryPercent` real), and `-DPEGASUS_ENABLE_LTO=OFF` for the
first build because it is slow and obscures errors.

Two repository details: clone `--recurse-submodules` (the theme, the
translations and `SortFilterProxyModel` are submodules), and pin a commit
rather than a tag — upstream's `weekly_*` tags stop at `2024w38` while master
is current.

### This has been done, once

Commit `83fd27f` cross-builds clean in a `debian:trixie` container with the
above: 394 ninja targets including the test suite, no patches, no warnings
worth repeating, and a 3.7 MB armhf binary out the other end.

    src/app/pegasus-fe: ELF 32-bit LSB pie executable, ARM, EABI5 version 1,
    dynamically linked, interpreter /lib/ld-linux-armhf.so.3

The whole container run, from `apt-get` to binary, is minutes on a desktop. A
native build on the device would be the better part of an hour by comparison,
and every minute of it at whatever frequency the thermal daemon had decided on
by then — which is the argument for doing it this way rather than a
measurement of it.

Two things cost a round trip each and are worth knowing before the first try:
`qttools5-dev:armhf` is needed as well as `qttools5-dev-tools`, because
`Qt5Config.cmake` pulls in `Qt5LinguistTools` and that config file comes from
the armhf development package; and a toolchain using
`CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY` fails to find Qt 5 at all, in the
vendored `SortFilterProxyModel`, which is a misleading place to be told about
it.

What has **not** been done is running it. The binary has never been on the
device.

## Running it on the device

- **In front of it goes `pyra-gles`.** Without the shim Pegasus will start,
  create a real EGL context and draw nothing. See `docs/qt-gles.md`.
- **Session, not replacement.** A session entry that runs
  `pyra-gles /opt/pegasus/pegasus-fe`, with MATE left installed and
  selectable. There is no reason to make this machine one-purpose.
- **Turn off X blanking for that session.** The one unfixed fault on this
  machine is a modeset that can wedge the display, and every DPMS transition is
  a modeset. A fullscreen launcher that blanks on idle is aimed straight at it.
  `pyra-idle-dim` dims the backlight and performs no modeset; that is the right
  idle behaviour here and it already exists.
- **Pick a theme with static art.** No hardware video decode.

## Maintenance, honestly

This is a patch carried against an upstream that commits weekly, and a Pyra
device object is not upstreamable as-is. Keep it as a small series against a
pinned commit, in the shape `patches/` already uses for the kernel, and expect
to rebase it occasionally. The alternative — a fork with merges — costs more
and hides what was changed.

---

## TODO

Ordered. Effort is one person's evenings, not ideal-world estimates.

- [ ] **Decide whether `pyra-gles` becomes fix 9.** Every Qt5 GLES program on
      this image renders nothing until the shim exists, which is the same class
      of silent, total failure the other eight fixes cover. Promoting it means
      `pc/pyra-trixie-prep.sh`, the prep selftest, `procedure.md` and the "six
      faults" framing in the README all change. Leaving it as a helper means
      anyone hitting the bug has to find this document first. — *your call,
      recorded in `TODO.md`*
- [ ] **Add a `pegasus` target to `pc/pyra-crossbuild.sh`.** The build itself
      is proven (above), so this is packaging it the way the other targets are
      packaged: same container pattern as `ddx`, a pinned commit, the toolchain
      file, and the binary dropped where `pyra-push-helpers.sh` can carry it
      over. — *two or three hours*
- [ ] **Get it onto the device and confirm it draws.** Under `pyra-gles`, on
      the real panel, with the frame counter on. First paint will be slow while
      shaders compile; what matters is the steady state and whether the theme's
      images fit in the 4096 texture limit. — *half a day*
- [ ] **Map the controls.** SDL2 sees `js2` as a joystick, not necessarily as a
      recognised game controller; Pegasus has in-app mapping, but check whether
      the shoulder buttons and the nubs land somewhere sane and whether an
      `SDL_GAMECONTROLLERCONFIG` entry is worth writing for this device. —
      *a few hours*
- [ ] **Write `PyraDevice`.** The C++ object, the `Api.h` registration, the
      logind D-Bus calls for both backlights, polled reads for the rest, and
      the three rules above enforced in the class rather than in the theme. —
      *1–2 days*
- [ ] **Write the menu page.** A theme fork or an overlay: brightness, keyboard
      light, battery and charger, temperatures, and the current frequency cap
      shown as a fact rather than a control. — *1 day*
- [ ] **Decide where the patch series lives.** `patches/` is kernel-only today.
      A sibling directory, or a separate repository. — *your call*
- [ ] **Measure what it costs at idle.** A QML frontend sitting on the home
      screen with animations running is not free, and this machine's idle draw
      is already the thing that decides its battery life.
      `device/pyra-cpu-attribution.sh` answers it directly. — *an hour*

## Measured here, versus assumed

Measured on the device on 2026-09-18: Qt Quick renders on the SGX through the
shim and at what speed; the trixie package availability including the absence
of `qtgamepad5-dev`; the input device list; the backlight ranges; the fuel
gauge's attribute set; the absence of `/dev/video*`. Measured on the
workstation: that Debian resolves an armhf Qt 5 dev environment with amd64 host
tools.

Built on the workstation on 2026-09-18: Pegasus `83fd27f` for armhf, from a
clean container, with the options above.

Read from the Pegasus source rather than run: the theme API surface, the engine
teardown on launch, and the shape of the `DeviceInfo` extension point.

Not done at all: running it on the device, and everything after.
