/// 界面文案层（中/英双语）。
///
/// 全 App 用户可见字符串的唯一来源：页面一律通过 `ref.watch(stringsProvider)`
/// 取 `S` 实例，禁止在 UI 里硬编码中文。技术标识符（方法名、路径、命令）
/// 保持英文原文，不进这里。
library;

import 'dart:ui' show Locale;

/// 语言设置值：system | zh | en。
S resolveStrings(String setting, Locale? platform) {
  final effective = setting == 'system'
      ? ((platform?.languageCode ?? '').startsWith('zh') ? 'zh' : 'en')
      : setting;
  return effective == 'en' ? const SEn() : const SZh();
}

/// 解析为 MaterialApp 用的 Locale（system 时返回 null 走平台）。
Locale? resolveLocale(String setting) => switch (setting) {
      'zh' => const Locale('zh'),
      'en' => const Locale('en'),
      _ => null,
    };

abstract class S {
  const S();

  // -------------------------------------------------------------------------
  // 通用
  // -------------------------------------------------------------------------
  String get cancel;
  String get save;
  String get delete;
  String get retry;
  String get refresh;
  String get rename;
  String get archive;
  String get notConnected;
  String get loadFailed;
  String get defaultLabel;

  // -------------------------------------------------------------------------
  // 设置页（本地设置）
  // -------------------------------------------------------------------------
  String get settingsTitle;
  String get sectionBehavior;
  String get sectionGeneral;
  String get sendModeTitle;
  String get sendModeSubtitle;
  String get sendModeQueue;
  String get sendModeQueueDesc;
  String get sendModeSteer;
  String get sendModeSteerDesc;
  String get languageTitle;

  // 语言选项名（两种语言下各自显示自身名称 + 跟随系统）
  String get langSystem;

  // -------------------------------------------------------------------------
  // 主页（会话 roster）
  // -------------------------------------------------------------------------
  String get fileReceived;
  String fileSavePrompt(String name, String size);
  String get ignore;
  String get saveToPhone;
  String get downloadStarted;
  String get downloadFailed;
  String get searchSessions;
  String get themeFollowSystem;
  String get themeLight;
  String get themeDark;
  String get newWorkspace;
  String get inboxTitle;
  String get appearance;
  String get backToHosts;
  String get noSessions;
  String get ungrouped;
  String get emptyRoster;
  String get newSession;
  String get chooseAgentPreset;
  String createSessionFailed(Object e);
  String createWorkspaceFailed(Object e);
  String get statusConnected;
  String get statusConnecting;
  String get statusReconnecting;
  String get statusFailed;
  String get statusOffline;
  String get renameWorkspace;
  String get deleteWorkspaceKeepData;
  String get deleteWorkspaceTitle;
  String get deleteWorkspaceBody;
  String opFailed(Object e);
  String get newSessionInWorkspace;
  String get runningSuffix;
  String get renameSessionTitle;
  String get chooseWorkspaceDir;
  String readFailed(Object e);
  String get manualPathInstead;
  String currentPath(String path);
  String get useThisPath;
  String get chooseThisDir;
  String get searchHint;
  String searchFailed(Object e);
  String get noMatchingSessions;
  String get nativePickerOnlyHint;
  String get dirPathLabel;

