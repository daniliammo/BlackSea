#!/usr/bin/env bash
#
# Подпись ядра (EFI-stub) для UEFI Secure Boot.
#
# Дистрибутив грузится как «голый» EFI-stub: bzImage кладётся в
# EFI/BOOT/BOOTX64.EFI и запускается прошивкой напрямую, без shim и без GRUB.
# Значит проверяется прошивкой ИМЕННО САМ bzImage (это валидный PE/COFF, т.к.
# CONFIG_EFI_STUB=y). Поэтому подписываем PE-подписью через sbsign нашим
# собственным самоподписанным ключом. Тот же ключ (в виде DER-сертификата)
# затем «вкатывается» в NVRAM виртуалки — см. включить_secureboot.sh.
#
# Использование:
#   подписать_ядро.sh <вход.efi> <выход.efi>   — подписать
#   подписать_ядро.sh --keys                    — только создать ключи и выйти
#
# Ключи создаются один раз и переиспользуются. Приватный ключ НИКОГДА не
# коммитится и не попадает в образ (каталог ключей — в .gitignore).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/ключи-secureboot"
KEY="$KEYS_DIR/db.key"   # приватный ключ (PEM), режим 0600, не коммитить
CRT="$KEYS_DIR/db.crt"   # сертификат (PEM) — для sbsign
DER="$KEYS_DIR/db.der"   # сертификат (DER) — для enroll в прошивку через UI
ESL="$KEYS_DIR/db.esl"   # EFI_SIGNATURE_LIST — для записи прямо в переменную db
CN="OS Chernoe More Secure Boot"
# owner-uuid нашего ключа в списке подписей (произвольный, но постоянный).
OWNER_UUID="77a70000-0000-0000-0000-00000000c0de"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Ошибка: нет '$1' на хосте." >&2; return 1; }; }

# Собирает EFI_SIGNATURE_LIST (.esl) из DER-сертификата: это ровно тот формат,
# в котором прошивка хранит переменную db. Позволяет записать наш ключ прямо в
# db (см. включить_secureboot.sh) без внешних утилит (efitools) — только python3.
build_esl() {
    need python3 || return 1
    python3 - "$DER" "$ESL" "$OWNER_UUID" <<'PY'
import struct, sys, uuid
der = open(sys.argv[1], "rb").read()
out, owner = sys.argv[2], uuid.UUID(sys.argv[3])
X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")  # EFI_CERT_X509_GUID
sig  = owner.bytes_le + der                    # SignatureOwner + данные (cert)
hdr  = X509.bytes_le + struct.pack("<III", 28 + len(sig), 0, len(sig))
open(out, "wb").write(hdr + sig)
PY
}

# Создаёт пару ключ/сертификат (+ .esl), если её ещё нет. Идемпотентно.
ensure_keys() {
    need openssl || return 1
    if [[ -f "$KEY" && -f "$CRT" && -f "$DER" && -f "$ESL" ]]; then
        return 0
    fi
    echo "Генерирую ключи Secure Boot в $KEYS_DIR …"
    mkdir -p "$KEYS_DIR"
    # Пометка на случай, если каталог всё же попадёт под git.
    printf '*\n!.gitignore\n' > "$KEYS_DIR/.gitignore"
    # RSA-2048: обязательный минимум для Secure Boot (dbx-совместимо, RSA-4096
    # некоторые прошивки не проверяют). SHA-256, срок 10 лет.
    if [[ ! -f "$KEY" || ! -f "$CRT" ]]; then
        openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
            -subj "/CN=$CN/" -keyout "$KEY" -out "$CRT"
    fi
    openssl x509 -in "$CRT" -outform DER -out "$DER"
    build_esl || { echo "Ошибка: не собрать db.esl (нужен python3)." >&2; return 1; }
    chmod 600 "$KEY"
    echo "Готово: db.key (0600), db.crt (PEM), db.der (DER), db.esl (для db)."
}

case "${1:-}" in
    --keys)
        ensure_keys
        exit 0
        ;;
    "")
        echo "Использование: $0 <вход.efi> <выход.efi>  |  $0 --keys" >&2
        exit 2
        ;;
esac

IN="$1"
OUT="${2:-}"
[[ -n "$OUT" ]] || { echo "Ошибка: не задан выходной файл." >&2; exit 2; }
[[ -f "$IN" ]]  || { echo "Ошибка: нет входного файла '$IN'." >&2; exit 1; }

need sbsign || exit 1
ensure_keys || exit 1

echo "Подписываю '$IN' → '$OUT' …"
sbsign --key "$KEY" --cert "$CRT" --output "$OUT" "$IN"

# Проверяем подпись, если есть sbverify (не обязателен для сборки).
if command -v sbverify >/dev/null 2>&1; then
    sbverify --cert "$CRT" "$OUT" >/dev/null \
        && echo "Подпись валидна (проверено нашим сертификатом)." \
        || echo "ВНИМАНИЕ: sbverify не подтвердил подпись." >&2
fi
