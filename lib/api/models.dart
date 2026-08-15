/// Data models for the DSH wire contract (parsed loosely: the host is the
/// validating side; the client tolerates unknown fields).
library;

/// `host.describe` response.
class HostDescription {
  HostDescription({
    required this.version,
    required this.cwd,
    this.provider,
    this.model,
    required this.attachedSessions,
    required this.canOpenPath,
  });

  final String version;
  final String cwd;
  final String? provider;
  final String? model;
  final int attachedSessions;
  final bool canOpenPath;

  factory HostDescription.fromJson(Map<String, dynamic> json) => HostDescription(
        version: json['version'] as String? ?? '?',
        cwd: json['cwd'] as String? ?? '',
        provider: json['provider'] as String?,
        model: json['model'] as String?,
        attachedSessions: (json['attachedSessions'] as num?)?.toInt() ?? 0,
        canOpenPath: json['canOpenPath'] as bool? ?? false,
      );
}

/// `workspace.*` WorkspaceView row.
class WorkspaceView {
  WorkspaceView({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
  });

  final String workspaceId;
  final String path;
  final String title;
  final List<String> sessionIds;

  factory WorkspaceView.fromJson(Map<String, dynamic> json) => WorkspaceView(
        workspaceId: json['workspaceId'] as String? ?? '',
        path: json['path'] as String? ?? '',
        title: json['title'] as String? ?? '',
        sessionIds: (json['sessionIds'] as List?)?.whereType<String>().toList() ?? const [],
      );
}

/// `session.list` SessionSummary row. `title` comes from the generic
/// projections block (key `title`) when present.
class SessionSummary {
  SessionSummary({
    required this.sessionId,
    required this.updatedAt,
    required this.running,
    required this.blank,
    this.parentSessionId,
    this.isSubagent = false,
    this.cwd,
    this.agentPreset,
    this.title,
  });

  final String sessionId;
  final double updatedAt;
  final bool running;
  final bool blank;
  final String? parentSessionId;
  final bool isSubagent;
  final String? cwd;
  final String? agentPreset;
  String? title;

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    String? title;
    final projections = json['projections'];
    if (projections is Map<String, dynamic>) {
      final values = projections['values'];
      if (values is Map<String, dynamic>) title = values['title'] as String?;
    }
    return SessionSummary(
      sessionId: json['sessionId'] as String? ?? '',
      updatedAt: (json['updatedAt'] as num?)?.toDouble() ?? 0,
      running: json['running'] as bool? ?? false,
      blank: json['blank'] as bool? ?? false,
      parentSessionId: json['parentSessionId'] as String?,
      isSubagent: json['origin'] == 'subagent',
      cwd: json['cwd'] as String?,
      agentPreset: json['agentPreset'] as String?,
      title: title,
    );
  }
}

/// One `question/requested` item (askUserQuestion tool contract).
class QuestionItem {
  QuestionItem({
    required this.id,
    required this.question,
    this.header,
    this.detail,
    this.options = const [],
    this.multiSelect = false,
  });

  final String id;
  final String question;
  final String? header;
  final String? detail;
  final List<QuestionOption> options;
  final bool multiSelect;

