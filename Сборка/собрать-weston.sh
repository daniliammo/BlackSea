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
PREFIX="/usr/local"          # weston зовёт хелперы по абсолютным путям из этого префикса
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

info() { printf '\033[1;34m»\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

[[ -f "$SRC/meson.build" ]] || { err "нет исходников weston: $SRC (субмодуль не инициализирован?)"; exit 1; }
command -v meson >/dev/null || { err "нет meson"; exit 1; }
command -v ninja >/dev/null || { err "нет ninja"; exit 1; }
[[ -x "$ROOT/добавить_программу.sh" ]] || { err "нет $ROOT/добавить_программу.sh"; exit 1; }

# 0. Fallback-subproject'ы для wayland-стека. weston 16.0.0 требует свежие
#    wayland-protocols (>= 1.46) и wayland-scanner (>= 1.23), но объявленных
#    .wrap в апстриме не поставляет, а на рантайм-хосте (напр. GitHub runner)
#    системный wayland-стек старый (protocols 1.45, scanner 1.22) → meson падает.
#    Кладём .wrap в subprojects/ до setup, пинясь на ПОСЛЕДНИЕ релизы. Источник —
#    канонический freedesktop gitlab (надёжного github-зеркала wayland нет;
#    оттуда же тянется display-info). Теги fetch-абельны depth 1.
#    meson всё равно предпочитает системные библиотеки, где их версия годится;
#    из subproject реально собирается лишь то, чего в системе не хватает по версии
#    (здесь — wayland-scanner для wayland-protocols).
info "Готовлю wrap'ы wayland-протоколов/стека (fallback subproject'ы)…"
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

# 1. Конфигурация meson (идемпотентно) и сборка.
info "Конфигурирую weston (meson, prefix=$PREFIX)…"
# meson-info появляется только после успешной конфигурации. Если его нет
# (первый запуск или прошлый setup упал) — конфигурируем заново с чистого листа.
if [[ -d "$BUILD/meson-info" ]]; then
    meson setup --reconfigure "$BUILD" "$SRC" --prefix="$PREFIX" $MESON_OPTS
else
    rm -rf "$BUILD"
    meson setup "$BUILD" "$SRC" --prefix="$PREFIX" $MESON_OPTS
fi

info "Собираю weston (ninja)…"
ninja -C "$BUILD"

# 2. Чистим ПРЕДЫДУЩИЕ установки weston (любых версий) из префикса и rootfs.
#    Иначе при смене версии остаются старые libweston-N.so.* и каталоги модулей
#    libweston-N/, а добавить_программу.sh подхватывает их по globу libweston-*/
#    и ругается на отсутствующие зависимости снятых версий (напр. libweston-16.so.0).
LIBDIR="$PREFIX/lib/x86_64-linux-gnu"   # мультиарх-путь установки weston на этом хосте
info "Убираю прошлые установки weston из $PREFIX и rootfs…"
# shellcheck disable=SC2086  # намеренный glob-разворот путей weston
sudo rm -rf "$LIBDIR"/libweston-* "$LIBDIR"/weston \
            "$PREFIX"/bin/weston "$PREFIX"/bin/weston-* \
            "$PREFIX"/libexec/weston-*
rm -rf "$ROOT/rootfs$LIBDIR"/libweston-* "$ROOT/rootfs$LIBDIR"/weston \
       "$ROOT"/rootfs/lib64/libweston-*.so* \
       "$ROOT"/rootfs/bin/weston "$ROOT"/rootfs/bin/weston-* \
       "$ROOT"/rootfs/usr/local/libexec/weston-*

# 3. Установка в /usr/local (хелперы/модули weston зовутся по абсолютным путям
#    этого префикса, а RUNPATH указывает сюда — поэтому ставим в реальный /usr/local).
info "Устанавливаю weston в $PREFIX (нужен sudo)…"
sudo ninja -C "$BUILD" install

# 4. Раскладка в rootfs. добавить_программу.sh: бинарники из /usr/local/* кладёт
#    по тем же абсолютным путям, тянет зависимости в lib64 и авто-подхватывает
#    каталоги модулей weston (libweston-*/, weston/) по RUNPATH.
info "Раскладываю weston в rootfs…"
"$ROOT/добавить_программу.sh" \
    "$PREFIX/bin/weston" \
    "$PREFIX/bin/weston-terminal" \
    "$PREFIX/libexec/weston-desktop-shell" \
    "$PREFIX/libexec/weston-keyboard"

# 5. Иконки/данные weston (их добавить_программу.sh не копирует).
info "Копирую данные weston (иконки)…"
mkdir -p "$ROOT/rootfs$PREFIX/share/weston"
cp -a "$PREFIX/share/weston/." "$ROOT/rootfs$PREFIX/share/weston/"

info "weston собран и разложен в rootfs."
