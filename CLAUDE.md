# CLAUDE.md — ОС «Чёрное Море»

Память и зафиксированные решения проекта. Читать в начале работы; описанное
ниже — уже проверенные факты, **не переоткрывать заново**.

> ## ⚠️ ПРАВИЛО: архитектурные изменения — ТОЛЬКО с согласия пользователя
> Любое изменение АРХИТЕКТУРЫ — СНАЧАЛА спросить пользователя и получить «да»,
> потом делать. Не менять молча по своему усмотрению. Это касается, в частности:
> - выбор стека (busybox/systemd/udev/libseat-бэкенд, glibc/musl, meson/make);
> - ядро: cmdline (`init=`, `root=`, консоль), крупные `=y/=m/=n`, схема initramfs,
>   версия/пины субмодулей, набор драйверов/рендереров;
> - формат/разметка образа (GPT/разделы, ФС, ESP), загрузчик (EFI-stub vs shim/GRUB);
> - Secure Boot (db/MOK/PK, ключи), способ enroll;
> - графика/GPU (VMSVGA↔VBoxVGA, vmwgfx/vboxvideo, GL↔pixman), рендер weston;
> - структура репозитория, политика .gitignore, порядок/логика сборки (`основа.c`).
> Мелкие правки (багфиксы, опечатки, локальные фиксы скриптов) — без спроса можно,
> но если сомневаешься, «архитектура ли это» — СПРОСИ. Философия проекта: всё
> современное, БЕЗ legacy (напр. GPU — VMSVGA/vmwgfx, диск — NVMe; см. ниже).

## О проекте
Минималистичный Linux-дистрибутив на **busybox**, загрузка через **UEFI**
(ядро — EFI-stub, `EFI/BOOT/BOOTX64.EFI`). Один пользователь — **root**.
**Нет** systemd / udev / dbus / logind.

**Главная цель — нормальная графика на обычном ПК с реальным GPU** (аппаратное
ускорение, weston на GL-рендере через Mesa и родной DRM-драйвер). VirtualBox /
QEMU и программный рендер (pixman) — это **только для разработки, отладки и
fallback**, не конечная цель. См. раздел про рендер ниже.

## Структура репозитория
- `rootfs/` — корневая ФС (попадает в образ). Библиотеки — в `lib64`.
  **В гите только ИСХОДНИКИ** (конфиги `etc/*`, скрипты `bin/run-weston`, `bin/ldd`,
  данные `usr/local/share/weston/*`). **Ни ELF-бинарников, ни `.so`, ни
  busybox-symlink'ов** — всё это порождается сборкой и лежит только локально/в образе.
- `boot/bzImage` — собранное ядро (**артефакт, в .gitignore**).
- `Программы/` — исходники программ (субмодули + обычные папки).
- `Сборка/` — оркестратор и скрипты сборки:
  - `основа.c` → `Собранное/Сборка` (оркестратор; бинарник в .gitignore),
  - `создать_образ.sh` (создаёт `.img`; нужен **sudo**: loop/parted/mount),
  - `конвертировать_образ.sh` (`.img` → `.vdi` через VBoxManage, `.qcow2` через qemu-img),
  - `update-kernel.sh`, `strip-config.sh` — обслуживание ядра (**ручные**),
  - `ядро.config`, `busybox.config` — версионированные копии kbuild-конфигов
    (в самих субмодулях их нет; сборка кладёт их на место перед `make`),
  - `собрать-weston.sh` — сборка weston (meson/ninja) и раскладка в rootfs.
- `добавить_программу.sh` — утилита «закинуть ELF-программу в rootfs».
- `ЗАДАЧИ.md` — анализ проекта и TODO.
- `ОбразыДляЗагрузки/` — выходные образы (в .gitignore).
- `.github/workflows/ci.yml` — CI: ОДНО задание (`apt` зависимостей + `make -C Сборка`,
  как на обычном ПК; ccache-кэш ядра; без VBoxManage → артефакт только qcow2).

