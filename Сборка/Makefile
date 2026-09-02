CC = gcc
CFLAGS = -Wall -Wextra -Werror -O3 -s -fdata-sections -ffunction-sections -Wl,--gc-sections -flto -fno-stack-protector
TARGET = Собранное/Сборка
SRC = основа.c

# ПОЛИТИКА «только свежий тулчейн»: требуем современный gcc (старьё/легаси в
# проекте не поддерживаем). Проверка — order-only prerequisite цели: гоняется
# каждую сборку, но НЕ форсит перекомпиляцию, если основа.c не менялся.
GCC_MIN := 13
GCC_VER := $(shell $(CC) -dumpversion 2>/dev/null | cut -d. -f1)

all: run

build: $(TARGET)

check-toolchain:
	@if [ -z "$(GCC_VER)" ]; then \
	  echo "✗ не найден компилятор '$(CC)'"; exit 1; fi
	@if [ "$(GCC_VER)" -lt "$(GCC_MIN)" ]; then \
	  echo "✗ нужен gcc >= $(GCC_MIN) (есть $(GCC_VER)). Старый компилятор не поддерживается — обнови."; \
	  exit 1; fi
	@echo "» тулчейн: gcc $(GCC_VER) (требуется >= $(GCC_MIN))"

$(TARGET): $(SRC) | check-toolchain
	mkdir -p Собранное
	$(CC) $(CFLAGS) $(SRC) -o $(TARGET)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	install -D -m 755 $(TARGET) /bin/$(TARGET)

.PHONY: all build run clean install check-toolchain
