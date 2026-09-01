#!/usr/bin/env bash
#
# Включает UEFI Secure Boot для виртуалки VirtualBox и вкатывает в её NVRAM наш
# сертификат, которым подписано ядро (см. подписать_ядро.sh).
#
# КАК ЭТО РАБОТАЕТ В VIRTUALBOX 7.x:
#   VBox эмулирует Secure Boot через `VBoxManage modifynvram`. Хранилище
#   UEFI-переменных живёт в .nvram файле VM (host-side), править его надо на
#   ВЫКЛЮЧЕННОЙ машине.
#     inituefivarstore   — создать чистое хранилище (setup mode)
#     enrollorclpk       — прописать штатный Oracle Platform Key → user mode,
#                          т.е. Secure Boot реально начинает enforce'ить
#     enrollmok          — добавить НАШ сертификат в MOK-список; загрузчик образов
#                          VBox проверяет образы и по нему (не только по db),
#                          поэтому shim не нужен — наш EFI-stub проходит проверку
#     secureboot --enable
#
# Использование:  включить_secureboot.sh <имя-или-UUID-VM>
#
# После этого пересоберите образ (ядро подпишется автоматически) и загрузите VM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DER="$SCRIPT_DIR/ключи-secureboot/db.der"
# Фиксированный owner-uuid для нашего ключа — чтобы enroll был воспроизводим.
OWNER_UUID="77a70000-0000-0000-0000-00000000c0de"

VM="${1:-}"
[[ -n "$VM" ]] || { echo "Использование: $0 <имя-или-UUID-VM>" >&2; exit 2; }
command -v VBoxManage >/dev/null || { echo "Ошибка: нет VBoxManage." >&2; exit 1; }

# Сертификат обязателен — создаём ключи, если их ещё нет.
if [[ ! -f "$DER" ]]; then
    echo "Нет $DER — создаю ключи…"
    "$SCRIPT_DIR/подписать_ядро.sh" --keys
fi

# VM должна быть выключена.
state=$(VBoxManage showvminfo "$VM" --machinereadable | sed -n 's/^VMState="\(.*\)"/\1/p')
if [[ "$state" != "poweroff" && "$state" != "aborted" && -n "$state" ]]; then
    echo "Ошибка: VM '$VM' в состоянии '$state'. Выключите её и повторите." >&2
    exit 1
fi

echo "Прошивка → EFI 64-bit…"
VBoxManage modifyvm "$VM" --firmware efi64

echo "Инициализирую хранилище UEFI-переменных (setup mode)…"
VBoxManage modifynvram "$VM" inituefivarstore

echo "Прописываю Oracle Platform Key (→ user mode)…"
VBoxManage modifynvram "$VM" enrollorclpk

echo "Вкатываю наш сертификат в MOK ($DER)…"
VBoxManage modifynvram "$VM" enrollmok --mok="$DER" --owner-uuid="$OWNER_UUID"

echo "Включаю Secure Boot…"
VBoxManage modifynvram "$VM" secureboot --enable

echo ""
echo "=== ГОТОВО. Текущие UEFI-переменные: ==="
VBoxManage modifynvram "$VM" listvars || true
echo ""
echo "Дальше: пересоберите образ (ядро подпишется само) и загрузите '$VM'."
echo "Проверка: если ядро НЕ подписано нашим ключом — VBox откажет в загрузке"
echo "с ошибкой Secure Boot violation. Значит проверка реально работает."