  // -------------------------------------------------------------------------
  // 会话页
  // -------------------------------------------------------------------------
  String get sessionTitleFallback;
  String get interruptSubagent;
  String get stopTurn;
  String get chooseModel;
  String get permissionMode;
  String get subagents;
  String get forkSession;
  String get exportLog;
  String historyLoadFailed(Object err);
  String get emptyChat;
  String get loadEarlier;
  String pickImagesFailed(Object e);
  String get addImage;
  String get hintRunningQueue;
  String get hintRunningSteer;
  String get hintInput;
  String sendFailed(Object e);
  String get thinkingEffort;
  String effortDefaultDesc(String? defaultEffort);
  String get adapterDecides;
  String get modelNotSwitchable;
  String currentModel(String provider, String model);
  String get providerNotRoutable;
  String setEffortFailed(Object e);
  String setModelFailed(Object e);
  String setPermissionFailed(Object e);
  String get cannotOpenExport;
  String get forked;
  String forkFailed(Object e);
  String get noSubagents;
  String diagnostic(String reason);
  String get continuable;
  String get oneshot;
  String get hasChildren;
  String get thinking;
  String callTool(String name);
  String get approved;
  String get rejected;
  String get cancelled;
  String get expired;
  String approveToolQ(String tool);
  String approvalOf(String tool);
  String get reject;
  String get approve;
  String get waitingHost;
  String get removeFromQueue;
  String get customAnswer;
  String get submit;
  String get goalInProgress;
  String get goalPaused;
  String get goalBlocked;
  String get goalComplete;
  String goalRounds(int started, int max);
  String get pauseGoal;
  String get resumeGoal;
  String get completeGoal;
  String get dismissGoalBanner;
  String get feedbackQuestion;
  String get helpful;
  String get problematic;
  String get feedbackNote;
  String feedbackFailed(Object e);
  String get feedbackSubmit;
  String todoProgress(int done, int total);
  String get planModePending;
  String get planModeActive;
  String get copyAll;
  String toolCallSnippet(String name);
  String get imageSnippet;
  String imageTooMany(int max);
  String get imageTooLarge;
  String get imagesTooLargeTotal;
  String get copiedToClipboard;
  String get feedbackTooltip;
  String get subagentReport;
  String get subagentDone;
  String get systemKind;
  List<String> get workingHints;
  String get compactionNotice;
  String get interruptedSuffix;

  // -------------------------------------------------------------------------
  // 工具卡片
  // -------------------------------------------------------------------------
  String get statusRunning;
  String get statusFailedBadge;
  String get statusDone;
  String get bashWaiting;
  String remainingLines(int n);
  String get readingFile;
  String writeTitle(String name);
  String middleLinesOmitted(int n);

  // -------------------------------------------------------------------------
  // 主机列表 / 编辑
  // -------------------------------------------------------------------------
  String get editHost;
  String get addHost;
  String get restartDsh;
  String get restartDshDesc;
  String get deleteHost;
  String deleteHostQ(String name);
  String get restartDshQ;
  String restartDshBody(String name);
  String get restartingDsh;
  String get dshRestarted;
  String get dshRestartWaiting;
  String restartFailed(Object e);
  String get chooseHost;
  String get emptyHosts;
  String get tokenSet;
  String get moreActions;
  String get hostNameOptional;
  String get hostNameHint;
  String get hostAddress;
  String get tokenRequired;
  String get tokenHint;
  String get connecting;
  String get testAndAdd;
  String get connectFailed;
  String get connectFailedBody;
  String get relayHint;

  // -------------------------------------------------------------------------
  // 文件收件箱
  // -------------------------------------------------------------------------
  String get fileFallback;
  String get deleteFile;
  String get deleteFileBody;
  String deletedFile(String name);
  String deleteFailedHttp(int code);
  String deleteFailed(Object e);
  String inboxReadFailed(Object e);
  String get inboxEmpty;
  String get download;

  // -------------------------------------------------------------------------
  // 本地通知
  // -------------------------------------------------------------------------
  String get notifChannelName;
  String get notifSessionFallback;
  String get notifTurnDoneTitle;
  String notifTurnDoneBody(String title);
}

// ---------------------------------------------------------------------------
// 中文
// ---------------------------------------------------------------------------
class SZh extends S {
  const SZh();

  @override
  String get cancel => '取消';
  @override
  String get save => '保存';
  @override
  String get delete => '删除';
  @override
  String get retry => '重试';
  @override
  String get refresh => '刷新';
  @override
  String get rename => '重命名';
  @override
  String get archive => '归档';
  @override
  String get notConnected => '未连接';
  @override
  String get loadFailed => '加载失败';
  @override
  String get defaultLabel => '默认';

  @override
  String get settingsTitle => '设置';
  @override
  String get sectionBehavior => '会话';
  @override
  String get sectionGeneral => '通用';
  @override
  String get sendModeTitle => '工作时发送消息';
  @override
  String get sendModeSubtitle => '回合进行中点按发送键的行为';
  @override
  String get sendModeQueue => '排队';
  @override
  String get sendModeQueueDesc => '排在当前回合之后，等它完成再发送';
  @override
  String get sendModeSteer => '插队';
  @override
  String get sendModeSteerDesc => '立即插入正在进行的回合（steer）';
  @override
  String get languageTitle => '语言';
  @override
  String get langSystem => '跟随系统';

