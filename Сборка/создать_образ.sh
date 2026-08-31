#!/usr/bin/env bash

set -euo pipefail

# Скрипт лежит в Сборка/, но работает с корнем репозитория (rootfs/, boot/,
# ОбразыДляЗагрузки/). Находим корень от расположения скрипта и переходим в него,
# чтобы все относительные пути ниже работали независимо от места запуска.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ── Очистка при любом выходе (в т.ч. при ошибке) ─────────────────────────────
# Иначе при падении скрипта loop-устройство и монтирования остаются висеть.
LOOP_DEV=""
cleanup() {
    local rc=$?
    set +e
    mountpoint -q mnt/root 2>/dev/null && sudo umount mnt/root
    mountpoint -q mnt/esp  2>/dev/null && sudo umount mnt/esp
    [ -n "$LOOP_DEV" ] && sudo losetup -d "$LOOP_DEV" 2>/dev/null
    rm -rf mnt/ 2>/dev/null
    [ $rc -ne 0 ] && echo "!! Ошибка ($rc). Выполнена очистка: loop отцеплён, mnt размонтирован." >&2
    return $rc
}
trap cleanup EXIT

# Пути
BOOT_DIR="$(pwd)/boot"
ROOTFS_DIR="$(pwd)/rootfs"
OUTPUT_IMG="ОбразыДляЗагрузки/ОСЧерноеМоре.img"
KERNEL_FILE="$BOOT_DIR/bzImage"

symlinks -cr $ROOTFS_DIR

# Обновляем кэш динамического загрузчика под текущее содержимое rootfs.
# КРИТИЧНО: загрузчик glibc 2.43 по умолчанию ищет библиотеки в
# /lib/x86_64-linux-gnu и /lib, но НЕ в /lib64, где дистрибутив держит все .so.
# Без ld.so.cache система не найдёт даже libc.so.6 и не загрузится.
# ld.so.conf перечисляет /lib64 и каталоги weston; ldconfig -r строит кэш.
if [[ -f "$ROOTFS_DIR/etc/ld.so.conf" ]]; then
    echo "Обновляю ld.so.cache под содержимое rootfs…"
    ldconfig -r "$ROOTFS_DIR" -X
else
    echo "ВНИМАНИЕ: нет $ROOTFS_DIR/etc/ld.so.conf — кэш загрузчика не будет обновлён!" >&2
fi

# ── Фиксированные идентификаторы разделов ────────────────────────────────────
# Корневой раздел (ext4): держим одинаковыми UUID файловой системы и GUID
# раздела в GPT (PARTUUID). По UUID ФС грузится ядро (root=UUID=…). ROOT_UUID —
# валидный GUID, поэтому годится и как UUID ФС, и как PARTUUID.
ROOT_UUID="12345678-1234-1234-1234-123456789abc"

# Загрузочный раздел (FAT32/ESP). ВАЖНО: у FAT НЕТ UUID. Есть только 32-битный
# «серийный номер тома» (blkid показывает его как UUID вида XXXX-XXXX). Это НЕ
# то же самое, что GUID раздела в GPT (PARTUUID). Раньше обе величины хранились
# в одной переменной "77A7-77A7": mkfs.vfat принимал её как серийник, а sgdisk —
# как GUID, но "77A7-77A7" невалидный GUID, sgdisk молча превращал его в мусор,
# и проверка PARTUUID всегда ругалась. Теперь это две РАЗНЫЕ величины:
BOOT_FAT_SERIAL="77A7-77A7"                          # серийник FAT (== UUID тома у blkid)
BOOT_PARTUUID="77a70000-0000-0000-0000-000000000000" # GUID раздела ESP в GPT

# Проверка
if [[ ! -d "$BOOT_DIR" || ! -d "$ROOTFS_DIR" || ! -f "$KERNEL_FILE" ]]; then
    echo "Ошибка: Не найдены boot/rootfs или kernel ($KERNEL_FILE)"
    exit 1
fi

# Показать структуру rootfs
echo "=== СТРУКТУРА ROOTFS ==="
ls -la "$ROOTFS_DIR"
echo ""

