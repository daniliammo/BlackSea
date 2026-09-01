#!/usr/bin/env bash
#
# собрать-weston.sh — собрать weston (meson/ninja) из субмодуля Программы/weston
# и разложить артефакты в rootfs. Вызывается оркестратором (основа.c) как
# спец-шаг: weston на meson, а не make, поэтому обычным правилом не собирается.
#
# Требует на хосте: meson, ninja и dev-зависимости weston (wayland, wayland-
# protocols, libinput, pixman, libxkbcommon, cairo, pango, Mesa/EGL и т.д.).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Программы/weston"
BUILD="$SRC/build"          # каталог сборки (в .gitignore weston)
PREFIX="/usr/local"          # ЛОГИЧЕСКИЙ префикс: RUNPATH и абсолютные пути хелперов
                             # weston зашиты сюда (в rootfs целевой ОС /usr/local есть).
                             # В РЕАЛЬНЫЙ /usr/local хоста НИЧЕГО не ставим — установка
                             # идёт в staging ($STAGE) через DESTDIR, без sudo и без
                             # засорения системных каталогов.
STAGE="$BUILD/stage"         # staging-каталог установки (пользовательский; = $DESTDIR)
# Лёгкий набор опций по умолчанию: цель — DRM-десктоп (pixman/GL), без удалёнок,
# X11, Lua-шелла и тест/демо-клиентов. Каждый пункт тянет свои dev-зависимости —
# отключение делает сборку и надёжнее (не падает без liblua/freerdp/…), и легче.
# Полностью переопределяется: WESTON_MESON_OPTS="-Dfoo=bar ...".
DEFAULT_MESON_OPTS="
  -Dbackend-x11=false
  -Dbackend-headless=false
  -Dxwayland=false
  -Dshell-lua=false
  -Dshell-kiosk=false
  -Dshell-ivi=false
  -Dbackend-rdp=false
  -Dbackend-vnc=false
  -Dbackend-pipewire=false
  -Drenderer-vulkan=false
  -Dsystemd=false
  -Dcolor-management-lcms=true
  -Dtests=false
  -Ddemo-clients=false
  -Dsimple-clients=
  -Dtools=terminal,debug,info
"
# Примечание: рендереры и color-lcms — dlopen-модули (gl-renderer.so,
# color-lcms.so). В память грузится только выбранный рендерер; color-lcms.so —
# лишь когда включено управление цветом. Поэтому их держим модулями, не статикой.
MESON_OPTS="${WESTON_MESON_OPTS:-$DEFAULT_MESON_OPTS}"

# sudo НЕ нужен: устанавливаем в staging-каталог ($STAGE), а не в системный /usr/local.
# Раскладку в rootfs делает добавить_программу.sh (тоже без рута). Образ (создать_образ.sh)
# по-прежнему требует рут — loop/mount/parted — но это отдельный шаг.

