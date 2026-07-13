#!/usr/bin/env bash
# Отключает debug / profiling / трассировку / сбор статистики и часть legacy.
# dmesg (printk) сохраняется — только он остаётся как канал диагностики.
#
# Запуск из корня дерева ядра, где лежит .config:
#   ./strip-config.sh           — изменить текущий .config
#   ./strip-config.sh path/.cfg — изменить указанный файл

set -euo pipefail

CONFIG="${1:-.config}"

if [[ ! -f "$CONFIG" ]]; then
    echo "Не найден $CONFIG. Сначала сгенерируйте конфиг (make defconfig / oldconfig)." >&2
    exit 1
fi

if [[ ! -x scripts/config ]]; then
    echo "scripts/config не найден — запустите скрипт из корня дерева ядра." >&2
    exit 1
fi

cp -- "$CONFIG" "${CONFIG}.bak.$(date +%s)"
echo "[+] Резервная копия сохранена."

cfg() { ./scripts/config --file "$CONFIG" "$@"; }

echo "[*] Отключаю debug-информацию и отладку ядра…"
cfg \
  -d DEBUG_INFO -d DEBUG_INFO_DWARF4 -d DEBUG_INFO_DWARF5 \
  -d DEBUG_INFO_BTF -d DEBUG_INFO_BTF_MODULES -d GDB_SCRIPTS \
  -d DEBUG_KERNEL -d DEBUG_MISC -d DEBUG_BUGVERBOSE \
  -d DEBUG_OBJECTS -d DEBUG_LIST -d DEBUG_PLIST \
  -d DEBUG_SG -d DEBUG_NOTIFIERS -d DEBUG_CREDENTIALS \
  -d DEBUG_STACK_USAGE -d DEBUG_VM -d DEBUG_MEMORY_INIT \
  -d DEBUG_SHIRQ -d DEBUG_TIMEKEEPING \
  -d SLUB_DEBUG -d SLUB_DEBUG_ON \
  -d PAGE_OWNER -d PAGE_POISONING -d DEBUG_PAGEALLOC \
  -d KASAN -d KCSAN -d UBSAN -d KMEMLEAK -d KFENCE \
  -d FAULT_INJECTION \
  -d PROVE_LOCKING -d DEBUG_LOCK_ALLOC -d LOCK_STAT \
  -d DEBUG_PREEMPT -d DEBUG_ATOMIC_SLEEP \
  -d DEBUG_RT_MUTEXES -d DEBUG_SPINLOCK -d DEBUG_MUTEXES \
  -d DEBUG_RWSEMS -d DEBUG_WW_MUTEX_SLOWPATH

echo "[*] Отключаю трассировку (ftrace / kprobes / BPF events)…"
cfg \
  -d FTRACE -d FUNCTION_TRACER -d FUNCTION_GRAPH_TRACER \
  -d STACK_TRACER -d DYNAMIC_FTRACE -d FTRACE_SYSCALLS \
  -d TRACING -d GENERIC_TRACER -d TRACEPOINTS \
  -d BLK_DEV_IO_TRACE -d IRQSOFF_TRACER -d PREEMPT_TRACER \
  -d SCHED_TRACER -d HWLAT_TRACER -d MMIOTRACE \
  -d KPROBES -d UPROBES -d KPROBE_EVENTS -d UPROBE_EVENTS \
  -d BPF_EVENTS -d BPF_JIT_ALWAYS_ON

echo "[*] Отключаю профайлинг и perf…"
cfg \
  -d PROFILING -d OPROFILE \
  -d PERF_EVENTS -d HW_PERF_EVENTS \
  -d JUMP_LABEL

echo "[*] Отключаю сбор статистики (kernel/scheduler/IO/memory accounting)…"
cfg \
  -d TASKSTATS -d TASK_DELAY_ACCT -d TASK_XACCT -d TASK_IO_ACCOUNTING \
  -d PSI -d PSI_DEFAULT_DISABLED \
  -d LATENCYTOP -d SCHEDSTATS -d SCHED_INFO \
  -d BSD_PROCESS_ACCT -d BSD_PROCESS_ACCT_V3 \
  -d AUDIT -d AUDITSYSCALL \
  -d MEMCG -d BLK_CGROUP_IOCOST -d BLK_CGROUP_IOLATENCY \
  -d VM_EVENT_COUNTERS \
  -d PROC_EVENTS \
  -d NET_DROP_MONITOR

echo "[*] Сохраняю dmesg / printk (это единственный остающийся канал диагностики)…"
cfg \
  -e PRINTK -e PRINTK_TIME -e EARLY_PRINTK \
  --set-val CONFIG_LOG_BUF_SHIFT 17

echo "[*] Отключаю часть legacy (осторожно — может сломать старый софт/железо)…"
cfg \
  -d IDE \
  -d LEGACY_PTYS \
  -d LEGACY_VSYSCALL_EMULATION \
  -d X86_16BIT -d MODIFY_LDT_SYSCALL \
  -d COMPAT_BRK

