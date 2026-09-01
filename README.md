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

Вся сборка управляется программой-оркестратором в `Сборка/` (в корне репозитория):

```bash
cd Сборка
make
```

Это последовательно:

1. **Собирает программы** из `Программы/` (`make` в каждой) и раскладывает артефакты:
   - ядро → `boot/bzImage`
   - инициализация → `rootfs/sbin/init`
   - остальные утилиты → `rootfs/bin/`
2. **Создаёт загрузочный образ** — запускает `создать_образ.sh`, результат: `ОбразыДляЗагрузки/ОСЧерноеМоре.img`
3. **Конвертирует образ** — запускает `конвертировать_образ.sh`, создаёт `.vdi` (VirtualBox) и `.qcow2` (QEMU).

> **GitHub CI делает ровно то же самое одним заданием**: установка зависимостей +
> `make -C Сборка` (см. `.github/workflows/ci.yml`) — никакой отдельной логики
> сборки в YAML, чтобы CI и локальная сборка не расходились. VBoxManage на раннере
> нет, поэтому конвертация даёт только `.qcow2` (артефакт сборки); `make` не рвётся.

### Отдельные шаги

Скрипты можно запускать вручную из корня проекта:

```bash
Сборка/создать_образ.sh          # собрать .img из boot/ и rootfs/
Сборка/конвертировать_образ.sh   # .img → .vdi и .qcow2 для виртуальных машин
```

## Известные проблемы сборки (другой ПК / GitHub CI)

Тяжелее всего собирается **weston** (`Сборка/собрать-weston.sh`). Он не зависит от
версий библиотек хоста: wayland-стек собирается из **форсированных fallback-
subproject'ов** — скрипт сам генерит `.wrap`'ы и тянет пинованные версии
(`wayland 1.26.0`, `wayland-protocols 1.49`, `display-info 0.2.0`). Отсюда типичные
симптомы на чужом ПК и на раннере GitHub:

- **`ERROR: requires argument not a string … got InternalDependency`** в
  `libweston/meson.build`. Причина: на Ubuntu 24.04 (и на GitHub-раннере) `apt`
  ставит **старый meson (1.3.2)**, который не умеет класть зависимость из
  subproject'а в `Requires.private` pkg-config. Новый meson (≥ ~1.10) это
  проглатывает — поэтому у себя вы можете не увидеть ошибку, а CI падает.
  `собрать-weston.sh` **чинит это автоматически** (идемпотентный патч: заменяет
  объекты зависимостей их pkg-config-именами — валидно на любой версии meson).
  Пересобирать weston: просто запустить `Сборка/собрать-weston.sh` заново.

- **`error: RPC failed; HTTP 502` при клоне `edid-decode`** (`git.linuxtv.org`).
  **НЕ фатально** — это nested-wrap внутри `display-info`, нужный лишь её
  собственным тестам; `display-info` сам отключает его (`buildable: NO (disabling)`)
  и собирается дальше. Если сборка падает именно тут — перезапустите джоб (502
  у linuxtv временный).

- **`warning: refs/tags/1.26.0 … is not a commit!`** при клоне wayland/display-info.
  **Безвредно** — артефакт shallow-клона на тег (`depth = 1`); сборка продолжается.

- **Клоны идут с `gitlab.freedesktop.org`** (канонический дом wayland-стека).
  Github-зеркал у `wayland`/`wayland-protocols`/`libdisplay-info` нет, поэтому
  надёжной альтернативы freedesktop gitlab для них не существует.

### Dev-зависимости weston (что доставить на хосте)

Ubuntu/Debian (совпадает со списком в `.github/workflows/ci.yml`):

```bash
sudo apt-get install -y \
  build-essential file binutils meson ninja-build pkg-config python3 \
  libffi-dev libexpat1-dev \
  libinput-dev libxkbcommon-dev libudev-dev libevdev-dev libmtdev-dev \
  libpixman-1-dev libdrm-dev libgbm-dev libegl-dev libgles2-mesa-dev \
  mesa-common-dev libgl-dev \
  libcairo2-dev libpango1.0-dev libfreetype-dev libfontconfig-dev \
  libpng-dev libjpeg-dev libwebp-dev liblcms2-dev libseat-dev
```

`libffi-dev` и `libexpat1-dev` нужны для сборки самого **wayland** из subproject'а
(его тянет force-fallback). Ставить конкретные версии `libwayland-dev` /
`wayland-protocols` **не требуется** — их версии-пины собираются из исходников.

> Установка weston идёт в `/usr/local` (хелперы зовутся по абсолютным путям). Скрипт
> использует `sudo` только если каталог не писабелен. Чтобы собирать weston без рута
> разово: `sudo chown -R "$USER" /usr/local`. Скрипты **образа**
> (`создать_образ.sh`) всё равно требуют рут (loop/mount/parted).
