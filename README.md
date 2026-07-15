https://github.com/daniliammo/BlackSea.git# BlackSea

ОС Чёрное Море — минималистичный Linux-дистрибутив.

## Сборка

### 1. Клонирование с субмодулями

Проект использует субмодули (ядро Linux, busybox, инициализация, транспилятор Konda).
Клонируйте вместе с ними:

```bash
git clone --recurse-submodules https://github.com/daniliammo/BlackSea.git MINIMAL-LINUX
cd MINIMAL-LINUX
```

Если репозиторий уже склонирован без субмодулей:

```bash
git submodule update --init --recursive
```

### 2. Зависимости

Для сборки нужны:

- `gcc`, `make` и обычный toolchain ядра Linux: `build-essential`(метапакет Debian/Ubuntu) `libncurses-dev` `flex` `bison` `libssl-dev` `libelf-dev` `dwarves` `bc` `cpio`
- `sudo`, `losetup`, `parted`, `sgdisk`, `partprobe`, `blkid`
- `mkfs.vfat` (dosfstools), `mkfs.ext4` (e2fsprogs)
- `symlinks`
- `VBoxManage` (VirtualBox) и `qemu-img` — для конвертации образа

Для ядра должен присутствовать конфиг `Программы/Ядро/.config` (уже включён в репозиторий).

### 3. Запуск сборки

Вся сборка управляется программой-оркестратором в `Программы/Сборка`:

```bash
cd Программы/Сборка
make
```

Это последовательно:

1. **Собирает программы** из `Программы/` (`make` в каждой) и раскладывает артефакты:
   - ядро → `boot/bzImage`
   - инициализация → `rootfs/sbin/init`
   - остальные утилиты → `rootfs/bin/`
2. **Создаёт загрузочный образ** — запускает `создать_образ.sh`, результат: `ОбразыДляЗагрузки/ОСЧерноеМоре.img`
3. **Конвертирует образ** — запускает `конвертировать_образ.sh`, создаёт `.vdi` (VirtualBox) и `.qcow2` (QEMU).

### Отдельные шаги

Скрипты можно запускать вручную из корня проекта:

```bash
./создать_образ.sh          # собрать .img из boot/ и rootfs/
./конвертировать_образ.sh   # .img → .vdi и .qcow2 для виртуальных машин
```