  @override
  String get fileReceived => '收到文件';
  @override
  String fileSavePrompt(String name, String size) => '$name（$size）\n保存到手机「下载」目录？';
  @override
  String get ignore => '忽略';
  @override
  String get saveToPhone => '保存到手机';
  @override
  String get downloadStarted => '已开始下载，进度见通知栏';
  @override
  String get downloadFailed => '下载失败';
  @override
  String get searchSessions => '搜索会话内容';
  @override
  String get themeFollowSystem => '跟随系统';
  @override
  String get themeLight => '浅色（奶蓝樱花）';
  @override
  String get themeDark => '深色（暗夜粉彩）';
  @override
  String get newWorkspace => '新建 Workspace';
  @override
  String get inboxTitle => '文件收件箱';
  @override
  String get appearance => '外观主题';
  @override
  String get backToHosts => '返回主机列表';
  @override
  String get noSessions => '（无会话）';
  @override
  String get ungrouped => '未分组';
  @override
  String get emptyRoster => '还没有会话，去发起第一段对话吧';
  @override
  String get newSession => '新建会话';
  @override
  String get chooseAgentPreset => '选择 Agent 组合';
  @override
  String createSessionFailed(Object e) => '创建会话失败: $e';
  @override
  String createWorkspaceFailed(Object e) => '创建 Workspace 失败: $e';
  @override
  String get statusConnected => '已连接';
  @override
  String get statusConnecting => '连接中';
  @override
  String get statusReconnecting => '重连中';
  @override
  String get statusFailed => '失败';
  @override
  String get statusOffline => '离线';
  @override
  String get renameWorkspace => '重命名 Workspace';
  @override
  String get deleteWorkspaceKeepData => '删除 Workspace 注册（保留目录与会话）';
  @override
  String get deleteWorkspaceTitle => '删除 Workspace？';
  @override
  String get deleteWorkspaceBody => '只移除注册信息；目录与会话日志都保留，会话变为未分组。';
  @override
  String opFailed(Object e) => '操作失败: $e';
  @override
  String get newSessionInWorkspace => '在此 Workspace 新建会话';
  @override
  String get runningSuffix => ' · 运行中';
  @override
  String get renameSessionTitle => '重命名会话';
  @override
  String get chooseWorkspaceDir => '选择 Workspace 目录';
  @override
  String readFailed(Object e) => '读取失败: $e';
  @override
  String get manualPathInstead => '改为手动输入路径';
  @override
  String currentPath(String path) => '当前：$path';
  @override
  String get useThisPath => '使用此路径';
  @override
  String get chooseThisDir => '选择此目录';
  @override
  String get searchHint => '输入关键词搜索会话内容';
  @override
  String searchFailed(Object e) => '搜索失败: $e';
  @override
  String get noMatchingSessions => '没有匹配的会话';
  @override
  String get nativePickerOnlyHint => '此主机只提供原生目录选择器，手机端请手动输入绝对路径：';
  @override
  String get dirPathLabel => '目录路径';

