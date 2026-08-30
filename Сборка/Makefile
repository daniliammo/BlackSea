CC = gcc
CFLAGS = -Wall -Wextra -O3 -s -fdata-sections -ffunction-sections -Wl,--gc-sections -flto -fno-stack-protector
TARGET = Собранное/Сборка
SRC = основа.c

all: run

build: $(TARGET)

$(TARGET): $(SRC)
	mkdir -p Собранное
	$(CC) $(CFLAGS) $(SRC) -o $(TARGET)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	install -D -m 755 $(TARGET) /bin/$(TARGET)

.PHONY: all build run clean install
