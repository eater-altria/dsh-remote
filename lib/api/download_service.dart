/// 文件下载：relay 暂存文件的系统级下载。
///
/// Android 上交给系统 DownloadManager（写公共 Downloads 目录 + 通知栏进度，
/// APK 可直接走系统安装器）；其他平台退回外部浏览器下载。
/// relay 支持 `?token=` query 鉴权（系统下载器/浏览器无法带自定义头）。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const _downloadChannel = MethodChannel('dsh_remote/downloads');

/// 让系统下载器下载 relay 上暂存的文件。
Future<bool> launchFileDownload({
  required String baseUrl,
  required String? token,
  required String fileId,
  required String fileName,
  String? title,
}) async {
  var base = baseUrl.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final tokenQuery = token != null && token.isNotEmpty ? '?token=${Uri.encodeQueryComponent(token)}' : '';
  final url = '$base/__relay/files/$fileId$tokenQuery';
  if (Platform.isAndroid) {
    try {
      await _downloadChannel.invokeMethod('enqueue', {
        'url': url,
        'filename': fileName,
        'title': title ?? fileName,
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // 原生侧不可用时退回浏览器下载
    }
  }
  return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}
