import 'package:dsh_remote/l10n/strings.dart';
import 'package:dsh_remote/state/app_settings.dart';
import 'package:dsh_remote/ui/settings_page.dart';
import 'package:dsh_remote/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveStrings / resolveLocale', () {
    test('显式选择优先于平台语言', () {
      expect(resolveStrings('zh', const Locale('en')), isA<SZh>());
      expect(resolveStrings('en', const Locale('zh')), isA<SEn>());
    });

    test('system 跟随平台语言，非中文平台回退英文', () {
      expect(resolveStrings('system', const Locale('zh', 'CN')), isA<SZh>());
      expect(resolveStrings('system', const Locale('zh', 'TW')), isA<SZh>());
      expect(resolveStrings('system', const Locale('en', 'US')), isA<SEn>());
      expect(resolveStrings('system', const Locale('ja', 'JP')), isA<SEn>());
    });

    test('resolveLocale：system 返回 null 交回平台', () {
      expect(resolveLocale('system'), isNull);
      expect(resolveLocale('zh'), const Locale('zh'));
      expect(resolveLocale('en'), const Locale('en'));
    });
  });

  group('设置页', () {
    Future<void> pump(WidgetTester tester, {S strings = const SZh()}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [stringsProvider.overrideWithValue(strings)],
          child: MaterialApp(theme: NekoTheme.light(), home: const SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('两个设置项都在：工作时发送消息 + 语言', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pump(tester);
      expect(find.text('工作时发送消息'), findsOneWidget);
      expect(find.text('语言'), findsOneWidget);
      // 默认值：排队 + 跟随系统
      expect(find.text('排队'), findsOneWidget);
      expect(find.text('跟随系统'), findsOneWidget);
    });

    testWidgets('切换发送模式为插队并持久化', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pump(tester);
      await tester.tap(find.text('工作时发送消息'));
      await tester.pumpAndSettle();
      expect(find.text('立即插入正在进行的回合（steer）'), findsOneWidget);
      await tester.tap(find.text('插队'));
      await tester.pumpAndSettle();
      // trailing 显示新值
      expect(find.text('插队'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dsh.sendMode'), 'steer');
    });

    testWidgets('切换语言为 English 并持久化', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pump(tester);
      await tester.tap(find.text('语言'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dsh.locale'), 'en');
      expect(find.text('English'), findsOneWidget);
    });

    testWidgets('英文文案渲染（SEn）', (tester) async {
      SharedPreferences.setMockInitialValues({'dsh.locale': 'en', 'dsh.sendMode': 'steer'});
      await pump(tester, strings: const SEn());
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Sending while busy'), findsOneWidget);
      expect(find.text('Steer'), findsOneWidget);
      expect(find.text('Language'), findsOneWidget);
    });

    testWidgets('读取持久化值：steer + zh', (tester) async {
      SharedPreferences.setMockInitialValues({'dsh.sendMode': 'steer', 'dsh.locale': 'zh'});
      await pump(tester);
      expect(find.text('插队'), findsOneWidget);
      expect(find.text('中文'), findsOneWidget);
    });
  });
}
