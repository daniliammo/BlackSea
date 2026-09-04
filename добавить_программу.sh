#!/usr/bin/env bash
#
# добавить_программу.sh — закинуть ELF-бинарник (или каталог модулей) и все
# его зависимости в rootfs минимального дистрибутива.
#
# Использование:
#   ./добавить_программу.sh /путь/к/бинарнику [ещё/бинарник | каталог ...]
#   ./добавить_программу.sh $(which weston)          # weston + авто-модули
#
# Что делает:
#   * определяет зависимости через ldd (весь транзитивный граф);
#   * бинарник  → rootfs/bin/;
#   * .so-зависимости → rootfs/lib64/  (именно lib64 — только его и /usr/lib64
#       ищет загрузчик этого дистрибутива, /lib НЕ в путях поиска!);
#   * если передать каталог — все *.so из него зеркалируются в rootfs по тем же
#       АБСОЛЮТНЫМ путям (нужно для плагинов, которые грузятся через dlopen,
#       например бэкенды weston: drm-backend.so, gl-renderer.so, desktop-shell.so),
#       и их зависимости тоже тянутся в lib64;
#   * для weston каталоги модулей подхватываются автоматически;
#   * пропускает то, что уже есть (libc, ld-linux, vdso).
#
# После этого пересобери образ:  ./создать_образ.sh
#
set -euo pipefail

# ── Настройки ────────────────────────────────────────────────────────────────
ROOTFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rootfs"
BIN_DIR="$ROOTFS_DIR/bin"        # куда класть бинарники
LIB_DIR="$ROOTFS_DIR/lib64"      # куда класть зависимости (единственный искомый путь)

STRIP="${STRIP:-0}"              # STRIP=1 — ужать strip'ом (экономит место)
AUTO_WESTON="${AUTO_WESTON:-1}"  # 0 — не подхватывать каталоги модулей weston
UPDATE_LIBC="${UPDATE_LIBC:-1}"  # 1 — автоматически обновлять glibc в дистрибутиве,
                                 #     если программе нужен более новый GLIBC_*
INSTALL_AS="${INSTALL_AS:-}"     # если задан — класть бинарник ИМЕННО по этому пути
                                 #     ВНУТРИ rootfs (напр. /sbin/init), а не в bin/ по
                                 #     эвристике. Зависимости всё равно идут в lib64.
                                 #     Так оркестратору не нужно копировать ELF самому:
                                 #     скрипт и кладёт бинарник, и досевает его либы —
                                 #     единым вызовом (не остаётся программы без нужной
                                 #     библиотеки; был инцидент: init на Konda линкуется
                                 #     с libjemalloc.so.2, при прямом копировании её не
                                 #     клали в lib64 → init не грузился).

# DESTDIR — если задан, программа установлена в STAGING-каталог: на диске файлы лежат
# по $DESTDIR + логический путь (напр. $DESTDIR/usr/local/bin/weston), а «логический»
# путь (для rootfs и как в RUNPATH бинарника) — БЕЗ него (/usr/local/bin/weston).
# Позволяет раскладывать weston, установленный в свой каталог через `DESTDIR=… ninja
# install`, НЕ трогая системный /usr/local и без sudo. Пусто → прежнее поведение.
DESTDIR="${DESTDIR:-}"
DESTDIR="${DESTDIR%/}"           # без хвостового слэша (чтобы срез префикса был точным)

# Откуда брать связку glibc при обновлении (обычный путь на хосте).
HOST_LIBC_DIR="${HOST_LIBC_DIR:-/usr/lib/x86_64-linux-gnu}"
HOST_LD="${HOST_LD:-/lib64/ld-linux-x86-64.so.2}"

