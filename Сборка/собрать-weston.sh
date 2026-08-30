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
# Опции meson можно переопределить: WESTON_MESON_OPTS="-Dfoo=bar ..."
MESON_OPTS="${WESTON_MESON_OPTS:-}"

info() { printf '\033[1;34m»\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

[[ -f "$SRC/meson.build" ]] || { err "нет исходников weston: $SRC (субмодуль не инициализирован?)"; exit 1; }
command -v meson >/dev/null || { err "нет meson"; exit 1; }
command -v ninja >/dev/null || { err "нет ninja"; exit 1; }
[[ -x "$ROOT/добавить_программу.sh" ]] || { err "нет $ROOT/добавить_программу.sh"; exit 1; }

# 1. Конфигурация meson (идемпотентно) и сборка.
info "Конфигурирую weston (meson, prefix=$PREFIX)…"
if [[ -d "$BUILD" ]]; then
    meson setup --reconfigure "$BUILD" "$SRC" --prefix="$PREFIX" $MESON_OPTS
else
    meson setup "$BUILD" "$SRC" --prefix="$PREFIX" $MESON_OPTS
fi

info "Собираю weston (ninja)…"
ninja -C "$BUILD"

# 2. Установка в /usr/local (хелперы/модули weston зовутся по абсолютным путям
#    этого префикса, а RUNPATH указывает сюда — поэтому ставим в реальный /usr/local).
info "Устанавливаю weston в $PREFIX (нужен sudo)…"
sudo ninja -C "$BUILD" install

# 3. Раскладка в rootfs. добавить_программу.sh: бинарники из /usr/local/* кладёт
#    по тем же абсолютным путям, тянет зависимости в lib64 и авто-подхватывает
#    каталоги модулей weston (libweston-*/, weston/) по RUNPATH.
info "Раскладываю weston в rootfs…"
"$ROOT/добавить_программу.sh" \
    "$PREFIX/bin/weston" \
    "$PREFIX/bin/weston-terminal" \
    "$PREFIX/libexec/weston-desktop-shell" \
    "$PREFIX/libexec/weston-keyboard"

# 4. Иконки/данные weston (их добавить_программу.sh не копирует).
info "Копирую данные weston (иконки)…"
mkdir -p "$ROOT/rootfs$PREFIX/share/weston"
cp -a "$PREFIX/share/weston/." "$ROOT/rootfs$PREFIX/share/weston/"

info "weston собран и разложен в rootfs."
