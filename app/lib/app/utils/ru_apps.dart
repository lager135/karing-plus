// Karing+: Russian apps (banks, government services, marketplaces, carriers) that refuse to work
// through a VPN. On Android they are left out of the VPN (split tunnel), so they use the normal
// connection. Packages that are not installed are skipped by the plugin.
class RuApps {
  static const List<String> packages = [
    // banks and payments
    "ru.sberbankmobile",
    "com.idamob.tinkoff.android",
    "ru.vtb24.mobilebanking.android",
    "ru.alfabank.mobile.android",
    "ru.gazprombank.android.mobilebank.app",
    "ru.raiffeisennews",
    "ru.rshb.dbo",
    "com.openbank",
    "ru.letobank.Prometheus",
    "ru.mts.money",
    "logo.com.mbanking",
    "ru.ozon.fintech.finance",
    "ru.yoo.money",
    "ru.nspk.mirpay",
    "ru.nspk.sbpay",
    // government services
    "ru.rostel",
    "ru.fns.lkfl",
    "com.gnivts.selfemployed",
    "com.octopod.russianpost.client.android",
    // marketplaces and services
    "ru.ozon.app.android",
    "com.wildberries.ru",
    "ru.beru.android",
    "com.avito.android",
    "ru.vk.store",
    "ru.dublgis.dgismobile",
    "ru.yandex.taxi",
    "ru.yandex.yandexmaps",
    "ru.yandex.searchplugin",
    "com.yandex.searchapp",
    "ru.yandex.music",
    "ru.kinopoisk",
    "ru.more.play",
    "ru.rutube.app",
    "ru.zen.android",
    // social and messengers
    "com.vkontakte.android",
    "ru.oneme.app",
    "ru.mail.mailapp",
    // carriers
    "ru.megafon.mlk",
    "ru.mts.mymts",
    "ru.beeline.services",
    "ru.tele2.mytele2",
  ];
}