echo "[*] Вырезаю legacy fbdev-драйверы (консоль обеспечивает simpledrm→fbcon)…"
# Старый слой fbdev не нужен: firmware-framebuffer обслуживает DRM_SIMPLEDRM,
# а нативный GPU подгружается модулем из userspace. FB_VESA и FB_EFI у тебя
# вшиты (=y) — именно они зря раздувают vmlinuz, остальные просто лишние модули.
cfg \
  -d FB_VESA -d FB_EFI -d FB_UVESA -d FB_VGA16 \
  -d FB_NVIDIA -d FB_RIVA -d FB_I740 \
  -d FB_MATROX -d FB_RADEON -d FB_ATY -d FB_ATY128 \
  -d FB_S3 -d FB_SAVAGE -d FB_SIS -d FB_VIA \
  -d FB_NEOMAGIC -d FB_KYRO -d FB_3DFX -d FB_VOODOO1 \
  -d FB_VT8623 -d FB_TRIDENT -d FB_ARK \
  -d FB_PM2 -d FB_PM3 -d FB_CYBER2000 -d FB_ARC \
  -d FB_CARMINE -d FB_SM501 -d FB_SMSCUFX -d FB_IBM_GXT4500 \
  -d FB_VIRTUAL -d FB_METRONOME -d FB_MB862XX \
  -d FB_SM712 -d FB_SM750 -d FB_SSD1307 -d FB_SSD1306 \
  -d FB_HECUBA -d FB_SVGALIB -d FB_CIRRUS \
  -d FB_S1D13XXX -d FB_N411 -d FB_OPENCORES

echo "[*] Гарантирую быстрый ранний вывод (без earlycon=efifb)…"
# CMDLINE_OVERRIDE=y заставляет ядро игнорировать строку загрузчика и всегда
# брать вшитую — из-за чего медленный earlycon=efifb нельзя убрать без пересборки.
# Выключаем: вшитый CMDLINE остаётся дефолтом, но загрузчик может его переопределить.
cfg -d CMDLINE_OVERRIDE

echo "[*] Отключаю встроенные тесты, KUnit и образцы (samples)…"
cfg \
  -d RUNTIME_TESTING_MENU \
  -d KUNIT -d KUNIT_ALL_TESTS -d KUNIT_DEBUGFS \
  -d SAMPLES \
  -d FTRACE_STARTUP_TEST -d RING_BUFFER_STARTUP_TEST \
  -d RING_BUFFER_BENCHMARK \
  -d ATOMIC64_SELFTEST -d ASYNC_RAID6_TEST \
  -d RBTREE_TEST -d INTERVAL_TREE_TEST \
  -d PERCPU_TEST -d TEST_LIST_SORT \
  -e CRYPTO_MANAGER_DISABLE_TESTS

echo "[*] Отключаю остаточную трассировку (события / гистограммы / fprobe)…"
cfg \
  -d BOOTTIME_TRACING -d SYNTH_EVENTS -d HIST_TRIGGERS \
  -d USER_EVENTS -d FPROBE -d FUNCTION_PROFILER \
  -d FTRACE_RECORD_RECURSION -d FUNCTION_ERROR_INJECTION \
  -d RV -d SAMPLE_TRACE_PRINTK

echo "[*] Отключаю остаточную отладку и watchdog'и (диагностика, не функционал)…"
cfg \
  -d DETECT_HUNG_TASK -d WQ_WATCHDOG \
  -d SOFTLOCKUP_DETECTOR -d HARDLOCKUP_DETECTOR \
  -d DEBUG_BOOT_PARAMS -d DEBUG_ENTRY -d DEBUG_NMI_SELFTEST \
  -d DEBUG_WX -d CPA_DEBUG -d DEBUG_TLBFLUSH \
  -d ACPI_DEBUG -d DYNAMIC_DEBUG \
  -d DEBUG_FS_ALLOW_ALL

echo "[*] Убираю встроенную копию .config и лишние таблицы символов…"
cfg \
  -d IKCONFIG -d IKCONFIG_PROC \
  -d IKHEADERS \
  -d KALLSYMS_ALL

# --- Защита критичных символов -------------------------------------------
# Эти опции обеспечивают загрузку и единственный канал вывода (tty0/fbcon
# поверх simpledrm) — их нельзя терять при стрипе. Принудительно включаем
# перед olddefconfig, а после — проверяем, что они выжили.
CRITICAL=(
  PRINTK PRINTK_TIME EARLY_PRINTK
  TTY VT VT_CONSOLE
  FB FB_CORE FRAMEBUFFER_CONSOLE
  DRM DRM_KMS_HELPER DRM_SYSFB_HELPER DRM_SIMPLEDRM DRM_FBDEV_EMULATION
  SYSFB SYSFB_SIMPLEFB
  EFI EFI_STUB
  CMDLINE_BOOL
  EXT4_FS DEVTMPFS DEVTMPFS_MOUNT
  BLK_DEV_SD ATA SATA_AHCI BLK_DEV_NVME SCSI
)

echo "[*] Принудительно включаю критичные для загрузки/вывода символы…"
for sym in "${CRITICAL[@]}"; do
  cfg -e "$sym"
done

echo "[*] Применяю зависимости (make olddefconfig)…"
make KCONFIG_CONFIG="$CONFIG" olddefconfig

echo "[*] Проверяю, что критичные символы уцелели после olddefconfig…"
PROBLEMS=0
for sym in "${CRITICAL[@]}"; do
  if ! grep -q "^CONFIG_${sym}=y" "$CONFIG"; then
    echo "    [!] CONFIG_${sym} НЕ установлен в =y — проверьте зависимости!" >&2
    PROBLEMS=$((PROBLEMS + 1))
  fi
done

if [[ "$PROBLEMS" -gt 0 ]]; then
  echo "[!] Внимание: $PROBLEMS критичных символов не на месте. Загрузка/вывод могут сломаться." >&2
  echo "    Сравните с резервной копией: diff -u ${CONFIG}.bak.* $CONFIG" >&2
else
  echo "[✓] Все критичные символы на месте."
fi

echo "[✓] Готово. Проверьте diff:"
echo "    diff -u ${CONFIG}.bak.* $CONFIG | less"
