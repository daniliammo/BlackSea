#!/usr/bin/env bash

set -euo pipefail

NAME="ОбразыДляЗагрузки/ОСЧерноеМоре"

# Фиксированный UUID для VDI. VBoxManage convertfromraw каждый раз генерирует
# случайный UUID, из-за чего VirtualBox ругается на несоответствие реестру.
# Прибиваем его к постоянному значению — тому, что уже зарегистрирован в
# ~/.config/VirtualBox/VirtualBox.xml, чтобы существующая ВМ продолжала работать.
VDI_UUID="3eeba471-ebcb-48fb-b3cc-ca061a466391"

cp "$NAME.img" "$NAME.img.старый"

echo "Конвертирую img в VDI"

rm -f "$NAME.vdi"

VBoxManage convertfromraw "$NAME.img" "$NAME.vdi"

echo "Фиксирую UUID VDI: $VDI_UUID"
VBoxManage internalcommands sethduuid "$NAME.vdi" "$VDI_UUID"

echo "Конвертирую img в QCOW2"

qemu-img convert -p -f raw -O qcow2 "$NAME.img" "$NAME.qcow2"