## Как собирать
```
cd Сборка && make          # оркестратор: программы → образ → конвертация
```
`основа.c`: собирает каталоги `Программы/*`, **только если есть Makefile**;
ядро собирает **только `bzImage`**; кладёт артефакты
(`Ядро`→`boot/bzImage`, `Инициализация`→`rootfs/sbin/init`, прочее: `.so*`→`lib64`,
остальное→`bin`); затем запускает скрипты образа из `Сборка/`. Особые случаи:
- **`busybox`** — свой kbuild: копирует `Сборка/busybox.config`→`.config`, `make
  olddefconfig`, собирает бинарник и `make CONFIG_PREFIX=…/rootfs install`
  (раскладывает applet-symlink'и прямо в rootfs; `INSTALL_APPLET_SYMLINKS=y`).
- **`weston`** — на meson, а не make: делегируется `Сборка/собрать-weston.sh`.
Одна ошибка модуля НЕ рвёт сборку — считается и идёт дальше; в конце печатается
**итог `собрано/ошибок/пропущено`**. Ctrl-C (SIGINT/SIGTERM) обрабатывается
корректно: текущий модуль завершается, печатается итог, код возврата 130.
При ошибках образ не создаётся.
Скрипты образа сами находят корень репозитория (`SCRIPT_DIR/..`), запускаются откуда угодно.

## Субмодули (политика shallow)
- **Чужие upstream — shallow, запинены на РЕЛИЗНЫЙ ТЕГ** (тег всегда fetch-абелен
  на depth 1, в отличие от произвольного dev-SHA): `Ядро` (тег vX.Y),
  `weston` (16.0.0), `busybox` (1_38_0). `shallow = true` в `.gitmodules`.
- **Свои репозитории — полные** (без shallow): `Инициализация`, `ТранспиляторКонда`,
  `KondaFromClang`. Их разрабатывают → нужна история (`log`/`blame`/`bisect`), а
  экономии от shallow почти нет.
- НЕ пинить shallow-субмодуль на произвольный коммит: `git submodule update --depth 1`
  у клонирующих не сможет его дотянуть (freedesktop/kernel.org не отдают SHA shallow).
- **ПРАВИЛО клонирования любых репозиториев (субмодули И `.wrap`-subproject'ы weston):
  история коммитов НЕЖЕЛАТЕЛЬНА** — клонируем **shallow** (`--depth 1` / `depth = 1`,
  пин на тег): быстрее, меньше трафика, надёжнее на CI. Полную историю тянуть, только
  **если без неё никак** (наши разрабатываемые репы — им нужен `log`/`blame`/`bisect`).
  **Источник — по возможности GitHub, а не GitLab, для надёжности** (github стабильнее
  на клонах из CI). Исключение — где github-зеркала объективно нет: весь wayland-стек
  (`wayland`, `wayland-protocols`, `libdisplay-info`) живёт ТОЛЬКО на
  `gitlab.freedesktop.org` (проверено: `github.com/{wayland-project,emersion}/…` не
  существуют) → для него оставляем freedesktop gitlab, shallow.

## Зафиксированные решения (НЕ переоткрывать)

### Загрузчик и библиотеки
- **ld-linux (glibc 2.43, хостовый) НЕ ищет в `/lib`** — только `/lib64`, `/usr/lib64`
  (+ `/lib`, `/usr/lib` у нового loader). Дистрибутив держит все `.so` в **`/lib64`**.
- **Обязателен `/etc/ld.so.cache`** — генерируется автоматически в `создать_образ.sh`
  (`ldconfig -r rootfs`). Без него не грузится даже `libc.so.6`. Пути — в
  `rootfs/etc/ld.so.conf` (версионируется через `!`-исключение в .gitignore).
- **glibc = хостовый 2.43** (нужен weston). Связка `libc/libm/libresolv/ld-linux`
  должна быть из одной сборки, иначе «version not found» / «cannot find».

### .gitignore — репозиторий только с исходниками
- **Принцип: в гите нет ни одного ELF-бинарника и ни одной `.so`.** Всё бинарное —
  артефакт сборки, лежит локально/в образе, но не версионируется.
- Игнорируются: `*.so`, `*.so.*`; артефактные каталоги rootfs целиком —
  `/rootfs/bin/*`, `/rootfs/sbin/*`, `/rootfs/lib/*`, `/rootfs/lib64/*`,
  `/rootfs/usr/local/bin/*`, `/rootfs/usr/local/libexec/*`; `/boot/bzImage`;
  `/rootfs/etc/ld.so.cache` (генерит ldconfig).
- **Исходники среди артефактов** возвращаются через `!`-исключения:
  `!/rootfs/bin/run-weston`, `!/rootfs/bin/ldd`. Добавляешь новый исходный скрипт
  в `rootfs/bin` → добавь такое же `!`-исключение (иначе он попадёт под `/rootfs/bin/*`).
- НЕ делай `git add -f` для `.so`/ELF — это нарушает принцип. Их приносит сборка.
- **CI собирает бинарники в rootfs сам — ОДНИМ заданием `cd Сборка && make`**
  (как на обычном ПК; см. `.github/workflows/ci.yml`). Джоб `build`: checkout →
  init загрузочных субмодулей (`Ядро`, `busybox`, `Инициализация`, `weston`,
  depth 1) → `apt` зависимостей → `make -C Сборка`. Оркестратор `основа.c` сам
  строит ядро (bzImage), busybox, init, weston и создаёт образ. **НЕ дублируем
  шаги сборки в YAML** — это было раньше (3 джоба checks/kernel/image) и
  расходилось с `основа.c`; теперь один источник правды. Досев загрузчика
  `ld-linux` делает **`создать_образ.sh`** (не отдельный шаг CI) — потому `make`
  самодостаточен и на чистом клоне (см. «Загрузка/init»). Ядро кэшируется между
  прогонами через **ccache** (единственное ускорение: `PATH=/usr/lib/ccache` +
  `actions/cache`). VBoxManage на раннере нет → конвертация даёт только qcow2
  (артефакт), Secure Boot-enroll пропускается (не рвётся).

### Ядро
- Собирается **только `bzImage`** (без модулей). Модули (`=m`) **не устанавливаются**,
  поэтому всё нужное должно быть **`=y`**.
- Конфиг — в `Сборка/ядро.config` (в субмодуле `Ядро` его нет: это upstream torvalds/linux).
  Локальная сборка и CI копируют его в `Программы/Ядро/.config`.
- Встроено (`=y`) для weston/VM: `INPUT_EVDEV`, `MOUSE_PS2`, `HID`, `USB_HID`,
  `HID_GENERIC`, `DRM_VBOXVIDEO`, `DRM_VMWGFX`, `DRM_VIRTIO_GPU`, `DRM_SIMPLEDRM`,
  `HYPERVISOR_GUEST`.
- `update-kernel.sh` (обновляет версию ядра) и `strip-config.sh` (режет конфиг) —
  **ручные**, НЕ в пайплайне сборки (иначе ломают воспроизводимость).
- **Сжатие — везде zstd**: образ ядра, initrd, hibernation, zswap, zram, а также
  ФС (f2fs/squashfs/erofs). `CONFIG_ZSTD_COMPRESS`/`CRYPTO_ZSTD` = `=y` (не `=m`):
  zswap встроен и должен иметь zstd на старте. XZ-декодеры оставлены только для
  x86 (POWERPC/ARM/…/RISCV выключены — ядро x86_64-only).

### Secure Boot (подпись ядра)
- Дистрибутив грузится как **голый EFI-stub** (`bzImage`→`EFI/BOOT/BOOTX64.EFI`,
  `CONFIG_EFI_STUB=y`), **без shim и GRUB**. Значит прошивка проверяет подпись
  ИМЕННО самого `bzImage` → подписываем его PE-подписью через **`sbsign`** нашим
  самоподписанным ключом (RSA-2048/SHA-256). shim не нужен.
- **`Сборка/подписать_ядро.sh`**: создаёт пару `db.key`/`db.crt`/`db.der` в
  `Сборка/ключи-secureboot/` (**приватный ключ в .gitignore, не в образе!**) и
  подписывает EFI-файл. `создать_образ.sh` зовёт его на шаге копирования ядра;
  подписанный образ грузится и при выключенном SB, поэтому подписываем **всегда**.
  `SECUREBOOT=0` или отсутствие `sbsign`/`openssl` → кладём неподписанное ядро
  (сборка/CI не рвётся, лишь предупреждение).
- **VirtualBox 7.x** эмулирует Secure Boot через `VBoxManage modifynvram`
  (правится на **выключенной** VM). **`Сборка/включить_secureboot.sh <VM>`**:
  `inituefivarstore` → `enrollmssignatures` (создаёт db/KEK) → `changevar
  --name=db --filename=db.esl` (ПЕРЕЗАПИСЫВАЕМ db НАШИМ сертификатом) →
  `enrollorclpk` (штатный Oracle PK → user mode) → `secureboot --enable`. Именно
  **db**, НЕ MOK: голый EFI-stub без shim прошивка проверяет только по db;
  `enrollmok` кладёт ключ в MokList (его читает shim, не прошивка) → «нет ОС».
  Проверено экспериментально. Проверка «работает»: чужое/неподписанное ядро →
  отказ загрузки.
- **Enroll делается АВТОМАТИЧЕСКИ в сборке**: `конвертировать_образ.sh` после
  создания `.vdi` зовёт `включить_secureboot.sh` для VM **`ЧерноеМоре`** (имя
  захардкожено). Нет VBoxManage или нет такой VM → подробное сообщение (что
  поставить/как назвать VM), сборка не рвётся. **SB в GUI VirtualBox включать
  НЕЛЬЗЯ** — галка вкатывает стоковые MS-ключи, наш ключ теряется. Только скрипт.
- **Подпись ядра — тоже автоматически** (`создать_образ.sh` зовёт
  `подписать_ядро.sh` на шаге копирования EFI); отдельно запускать не нужно.
- Для реального железа / QEMU+OVMF та же связка: подписать тем же ключом, а
  `db.der` вкатить в `db` прошивки (в QEMU — через OVMF VARS / `enroll-keys`).

### `добавить_программу.sh`
- Зависимости (`ldd`, весь граф) → `rootfs/lib64`.
- Бинарник: источник из **`/usr/local/*`** → тот же **абсолютный путь** в rootfs
  (их зовут абсолютно: weston грузит хелперы из `/usr/local/libexec`,
  desktop-shell — `/usr/local/bin/weston-terminal`); иначе → `rootfs/bin`.
- Аргумент-каталог (dlopen-модули) зеркалируется по абсолютному пути + deps.
- `auto_weston_modules`: подхватывает `libweston-*/` и `weston/` по RUNPATH.
- `ensure_glibc`: обновляет glibc в rootfs, если требуется более новая версия символов.
- **`DESTDIR=<staging>`** (опц.): программа установлена не в реальный `/usr/local`, а в
  staging (`$DESTDIR/usr/local/…`). Скрипт **срезает** `$DESTDIR` → кладёт по логическим
  путям `/usr/local/*` в rootfs (как в RUNPATH), а `ldd` ищет staged-либы через
  `LD_LIBRARY_PATH` на staging. Так `собрать-weston.sh` ставит weston без sudo/системы.
  Пусто → прежнее поведение (источник = реальный `/usr/local`).

### Weston (рабочая конфигурация)
- **seat**: `LIBSEAT_BACKEND=builtin` — встроенный бэкенд libseat, **без демона seatd
  и без logind** (logind не работает — нет systemd-сессии).
- **рендер**:
  - **Цель (обычный ПК): GL-рендер на реальном GPU** — нужны Mesa
    (`libgallium`, `libLLVM`, `dri/*_dri.so` → симлинки на `libdril_dri.so`,
    `gbm/dri_gbm.so`) в rootfs + родной DRM-драйвер GPU (`i915`/`amdgpu`/`nouveau`)
    как `=y` в ядре. Это ещё НЕ сделано — основная задача.
  - **Fallback/дебаг (VM): pixman** (`/etc/xdg/weston/weston.ini` →
    `[core] renderer=pixman` + флаг в `run-weston`). Без Mesa, программный рендер.
    Использовать только для отладки; для реальной работы вернуть GL-рендер.
  - **Рендереры/модули — как в ядре Linux (dlopen).** weston грузит бэкенды и
    рендереры через `weston_load_module()` только по требованию: `gl-renderer.so`,
    `vulkan-renderer.so`, `color-lcms.so`, `xwayland.so`, `drm-backend.so` —
    отдельные `.so` в `libweston-17/`. В память грузится **только выбранный**
    рендерер (pixman вкомпилен в libweston как крохотный fallback; gl-renderer.so
    подгружается только при GL). Поэтому их держим модулями, не статикой.
- **управление цветом**: `color-management-lcms=true` → модуль `color-lcms.so`
  (грузится по требованию), зависит от `liblcms2.so.2` (в rootfs есть). Для
  откалиброванных цветов; ICC-профиль задаётся в weston.ini на выход.
- **GPU в VirtualBox**: графика **VMSVGA** → драйвер ядра **`vmwgfx`** (современный
  стек). Это ОСОЗНАННЫЙ выбор: система принципиально БЕЗ legacy — никаких
  VBoxVGA/`vboxvideo`. На реальном железе — родной GPU-драйвер + Mesa (см. выше).
  (Историческая заметка: раньше в этом файле стоял VBoxVGA — отменено по решению
  пользователя, держим всё новое.) `DRM_VMWGFX`/`DRM_SIMPLEDRM` в ядре = `=y`.
- **ввод**: **libudev-zero** заменяет `libudev.so.1` — синтезирует `ID_INPUT`/`ID_SEAT`
  из sysfs **без udevd**. Systemd-libudev без демона не помечает устройства → libinput
  их не видит. (Символы клиентов покрыты: libinput/libgudev/libwacom.)
- **раскладки**: `rootfs/usr/share/X11/xkb` → `xkeyboard-config-2` (данные в rootfs).
- **терминал**: `weston-desktop-shell` зовёт `/usr/local/bin/weston-terminal`
  (абсолютно). Нужны: иконки `/usr/local/share/weston/`, шрифты + fontconfig
  (`/etc/fonts`, `/usr/share/fontconfig`, DejaVu Sans Mono), и **`/dev/pts`** (devpts;
  `weston-terminal` использует `forkpty`).
- **запускать через `rootfs/bin/run-weston`** (не голый `weston`).
- **источник/сборка weston**: субмодуль **`Программы/weston`** (shallow, `shallow = true`),
  запинен на тег **`16.0.0`**. Система сборки — **meson**. Оркестратор собирает его
  спец-шагом (`основа.c` видит имя `weston` → запускает **`Сборка/собрать-weston.sh`**):
  `meson setup build` → `ninja` → `DESTDIR=<staging> ninja install` → раскладка в
  rootfs через `добавить_программу.sh` (бинарники+deps+модули) + копирование иконок
  `/usr/local/share/weston`. Опции meson переопределяются `WESTON_MESON_OPTS`.
  Требует dev-зависимости weston на хосте (wayland, wayland-protocols, libinput,
  pixman, libxkbcommon, cairo, pango, Mesa/EGL).
- **weston НЕ ставится в системный `/usr/local` — только в staging, БЕЗ sudo**
  (решение пользователя: не засорять системные каталоги). `meson --prefix=/usr/local`
  оставляем (в бинарники зашиты RUNPATH и абсолютные пути хелперов `/usr/local/…`,
  и это верно для целевой ОС — в её rootfs `/usr/local` есть), но `ninja install`
  идёт под `DESTDIR="$BUILD/stage"` → всё ложится в `stage/usr/local/…` на хосте.
  `добавить_программу.sh` вызывается с `DESTDIR=$STAGE`: **срезает staging-префикс**
  (кладёт по ЛОГИЧЕСКИМ путям `/usr/local/*` в rootfs), а `ldd` находит staged-либы
  (libweston-*, libwayland из subproject'а) через `LD_LIBRARY_PATH` на staging. При
  пустом `DESTDIR` поведение прежнее. Итог: `собрать-weston.sh` рут не требует НИГДЕ
  (ни локально, ни на CI); образ (`создать_образ.sh`) рут по-прежнему требует —
  loop/mount/parted. ⚠ ЛЕГАСИ: если от СТАРОГО подхода в `build/` остались root-файлы
  (`sudo ninja install` писал `meson-logs/install-log.txt` от рута) → новый install
  падает `PermissionError`; починка разовая: `sudo chown -R "$USER" Программы/weston/build`.
  ВНИМАНИЕ: рабочая сборка пользователя — dev-снапшот **16.0.90 / 29d5739d
  (libweston-17)**, на 29 коммитов новее тега. Точный dev-коммит нельзя запинить
  shallow (freedesktop не отдаёт произвольный SHA / нет тега), поэтому субмодуль на
  ближайшем релизе 16.0.0. При пересборке weston из субмодуля версия/soname может
  отличаться — тогда просто заново прогнать `добавить_программу.sh` (обновит rootfs
  согласованно). Для точной сборки 29d5739d — держать отдельный полный клон.
- **wayland-стек — форсированные fallback-subproject'ы (НЕ зависим от версий хоста).**
  weston 16.0.0 требует свежие `wayland-protocols` (>= 1.46) и `wayland-scanner`
  (>= 1.25 для protocols 1.49), а типовой хост (Ubuntu 24.04 / GitHub runner) даёт
  старьё (protocols 1.45, scanner 1.22) → meson падал. `собрать-weston.sh` перед
  `meson setup` генерит `subprojects/*.wrap` и форсит их `--force-fallback-for=`
  `wayland,wayland-protocols`: meson СОБИРАЕТ пинованные версии из исходников,
  игнорируя системные. Так сборка воспроизводима на любом ПК из одних сурсов.
  Пины: `wayland 1.26.0`, `wayland-protocols 1.49`, `display-info 0.2.0` (0.3/0.4
  ломают API weston 16 — НЕ поднимать). Все .wrap — `depth = 1` на тег. Обвязка
  wayland (docs/tests/dtd_validation) выключена — иначе тянет doxygen/xmlto/libxml2.
  Билд-deps хоста для сборки wayland из сурсов: **`libffi-dev`, `libexpat1-dev`**
  (добавлены в `ci.yml`). Апстримные .wrap (в самом субмодуле) не поставляют
  wayland/wayland-protocols и не переживают чистый клон на теге — потому генерим
  из скрипта. `edid-decode` (nested-wrap в display-info, `git.linuxtv.org`) иногда
  отдаёт 502 — НЕ фатально: display-info отключает его (нужен лишь своим тестам).
  Плюс `собрать-weston.sh` патчит `protocol/meson.build` (sed, идемпотентно): у
  weston 16.0.0 там `get_variable(pkgconfig: 'wayland_scanner')` без internal-
  фолбэка → при scanner из subproject (internal-dependency) падает «Could not get
  an internal variable». Дописываем `internal: 'wayland_scanner'` — ровно как
  апстрим уже делает строкой ниже для `pkgdatadir` wayland-protocols.
- **Патч weston 16.0.0 №2 (`libweston/meson.build`, sed, идемпотентно) — совместимость
  со СТАРЫМ meson на раннере.** `libweston/meson.build:173` генерит pkgconfig-файл
  libweston с `requires_private: deps_for_libweston_users` (= `[dep_wayland_server,
  dep_pixman, dep_xkbcommon]`). Когда wayland форсится из subproject'а (наш
  `--force-fallback-for=wayland`), `dep_wayland_server` — это **InternalDependency**.
  **Старый meson (Ubuntu 24.04 / GitHub runner даёт 1.3.2)** НЕ умеет класть
  internal-dependency в `Requires.private` → падает `ERROR: requires argument not a
  string … got <InternalDependency …>`. **Новый meson (≥ ~1.10) это проглатывает**
  (резолвит pc-имя из `override_dependency`) — поэтому ЛОКАЛЬНО (свежий meson) сборка
  проходит, а на CI со старым meson падает. Скрипт заменяет список объектов на их
  **pkg-config-имена-строки** `['wayland-server', 'pixman-1', 'xkbcommon']` — валидный
  `Requires.private` на ЛЮБОЙ версии meson и независимо от того, системный wayland или
  subproject. Симптом на CI, если патч не сработал: ошибка `requires argument not a
  string` в `libweston/meson.build`. (Альтернатива — поднять meson на раннере ≥1.10,
  но патч надёжнее: не зависит от версии тулчейна хоста, в духе воспроизводимости.)

### Загрузка / init
- **cmdline ядра — из встроенного `CONFIG_CMDLINE`** (голый EFI-stub грузится
  прошивкой напрямую, LoadOptions нет; startup.nsh в EFI Shell — запасной путь).
  Содержит **`init=/sbin/init`** явно: так при сбое init ядро даёт ПОНЯТНУЮ панику
  `Requested init … failed (error -N)` с errno (−2 ENOENT/нет интерпретатора,
  −8 ENOEXEC, −13 EACCES, −5 EIO), а не тихий перебор `/sbin/init→/etc/init→…`.
- **`основа.c` при сборке ядра КОПИРУЕТ `Сборка/ядро.config`→`.config` + `make
  olddefconfig`** (как busybox), потом `make bzImage`. Значит `Сборка/ядро.config`
  — ЕДИНСТВЕННЫЙ источник правды для cmdline/фич; поправил конфиг → пересборка
  ядра применит. (Раньше не копировал → правки cmdline не доезжали, ядро было
  «устаревшим». `make olddefconfig` переформатирует .config — точного diff с
  эталоном не будет, но значения применяются.)
- **Симптом «ядро перебирает `/sbin/init → /etc/init → /bin/init`»** (или паника
  `No working init found`): execve init провалился. Причины: (1) `/sbin/init` стал
  СИМЛИНКОМ на busybox (регрессия busybox `make install` — наш init затёрт);
  (2) нет интерпретатора `lib64/ld-linux-x86-64.so.2` / `lib64/libc.so.6`.
  `создать_образ.sh` СТРАХУЕТ: `/sbin/init` — настоящий ELF (не симлинк), и что
  загрузчик и libc на месте, иначе стоп. **Загрузчик `ld-linux` он же ДОСЕВАЕТ**
  из хостового `/lib64` (или `/lib/x86_64-linux-gnu`), если его нет в rootfs:
  `добавить_программу.sh` его намеренно пропускает, а на чистом клоне/CI без
  досева проверка бы валилась. Так `cd Сборка && make` самодостаточен на любом ПК
  (отдельный CI-шаг для загрузчика больше не нужен). Выходной каталог
  `ОбразыДляЗагрузки/` тоже создаётся скриптом (`mkdir -p`) — git не хранит пустые
  папки. **Инспекция образа БЕЗ рута**: `dd` вырезать ext4-раздел (offset из
  `fdisk -l img`) → `debugfs -R "stat/dump …"`.
- **fstab БЕЗ `/boot`**: минимальной ОС ESP на рантайме не нужен, а строка
  `PARTUUID=77A7-77A7 /boot vfat` ломала `mount -a` (77A7-77A7 — FAT-серийник, не
  PARTUUID; busybox не резолвит). Нужен ESP — монтировать вручную.
- **СНИМКИ VirtualBox ЛОМАЮТ загрузку** (было причиной `error -2`/`No working init
  found` при исправном образе!). VM грузит дельту снимка ПОВЕРХ базового диска, а
  `конвертировать_образ.sh` каждую сборку ПЕРЕЗАПИСЫВАЕТ базовый `.vdi` (пиннит
  UUID) → старые блоки снимка перекрывают свежий rootfs, ядро не находит init.
  Диск у VM — **NVMe** (`CONFIG_BLK_DEV_NVME=y`, ОК; новый стек, не legacy). Правило:
  **НЕ делать снимки** этой VM. `конвертировать_образ.sh` предупреждает, если снимки
  есть. Убрать: `storageattach … --medium none` → `snapshot delete` → заново
  `storageattach … --medium ОСЧерноеМоре.vdi`. Проверка образа без рута — см. выше.
- **`/etc/profile` НЕ читается на загрузке** — init запускает `/bin/sh` как
  НЕ-login shell (признак: простой `#`, а не цветной PS1). Поэтому весь
  рантайм-сетап (PATH, `XDG_RUNTIME_DIR`, `LIBSEAT_BACKEND`, монтирование `/dev/pts`)
  живёт в **`run-weston`**, а не в профиле.
- **devtmpfs перекрывает `/dev`** — статические файлы в `rootfs/dev` не видны;
  `/dev/pts` создаётся и монтируется **в рантайме** (в `run-weston`).
- `создать_образ.sh` создаёт стандартные пустые каталоги-точки монтирования
  (`proc, sys, dev, run, tmp, mnt, root, home`) — git не хранит пустые папки.
- `fstab`: `proc`, `sys`, `/run` (tmpfs), `/tmp` (tmpfs), `/boot`.

## Гочи
- **Кириллица**: bash-переменные НЕ могут быть кириллицей (в C с gcc — можно).
  Имена запускаемых из VM-консоли скриптов — **ASCII** (в консоли нельзя переключить
  раскладку). Пример: `run-weston`, а не `запуск-weston`.
- Скрипты образа требуют **sudo** (loop, mount, parted) — запускать в терминале
  пользователя, не в песочнице.
- **ESP держать ≥ 48 МБ**: FAT32 требует ≥65525 кластеров; на меньшем разделе
  `mkfs.vfat -F32` делает невалидный FAT32 и UEFI VirtualBox не грузится.
- Сборка ядра тяжёлая по диску: `make clean` в дереве ядра освобождает ~4–5 ГБ;
  собирать только `bzImage`.
- Оркестратор `Собранное/Сборка` в .gitignore — при правке `основа.c` пересобрать
  (`make` в `Сборка/`), иначе запускается старый бинарник.

## Коммиты
- **ОБЯЗАТЕЛЬНО коммитить после выполненной работы** — не оставлять сделанное
  незакоммиченным. По умолчанию коммит делается САМ по завершении задания (спрашивать
  разрешение на `git commit` не нужно; `git push` — только по явной просьбе).
- **Коммитить отдельно по смыслу заданий**: одна логически цельная задача → один
  коммит (не сваливать несвязанные правки в один; не дробить одну задачу без нужды).
  Сообщение — на русском, по сути изменения.
- Исключения из коммитов — см. «Не трогать в коммитах» ниже.

## Не трогать в коммитах
- `Программы/СтандартнаяБиблиотекаКонда` — по указанию пользователя исключать.
- `Программы/KondaZed/konda-grammar` — вложенный git-репозиторий, оставлять untracked.