# Рассчитать размер
ROOTFS_SIZE=$(du -sb "$ROOTFS_DIR" | cut -f1)
ROOTFS_MB=$(( (ROOTFS_SIZE + 1048576) / 1048576 ))
# EXTRA_MB=$(( ROOTFS_MB / 2 + 50 ))
# TOTAL_ROOT_MB=$(( ROOTFS_MB + EXTRA_MB ))
# TOTAL_ROOT_MB=$( ROOTFS_MB )
# ESP держим >= 48 МБ: FAT32 требует минимум 65525 кластеров, а при 512-байтных
# кластерах это ~34 МБ. На меньшем разделе mkfs.vfat -F32 делает НЕвалидный FAT32,
# и UEFI (в т.ч. EFI VirtualBox) отказывается грузиться — «нет загрузочного носителя».
ESP_MB=48
# Запас под накладные расходы ext4 (журнал ~4 МБ, таблицы inode, резерв) плюс
# немного места для работы системы. Иначе rootfs не влезает в раздел.
ROOT_EXTRA_MB=$(( ROOTFS_MB / 3 + 40 ))
TOTAL_MB=$(( ESP_MB + ROOTFS_MB + ROOT_EXTRA_MB ))

echo "=== РАСЧЕТ РАЗМЕРОВ ==="
echo "Rootfs: ${ROOTFS_MB} MiB"
echo "ESP: ${ESP_MB} MiB, запас корня: ${ROOT_EXTRA_MB} MiB"
echo "Размер образа: ${TOTAL_MB} MiB"
echo "Фиксированный UUID: $ROOT_UUID"
echo ""

# Создать образ
echo "Создаю raw disk image..."
dd if=/dev/zero of="$OUTPUT_IMG" bs=1M count="$TOTAL_MB" status=progress conv=fsync
sync

# Настроить loop устройство
LOOP_DEV=$(sudo losetup -f --show -P "$OUTPUT_IMG")
echo "Loop device: $LOOP_DEV"
sleep 1

# Создать таблицу разделов
echo "Создаю GPT таблицу..."
sudo parted -s "$LOOP_DEV" mklabel gpt
sudo parted -s "$LOOP_DEV" mkpart ESP fat32 1MiB "${ESP_MB}MiB"
sudo parted -s "$LOOP_DEV" set 1 esp on
sudo parted -s "$LOOP_DEV" mkpart primary ext4 "${ESP_MB}MiB" 100%
sudo parted -s "$LOOP_DEV" name 2 "ROOTFS"

# Обновить таблицу разделов и дождаться появления узлов разделов.
# На CI-раннерах узлы ${LOOP_DEV}p1/p2 появляются не мгновенно — ждём явно,
# иначе mkfs падает с «No such file or directory».
sudo partprobe "$LOOP_DEV"
command -v udevadm >/dev/null && sudo udevadm settle || true
for _ in $(seq 1 50); do
    [[ -b "${LOOP_DEV}p1" && -b "${LOOP_DEV}p2" ]] && break
    sleep 0.2
done
if [[ ! -b "${LOOP_DEV}p1" || ! -b "${LOOP_DEV}p2" ]]; then
    echo "Ошибка: разделы ${LOOP_DEV}p1/p2 не появились" >&2
    exit 1
fi

# Форматировать разделы с ФИКСИРОВАННЫМ UUID
echo ""
echo "Форматирую разделы..."
sudo mkfs.vfat -F 32 -n "EFI" -i "${BOOT_FAT_SERIAL//-/}" "${LOOP_DEV}p1"
sudo mkfs.ext4 -m 1 -L "ROOTFS" -U "$ROOT_UUID" -O ^metadata_csum,^64bit "${LOOP_DEV}p2"

# Проставляем GUID разделов в таблице GPT (это PARTUUID, не UUID ФС).
# stdout sgdisk («The operation has completed successfully.») бесполезен — гасим;
# ошибки идут в stderr и остаются видны.
sudo sgdisk --partition-guid=1:"$BOOT_PARTUUID" "${LOOP_DEV}" >/dev/null
sudo sgdisk --partition-guid=2:"$ROOT_UUID"     "${LOOP_DEV}" >/dev/null
sudo partprobe "$LOOP_DEV"

# ── Проверка идентификаторов ─────────────────────────────────────────────────
# Печатает выровненную строку: [ OK ] если факт совпал с ожидаемым, иначе [FAIL]
# плюс предупреждение в stderr. Ставит BAD=1 при любом расхождении.
BAD=0
check_id() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        printf '  [ OK ] %-22s %s\n' "$label" "$actual"
    else
        printf '  [FAIL] %-22s %s (ожидалось: %s)\n' "$label" "$actual" "$expected"
        echo "ВНИМАНИЕ: $label не совпадает — возможны проблемы с загрузкой." >&2
        BAD=1
    fi
}

