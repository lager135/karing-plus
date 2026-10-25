// Karing+: Russian sites that go around the VPN on Windows and Linux (the desktop counterpart of
// RuApps). Matched as domain suffixes: the national zones plus Russian services on other zones.
class RuSites {
  static const List<String> domainSuffixes = [
    // national zones: .ru, .su, .рф, .москва, .рус, .дети, .tatar
    "ru",
    "su",
    "xn--p1ai",
    "xn--80adxhks",
    "xn--p1acf",
    "xn--d1acj3b",
    "tatar",
    // Yandex
    "yandex.com",
    "yandex.net",
    "yastatic.net",
    "yandexcloud.net",
    "yandex.cloud",
    // VK, Odnoklassniki, Mail.ru group CDNs
    "vk.com",
    "vk.me",
    "userapi.com",
    "vkuser.net",
    "vk-cdn.net",
    "vkuservideo.net",
    "vkuseraudio.net",
    "mycdn.me",
    // marketplaces and others
    "avito.st",
    "wbstatic.net",
    "sberbank.com",
    "2gis.com",
  ];
}