  factory QuestionItem.fromJson(Map<String, dynamic> json) => QuestionItem(
        id: json['id'] as String? ?? '',
        question: json['question'] as String? ?? '',
        header: json['header'] as String?,
        detail: json['detail'] as String?,
        options: (json['options'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(QuestionOption.fromJson)
                .toList() ??
            const [],
        multiSelect: json['multiSelect'] as bool? ?? false,
      );
}

class QuestionOption {
  QuestionOption({required this.label, this.description});

  final String label;
  final String? description;

  factory QuestionOption.fromJson(Map<String, dynamic> json) => QuestionOption(
        label: json['label'] as String? ?? '',
        description: json['description'] as String?,
      );
}

/// A pending host-owned interaction surfaced on the mux stream.
class PendingQuestion {
  PendingQuestion({required this.rpcId, required this.sessionId, required this.questions});

  final String rpcId;
  final String sessionId;
  final List<QuestionItem> questions;
}

class PendingApproval {
  PendingApproval({
    required this.rpcId,
    required this.sessionId,
    required this.approvalId,
    required this.toolName,
    this.callId,
    this.reason,
  });

  final String rpcId;
  final String sessionId;
  final String approvalId;
  final String toolName;
  final String? callId;
  final String? reason;
}

/// One queued-inbox entry from `session/queue` frames.
class QueueItem {
  QueueItem({required this.id, required this.placement, required this.text});

  final String id;
  final String placement; // queued | steering | context
  final String text;
}

/// `session.models` selection.
class ModelSelection {
  ModelSelection({required this.provider, required this.model, this.reasoningEffort});

  final String provider;
  final String model;
  final String? reasoningEffort;

  factory ModelSelection.fromJson(Map<String, dynamic> json) => ModelSelection(
        provider: json['provider'] as String? ?? '',
        model: json['model'] as String? ?? '',
        reasoningEffort: json['reasoningEffort'] as String?,
      );
}

/// `session.models` 的 provider 分组目录。
class ModelProviderGroup {
  ModelProviderGroup({required this.id, required this.name, required this.models});

  final String id;
  final String name;
  final List<ModelCatalogModel> models;

  factory ModelProviderGroup.fromJson(Map<String, dynamic> json) => ModelProviderGroup(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        models: (json['models'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(ModelCatalogModel.fromJson)
                .toList() ??
            const [],
      );
}

class ModelCatalogModel {
  ModelCatalogModel({required this.id, required this.name, this.description});

  final String id;
  final String name;
  final String? description;

  factory ModelCatalogModel.fromJson(Map<String, dynamic> json) => ModelCatalogModel(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String?,
      );
}

/// `skill.list` 条目。
class SkillEntry {
  SkillEntry({required this.name, required this.description, this.whenToUse, required this.modelInvocable});

  final String name;
  final String description;
  final String? whenToUse;
  final bool modelInvocable;

  factory SkillEntry.fromJson(Map<String, dynamic> json) => SkillEntry(
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        whenToUse: json['whenToUse'] as String?,
        modelInvocable: json['modelInvocable'] as bool? ?? true,
      );
}

/// `goal` 会话投影（goal.* 变更的读侧）。
class GoalView {
  GoalView({
    required this.id,
    required this.revision,
    required this.objective,
    required this.phase,
    required this.roundsStarted,
    required this.maxGoalRounds,
    this.blockedReason,
  });

  final String id;
  final int revision;
  final String objective;
  final String phase; // active | paused | blocked | complete | none
  final int roundsStarted;
  final int maxGoalRounds;
  final String? blockedReason;

  factory GoalView.fromProjection(dynamic value) {
    if (value is! Map<String, dynamic>) return empty;
    final goal = value['goal'];
    if (goal is! Map<String, dynamic>) return empty;
    final blocked = goal['blockedReason'];
    return GoalView(
      id: goal['id'] as String? ?? '',
      revision: (goal['revision'] as num?)?.toInt() ?? 0,
      objective: goal['objective'] as String? ?? '',
      phase: goal['phase'] as String? ?? 'active',
      roundsStarted: (value['roundsStarted'] as num?)?.toInt() ?? 0,
      maxGoalRounds: (goal['maxGoalRounds'] as num?)?.toInt() ?? 0,
      blockedReason: blocked is Map<String, dynamic> ? blocked['message'] as String? : null,
    );
  }

  static final GoalView empty = GoalView(
    id: '',
    revision: 0,
    objective: '',
    phase: 'none',
    roundsStarted: 0,
    maxGoalRounds: 0,
  );

  bool get exists => id.isNotEmpty;
}

/// `host.listDirectory` 的目录条目。
class DirectoryEntry {
  DirectoryEntry({required this.name, required this.path, required this.hidden});

  final String name;
  final String path;
  final bool hidden;

  factory DirectoryEntry.fromJson(Map<String, dynamic> json) => DirectoryEntry(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        hidden: json['hidden'] as bool? ?? false,
      );
}

class DirectoryListing {
  DirectoryListing({required this.path, required this.home, required this.crumbs, required this.entries});

  final String path;
  final String home;
  final List<DirectoryEntry> crumbs;
  final List<DirectoryEntry> entries;

  factory DirectoryListing.fromJson(Map<String, dynamic> json) => DirectoryListing(
        path: json['path'] as String? ?? '',
        home: json['home'] as String? ?? '',
        crumbs:
            (json['crumbs'] as List?)?.whereType<Map<String, dynamic>>().map(DirectoryEntry.fromJson).toList() ??
                const [],
        entries:
            (json['entries'] as List?)?.whereType<Map<String, dynamic>>().map(DirectoryEntry.fromJson).toList() ??
                const [],
      );
}

/// `session.search` 命中。
class SessionSearchItem {
  SessionSearchItem({required this.sessionId, required this.snippet});

  final String sessionId;
  final String snippet;

  factory SessionSearchItem.fromJson(Map<String, dynamic> json) => SessionSearchItem(
        sessionId: json['sessionId'] as String? ?? '',
        snippet: json['snippet'] as String? ?? '',
      );
}