  @override
  String get sessionTitleFallback => '会话';
  @override
  String get interruptSubagent => '打断子代理';
  @override
  String get stopTurn => '停止当前回合';
  @override
  String get chooseModel => '选择模型';
  @override
  String get permissionMode => '权限模式';
  @override
  String get subagents => '子代理';
  @override
  String get forkSession => '分叉会话';
  @override
  String get exportLog => '导出会话日志';
  @override
  String historyLoadFailed(Object err) => '历史加载失败\n$err';
  @override
  String get emptyChat => '开始新的对话吧';
  @override
  String get loadEarlier => '加载更早的消息';
  @override
  String pickImagesFailed(Object e) => '选择图片失败: $e';
  @override
  String get addImage => '添加图片';
  @override
  String get hintRunningQueue => '发送将排队；长按 🐾 立即插队（steer）';
  @override
  String get hintRunningSteer => '发送将插队；长按 🐾 改为排队';
  @override
  String get hintInput => '输入消息…';
  @override
  String sendFailed(Object e) => '发送失败: $e';
  @override
  String get thinkingEffort => '思考强度';
  @override
  String effortDefaultDesc(String? defaultEffort) => '使用适配器默认（${defaultEffort ?? "适配器决定"}）';
  @override
  String get adapterDecides => '适配器决定';
  @override
  String get modelNotSwitchable => '该会话不支持切换模型（子代理的组合由父会话决定）';
  @override
  String currentModel(String provider, String model) => '当前：$provider / $model';
  @override
  String get providerNotRoutable => '（当前 provider 不可路由）';
  @override
  String setEffortFailed(Object e) => '切换思考强度失败: $e';
  @override
  String setModelFailed(Object e) => '切换模型失败: $e';
  @override
  String setPermissionFailed(Object e) => '切换权限模式失败: $e';
  @override
  String get cannotOpenExport => '无法打开导出链接';
  @override
  String get forked => '已分叉为新会话';
  @override
  String forkFailed(Object e) => '分叉失败: $e';
  @override
  String get noSubagents => '这个会话还没有子代理';
  @override
  String diagnostic(String reason) => '诊断：$reason';
  @override
  String get continuable => '可续聊';
  @override
  String get oneshot => '一次性';
  @override
  String get hasChildren => ' · 有子级';
  @override
  String get thinking => '思考过程';
  @override
  String callTool(String name) => '调用 $name';
  @override
  String get approved => '已批准';
  @override
  String get rejected => '已拒绝';
  @override
  String get cancelled => '已取消';
  @override
  String get expired => '已失效';
  @override
  String approveToolQ(String tool) => '批准 $tool？';
  @override
  String approvalOf(String tool) => '审批 $tool';
  @override
  String get reject => '拒绝';
  @override
  String get approve => '批准';
  @override
  String get waitingHost => '等待主机确认中…';
  @override
  String get removeFromQueue => '从队列移除';
  @override
  String get customAnswer => '自定义回答（可选）';
  @override
  String get submit => '提交';
  @override
  String get goalInProgress => '进行中';
  @override
  String get goalPaused => '已暂停';
  @override
  String get goalBlocked => '受阻';
  @override
  String get goalComplete => '已完成';
  @override
  String goalRounds(int started, int max) => '（$started/$max 轮）';
  @override
  String get pauseGoal => '暂停目标';
  @override
  String get resumeGoal => '恢复目标';
  @override
  String get completeGoal => '标记完成';
  @override
  String get dismissGoalBanner => '关闭目标横幅';
  @override
  String get feedbackQuestion => '这条回答怎么样？';
  @override
  String get helpful => '有帮助';
  @override
  String get problematic => '有问题';
  @override
  String get feedbackNote => '备注（可选）';
  @override
  String feedbackFailed(Object e) => '提交失败: $e';
  @override
  String get feedbackSubmit => '提交反馈';
  @override
  String todoProgress(int done, int total) => '任务清单 $done/$total';
  @override
  String get planModePending => '计划模式（等待生效）';
  @override
  String get planModeActive => '计划模式：先出方案再动手';
  @override
  String get copyAll => '复制全文';
  @override
  String toolCallSnippet(String name) => '[工具调用 $name]';
  @override
  String get imageSnippet => '[图片]';
  @override
  String imageTooMany(int max) => '一条消息最多 $max 张图片';
  @override
  String get imageTooLarge => '单张图片超出大小限制';
  @override
  String get imagesTooLargeTotal => '图片总大小超出限制';
  @override
  String get copiedToClipboard => '已复制到剪贴板';
  @override
  String get feedbackTooltip => '反馈（赞/踩）';
  @override
  String get subagentReport => '子代理汇报';
  @override
  String get subagentDone => '子代理完成';
  @override
  String get systemKind => '系统';
  @override
  List<String> get workingHints => const [
        '妮可咪正在努力思考喵',
        '猫娘大脑飞速运转中',
        '正在给主人攒一个好回答',
        '喵呜喵呜地敲着代码',
      ];
  @override
  String get compactionNotice => '⤬ 上下文已压缩（较早的对话已折叠为摘要）';
  @override
  String get interruptedSuffix => '\n\n*（回合中断，内容未完整）*';

