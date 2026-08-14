import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'ui/home_page.dart';
import 'ui/setup_page.dart';
import 'ui/theme.dart';

void main() {
  runApp(const ProviderScope(child: DshRemoteApp()));
}

class DshRemoteApp extends ConsumerWidget {
  const DshRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverUrl = ref.watch(serverProfileProvider);
    return MaterialApp(
      title: 'DSH Remote',
      debugShowCheckedModeBanner: false,
      theme: NekoTheme.light(),
      darkTheme: NekoTheme.dark(),
      home: serverUrl == null ? const SetupPage() : const HomePage(),
    );
  }
}
