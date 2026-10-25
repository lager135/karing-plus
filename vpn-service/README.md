# vpn_service 1.0.0

Собственная замена приватного плагина `vpn_service` для Karing+. Платформа пока только Android (minSdk 26, compileSdk 35). Ядро: sing-box libbox v1.14.3 (`libbox.aar`), поднимается через `VpnService` (TUN).

Имена:
- Dart-пакет: `vpn_service`.
- Android-пакет (Kotlin): `lfw.fly.vpn_service`. Запрошенное имя `lfw.fly.vpn-service` с дефисом не подходит ни для Dart, ни для Android, поэтому используется подчёркивание.

## Структура

- `lib/vpn_service.dart`: `FlutterVpnService`, `VpnServiceError`, `VPNServiceSetServerOptions`.
- `lib/state.dart`: `FlutterVpnServiceState`.
- `lib/proxy_manager.dart`: пустой файл (приложение его импортирует, символов не использует).
- `android/src/main/kotlin/lfw/fly/vpn_service/`:
  - `VpnServicePlugin.kt`: FlutterPlugin, MethodChannel, EventChannel, ActivityAware (запрос разрешения VPN).
  - `VpnServiceImpl.kt`: сервис `VpnService`, управление ядром через `CommandServer`, foreground-уведомление, broadcast-ы.
  - `VpnPlatformInterface.kt`: реализация `io.nekohasekai.libbox.PlatformInterface` (27 методов).
  - `VpnState.kt`: `VpnState` и `VpnStateListener`.

## Dart API

Каналы: MethodChannel `lfw.fly.vpn_service/methods`, EventChannel `lfw.fly.vpn_service/state`.

| Метод | Тип | Поведение |
|---|---|---|
| `FlutterVpnService.onStateChanged` | `Stream<FlutterVpnServiceState>` | Сразу текущее состояние, затем каждое изменение. |
| `prepare()` | `Future<bool>` | Запрос разрешения VPN (диалог системы). Нужен Activity. |
| `start(configJson, {timeout})` | `Future<VpnServiceError?>` | Запуск ядра с JSON-конфигом. Ошибка, если ядро уже работает. Возвращает null при успехе. |
| `reload(configJson, {timeout})` | `Future<VpnServiceError?>` | Перезапуск на месте (`startOrReloadService`) с новым конфигом. Ошибка, если ядро не работает. |
| `stop({timeout})` | `Future<void>` | Остановка ядра и TUN. Бросает `VpnServiceError`, если не остановилось за timeout. |
| `getState()` | `Future<FlutterVpnServiceState>` | Текущее состояние. |
| `getSystemVersion()` | `Future<String>` | Android: версия и уровень API. |
| `setExcludeFromRecents(bool)` | `Future<String?>` | Скрыть из последних задач. Возвращает текст ошибки или null. |
| `setAlwaysOn(bool)` | `Future<void>` | Android: no-op (настраивается пользователем в системе). |
| `firewallAddPorts`, `hideDockIcon` | `void` | No-op (десктоп). |
| `clashiApiConnections(bool)` | `Future<String>` | Всегда `"{}"`. |
| `isServiceAuthorized`, `authorizeService`, `getAppGroupDirectory` | разное | Нейтральные значения (desktop). |

Классы:
- `FlutterVpnServiceState`: `connected`, `connecting`, `disconnected`, `disconnecting`, `invalid`, `reasserting`.
- `VpnServiceError(String message)`.
- `VPNServiceSetServerOptions`: поля `disabledServerError`, `invalidServerError`, `expiredServerError` (строки).

## Модель состояний

Native `VpnState` отправляется в Dart в виде имени в нижнем регистре.

- `disconnected` -> `connecting` (start/reload) -> `connected`.
- Ошибка запуска: `connecting` -> `invalid` (с текстом ошибки) -> `disconnected`.
- `stop`: `connected` -> `disconnecting` -> `disconnected`.
- Потеря сети при работе: `connected` -> `reasserting`. Сеть вернулась: `reasserting` -> `connected`.
- Отзыв VPN-разрешения системой: остановка ядра, `disconnected`.

## Android: как это работает

1. `start` сохраняет JSON в `filesDir/vpn_service_config.json` (атомарно), затем запускает `VpnServiceImpl` с действием `ACTION_START`. Сервис читает файл, поэтому интент не несёт большой конфиг.
2. `Libbox.setup` (один раз за процесс), `Libbox.newCommandServer(handler, platformInterface)`, `CommandServer.startOrReloadService(config, OverrideOptions())`.
3. Ядро вызывает `openTun`: `VpnService.Builder` (адреса, маршруты, DNS, include/exclude пакеты), `establish()`, `detachFd()`. Дескриптор отдаётся libbox.
4. Исходящие сокеты ядра защищаются через `VpnService.protect(fd)` (`autoDetectInterfaceControl`).
5. Состояние публикуется в EventChannel и broadcast-ом `ACTION_STATE` (только внутри приложения). Также шлются `ACTION_START_RESULT` и `ACTION_STOPPED`.

Broadcast-действия и константы сохранены для кода Karing: `VpnServiceImpl.ACTION_START`, `ACTION_STOP`, `ACTION_START_RESULT`, `ACTION_STOPPED` (исправлено написание `ACTION_STOPED`), `ACTION_STATE`, `service_file_name`, companion `getCurrentState()`, `VpnState.CONNECTED`, `VpnState.DISCONNECTED`. Новые: `ACTION_RELOAD`.

## Что нужно приложению Karing+ (вне этой папки)

- Манифест пакета уже объявляет сервис, `BIND_VPN_SERVICE`, `specialUse` и права `FOREGROUND_SERVICE*`, `INTERNET`, `ACCESS_NETWORK_STATE`. Manifest merge подхватит их автоматически.
- Kotlin-код Karing: заменить `io.nebula.vpn_service.` на `lfw.fly.vpn_service.` (AutomationCommandReceiver.kt, TileService.kt), `ACTION_STOPED` на `ACTION_STOPPED` (TileService.kt, строки 26, 40). `GeneratedPluginRegistrant.java` пересоздастся при `flutter pub get`.
- Обёртка `lib/app/local_services/vpn_service.dart` (30 членов `VPNService`) должна вызывать новые методы: `start`, `reload`, `stop`, `getState`, `prepare`, `onStateChanged`. Конфиг передаётся строкой.
- libbox.aar: приложение уже подключает его. Плагин использует `compileOnly` из `android/libs/*.aar`. Туда нужно положить копию AAR (в git её не класть).

## Ограничения

- Не реализовано: `localDNSTransport` (возвращает null), platform shell/SSH/SFTP/user lookup, platform bridge, `findConnectionOwner` (бросает исключение), Wi-Fi state, neighbor monitor (no-op), HTTP proxy mode (`openTun` пишет warning).
- `CommandServer.start()` не вызывается (unix-socket для внешних клиентов не поднимается). Проверить на устройстве, нужен ли он для `startOrReloadService`.
- `onStateChanged` отдаёт только состояние. Map-параметр из старого `onEventStateChanged` не передаётся.
- `clashiApiConnections` всегда `"{}"`: статистика соединений не реализована.
- Файл `service_file_name` (для `allowed_sender_packages`) плагин не пишет. Кто его пишет и какой список разрешён, решает команда. Пока Karing читает только.
- Сборка Android и тесты на устройстве не запускались.