  @override
  String get statusRunning => '运行中';
  @override
  String get statusFailedBadge => '失败';
  @override
  String get statusDone => '完成';
  @override
  String get bashWaiting => '命令还在终端里奔跑，输出回来就自动补上…';
  @override
  String remainingLines(int n) => '… 余下 $n 行从略';
  @override
  String get readingFile => '读取中…';
  @override
  String writeTitle(String name) => '写入 $name';
  @override
  String middleLinesOmitted(int n) => '… 中间 $n 行从略';

  @override
  String get editHost => '编辑主机';
  @override
  String get addHost => '添加主机';
  @override
  String get restartDsh => '重启 dsh';
  @override
  String get restartDshDesc => '断开全部会话连接，约半分钟后恢复';
  @override
  String get deleteHost => '删除主机';
  @override
  String deleteHostQ(String name) => '删除「$name」的连接配置？此操作不影响主机上的数据。';
  @override
  String get restartDshQ => '重启 dsh？';
  @override
  String restartDshBody(String name) =>
      '「$name」上的 dsh 会停止并重新启动，所有会话连接中断，进行中的回合会被打断。上游鉴权不受影响（relay 自动处理）。';
  @override
  String get restartingDsh => '正在重启 dsh…';
  @override
  String get dshRestarted => 'dsh 已重启并就绪';
  @override
  String get dshRestartWaiting => 'dsh 已启动，等待就绪中…';
  @override
  String restartFailed(Object e) => '重启失败：$e';
  @override
  String get chooseHost => '选择主机';
  @override
  String get emptyHosts => '还没有主机，添加一台开始吧';
  @override
  String get tokenSet => '已设令牌';
  @override
  String get moreActions => '更多操作';
  @override
  String get hostNameOptional => '名称（可选）';
  @override
  String get hostNameHint => '留空则使用主机地址';
  @override
  String get hostAddress => '主机地址';
  @override
  String get tokenRequired => '访问令牌（必填）';
  @override
  String get tokenHint => '主机 ~/.dsh-remote/config.json 里的 token';
  @override
  String get connecting => '连接中…';
  @override
  String get testAndAdd => '测试并添加';
  @override
  String get connectFailed => '连接失败';
  @override
  String get connectFailedBody => '确认 relay 已在主机上运行（launchd 服务或 node relay/dsh-relay.mjs），且手机与主机在同一 Wi-Fi。';
  @override
  String get relayHint =>
      '提示：在主机上运行 `node relay/dsh-relay.mjs` 启动局域网中继，手机与主机连同一 Wi-Fi 后填写中继地址（默认端口 3081）。访问令牌在 relay 首次启动时生成，见主机 `~/.dsh-remote/config.json` 或 relay 启动日志。';

  @override
  String get fileFallback => '文件';
  @override
  String get deleteFile => '删除文件';
  @override
  String get deleteFileBody => '主机上暂存的文件会被移除；已下载到「下载」目录的副本不受影响。';
  @override
  String deletedFile(String name) => '已删除 $name';
  @override
  String deleteFailedHttp(int code) => '删除失败：HTTP $code';
  @override
  String deleteFailed(Object e) => '删除失败：$e';
  @override
  String inboxReadFailed(Object e) => '读取失败：$e';
  @override
  String get inboxEmpty => '收件箱是空的';
  @override
  String get download => '下载';

  @override
  String get notifChannelName => '回合完成';
  @override
  String get notifSessionFallback => '会话';
  @override
  String get notifTurnDoneTitle => '回合完成';
  @override
  String notifTurnDoneBody(String title) => '「$title」的回答已完成';
}

// ---------------------------------------------------------------------------
// English
// ---------------------------------------------------------------------------
class SEn extends S {
  const SEn();

  @override
  String get cancel => 'Cancel';
  @override
  String get save => 'Save';
  @override
  String get delete => 'Delete';
  @override
  String get retry => 'Retry';
  @override
  String get refresh => 'Refresh';
  @override
  String get rename => 'Rename';
  @override
  String get archive => 'Archive';
  @override
  String get notConnected => 'Not connected';
  @override
  String get loadFailed => 'Failed to load';
  @override
  String get defaultLabel => 'Default';

