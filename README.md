<div align="center">

# Karing+

**VPN-клиент для Windows, Android и Linux на базе [Karing](https://github.com/KaringX/karing)**

[![Скачать для Windows](https://img.shields.io/badge/Скачать-Windows%2010%2F11-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/lager135/karing-plus/releases/download/v0.1.0_b/Karing%2B-0.1.0_b-Setup.exe)
[![Скачать для Android](https://img.shields.io/badge/Скачать-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/lager135/karing-plus/releases/download/v0.1.0_b/Karing%2B-0.1.0_b-android.apk)
[![Скачать для Linux](https://img.shields.io/badge/Скачать-Linux%20x64-FCC624?style=for-the-badge&logo=linux&logoColor=black)](https://github.com/lager135/karing-plus/releases/download/v0.1.0_b/Karing%2B-0.1.0_b-linux-x64.run)

[![Версия](https://img.shields.io/badge/версия-0.1.0__b%20(бета)-orange)](https://github.com/lager135/karing-plus/releases/tag/v0.1.0_b)
[![Лицензия](https://img.shields.io/badge/лицензия-GPL--3.0-blue)](LICENSE.md)

[Все релизы](https://github.com/lager135/karing-plus/releases) · [Сборка из исходников](BUILDING.md)

</div>

---

## Установка

| Платформа | Как поставить |
|---|---|
| **Windows 10/11 x64** | Запустите `Karing+-0.1.0_b-Setup.exe` — мастер установки. Новая версия ставится поверх старой, настройки сохраняются. |
| **Android 7+** | Установите `Karing+-0.1.0_b-android.apk`. Ставится рядом с оригинальным Karing. |
| **Linux x64** (Ubuntu 24.04+) | `sh Karing+-0.1.0_b-linux-x64.run` — установка или обновление; `--uninstall` — удаление. |

## Что добавлено

- **Режим TUN на Windows** — весь трафик системы идёт через VPN; переключатель на главном экране.
- **Встроенный zapret на Windows** (обход DPI) — отдельная вкладка и режимы «VPN / Zapret / VPN+Zapret» с выбором стратегии.
- **Раздача Wi-Fi-хотспота на Windows** с VPN и/или zapret, настройка и QR-код прямо из приложения.
- **Российские приложения в обход VPN на Android** — банки, Госуслуги, маркетплейсы, операторы.
- **Российские сайты в обход VPN на Windows и Linux** — .ru, .su, .рф, Яндекс, VK и др.
- **Главный экран:** время подключения, внешний IP, число соединений.
- **Проверка обновлений** по релизам этого репозитория (окно можно отложить на 24 часа).

## Что переработано

- Ядро на Windows и Linux работает в отдельной службе: быстрое переподключение, старое ядро завершается сразу, память освобождается после отключения.
- Автоматическая совместимость конфигов оригинального Karing — подписки не падают с `unknown field`.
- Новые установщики: мастер для Windows с режимом обновления и установщик Linux одним файлом.
- Свой идентификатор и папка данных — Karing+ не конфликтует с оригинальным Karing.
- Обновления идут только из этого репозитория.

## Версии

Формат `X.Y.Z_b` (бета): исправление ошибок — `Z+1`, небольшая доработка — `Y+1`, крупное обновление — `X+1`.

## Исходники

| Папка | Что это |
|---|---|
| [`app/`](app) | Приложение Karing+ (Flutter) |
| [`vpn-service/`](vpn-service) | Плагин подключения VPN |
| [`service/`](service) | Служба ядра (Go, sing-box) |
| [`zapret-backend/`](zapret-backend) | Бэкенд zapret для Windows |
| [`installer/`](installer) | Установщики Windows и Linux |

Как собрать — в [BUILDING.md](BUILDING.md).

## Лицензия и авторы

Karing+ — форк [Karing](https://github.com/KaringX/karing) (автор nebula / KaringX) и распространяется по лицензии [GNU GPL v3](LICENSE.md).
В сборку для Windows входит [zapret](https://github.com/bol-van/zapret) (лицензия в `zapret-backend/zapret/LICENSE.txt`).
