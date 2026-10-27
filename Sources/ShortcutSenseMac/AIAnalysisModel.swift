import SwiftUI
import ShortcutSenseCore

/// Drives Ollama discovery and explanations for the UI.
///
/// Rules this type enforces:
/// - A request is only ever sent after an explicit user action. Nothing fires on
///   view appearance, on a timer, or on every refresh.
/// - Every task is cancellable and cancelled when the owning view goes away.
/// - The outcome always states whether it came from the local model or the
///   deterministic template, and why.
@MainActor
final class AIAnalysisModel: ObservableObject {
    @Published private(set) var status: OllamaService.Status = .disabled
    @Published private(set) var models: [OllamaModel] = []
    @Published var selectedModel: String = ""
    @Published private(set) var checking = false
    @Published private(set) var analyzing = false
    @Published private(set) var outcome: OllamaService.GenerationOutcome?
    @Published private(set) var discoveryLatency: Int = 0
    @Published private(set) var lastChecked: Date?

    private var discoveryTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    var isEnabled: Bool { AppController.shared.isAIEnabled }
    var canAnalyze: Bool { isEnabled && !selectedModel.isEmpty && !analyzing }

    var statusText: String {
        switch status {
        case .disabled:
            return L.isChinese ? "本地 AI 已关闭" : "Local AI is off"
        case .connected(let models):
            return L.isChinese ? "已连接，检测到 \(models.count) 个本地模型"
                               : "Connected — \(models.count) local model(s) found"
        case .connectedCloudOnly:
            return L.isChinese ? "Ollama 在线，但只提供云端模型，无法保证离机执行"
                               : "Ollama is running but only offers cloud models; offline execution cannot be guaranteed"
        case .installedNotRunning:
            return L.isChinese ? "已安装 Ollama，但服务未运行"
                               : "Ollama is installed but the service is not running"
        case .notInstalled:
            return L.isChinese ? "未检测到 Ollama" : "Ollama was not found"
        case .failed(let message):
            return L.isChinese ? "检测失败：\(message)" : "Check failed: \(message)"
        }
    }

    func refreshDiscovery() {
        guard isEnabled else {
            status = .disabled
            models = []
            return
        }
        checking = true
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let report = await AppController.shared.ollama.discover()
            guard !Task.isCancelled else { return }
            self.apply(report)
            self.checking = false
        }
    }

    /// Starts the installed Ollama app after the user allowed it, then re-checks.
    func startOllamaIfAllowed() {
        guard AppController.shared.allowAutoStartOllama else { return }
        checking = true
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let report = await AppController.shared.ollama.startInstalledAppAndWait()
            guard !Task.isCancelled else { return }
            self.apply(report)
            self.checking = false
        }
    }

    private func apply(_ report: OllamaService.DiscoveryReport) {
        // AI may have been switched off while discovery was in flight.
        guard isEnabled else {
            status = .disabled
            models = []
            selectedModel = ""
            return
        }
        status = report.status
        models = report.status.models.filter(\.isLocallyExecutable)
        discoveryLatency = report.latencyMilliseconds
        lastChecked = report.checkedAt
        if let resolved = AppController.shared.resolveModel(from: models) {
            selectedModel = resolved
            AppController.shared.selectedModel = resolved
        } else {
            selectedModel = ""
        }
        // If the app is installed but not running and the user already allowed
        // auto-start, try once. Never loops, never starts a service unasked.
        if case .installedNotRunning = status,
           AppController.shared.allowAutoStartOllama,
           isEnabled {
            startOllamaIfAllowed()
        }
    }

    func analyze(_ request: AIExplanationRequest) {
        guard canAnalyze else { return }
        analyzing = true
        outcome = nil
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            guard let self else { return }
            // Re-checked here, not only at the button: the user can switch AI off
            // while the task is queued, and no request may be sent after that.
            guard !Task.isCancelled, self.isEnabled else {
                self.analyzing = false
                return
            }
            let result = await AppController.shared.ollama.explain(request, model: self.selectedModel)
            guard !Task.isCancelled else { return }
            self.outcome = result
            self.analyzing = false
        }
    }

    /// A fixed request used only by the Settings self-test.
    ///
    /// It deliberately carries no user data: the point is to prove that discovery,
    /// generation and schema validation work, not to produce an opinion. The result
    /// is labelled as a test so it cannot be mistaken for a real recommendation.
    static let selfTestRequest = AIExplanationRequest(
        type: "connectivity_test", appName: "Connectivity test",
        observedActivations7d: 0, originLabel: "unknown_origin", activeDays: 0,
        proposedShortcut: "none", conflictStatus: "unknown", confidence: "unknown")

    func runSelfTest() {
        analyze(Self.selfTestRequest)
    }

    func cancel() {
        analysisTask?.cancel()
        analysisTask = nil
        analyzing = false
    }

    func stop() {
        discoveryTask?.cancel()
        analysisTask?.cancel()
        discoveryTask = nil
        analysisTask = nil
    }
}

