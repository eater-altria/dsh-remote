import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'ui/home_page.dart';
import 'ui/setup_page.dart';

void main() {
  runApp(const ProviderScope(child: DshRemoteApp()));
}

class DshRemoteApp extends ConsumerWidget {
  const DshRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverUrl = ref.watch(serverProfileProvider);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F6BFF),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'DSH Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      home: serverUrl == null ? const SetupPage() : const HomePage(),
    );
  }
}