  @override
  String get settingsTitle => 'Settings';
  @override
  String get sectionBehavior => 'Chat';
  @override
  String get sectionGeneral => 'General';
  @override
  String get sendModeTitle => 'Sending while busy';
  @override
  String get sendModeSubtitle => 'What the send button does during a turn';
  @override
  String get sendModeQueue => 'Queue';
  @override
  String get sendModeQueueDesc => 'Wait in line and send after the current turn';
  @override
  String get sendModeSteer => 'Steer';
  @override
  String get sendModeSteerDesc => 'Inject into the running turn right away';
  @override
  String get languageTitle => 'Language';
  @override
  String get langSystem => 'System';

  @override
  String get fileReceived => 'File received';
  @override
  String fileSavePrompt(String name, String size) => '$name ($size)\nSave to the phone\'s Downloads folder?';
  @override
  String get ignore => 'Ignore';
  @override
  String get saveToPhone => 'Save to phone';
  @override
  String get downloadStarted => 'Download started — progress in the notification bar';
  @override
  String get downloadFailed => 'Download failed';
  @override
  String get searchSessions => 'Search session content';
  @override
  String get themeFollowSystem => 'System';
  @override
  String get themeLight => 'Light (milk blue & sakura)';
  @override
  String get themeDark => 'Dark (night pastel)';
  @override
  String get newWorkspace => 'New Workspace';
  @override
  String get inboxTitle => 'File Inbox';
  @override
  String get appearance => 'Appearance';
  @override
  String get backToHosts => 'Back to hosts';
  @override
  String get noSessions => '(no sessions)';
  @override
  String get ungrouped => 'Ungrouped';
  @override
  String get emptyRoster => 'No sessions yet — start your first conversation';
  @override
  String get newSession => 'New session';
  @override
  String get chooseAgentPreset => 'Choose an agent preset';
  @override
  String createSessionFailed(Object e) => 'Failed to create session: $e';
  @override
  String createWorkspaceFailed(Object e) => 'Failed to create workspace: $e';
  @override
  String get statusConnected => 'Connected';
  @override
  String get statusConnecting => 'Connecting';
  @override
  String get statusReconnecting => 'Reconnecting';
  @override
  String get statusFailed => 'Failed';
  @override
  String get statusOffline => 'Offline';
  @override
  String get renameWorkspace => 'Rename Workspace';
  @override
  String get deleteWorkspaceKeepData => 'Remove Workspace registration (keep directory & sessions)';
  @override
  String get deleteWorkspaceTitle => 'Delete Workspace?';
  @override
  String get deleteWorkspaceBody =>
      'Only the registration is removed; the directory and session logs stay. Sessions become ungrouped.';
  @override
  String opFailed(Object e) => 'Operation failed: $e';
  @override
  String get newSessionInWorkspace => 'New session in this Workspace';
  @override
  String get runningSuffix => ' · running';
  @override
  String get renameSessionTitle => 'Rename session';
  @override
  String get chooseWorkspaceDir => 'Choose a Workspace directory';
  @override
  String readFailed(Object e) => 'Read failed: $e';
  @override
  String get manualPathInstead => 'Enter path manually';
  @override
  String currentPath(String path) => 'Current: $path';
  @override
  String get useThisPath => 'Use this path';
  @override
  String get chooseThisDir => 'Choose this directory';
  @override
  String get searchHint => 'Type keywords to search session content';
  @override
  String searchFailed(Object e) => 'Search failed: $e';
  @override
  String get noMatchingSessions => 'No matching sessions';
  @override
  String get nativePickerOnlyHint =>
      'This host only offers the native directory picker — enter an absolute path manually:';
  @override
  String get dirPathLabel => 'Directory path';

