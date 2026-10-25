// ignore_for_file: unused_catch_stack

import 'dart:io';
import 'package:build_info/build_info.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:karing/app/modules/karingplus_update.dart';
import 'package:karing/app/utils/build_flags.dart';
import 'package:karing/app/utils/url_launcher_utils.dart';
import 'package:karing/app/modules/auto_update_manager.dart';
import 'package:karing/app/modules/biz.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/analytics_utils.dart';
import 'package:karing/app/utils/app_utils.dart';
import 'package:karing/app/utils/file_utils.dart';
import 'package:karing/app/utils/install_referrer_utils.dart';
import 'package:karing/app/utils/path_utils.dart';
import 'package:karing/app/utils/platform_utils.dart';
import 'package:karing/app/utils/proxy_conf_utils.dart';
import 'package:karing/app/utils/singbox_json_utils.dart';
import 'package:karing/i18n/strings.g.dart';
import 'package:karing/screens/dialog_utils.dart';
import 'package:karing/screens/file_content_viewer_screen.dart';
import 'package:karing/screens/group_item_creator.dart';
import 'package:karing/screens/group_item_options.dart';
import 'package:karing/screens/group_screen.dart';
import 'package:karing/screens/theme_config.dart';
import 'package:karing/screens/hash_string_screen.dart';
import 'package:karing/screens/webview_helper.dart';
import 'package:karing/screens/widgets/framework.dart';
import 'package:path/path.dart' as path;

class AboutScreen extends LasyRenderingStatefulWidget {
  static RouteSettings routSettings() {
    return const RouteSettings(name: "AboutScreen");
  }

  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => AboutScreenState();
}