# ── Вывод ────────────────────────────────────────────────────────────────────
info() { printf '\033[1;34m»\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m·\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

# ── Проверки ─────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    err "Не указан путь к бинарнику."
    echo "Использование: $0 /путь/к/бинарнику [каталог-модулей ...]" >&2
    echo "Пример:        $0 \$(which weston)" >&2
    exit 1
fi
[[ -d "$ROOTFS_DIR" ]]     || { err "Не найден rootfs: $ROOTFS_DIR"; exit 1; }
command -v ldd >/dev/null  || { err "нет ldd"; exit 1; }

mkdir -p "$BIN_DIR" "$LIB_DIR"

# Библиотека уже есть в дистрибутиве (lib64 или lib) — не дублируем.
have_lib() { [[ -e "$LIB_DIR/$1" || -e "$ROOTFS_DIR/lib/$1" ]]; }

# Ужать strip'ом при STRIP=1.
maybe_strip() {
    if [[ "$STRIP" == "1" ]] && command -v strip >/dev/null; then
        strip --strip-unneeded "$1" 2>/dev/null || true
    fi
}

# Логический путь = путь на диске без DESTDIR-префикса (если задан и присутствует).
# Это путь, по которому файл кладётся в rootfs и на который указывает RUNPATH.
logical_path() {
    local p="$1"
    if [[ -n "$DESTDIR" && "$p" == "$DESTDIR"/* ]]; then
        printf '%s' "${p#"$DESTDIR"}"
    else
        printf '%s' "$p"
    fi
}

# ldd с учётом staging: RUNPATH бинарника указывает на ЛОГИЧЕСКИЙ /usr/local/lib/…,
# которого на хосте нет — там внутренние либы weston (libweston-*.so) и libwayland
# из subproject'а. Даём ldd найти их в staging через LD_LIBRARY_PATH. Внешние
# зависимости (cairo/pango/glibc) по-прежнему берутся из системного кэша.
run_ldd() {
    if [[ -n "$DESTDIR" ]]; then
        local wl="$DESTDIR/usr/local/lib/x86_64-linux-gnu"
        # Плюс подкаталоги модулей weston (weston/, libweston-*/): там лежит
        # libexec_weston.so.0, на которую ссылается сам бинарник weston (его RUNPATH
        # указывает в эти каталоги). Без них ldd её не находит → шумное «не найдена
        # зависимость» (не фатально, но лог грязный) и она не попадала бы в lib64.
        local extra="" d
        for d in "$wl"/weston "$wl"/libweston-*; do
            [[ -d "$d" ]] && extra="$extra:$d"
        done
        LD_LIBRARY_PATH="$wl:$DESTDIR/usr/local/lib$extra${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$@"
    else
        ldd "$@"
    fi
}

# Скопировать зависимость по SONAME в lib64 (реальный файл, cp -L).
copy_lib() {
    local name="$1" path="$2"
    have_lib "$name" && { skip "уже есть: $name"; return; }
    cp -L "$path" "$LIB_DIR/$name"
    chmod 0755 "$LIB_DIR/$name"
    maybe_strip "$LIB_DIR/$name"
    ok "библиотека → lib64/$name"
}

# Разобрать ldd и растащить зависимости в lib64.
resolve_deps() {
    local elf="$1" line name path
    run_ldd "$elf" >/dev/null 2>&1 || { skip "ldd не разобрал ($elf) — без зависимостей"; return; }
    while read -r line; do
        [[ "$line" == *"=>"* ]] || continue
        name="${line%% =>*}"; name="${name##*/}"
        path="${line#*=> }"; path="${path%% (0x*}"
        [[ -z "$path" || "$path" == *"not found"* ]] && { err "не найдена зависимость: $name"; continue; }
        [[ -e "$path" ]] || { err "нет файла зависимости: $path"; continue; }
        [[ "$name" == ld-linux* || "$name" == ld-*.so* ]] && continue
        copy_lib "$name" "$path"
    done < <(run_ldd "$elf")
}

# Обработать один бинарник → bin/ + зависимости.
process_bin() {
    local bin="$1"
    [[ -f "$bin" ]] || { err "Файл не найден: $bin"; return 1; }
    file -b "$bin" | grep -q 'ELF' || { err "Не ELF-файл: $bin"; return 1; }
    local binname; binname="$(basename "$bin")"
    info "Бинарник: $binname  ($bin)"
    resolve_deps "$bin"

    # INSTALL_AS — явный путь внутри rootfs (напр. /sbin/init): кладём бинарник
    # ровно туда, минуя эвристику bin/usr-local. rm -f снимает возможный симлинк
    # (busybox `make install` делает /sbin/init → busybox; без rm cp -L писал бы
    # ПО симлинку и затирал сам busybox), потом кладём свежий обычный файл.
    if [[ -n "$INSTALL_AS" ]]; then
        local out="$ROOTFS_DIR$INSTALL_AS"
        mkdir -p "$(dirname "$out")"
        rm -f "$out"
        cp -L "$bin" "$out"
        chmod 0755 "$out"
        maybe_strip "$out"
        ok "бинарник → ${out#"$ROOTFS_DIR"}"
        return 0
    fi

    # Выбор каталога назначения. Программы из /usr/local/ (bin, sbin, libexec)
    # зовутся по АБСОЛЮТНОМУ пути: weston грузит хелперы из /usr/local/libexec,
    # а weston-desktop-shell запускает /usr/local/bin/weston-terminal. Поэтому
    # такие кладём по тому же абсолютному пути в rootfs, а не в /bin.
    # Остальное (обычные /bin, /usr/bin) — в rootfs/bin (это /bin, он в PATH).
    local srcdir logicaldir destdir
    srcdir="$(cd "$(dirname "$bin")" && pwd)"
    logicaldir="$(logical_path "$srcdir")"   # без staging-префикса (DESTDIR)
    case "$logicaldir" in
        /usr/local/*) destdir="$ROOTFS_DIR$logicaldir" ;;
        *)            destdir="$BIN_DIR" ;;
    esac
    mkdir -p "$destdir"
    rm -f "$destdir/$binname"    # снять возможный симлинк (busybox-applet), иначе
                                 # cp -L писал бы ПО нему и затирал busybox
    cp -L "$bin" "$destdir/$binname"
    chmod 0755 "$destdir/$binname"
    maybe_strip "$destdir/$binname"
    ok "бинарник → ${destdir#"$ROOTFS_DIR"}/$binname"
}

# Обработать каталог модулей: зеркалировать *.so по абсолютному пути + их deps.
# Нужно для плагинов, которые weston грузит через dlopen по фикс. пути.
process_dir() {
    local dir="$1"
    dir="$(cd "$dir" && pwd)"                 # абсолютный путь на диске (со staging)
    local logicaldir; logicaldir="$(logical_path "$dir")"  # без DESTDIR-префикса
    local dst="$ROOTFS_DIR$logicaldir"        # логический путь внутри rootfs
    info "Каталог модулей: $dir → rootfs$logicaldir"
    mkdir -p "$dst"
    local f
    while IFS= read -r -d '' f; do
        file -b "$f" | grep -q 'ELF' || continue
        cp -L "$f" "$dst/$(basename "$f")"
        chmod 0755 "$dst/$(basename "$f")"
        maybe_strip "$dst/$(basename "$f")"
        ok "модуль → ${dst#$ROOTFS_DIR}/$(basename "$f")"
        resolve_deps "$f"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.so*' -print0)
}

# Автоподхват каталогов плагинов weston по его RUNPATH/install-prefix.
auto_weston_modules() {
    local bin="$1"
    [[ "$(basename "$bin")" == weston ]] || return 0
    [[ "$AUTO_WESTON" == "1" ]] || return 0
    local runpath prefixlib
    runpath="$(readelf -d "$bin" 2>/dev/null | awk -F'[][]' '/RUNPATH|RPATH/{print $2}' | head -1)"
    # runpath вида /usr/local/lib/x86_64-linux-gnu/weston  → prefixlib = /usr/local/lib/x86_64-linux-gnu
    [[ -n "$runpath" ]] || return 0
    prefixlib="$(dirname "$runpath")"   # логический /usr/local/lib/x86_64-linux-gnu
    local d
    # На диске каталоги модулей лежат под staging: $DESTDIR + логический путь (при
    # пустом DESTDIR — обычный /usr/local). trailing-slash glob → только каталоги.
    for d in "$DESTDIR$prefixlib/weston/" "$DESTDIR$prefixlib"/libweston-*/; do
        [[ -d "$d" ]] || continue
        process_dir "$d"
    done
    return 0
}

# Максимальная версия символов GLIBC_x.y в файле(ах). $1 — файлы через find-выборку.
max_glibc_ver() { grep -aoE 'GLIBC_2\.[0-9]+' "$@" 2>/dev/null | grep -oE '2\.[0-9]+' | sort -V | tail -1; }

# Проверить, хватает ли glibc дистрибутива всему, что уже лежит в bin/lib64/usr.
# Если требуется более новая версия — обновить связку glibc из системы.
ensure_glibc() {
    local libc="$LIB_DIR/libc.so.6"
    [[ -e "$libc" ]] || return 0
    local provided need
    provided="$(max_glibc_ver "$libc")"
    # что требуется всем ELF-файлам, которые мы принесли
    mapfile -t files < <(find "$BIN_DIR" "$LIB_DIR" "$ROOTFS_DIR"/usr -type f 2>/dev/null)
    [[ ${#files[@]} -eq 0 ]] && return 0
    need="$(max_glibc_ver "${files[@]}")"
    [[ -z "$need" || -z "$provided" ]] && return 0
    # need <= provided ?
    if [[ "$(printf '%s\n%s\n' "$need" "$provided" | sort -V | tail -1)" == "$provided" ]]; then
        info "glibc дистрибутива (2.$( echo $provided|cut -d. -f2 )) достаточно (нужно ≤ 2.${need#2.})"
        return 0
    fi
    err "Требуется GLIBC_2.${need#2.}, а в дистрибутиве только 2.${provided#2.}."
    if [[ "$UPDATE_LIBC" != "1" ]]; then
        err "Программа НЕ запустится. Обнови glibc: UPDATE_LIBC=1 $0 ..."
        return 1
    fi
    info "Обновляю связку glibc дистрибутива из $HOST_LIBC_DIR …"
    local f dst
    for f in libc.so.6 libm.so.6 libresolv.so.2; do
        [[ -e "$HOST_LIBC_DIR/$f" ]] && { cp -L "$HOST_LIBC_DIR/$f" "$LIB_DIR/$f"; chmod 0755 "$LIB_DIR/$f"; ok "glibc → lib64/$f"; }
    done
    [[ -e "$HOST_LD" ]] && { cp -L "$HOST_LD" "$LIB_DIR/ld-linux-x86-64.so.2"; chmod 0755 "$LIB_DIR/ld-linux-x86-64.so.2"; ok "glibc → lib64/ld-linux-x86-64.so.2"; }
    local now; now="$(max_glibc_ver "$LIB_DIR/libc.so.6")"
    ok "glibc обновлён до 2.${now#2.}"
}

# ── Основной цикл ────────────────────────────────────────────────────────────
rc=0
for target in "$@"; do
    if [[ -d "$target" ]]; then
        process_dir "$target" || rc=1
    else
        process_bin "$target" || rc=1
        auto_weston_modules "$target" || rc=1
    fi
    echo
done

# Проверить/обновить glibc под принесённые бинарники.
ensure_glibc || rc=1
echo

info "Готово. Пересобери образ:  ./создать_образ.sh"
exit $rc