info() { printf '\033[1;34m»\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

[[ -f "$SRC/meson.build" ]] || { err "нет исходников weston: $SRC (субмодуль не инициализирован?)"; exit 1; }
command -v meson >/dev/null || { err "нет meson"; exit 1; }
command -v ninja >/dev/null || { err "нет ninja"; exit 1; }
[[ -x "$ROOT/добавить_программу.sh" ]] || { err "нет $ROOT/добавить_программу.sh"; exit 1; }

# 0. Fallback-subproject'ы для wayland-стека, чтобы сборка НЕ зависела от версий
#    хостовых библиотек. weston 16.0.0 требует свежие wayland-protocols (>= 1.46)
#    и wayland-scanner (>= 1.25 для protocols 1.49), но апстрим не поставляет
#    нужных .wrap, а на типовом хосте (GitHub runner, Ubuntu 24.04) стек старый
#    (protocols 1.45, scanner 1.22) → meson падает. Генерируем .wrap до setup и
#    ФОРСИМ их через --force-fallback-for (см. FORCE_FALLBACK ниже): meson тянет
#    и собирает пинованные версии из исходников, игнорируя системные. Это делает
#    сборку воспроизводимой на любом ПК (нужны лишь сурсы + тулчейн, не конкретные
#    версии libwayland-dev). Источник — канонический freedesktop gitlab (надёжного
#    github-зеркала wayland нет; оттуда же тянется display-info). Все клоны shallow
#    (depth = 1), пинятся на теги (тег fetch-абелен на depth 1, в отличие от SHA).
#    display-info оставляем на 0.2.0 — эту версию API weston 16.0.0 и поддерживает
#    (0.3/0.4 ломают сборку weston); апстримный .wrap просто дублируем с depth=1.
info "Готовлю wrap'ы wayland-стека (форсированные fallback-subproject'ы)…"
mkdir -p "$SRC/subprojects"
cat > "$SRC/subprojects/wayland-protocols.wrap" <<'WRAP'
[wrap-git]
directory = wayland-protocols
url = https://gitlab.freedesktop.org/wayland/wayland-protocols.git
revision = 1.49
depth = 1

[provide]
wayland-protocols = wayland_protocols
WRAP
cat > "$SRC/subprojects/wayland.wrap" <<'WRAP'
[wrap-git]
directory = wayland
url = https://gitlab.freedesktop.org/wayland/wayland.git
revision = 1.26.0
depth = 1

[provide]
dependency_names = wayland-client, wayland-server, wayland-cursor, wayland-egl, wayland-scanner
WRAP
cat > "$SRC/subprojects/display-info.wrap" <<'WRAP'
[wrap-git]
directory = display-info
url = https://gitlab.freedesktop.org/emersion/libdisplay-info.git
revision = 0.2.0
depth = 1

[provide]
libdisplay-info = libdisplay_info_dep
WRAP

# Патч weston 16.0.0: protocol/meson.build берёт путь до wayland-scanner ТОЛЬКО
# как pkgconfig-переменную. Когда scanner приходит из subproject (наш форс выше),
# это internal-dependency → get_variable(pkgconfig:) падает с «Could not get an
# internal variable». Апстрим для СОСЕДНЕЙ строки (pkgdatadir wayland-protocols)
# уже указывает и pkgconfig, и internal — а для scanner забыл. Правим ту же строку
# симметрично. Идемпотентно: якорь на закрывающей ')', повторный прогон — no-op.
SCANNER_MB="$SRC/protocol/meson.build"
if grep -q "get_variable(pkgconfig: 'wayland_scanner')" "$SCANNER_MB"; then
    info "Патчу protocol/meson.build: internal-fallback для wayland-scanner…"
    sed -i "s/get_variable(pkgconfig: 'wayland_scanner')/get_variable(pkgconfig: 'wayland_scanner', internal: 'wayland_scanner')/" "$SCANNER_MB"
fi

# Патч weston 16.0.0 (№2): libweston/meson.build генерит pkgconfig-файл libweston с
# «requires_private: deps_for_libweston_users» (= [dep_wayland_server, dep_pixman,
# dep_xkbcommon]). Когда wayland форсится из subproject (наш --force-fallback-for=
# wayland выше), dep_wayland_server становится InternalDependency. СТАРЫЙ meson на
# GitHub-раннере (Ubuntu 24.04 даёт meson 1.3.2) НЕ умеет класть internal-dependency
# в Requires.private → «requires argument not a string … got InternalDependency».
# (Новый meson, напр. 1.10, это уже проглатывает — потому локально не воспроизводится,
# а CI падает.) Requires.private в .pc всё равно ссылается по ИМЕНАМ pkg-config,
# поэтому заменяем список объектов на их pc-имена: валидно на ЛЮБОЙ версии meson и
# не зависит от того, системный wayland или subproject. Идемпотентно (grep-guard).
LIBW_MB="$SRC/libweston/meson.build"
if grep -q "requires_private: deps_for_libweston_users," "$LIBW_MB"; then
    info "Патчу libweston/meson.build: requires_private по pc-именам (совместимо со старым meson)…"
    sed -i "s/requires_private: deps_for_libweston_users,/requires_private: ['wayland-server', 'pixman-1', 'xkbcommon'],/" "$LIBW_MB"
fi

# Форсим wayland-стек из subproject'ов (независимость от версий хоста) и гасим
# необязательную обвязку wayland (docs/тесты/DTD-валидация тянут doxygen/xmlto/
# libxml2 — они тут не нужны и только добавляют зависимости хоста).
FORCE_FALLBACK="--force-fallback-for=wayland,wayland-protocols"
SUBPROJ_OPTS="
  -Dwayland:documentation=false
  -Dwayland:dtd_validation=false
  -Dwayland:tests=false
  -Dwayland-protocols:tests=false
"

# 1. Конфигурация meson (идемпотентно) и сборка.
info "Конфигурирую weston (meson, prefix=$PREFIX)…"
# meson-info появляется только после успешной конфигурации. Если его нет
# (первый запуск или прошлый setup упал) — конфигурируем заново с чистого листа.
if [[ -d "$BUILD/meson-info" ]]; then
    # Пытаемся переконфигурировать инкрементально. НО если build-каталог остался
    # от СТАРОЙ версии скрипта (без wayland-subproject'а), meson не знает опций
    # -Dwayland:* / -Dwayland-protocols:* и падает «Unknown option: wayland:…».
    # На чистом клоне (CI) этой проблемы нет, а на локальной машине со старым
    # build/ — есть. Ловим сбой и переконфигурируем начисто.
    meson setup --reconfigure "$BUILD" "$SRC" --prefix="$PREFIX" $FORCE_FALLBACK $SUBPROJ_OPTS $MESON_OPTS || {
        info "reconfigure не удался (старый build-каталог?) — конфигурирую начисто…"
        rm -rf "$BUILD"
        meson setup "$BUILD" "$SRC" --prefix="$PREFIX" $FORCE_FALLBACK $SUBPROJ_OPTS $MESON_OPTS
    }
else
    rm -rf "$BUILD"
    meson setup "$BUILD" "$SRC" --prefix="$PREFIX" $FORCE_FALLBACK $SUBPROJ_OPTS $MESON_OPTS
fi

info "Собираю weston (ninja)…"
ninja -C "$BUILD"

# 2. Чистим ПРЕДЫДУЩИЕ установки weston (любых версий) из rootfs. Иначе при смене
#    версии остаются старые libweston-N.so.* и каталоги модулей libweston-N/, а
#    добавить_программу.sh подхватывает их по globу libweston-*/ и ругается на
#    отсутствующие зависимости снятых версий (напр. libweston-16.so.0). Реальный
#    /usr/local НЕ трогаем (мы туда не ставим); staging пересоздаётся целиком ниже.
LIBDIR="$PREFIX/lib/x86_64-linux-gnu"   # мультиарх-подпуть (логический, внутри префикса)
info "Убираю прошлые установки weston из rootfs…"
# shellcheck disable=SC2086  # намеренный glob-разворот путей weston
rm -rf "$ROOT/rootfs$LIBDIR"/libweston-* "$ROOT/rootfs$LIBDIR"/weston \
       "$ROOT"/rootfs/lib64/libweston-*.so* \
       "$ROOT"/rootfs/bin/weston "$ROOT"/rootfs/bin/weston-* \
       "$ROOT"/rootfs/usr/local/libexec/weston-*

# 3. Установка в STAGING ($STAGE), НЕ в системный /usr/local. meson сконфигурирован
#    с --prefix=/usr/local, поэтому RUNPATH и абсолютные пути хелперов в бинарниках
#    зашиты как /usr/local/... (это верно для целевой ОС, где /usr/local есть в
#    rootfs). DESTDIR лишь СМЕЩАЕТ место записи на хосте → всё ложится в
#    $STAGE/usr/local/... . Без sudo, без засорения системы.
info "Устанавливаю weston в staging ($STAGE)…"
rm -rf "$STAGE"
DESTDIR="$STAGE" ninja -C "$BUILD" install
STAGED="$STAGE$PREFIX"                  # = $STAGE/usr/local

# 4. Раскладка в rootfs. добавить_программу.sh с DESTDIR=$STAGE: срезает staging-
#    префикс, кладёт бинарники по ЛОГИЧЕСКИМ путям /usr/local/*, тянет зависимости
#    в lib64 (ldd находит staged-либы через LD_LIBRARY_PATH) и авто-подхватывает
#    каталоги модулей weston (libweston-*/, weston/) по RUNPATH.
info "Раскладываю weston в rootfs…"
DESTDIR="$STAGE" "$ROOT/добавить_программу.sh" \
    "$STAGED/bin/weston" \
    "$STAGED/bin/weston-terminal" \
    "$STAGED/libexec/weston-desktop-shell" \
    "$STAGED/libexec/weston-keyboard"

# 5. Иконки/данные weston (их добавить_программу.sh не копирует) — из staging.
info "Копирую данные weston (иконки)…"
mkdir -p "$ROOT/rootfs$PREFIX/share/weston"
cp -a "$STAGED/share/weston/." "$ROOT/rootfs$PREFIX/share/weston/"

info "weston собран (staging, без sudo) и разложен в rootfs."