/// Builds the aggregate request for a recommendation card. Only whitelisted fields.
extension AIExplanationRequest {
    init(card: RecommendationCardModel) {
        self.init(
            type: card.kind.rawValue,
            appName: card.appName,
            observedActivations7d: card.observedCount ?? 0,
            originLabel: card.provenanceNote == .launchFocusInferred
                ? "unknown_origin" : card.provenanceNote.rawValue,
            activeDays: card.activeDays ?? 0,
            proposedShortcut: card.proposedCombo?.displayString ?? "none",
            conflictStatus: card.conflict.status.rawValue,
            confidence: card.confidence.rawValue,
            estimatedMinutesSaved: nil)
    }
}

/// Result panel shared by the recommendation detail and the weekly review.
struct AIExplanationPanel: View {
    @ObservedObject var model: AIAnalysisModel
    let request: AIExplanationRequest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(model.canAnalyze ? Theme.accent : .secondary)
                Text(L.isChinese ? "本地 AI 分析" : "Local AI analysis")
                    .font(Theme.Font.cardTitle)
                Spacer()
                if model.analyzing {
                    ProgressView().controlSize(.small)
                    Button(L.t("common.cancel")) { model.cancel() }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                } else {
                    Button(L.isChinese ? "用本地 AI 分析" : "Analyze with local AI") {
                        model.analyze(request)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.canAnalyze)
                }
            }

            Text(model.statusText)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)

            if !model.isEnabled {
                Text(L.isChinese
                     ? "在设置里开启「本地 AI 解释」后可用。开启前不会发出任何请求。"
                     : "Enable local AI in Settings. Nothing is sent before you do.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            if let outcome = model.outcome {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: outcome.usedFallback
                          ? "doc.text" : "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(outcome.usedFallback ? .orange : .green)
                    Text(outcome.usedFallback
                         ? (L.isChinese ? "内置模板（模型未参与）" : "Built-in template (model not used)")
                         : (L.isChinese ? "本地模型 \(outcome.model)"
                                        : "Local model \(outcome.model)"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(outcome.usedFallback ? .orange : .green)
                    Spacer()
                    Text("\(outcome.latencyMilliseconds) ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let reason = outcome.fallbackReason {
                    Text(reason)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(outcome.explanation.reason)
                    .font(.system(size: 12, weight: .semibold))
                Text(outcome.explanation.explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L.isChinese
                     ? "这是模型生成的解释，不是测量结果。它不能修改任何设置。"
                     : "This is generated explanation, not a measurement. It cannot change any setting.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        // Discovery is a read-only GET, issued only when AI is enabled; generation
        // never starts merely because a view appeared.
        .onAppear {
            if model.isEnabled && model.models.isEmpty { model.refreshDiscovery() }
        }
        .onDisappear { model.cancel() }
    }
}