  @override
  String get sessionTitleFallback => 'Session';
  @override
  String get interruptSubagent => 'Interrupt subagent';
  @override
  String get stopTurn => 'Stop current turn';
  @override
  String get chooseModel => 'Choose model';
  @override
  String get permissionMode => 'Permission mode';
  @override
  String get subagents => 'Subagents';
  @override
  String get forkSession => 'Fork session';
  @override
  String get exportLog => 'Export session log';
  @override
  String historyLoadFailed(Object err) => 'Failed to load history\n$err';
  @override
  String get emptyChat => 'Start a new conversation';
  @override
  String get loadEarlier => 'Load earlier messages';
  @override
  String pickImagesFailed(Object e) => 'Failed to pick images: $e';
  @override
  String get addImage => 'Add image';
  @override
  String get hintRunningQueue => 'Send will queue; long-press 🐾 to steer';
  @override
  String get hintRunningSteer => 'Send will steer; long-press 🐾 to queue';
  @override
  String get hintInput => 'Type a message…';
  @override
  String sendFailed(Object e) => 'Failed to send: $e';
  @override
  String get thinkingEffort => 'Thinking effort';
  @override
  String effortDefaultDesc(String? defaultEffort) =>
      'Use adapter default (${defaultEffort ?? "adapter decides"})';
  @override
  String get adapterDecides => 'adapter decides';
  @override
  String get modelNotSwitchable =>
      'This session cannot switch models (a subagent\'s preset is decided by its parent)';
  @override
  String currentModel(String provider, String model) => 'Current: $provider / $model';
  @override
  String get providerNotRoutable => '(current provider is not routable)';
  @override
  String setEffortFailed(Object e) => 'Failed to set thinking effort: $e';
  @override
  String setModelFailed(Object e) => 'Failed to switch model: $e';
  @override
  String setPermissionFailed(Object e) => 'Failed to switch permission mode: $e';
  @override
  String get cannotOpenExport => 'Cannot open the export link';
  @override
  String get forked => 'Forked into a new session';
  @override
  String forkFailed(Object e) => 'Fork failed: $e';
  @override
  String get noSubagents => 'This session has no subagents yet';
  @override
  String diagnostic(String reason) => 'Diagnostic: $reason';
  @override
  String get continuable => 'Continuable';
  @override
  String get oneshot => 'One-shot';
  @override
  String get hasChildren => ' · has children';
  @override
  String get thinking => 'Thinking';
  @override
  String callTool(String name) => 'Calling $name';
  @override
  String get approved => 'Approved';
  @override
  String get rejected => 'Rejected';
  @override
  String get cancelled => 'Cancelled';
  @override
  String get expired => 'Expired';
  @override
  String approveToolQ(String tool) => 'Approve $tool?';
  @override
  String approvalOf(String tool) => 'Approve $tool';
  @override
  String get reject => 'Reject';
  @override
  String get approve => 'Approve';
  @override
  String get waitingHost => 'Waiting for host confirmation…';
  @override
  String get removeFromQueue => 'Remove from queue';
  @override
  String get customAnswer => 'Custom answer (optional)';
  @override
  String get submit => 'Submit';
  @override
  String get goalInProgress => 'Active';
  @override
  String get goalPaused => 'Paused';
  @override
  String get goalBlocked => 'Blocked';
  @override
  String get goalComplete => 'Complete';
  @override
  String goalRounds(int started, int max) => '($started/$max rounds)';
  @override
  String get pauseGoal => 'Pause goal';
  @override
  String get resumeGoal => 'Resume goal';
  @override
  String get completeGoal => 'Mark complete';
  @override
  String get dismissGoalBanner => 'Dismiss goal banner';
  @override
  String get feedbackQuestion => 'How was this answer?';
  @override
  String get helpful => 'Helpful';
  @override
  String get problematic => 'Has issues';
  @override
  String get feedbackNote => 'Note (optional)';
  @override
  String feedbackFailed(Object e) => 'Submit failed: $e';
  @override
  String get feedbackSubmit => 'Send feedback';
  @override
  String todoProgress(int done, int total) => 'Tasks $done/$total';
  @override
  String get planModePending => 'Plan mode (pending)';
  @override
  String get planModeActive => 'Plan mode: propose before acting';
  @override
  String get copyAll => 'Copy all';
  @override
  String toolCallSnippet(String name) => '[tool call $name]';
  @override
  String get imageSnippet => '[image]';
  @override
  String imageTooMany(int max) => 'At most $max images per message';
  @override
  String get imageTooLarge => 'A single image exceeds the size limit';
  @override
  String get imagesTooLargeTotal => 'Total image size exceeds the limit';
  @override
  String get copiedToClipboard => 'Copied to clipboard';
  @override
  String get feedbackTooltip => 'Feedback (up/down)';
  @override
  String get subagentReport => 'Subagent report';
  @override
  String get subagentDone => 'Subagent finished';
  @override
  String get systemKind => 'System';
  @override
  List<String> get workingHints => const [
        'Nekomi is thinking hard, nya~',
        'Her cat-girl brain is spinning at full speed',
        'Saving up a great answer for you, Master',
        'Typing away, nya-nya-nya',
      ];
  @override
  String get compactionNotice => '⤬ Context compacted (earlier conversation folded into a summary)';
  @override
  String get interruptedSuffix => '\n\n*(turn interrupted — content incomplete)*';

