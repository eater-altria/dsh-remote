/// 本地 App 设置（SharedPreferences 持久化，与 host 无关）。
library;

import 'dart:ui' show PlatformDispatcher, Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';

export '../l10n/strings.dart' show S, resolveLocale, resolveStrings;

const _kSendModeKey = 'dsh.sendMode'; // queue | steer
const _kLocaleKey = 'dsh.locale'; // system | zh | en

/// 回合进行中点按发送键的行为：'queue'（排队，默认）或 'steer'（插队）。
class SendModeNotifier extends Notifier<String> {
  @override
  String build() {
    _load();
    return 'queue';
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_kSendModeKey) ?? 'queue';
  }

  Future<void> setMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSendModeKey, mode);
    state = mode;
  }
}

final sendModeProvider = NotifierProvider<SendModeNotifier, String>(SendModeNotifier.new);

/// 界面语言：'system'（跟随系统，默认）| 'zh' | 'en'。
class LocaleSettingNotifier extends Notifier<String> {
  @override
  String build() {
    _load();
    return 'system';
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_kLocaleKey) ?? 'system';
  }

  Future<void> setLocale(String locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLocaleKey, locale);
    state = locale;
  }
}

final localeSettingProvider = NotifierProvider<LocaleSettingNotifier, String>(LocaleSettingNotifier.new);

/// 当前生效的文案实例（system 时按平台语言解析，取不到平台语言回退中文）。
final stringsProvider = Provider<S>((ref) {
  final setting = ref.watch(localeSettingProvider);
  Locale? platform;
  if (setting == 'system') {
    platform = PlatformDispatcher.instance.locale;
  }
  return resolveStrings(setting, platform);
});
