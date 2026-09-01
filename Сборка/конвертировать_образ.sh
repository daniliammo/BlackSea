#!/usr/bin/env bash

set -euo pipefail

# Скрипт лежит в Сборка/, а образы — в корне репозитория. Находим корень от
# расположения скрипта и переходим в него, чтобы путь NAME работал откуда угодно.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME="ОбразыДляЗагрузки/ОСЧерноеМоре"

# Фиксированный UUID для VDI. VBoxManage convertfromraw каждый раз генерирует
# случайный UUID, из-за чего VirtualBox ругается на несоответствие реестру.
# Прибиваем его к постоянному значению — тому, что уже зарегистрирован в
# ~/.config/VirtualBox/VirtualBox.xml, чтобы существующая ВМ продолжала работать.
VDI_UUID="3eeba471-ebcb-48fb-b3cc-ca061a466391"

# Имя виртуалки VirtualBox (значение переменной — кириллица можно; кириллицей
# нельзя ИМЯ bash-переменной). Подпись ядра делается автоматически в
# создать_образ.sh; здесь — автоматический enroll ключа и включение Secure Boot.
VM_NAME="ЧерноеМоре"
ENROLL_SH="$ROOT/Сборка/включить_secureboot.sh"

cp "$NAME.img" "$NAME.img.старый"

# ── QCOW2 (для QEMU) — только если есть qemu-img ─────────────────────────────
if command -v qemu-img >/dev/null; then
    echo "Конвертирую img в QCOW2"
    qemu-img convert -p -f raw -O qcow2 "$NAME.img" "$NAME.qcow2"
else
    echo "· qemu-img не найден — пропускаю QCOW2 (нужен только для QEMU)."
fi

# ── VDI + автоматический Secure Boot (VirtualBox) ────────────────────────────
if ! command -v VBoxManage >/dev/null; then
    cat >&2 <<MSG

────────────────────────────────────────────────────────────────────────────
VirtualBox (VBoxManage) НЕ УСТАНОВЛЕН — .vdi не создан, Secure Boot не включён.
Ядро в образе УЖЕ подписано (создать_образ.sh), но чтобы загрузиться под
Secure Boot, наш ключ надо вкатить в NVRAM виртуалки. Что сделать:
  1) Установите VirtualBox 7.x.
  2) Создайте виртуалку с именем РОВНО «ЧерноеМоре»:
       тип Linux / Other Linux (64-bit), включите EFI (галка «Enable EFI»);
       Secure Boot В GUI НЕ ВКЛЮЧАЙТЕ — это сделает скрипт нашим ключом.
       Подключите диск: $NAME.vdi
  3) Перезапустите сборку — .vdi создастся, Secure Boot включится сам.
Готовый raw-образ: $NAME.img (можно записать на флешку/диск напрямую).
────────────────────────────────────────────────────────────────────────────
MSG
    exit 0
fi

echo "Конвертирую img в VDI"
rm -f "$NAME.vdi"
VBoxManage convertfromraw "$NAME.img" "$NAME.vdi"
echo "Фиксирую UUID VDI: $VDI_UUID"
VBoxManage internalcommands sethduuid "$NAME.vdi" "$VDI_UUID"

# Есть ли виртуалка с нужным именем? Если да — автоматически включаем Secure Boot
# и вкатываем наш сертификат в db (см. включить_secureboot.sh: правит ВЫКЛЮЧЕННУЮ
# VM). Если нет — подробно объясняем, что и как назвать.
if VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; then
    # СНИМКИ несовместимы с этим workflow: VM грузит дельту снимка ПОВЕРХ базового
    # диска, а каждая сборка ПЕРЕЗАПИСЫВАЕТ базовый .vdi → старые блоки снимка
    # перекрывают свежий rootfs. Симптом: ядро не находит init (ENOENT / «No
    # working init found»), хотя в образе всё на месте. Предупреждаем (не трогаем
    # снимки автоматически — это разрушительно).
    snaps="$(VBoxManage snapshot "$VM_NAME" list --machinereadable 2>/dev/null | grep -c '^SnapshotName')"
    if [[ "${snaps:-0}" -gt 0 ]]; then
        ctl="$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null | sed -n 's/^storagecontrollername0="\(.*\)"/\1/p')"
        cat >&2 <<MSG

⚠ ВНИМАНИЕ: у VM «$VM_NAME» есть снимки ($snaps шт.). Она грузит ДЕЛЬТУ снимка,
  а НЕ свежесобранный $NAME.vdi → старый rootfs перекрывает новый, и ядро не
  найдёт init. Уберите снимки и подключите свежий базовый диск:
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    VBoxManage storageattach "$VM_NAME" --storagectl "${ctl:-SATA}" --port 0 --device 0 --medium none
    VBoxManage snapshot "$VM_NAME" delete <имя-снимка>     # для каждого снимка
    VBoxManage storageattach "$VM_NAME" --storagectl "${ctl:-SATA}" --port 0 --device 0 --type hdd --medium "$(pwd)/$NAME.vdi"
  И БОЛЬШЕ НЕ ДЕЛАЙТЕ снимки — каждая сборка пересоздаёт $NAME.vdi.
MSG
    fi
    echo "Виртуалка «$VM_NAME» найдена — включаю Secure Boot и вкатываю ключ…"
    if ! "$ENROLL_SH" "$VM_NAME"; then
        cat >&2 <<MSG
ВНИМАНИЕ: автоматически включить Secure Boot не вышло.
Скорее всего VM «$VM_NAME» запущена — выключите её и выполните вручную:
  $ENROLL_SH "$VM_NAME"
MSG
    fi
else
    cat >&2 <<MSG

────────────────────────────────────────────────────────────────────────────
Виртуалка «ЧерноеМоре» НЕ НАЙДЕНА — .vdi создан, но Secure Boot не включён.
Создайте VM с именем РОВНО «ЧерноеМоре»:
    тип Linux / Other Linux (64-bit), включите EFI (галка «Enable EFI»);
    Secure Boot в GUI НЕ включайте — это сделает скрипт нашим ключом;
    подключите диск: $NAME.vdi
Затем: $ENROLL_SH "ЧерноеМоре"     (или просто перезапустите сборку).
────────────────────────────────────────────────────────────────────────────
MSG
fi
