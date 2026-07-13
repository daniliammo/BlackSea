#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>

typedef int (*шаг_функция)(void);

typedef struct {
    шаг_функция выполнить;
    const char *ошибка;
    const char *успех;
} шаг;

// Прототипы функций
int копировать_файл(const char *откуда, const char* куда);
char* найти_единственный_файл(const char *путь_к_директории);

static int выполнить_шаги(шаг *шаги, int количество) {
    for (int i = 0; i < количество; i++) {
        int результат = шаги[i].выполнить();
        if (результат != 0) {
            printf("Ошибка при %s, код: %i\n", шаги[i].ошибка, результат);
            return результат;
        }
        printf("%s\n", шаги[i].успех);
    }
    return 0;
}

int построить_программы(void) {
    DIR *программы;
    struct dirent *директория;
    char текущая_директория[PATH_MAX];

    if (getcwd(текущая_директория, sizeof(текущая_директория)) == NULL) {
        perror("не получилось получить текущую директорию getcwd()");
        return 1;
    }

    программы = opendir("..");
    if (программы == NULL) {
        perror("Ошибка открытия директории");
        return 1;
    }

    while ((директория = readdir(программы)) != NULL) {
        if (strcmp(директория->d_name, ".") == 0 || strcmp(директория->d_name, "..") == 0)
            continue;

        if (директория->d_type != DT_DIR)
            continue;

        printf("Работаю над: %s\n", директория->d_name);

        if (chdir("..") != 0) {
            perror("chdir ..");
            continue;
        }
        if (chdir(директория->d_name) != 0) {
            perror("chdir в поддиректорию");
            chdir(текущая_директория);
            continue;
        }

        if (strcmp(директория->d_name, "Сборка") == 0) {
            printf("Сборку пропускаю\n");
            continue;
        } 
        else if (strcmp(директория->d_name, "busybox") == 0) {
            continue;
            if (system("make -j8") != 0)
            {
                printf("make не вернул код 0");
                return 1;
            }
            копировать_файл("busybox", "../../rootfs/bin/busybox");
        } 
        else if (strcmp(директория->d_name, "Инициализация") == 0) {
            if (system("make -j8") != 0)
            {
                printf("make не вернул код 0");
                return 1;
            }
            копировать_файл("Собранное/init", "../../rootfs/sbin/init");
        } 
        else if (strcmp(директория->d_name, "Ядро") == 0) {
            if (system("make -j24 bzImage") != 0)
            {
                printf("make не вернул код 0");
                return 1;
            }            
            // Копируем ядро в /boot/bzImage
            копировать_файл("arch/x86_64/boot/bzImage", "../../boot/bzImage");
        } else {
            if (system("make -j8") != 0)
            {
                printf("make не вернул код 0");
                return 1;
            }

            // Проверяем наличие директории Собранное//
            DIR *build_dir = opendir("Собранное/");
            if (build_dir != NULL) {
                closedir(build_dir);
                char *имя_файла = найти_единственный_файл("Собранное/");
                if (имя_файла != NULL) {
                    char путь_откуда[PATH_MAX];
                    char путь_куда[PATH_MAX];

                    snprintf(путь_откуда, sizeof(путь_откуда), "Собранное/%s", имя_файла);
                    snprintf(путь_куда, sizeof(путь_куда), "../../rootfs/bin/%s", имя_файла);

                    printf("Копируем %s в %s\n", путь_откуда, путь_куда);
                    копировать_файл(путь_откуда, путь_куда);
                    free(имя_файла);
                }
            }
        }

        printf("Завершено успешно: %s\n", директория->d_name);

        if (chdir(текущая_директория) != 0)
            perror("chdir обратно");
    }

    closedir(программы);
    return 0;
}

int копировать_файл(const char *откуда, const char* куда) {
    FILE *src = fopen(откуда, "rb");
    FILE *dest = fopen(куда, "wb");

    if (!src || !dest) {
        perror("Ошибка при открытии файлов");
        return 1;
    }

    struct stat st;

    if (access(откуда, F_OK) != 0) {
        printf("Файл %s не найден\n", откуда);
        perror("Ошибка при проверке наличия файла");
        fclose(src);
        fclose(dest);
        return 1;
    }

    if (stat(откуда, &st) != 0) {
        perror("Ошибка при получении размера файла");
        fclose(src);
        fclose(dest);
        return 1;
    }

    char *buffer = malloc(st.st_size);
    if (!buffer) {
        perror("Ошибка выделения памяти");
        fclose(src);
        fclose(dest);
        return 1;
    }

    // Читаем весь файл за один раз
    size_t прочитано = fread(buffer, 1, st.st_size, src);
    if (прочитано != (size_t)st.st_size) {
        perror("Ошибка чтения файла");
        free(buffer);
        fclose(src);
        fclose(dest);
        return 1;
    }

    // Записываем весь файл за один раз
    size_t записано = fwrite(buffer, 1, st.st_size, dest);
    if (записано != (size_t)st.st_size) {
        perror("Ошибка записи файла");
        free(buffer);
        fclose(src);
        fclose(dest);
        return 1;
    }

    free(buffer);
    fclose(src);
    fclose(dest);
    return 0;
}

char* найти_единственный_файл(const char *путь_к_директории) {
    DIR *дир = opendir(путь_к_директории);
    if (!дир) return NULL;

    char *найденный_файл = NULL;
    struct dirent *запись;

    while ((запись = readdir(дир)) != NULL) {
        if (strcmp(запись->d_name, ".") == 0 || strcmp(запись->d_name, "..") == 0)
            continue;
        if (запись->d_type == DT_REG) {
            if (найденный_файл != NULL) {
                // Найдено больше одного файла
                free(найденный_файл);
                closedir(дир);
                return NULL;
            }
            найденный_файл = strdup(запись->d_name);
        }
    }

    closedir(дир);
    return найденный_файл;
}

int создать_образ(void) {
    chdir("..");
    chdir("..");

    int результат = system("./создать_образ.sh");

    return результат;
}

int конвертировать_образ(void) {
    int результат = system("./конвертировать_образ.sh");

    return результат;
}


int main(void) {
    шаг шаги[] = {
        { построить_программы, "построении программ", "Построение программ закончилось успешно!" },
        { создать_образ, "создании образа", "Создание образа закончилось успешно!" },
        { конвертировать_образ, "конвертации образа", "Конвертация образа закончилась успешно!" },
    };
    return выполнить_шаги(шаги, sizeof(шаги) / sizeof(шаги[0]));
}
