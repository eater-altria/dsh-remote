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