echo ""
echo "=== ИДЕНТИФИКАТОРЫ РАЗДЕЛОВ ==="
echo "Корневой раздел ext4 (${LOOP_DEV}p2):"
check_id "UUID ФС"        "$ROOT_UUID"       "$(sudo blkid -s UUID     -o value "${LOOP_DEV}p2")"
check_id "PARTUUID (GPT)" "$ROOT_UUID"       "$(sudo blkid -s PARTUUID -o value "${LOOP_DEV}p2")"
echo "Загрузочный раздел FAT32/ESP (${LOOP_DEV}p1):"
check_id "серийник FAT"   "$BOOT_FAT_SERIAL" "$(sudo blkid -s UUID     -o value "${LOOP_DEV}p1")"
check_id "PARTUUID (GPT)" "$BOOT_PARTUUID"   "$(sudo blkid -s PARTUUID -o value "${LOOP_DEV}p1")"
[ "$BAD" -eq 0 ] && echo "Все идентификаторы совпали." || echo "Есть расхождения (см. выше)."


# Создать точку монтирования
mkdir -p mnt/{esp,root}

# Монтировать и копировать rootfs
echo ""
echo "Копирую rootfs..."
sudo mount "${LOOP_DEV}p2" mnt/root

sudo cp -a "$ROOTFS_DIR"/. mnt/root/

# Гарантируем стандартные пустые каталоги — точки монтирования. git не хранит
# пустые папки, поэтому на свежем клоне их может не быть; без них mount -a и
# работа системы ломаются. Создаём, если отсутствуют (cp -a их не восстановит).
# /dev/pts здесь не нужен: devtmpfs перекрывает /dev, его монтируют в рантайме.
sudo mkdir -p mnt/root/proc mnt/root/sys mnt/root/dev mnt/root/run \
             mnt/root/tmp mnt/root/mnt mnt/root/root mnt/root/home

sudo umount mnt/root

# Монтировать ESP раздел
echo ""
echo "Настраиваю ESP раздел..."
sudo mount "${LOOP_DEV}p1" mnt/esp
sudo mkdir -p mnt/esp/EFI/BOOT

# Копировать ядро
sudo cp "$KERNEL_FILE" mnt/esp/EFI/BOOT/BOOTX64.EFI

# ================================================
# ВАРИАНТ 2: Мультизагрузочный конфиг для EFI
# ================================================

# Создать мультизагрузочный конфиг (grub-like)
# cat << 'EOF' | sudo tee mnt/esp/EFI/BOOT/grub.cfg > /dev/null
# set timeout=5
# set default=0

# menuentry "Minimal Linux (UUID)" {
#     echo "Loading kernel..."
#     linux /EFI/BOOT/BOOTX64.EFI root=UUID=12345678-1234-1234-1234-123456789abc rootfstype=ext4 rw console=ttyS0,115200 init=/init
# }

# menuentry "Minimal Linux (by label)" {
#     echo "Loading kernel..."
#     linux /EFI/BOOT/BOOTX64.EFI root=LABEL=ROOTFS rootfstype=ext4 rw console=ttyS0,115200 init=/init
# }
# EOF

# ================================================
# ВАРИАНТ 3: Скрипт для EFI Shell
# ================================================

cat << EOF | sudo tee mnt/esp/startup.nsh > /dev/null
# EFI Shell boot script
echo "=== Minimal Linux Boot Menu ==="
echo "1. Boot with UUID (recommended)"
echo "2. Boot by filesystem label"
echo ""
echo -n "Select option (1): "
set -v choice
if %choice% == 2 then
    echo "Booting by label..."
    EFI\BOOT\BOOTX64.EFI root=LABEL=ROOTFS rootfstype=ext4 rw console=ttyS0,115200 init=/init
else
    echo "Booting with UUID..."
    EFI\BOOT\BOOTX64.EFI root=UUID=$ROOT_UUID rootfstype=ext4 rw console=ttyS0,115200 init=/init
endif
EOF

# Также создать простой cmdline.txt для совместимости
echo "root=UUID=$ROOT_UUID rootfstype=ext4 rw console=ttyS0,115200 init=/init" | sudo tee mnt/esp/cmdline.txt > /dev/null

sudo umount mnt/esp

# Очистка
echo ""
echo "Очищаю..."
sudo losetup -d "$LOOP_DEV"
rm -rf mnt/
sync

echo ""
echo "================================================"
echo "ОБРАЗ УСПЕШНО СОЗДАН: $OUTPUT_IMG"
echo "================================================"
