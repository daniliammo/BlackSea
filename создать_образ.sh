#!/usr/bin/env bash

set -euo pipefail

# Пути
BOOT_DIR="$(pwd)/boot"
ROOTFS_DIR="$(pwd)/rootfs"
OUTPUT_IMG="ОбразыДляЗагрузки/ОСЧерноеМоре.img"
KERNEL_FILE="$BOOT_DIR/bzImage"

symlinks -cr $ROOTFS_DIR

# ФИКСИРОВАННЫЙ UUID для корневого раздела
# Можно использовать любой UUID, главное чтобы он был постоянным
ROOT_UUID="12345678-1234-1234-1234-123456789abc"
BOOT_PARTUUID="77A7-77A7"

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
ESP_MB=48
TOTAL_MB=$(( ESP_MB + ROOTFS_MB + 8 ))

echo "=== РАСЧЕТ РАЗМЕРОВ ==="
echo "Rootfs: ${ROOTFS_MB} MiB"
# echo "Дополнительно: ${EXTRA_MB} MiB"
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

# Обновить таблицу разделов
sudo partprobe "$LOOP_DEV"
sleep 0.2

# Форматировать разделы с ФИКСИРОВАННЫМ UUID
echo ""
echo "Форматирую разделы..."
sudo mkfs.vfat -F 32 -n "EFI" -i "${BOOT_PARTUUID//-/}" "${LOOP_DEV}p1"
sudo mkfs.ext4 -L "ROOTFS" -U "$ROOT_UUID" -O ^metadata_csum,^64bit "${LOOP_DEV}p2"

# Устанавливаем PARTUUID для разделов в GPT таблице
sudo sgdisk --partition-guid=1:"$BOOT_PARTUUID" "${LOOP_DEV}"
sudo sgdisk --partition-guid=2:"$ROOT_UUID" "${LOOP_DEV}"

PARTUUID=$(sudo blkid -s PARTUUID -o value "${LOOP_DEV}p2")
echo "PARTUUID: $PARTUUID"
echo "ROOT_UUID: $ROOT_UUID"
[ "$PARTUUID" = "$ROOT_UUID" ] && echo "СОВПАДАЕТ!" || echo "НЕ СОВПАДАЕТ!"

# Проверить UUID
ACTUAL_UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p2")
echo "UUID корневого раздела (должен совпадать с фиксированным): $ACTUAL_UUID"
if [[ "$ACTUAL_UUID" != "$ROOT_UUID" ]]; then
    echo "ВНИМАНИЕ: UUID не совпадает! Возможны проблемы с загрузкой."
fi

# Проверить UUID
ACTUAL_BOOT_UUID=$(sudo blkid -s UUID -o value "${LOOP_DEV}p1")
echo "UUID boot раздела (должен совпадать с фиксированным): $ACTUAL_BOOT_UUID"
if [[ "$ACTUAL_BOOT_UUID" != "$BOOT_PARTUUID" ]]; then
    echo "ВНИМАНИЕ: UUID не совпадает! Возможны проблемы с загрузкой."
fi

# Проверить PARTUUID
ACTUAL_BOOT_UUID=$(sudo blkid -s PARTUUID -o value "${LOOP_DEV}p1")
echo "PARTUUID boot раздела (должен совпадать с фиксированным): $ACTUAL_BOOT_UUID"
if [[ "$ACTUAL_BOOT_UUID" != "$BOOT_PARTUUID" ]]; then
    echo "ВНИМАНИЕ: PARTUUID не совпадает! Возможны проблемы с загрузкой."
fi


# Создать точку монтирования
mkdir -p mnt/{esp,root}

# Монтировать и копировать rootfs
echo ""
echo "Копирую rootfs..."
sudo mount "${LOOP_DEV}p2" mnt/root

sudo cp -a "$ROOTFS_DIR"/. mnt/root/

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
