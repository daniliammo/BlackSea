#!/usr/bin/env bash
#
# Включает UEFI Secure Boot для виртуалки VirtualBox и вкатывает в её NVRAM наш
# сертификат в переменную db (базу разрешённых подписей), которой подписано ядро.
#
# ПОЧЕМУ ИМЕННО db, А НЕ MOK:
#   Дистрибутив грузится как голый EFI-stub (BOOTX64.EFI), без shim. Прошивка при
#   прямом запуске образа проверяет его подпись ТОЛЬКО по db (MokList — выдумка
#   shim, её читает shim, а не прошивка). Команда `enrollmok` в VBox кладёт ключ
#   в MokList → образ не проходит проверку → «нет ОС / неверный порядок загрузки».
#   Проверено экспериментально (queryvar показывал ключ в MokList, а db пустой).
#
# РАБОЧАЯ ПОСЛЕДОВАТЕЛЬНОСТЬ (правится на ВЫКЛЮЧЕННОЙ VM):
#   inituefivarstore     — чистое хранилище
#   enrollmssignatures   — создаёт переменные db и KEK (иначе changevar не к чему
#                          применить: он умеет менять, но не создавать переменную)
#   changevar --name=db  — ПЕРЕЗАПИСЫВАЕМ db нашим сертификатом (db.esl)
#   enrollorclpk         — штатный Oracle PK → user mode, Secure Boot enforce'ит
#   secureboot --enable
#
# Использование:  включить_secureboot.sh <имя-или-UUID-VM>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESL="$SCRIPT_DIR/ключи-secureboot/db.esl"

VM="${1:-}"
[[ -n "$VM" ]] || { echo "Использование: $0 <имя-или-UUID-VM>" >&2; exit 2; }
command -v VBoxManage >/dev/null || { echo "Ошибка: нет VBoxManage." >&2; exit 1; }

# Нужен db.esl — создаём ключи, если их ещё нет.
[[ -f "$ESL" ]] || { echo "Нет $ESL — создаю ключи…"; "$SCRIPT_DIR/подписать_ядро.sh" --keys; }

# VM должна быть выключена.
state=$(VBoxManage showvminfo "$VM" --machinereadable | sed -n 's/^VMState="\(.*\)"/\1/p')
if [[ -n "$state" && "$state" != "poweroff" && "$state" != "aborted" ]]; then
    echo "Ошибка: VM '$VM' в состоянии '$state'. Выключите её и повторите." >&2
    exit 1
fi

echo "Прошивка → EFI 64-bit…"
VBoxManage modifyvm "$VM" --firmware efi64

echo "Чистое хранилище UEFI-переменных…"
VBoxManage modifynvram "$VM" inituefivarstore

echo "Создаю db/KEK (заглушка MS-подписей)…"
VBoxManage modifynvram "$VM" enrollmssignatures

echo "Перезаписываю db нашим сертификатом ($ESL)…"
VBoxManage modifynvram "$VM" changevar --name=db --filename="$ESL"

echo "Прописываю Platform Key (→ user mode)…"
VBoxManage modifynvram "$VM" enrollorclpk

echo "Включаю Secure Boot…"
VBoxManage modifynvram "$VM" secureboot --enable

echo ""
echo "=== ГОТОВО. UEFI-переменные (ожидаем PK, KEK, db, SecureBootEnable): ==="
VBoxManage modifynvram "$VM" listvars || true
echo ""
echo "Пересоберите образ (ядро подпишется само) и загрузите '$VM'."
echo "Если подсунуть неподписанное/чужое ядро — VBox откажет в загрузке: значит"
echo "проверка Secure Boot реально работает."