  @override
  String get statusRunning => 'Running';
  @override
  String get statusFailedBadge => 'Failed';
  @override
  String get statusDone => 'Done';
  @override
  String get bashWaiting => 'The command is still running — output lands here automatically…';
  @override
  String remainingLines(int n) => '… $n more lines omitted';
  @override
  String get readingFile => 'Reading…';
  @override
  String writeTitle(String name) => 'Write $name';
  @override
  String middleLinesOmitted(int n) => '… $n middle lines omitted';

  @override
  String get editHost => 'Edit host';
  @override
  String get addHost => 'Add host';
  @override
  String get restartDsh => 'Restart dsh';
  @override
  String get restartDshDesc => 'Drops all session connections; back in about half a minute';
  @override
  String get deleteHost => 'Delete host';
  @override
  String deleteHostQ(String name) =>
      'Delete the connection config for "$name"? Data on the host is not affected.';
  @override
  String get restartDshQ => 'Restart dsh?';
  @override
  String restartDshBody(String name) =>
      'dsh on "$name" will stop and start again. All session connections drop and running turns are interrupted. Upstream auth is unaffected (the relay handles it).';
  @override
  String get restartingDsh => 'Restarting dsh…';
  @override
  String get dshRestarted => 'dsh restarted and ready';
  @override
  String get dshRestartWaiting => 'dsh started, waiting for readiness…';
  @override
  String restartFailed(Object e) => 'Restart failed: $e';
  @override
  String get chooseHost => 'Choose a host';
  @override
  String get emptyHosts => 'No hosts yet — add one to get started';
  @override
  String get tokenSet => 'Token set';
  @override
  String get moreActions => 'More actions';
  @override
  String get hostNameOptional => 'Name (optional)';
  @override
  String get hostNameHint => 'Leave empty to use the host address';
  @override
  String get hostAddress => 'Host address';
  @override
  String get tokenRequired => 'Access token (required)';
  @override
  String get tokenHint => 'The token in ~/.dsh-remote/config.json on the host';
  @override
  String get connecting => 'Connecting…';
  @override
  String get testAndAdd => 'Test & add';
  @override
  String get connectFailed => 'Connection failed';
  @override
  String get connectFailedBody =>
      'Make sure the relay is running on the host (launchd service or node relay/dsh-relay.mjs), and that the phone and host are on the same Wi-Fi.';
  @override
  String get relayHint =>
      'Tip: run `node relay/dsh-relay.mjs` on the host to start the LAN relay, then fill in the relay address (default port 3081) while the phone shares the host\'s Wi-Fi. The access token is generated on the relay\'s first launch — see `~/.dsh-remote/config.json` or the relay startup log.';

  @override
  String get fileFallback => 'File';
  @override
  String get deleteFile => 'Delete file';
  @override
  String get deleteFileBody =>
      'The staged copy on the host will be removed; copies already in the phone\'s Downloads folder are unaffected.';
  @override
  String deletedFile(String name) => 'Deleted $name';
  @override
  String deleteFailedHttp(int code) => 'Delete failed: HTTP $code';
  @override
  String deleteFailed(Object e) => 'Delete failed: $e';
  @override
  String inboxReadFailed(Object e) => 'Read failed: $e';
  @override
  String get inboxEmpty => 'Inbox is empty';
  @override
  String get download => 'Download';

  @override
  String get notifChannelName => 'Turn finished';
  @override
  String get notifSessionFallback => 'Session';
  @override
  String get notifTurnDoneTitle => 'Turn finished';
  @override
  String notifTurnDoneBody(String title) => '"$title" has finished its reply';
}