class AboutScreenState extends LasyRenderingState<AboutScreen> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    if (SettingManager.getDirty()) {
      SettingManager.saveConfig();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tcontext = Translations.of(context);
    Size windowSize = MediaQuery.of(context).size;
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.zero,
        child: AppBar(),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      child: const SizedBox(
                        width: 50,
                        height: 30,
                        child: Icon(
                          Icons.arrow_back_ios_outlined,
                          size: 26,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: windowSize.width - 50 * 2,
                      child: Text(
                        tcontext.meta.about,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: ThemeConfig.kFontWeightTitle,
                            fontSize: ThemeConfig.kFontSizeTitle),
                      ),
                    ),
                    const SizedBox(
                      width: 50,
                    ),
                  ],
                ),
              ),
              const SizedBox(
                height: 10,
              ),
              InkWell(
                onDoubleTap: () {
                  SettingManager.getConfig().dev.devMode =
                      !SettingManager.getConfig().dev.devMode;

                  setState(() {});
                },
                child: Stack(children: [
                  Image.asset(
                    "assets/images/app_icon_128.png",
                    width: 128,
                    height: 128,
                  ),
                  SettingManager.getConfig().dev.devMode
                      ? Positioned(
                          left: 100,
                          top: 100,
                          child: Icon(
                            Icons.logo_dev,
                            size: 26,
                          ),
                        )
                      : const SizedBox(
                          width: 0,
                        ),
                ]),
              ),
              const SizedBox(
                height: 10,
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: FutureBuilder(
                    future: getGroupOptions(),
                    builder: (BuildContext context,
                        AsyncSnapshot<List<GroupItem>> snapshot) {
                      List<GroupItem> data =
                          snapshot.hasData ? snapshot.data! : [];
                      return Column(
                          children:
                              GroupItemCreator.createGroups(context, data));
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> startVPN() async {
    return await Biz.startVPN(context, true, "AboutScreen");
  }

  Future<List<GroupItem>> getGroupOptions() async {
    final tcontext = Translations.of(context);
    var settingConfig = SettingManager.getConfig();
    var dev = settingConfig.dev;
    List<GroupItem> groupOptions = [];
    late BuildInfoData? buildInfo;
    if (!Platform.isLinux) {
      buildInfo = await BuildInfo.fromPlatform();
    }
    {
      List<GroupItemOptions> options = [
        GroupItemOptions(
            textOptions: GroupItemTextOptions(
          name: tcontext.meta.name,
          text: AppUtils.getName(),
        )),
        GroupItemOptions(
            textOptions: GroupItemTextOptions(
          name: tcontext.meta.version,
          text: AppUtils.getDisplayVersion(),
        )),
        GroupItemOptions(
            textOptions: GroupItemTextOptions(
          name: tcontext.AboutScreen.installRefer,
          text: await InstallReferrerUtils.getString(),
        )),
        dev.devMode && buildInfo != null
            ? GroupItemOptions(
                textOptions: GroupItemTextOptions(
                name: tcontext.AboutScreen.installTime,
                text: buildInfo.installDate.toString(),
              ))
            : GroupItemOptions(),
        AutoUpdateManager.isSupport()
            ? GroupItemOptions(
                pushOptions: GroupItemPushOptions(
                    name: tcontext.AboutScreen.versionChannel,
                    text: SettingManager.getConfig().autoUpdateChannel,
                    onPush: () async {
                      onTapAutoUpdateChannel();
                    }))
            : GroupItemOptions()
      ];

      groupOptions.add(GroupItem(options: options));
    }
    {
      // Karing+ is a fork of Karing (GPL-3.0). Credit the original authors and link the project.
      final ru = settingConfig.languageTag.startsWith("ru");
      List<GroupItemOptions> options = [
        GroupItemOptions(
            pushOptions: GroupItemPushOptions(
                name: ru ? "Релизы Karing+" : "Karing+ releases",
                text: "github.com/${KaringPlusUpdate.repo}",
                onPush: () async {
                  await UrlLauncherUtils.loadUrl(KaringPlusUpdate.releasesUrl);
                })),
        GroupItemOptions(
            textOptions: GroupItemTextOptions(
          name: ru ? "Основано на" : "Based on",
          text: ru
              ? "Karing, автор nebula (KaringX)"
              : "Karing by nebula (KaringX)",
        )),
        GroupItemOptions(
            pushOptions: GroupItemPushOptions(
                name: ru ? "Оригинальный проект" : "Original project",
                text: "github.com/KaringX/karing",
                onPush: () async {
                  await UrlLauncherUtils.loadUrl(
                      "https://github.com/KaringX/karing");
                })),
        GroupItemOptions(
            textOptions: GroupItemTextOptions(
          name: ru ? "Лицензия" : "License",
          text: "GNU GPL v3",
        )),
      ];
      groupOptions.add(GroupItem(
          name: ru ? "Оригинальный проект" : "Original project",
          options: options));
    }
    if (BuildFlags.debug) {
      // Karing+ test builds: send the logs to the developers by any app (messenger, mail).
      final ruD = settingConfig.languageTag.startsWith("ru");
      groupOptions.add(GroupItem(name: "DEBUG", options: [
        GroupItemOptions(
            pushOptions: GroupItemPushOptions(
                name: ruD ? "Поделиться логами" : "Share logs",
                onPush: () async {
                  final files = <XFile>[];
                  for (final p in [
                    await PathUtils.logFilePath(),
                    await PathUtils.serviceLogFilePath(),
                    await PathUtils.serviceStdErrorFilePath(),
                  ]) {
                    if (await File(p).exists()) files.add(XFile(p));
                  }
                  if (files.isEmpty) return;
                  await Share.shareXFiles(files, subject: "Karing+ logs");
                })),
      ]));
    }

    List<GroupItemOptions> options = [
      GroupItemOptions(
          pushOptions: GroupItemPushOptions(
              name: tcontext.AboutScreen.devOptions,
              onPush: () async {
                onTapDevOptions();
              }))
    ];
    groupOptions.add(GroupItem(options: options));

    return groupOptions;
  }

  void onTapDevOptions() async {
    final tcontext = Translations.of(context);
    var settingConfig = SettingManager.getConfig();
    var dev = settingConfig.dev;

    AnalyticsUtils.logEvent(
        analyticsEventType: analyticsEventTypeUA,
        name: 'SSS_devOptions',
        repeatable: false);
    Future<List<GroupItem>> getOptions(
        BuildContext context, SetStateCallback? setstate) async {
      List<GroupItemOptions> options = [
        GroupItemOptions(
            pushOptions: GroupItemPushOptions(
                name: tcontext.AboutScreen.viewFilsContent,
                onPush: () async {
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          settings: FileContentViewerScreen.routSettings(),
                          builder: (context) =>
                              const FileContentViewerScreen()));
                })),
        PlatformUtils.isPC()
            ? GroupItemOptions(
                pushOptions: GroupItemPushOptions(
                    name: tcontext.meta.openDir,
                    onPush: () async {
                      await FileUtils.openDirectory(
                          await PathUtils.profileDir());
                    }))
            : GroupItemOptions(),
      ];

      List<GroupItemOptions> options0 = [
        GroupItemOptions(
            pushOptions: GroupItemPushOptions(
                name: tcontext.AboutScreen.useOriginalSBProfile,
                text: path.basename(settingConfig.originSBProfile),
                textWidthPercent: 0.4,
                onPush: () async {
                  await onTapUseOriginSBProfile();
                }))
      ];
      List<GroupItemOptions> options1 = [
        GroupItemOptions(
            switchOptions: GroupItemSwitchOptions(
                name: tcontext.AboutScreen.enableDebugLog,
                switchValue: dev.enableDebugLog,
                onSwitch: (bool value) async {
                  dev.enableDebugLog = value;
                  SettingManager.setDirty(true);
                  setState(() {});
                }))
      ];
      if (!dev.devMode) {
        return [
          GroupItem(options: options),
          GroupItem(options: options0),
          GroupItem(options: options1),
        ];
      }
      List<GroupItemOptions> options2 = [];
      List<GroupItemOptions> options3 = [];
      List<GroupItemOptions> options4 = [];

      options2.add(GroupItemOptions(
          switchOptions: GroupItemSwitchOptions(
              name: tcontext.AboutScreen.enablePprof,
              switchValue: settingConfig.dev.pprofPort ==
                  SettingConfigItemDev.pprofPortDefault,
              onSwitch: (bool value) async {
                settingConfig.dev.pprofPort =
                    value ? SettingConfigItemDev.pprofPortDefault : 0;
                SettingManager.setDirty(true);
                setState(() {});
              })));
      if (settingConfig.dev.pprofPort != 0) {
        options2.add(GroupItemOptions(
            switchOptions: GroupItemSwitchOptions(
                name: tcontext.AboutScreen.allowRemoteAccessPprof,
                switchValue: settingConfig.dev.allowRemoteAccessPprof,
                onSwitch: (bool value) async {
                  settingConfig.dev.allowRemoteAccessPprof = value;
                  SettingManager.setDirty(true);
                  setState(() {});
                })));
        options2.add(GroupItemOptions(
            pushOptions: GroupItemPushOptions(
                name: tcontext.AboutScreen.pprofPanel,
                onPush: () async {
                  bool ok = await startVPN();
                  if (!ok) {
                    return;
                  }
                  if (!context.mounted) {
                    return;
                  }
                  await WebviewHelper.loadUrl(
                      context,
                      "http://127.0.0.1:${settingConfig.dev.pprofPort}/debug/pprof/",
                      "pprof",
                      title: tcontext.AboutScreen.pprofPanel);
                })));
      }
      options3.add(GroupItemOptions(
          switchOptions: GroupItemSwitchOptions(
              name: tcontext.AboutScreen.allowRemoteAccessHtmlBoard,
              switchValue: settingConfig.dev.allowRemoteAccessHtmlBoard,
              onSwitch: (bool value) async {
                settingConfig.dev.allowRemoteAccessHtmlBoard = value;
                SettingManager.setDirty(true);
                setState(() {});
              })));

      if (Platform.isWindows) {
        options4.add(GroupItemOptions(
            pushOptions: GroupItemPushOptions(
                name: "Hash String",
                onPush: () async {
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          settings: HashStringScreen.routSettings(),
                          builder: (context) => const HashStringScreen()));
                })));
      }

      return [
        GroupItem(options: options),
        GroupItem(options: options0),
        GroupItem(options: options1),
        GroupItem(options: options2),
        GroupItem(options: options3),
        GroupItem(options: options4),
      ];
    }

    await Navigator.push(
        context,
        MaterialPageRoute(
            settings: GroupScreen.routSettings("devOptions"),
            builder: (context) => GroupScreen(
                  title: tcontext.AboutScreen.devOptions,
                  getOptions: getOptions,
                )));
    setState(() {});
  }

  void onTapAutoUpdateChannel() async {
    final tcontext = Translations.of(context);

    Future<List<GroupItem>> getOptions(
        BuildContext context, SetStateCallback? setstate) async {
      List<GroupItemOptions> options = [];

      for (var channel in AutoUpdateManager.updateChannels()) {
        options.add(GroupItemOptions(
            textOptions: GroupItemTextOptions(
                name: channel,
                text: "",
                onPush: () async {
                  if (SettingManager.getConfig().autoUpdateChannel == channel) {
                    return;
                  }
                  SettingManager.getConfig().autoUpdateChannel = channel;

                  AutoUpdateManager.updateChannelChanged();
                  Navigator.pop(context);
                })));
      }
      return [GroupItem(options: options)];
    }

    await Navigator.push(
        context,
        MaterialPageRoute(
            settings: GroupScreen.routSettings("versionChannel"),
            builder: (context) => GroupScreen(
                  title: tcontext.AboutScreen.versionChannel,
                  getOptions: getOptions,
                )));
    setState(() {});
  }

  Future<void> onTapUseOriginSBProfile() async {
    if (SettingManager.getConfig().originSBProfile.isNotEmpty) {
      bool? ok = await DialogUtils.showConfirmDialog(context, "Clear ?");
      if (ok == true) {
        SettingManager.getConfig().originSBProfile = "";
        setState(() {});
        SettingManager.setDirty(true);
      }

      return;
    }
    try {
      List<String> extensions = ["json"];
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
      );
      if (result != null) {
        String filePath = result.files.first.path!;
        String ext = path.extension(filePath).replaceAll('.', '').toLowerCase();
        if (!extensions.contains(ext)) {
          return;
        }
        var file = File(filePath);
        String content = await file.readAsString();
        ServerConfigGroupItem proxyItem = ServerConfigGroupItem();
        List<ServerDiversionGroupRuleSetItem> rulesetItems = [];
        TransExceptionAndUnsupport eu = TransExceptionAndUnsupport();

        var cresult = SingboxJsonUtils.tryConvert(
            content, proxyItem, rulesetItems, null, eu);
        if (cresult.error != null) {
          if (!mounted) {
            return;
          }
          DialogUtils.showAlertDialog(
              context, cresult.error!.message.toString(),
              showCopy: true, showFAQ: true, withVersion: true);
          return;
        }
        SettingManager.getConfig().originSBProfile = filePath;
        setState(() {});
        SettingManager.setDirty(true);
      }
    } catch (err, stacktrace) {
      if (!mounted) {
        return;
      }
      DialogUtils.showAlertDialog(context, err.toString(),
          showCopy: true, showFAQ: true, withVersion: true);
    }
  }
}
