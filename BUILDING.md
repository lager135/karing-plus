# Сборка Karing+

Репозиторий содержит все исходники Karing+:

| Папка | Что это |
|---|---|
| `app/` | Приложение Karing+ (Flutter), форк [Karing](https://github.com/KaringX/karing) |
| `vpn-service/` | Плагин `vpn_service`: Windows/Linux — через службу ядра, Android — VpnService + libbox |
| `service/` | Служба ядра `karingService` (Go, sing-box 1.12): TUN, запуск zapret, systemd/служба Windows |
| `zapret-backend/` | Бэкенд zapret для Windows (Python), стратегии и бинарники zapret |
| `installer/inno/` | Установщик Windows (Inno Setup 6) |
| `installer/linux/` | Установщик Linux одним файлом (`.run`) |

Собранные бинарники в репозиторий не входят: их нужно собрать самому (шаги ниже).

## Требования

- Flutter 3.47.7 (Dart 3.13), Go 1.25, JDK 17 + Android SDK (для Android)
- Windows: Visual Studio 2022 с C++ и ATL, Inno Setup 6
- Linux: сборка на Ubuntu 24.04 (результат требует glibc 2.38+)
- Python 3.12 + PyInstaller (бэкенд zapret)

## 1. Служба ядра

```bash
cd service
# Windows
GOOS=windows GOARCH=amd64 go build -tags with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_clash_api -o ../app/bind/windows/core/karingService.exe .
# Linux
GOOS=linux GOARCH=amd64 go build -tags with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_clash_api -o ../app/bind/linux/core/karingService.so .
```

## 2. Бэкенд zapret (Windows)

```powershell
cd zapret-backend
pip install -r requirements.txt pyinstaller
.\build-desktop.ps1
```

Содержимое собранной папки положите в `app/bind/windows/zapret/` (`backend/` и `zapret-web/`).

## 3. libbox для Android

`libbox.aar` собирается из sing-box 1.12 через `gomobile bind` и кладётся в
`vpn-service/android/libs/libbox.aar` и `app/android/app/libs/libbox.aar`.

## 4. Приложение

```bash
cd app
flutter pub get
flutter build windows --release
flutter build apk --release --target-platform android-arm,android-arm64
flutter build linux --release
```

Подпись APK: заполните `app/android/key.properties` (поля `*.release`) своим keystore.
Чтобы обновления ставились поверх, все версии нужно подписывать одним и тем же ключом.

## 5. Установщики

```powershell
# Windows: Karing+-<версия>-Setup.exe в dist/
ISCC.exe /DMyAppVersion=0.1.0_b installer\inno\karingplus.iss
```

```bash
# Linux: Karing+-<версия>-linux-x64.run
cd app/build/linux/x64/release
tar -czf /tmp/bundle.tar.gz --transform "s,^bundle,karingplus," bundle
sh ../../../../../installer/linux/build-run.sh /tmp/bundle.tar.gz 0.1.0_b Karing+-0.1.0_b-linux-x64.run
```

## Версии

`X.Y.Z_b`: исправление ошибок — `Z+1`, небольшая доработка — `Y+1`, крупное обновление — `X+1`.
Версия меняется только вместе с релизом на GitHub. Номер в приложении: `AppUtils.getDisplayVersion()`
и `getBuildinVersion()` в `app/lib/app/utils/app_utils.dart`, плюс `version:` в `app/pubspec.yaml`.
