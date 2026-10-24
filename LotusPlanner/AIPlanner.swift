import Foundation

enum PlannerAssistantError: LocalizedError {
    case unavailable(AIProvider)
    case execution(String)
    case invalidResponse(AIProvider)

    var errorDescription: String? {
        switch self {
        case .unavailable(.codex):
            "لم يُعثر على Codex على الجهاز. يلزم تثبيت تطبيق ChatGPT أو أداة codex وتسجيل الدخول."
        case .unavailable(.claude):
            "لم يُعثر على Claude Code على الجهاز. يلزم تثبيت أداة claude وتسجيل الدخول بحساب Claude."
        case .execution(let message):
            message
        case .invalidResponse(let provider):
            "وصلت نتيجة غير مكتملة من \(provider == .codex ? "Codex" : "Claude"). يرجى المحاولة مرة أخرى."
        }
    }
}

/// المساعد الذكي. يعمل عبر أداة محلية مثبتة على الجهاز (codex أو claude)،
/// فلا يتصل التطبيق نفسه بالإنترنت ولا يخزّن أي مفاتيح.
struct PlannerAssistant {
    let provider: AIProvider
    let model: String

    static func isAvailable(_ provider: AIProvider) -> Bool {
        executableURL(for: provider) != nil
    }

    /// يقرأ تفاصيل المهام كتعليمات: يستخرج الخطوات المذكورة صراحةً وطلبات
    /// التخطيط والتذكير فقط. الاقتراحات لا تُطلب إلا بزر «اقتراح خطوات».
    func interpret(tasks: [PlannerTask], mode: PlannerAIMode, date: Date) async throws -> PlannerAIResult {
        guard let executableURL = Self.executableURL(for: provider) else {
            throw PlannerAssistantError.unavailable(provider)
        }
        let prompt = try planningPrompt(tasks: tasks, mode: mode, date: date)
        let selectedProvider = provider
        let selectedModel = model
        return try await Task.detached(priority: .userInitiated) {
            switch selectedProvider {
            case .codex:
                try runCodex(executableURL: executableURL, model: selectedModel, prompt: prompt, date: date)
            case .claude:
                try runClaude(executableURL: executableURL, model: selectedModel, prompt: prompt, date: date)
            }
        }.value
    }

    static func executableURL(for provider: AIProvider) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String]
        switch provider {
        case .codex:
            candidates = [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/.local/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex"
            ]
        case .claude:
            candidates = [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]
            // نسخة Claude Code المرفقة بتطبيق Claude لسطح المكتب (إن وُجدت)، الأحدث أولًا.
            let bundled = URL(fileURLWithPath: "\(home)/Library/Application Support/Claude/claude-code", isDirectory: true)
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: bundled.path) {
                let newestFirst = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                for version in newestFirst {
                    candidates.append(bundled.appendingPathComponent(version).appendingPathComponent("claude").path)
                }
            }
        }
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

// MARK: - تشغيل الأدوات المحلية

private struct AssistantRunFiles {
    let workspace: URL
    let schema: URL
    let output: URL
    let error: URL
}

private func prepareWorkspace() throws -> AssistantRunFiles {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("lotus-planner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let schemaURL = workspace.appendingPathComponent("plan-schema.json")
    let outputURL = workspace.appendingPathComponent("plan-output.json")
    let errorURL = workspace.appendingPathComponent("assistant-error.txt")
    try JSONSerialization.data(withJSONObject: makePlanSchema()).write(to: schemaURL)
    _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    return AssistantRunFiles(workspace: workspace, schema: schemaURL, output: outputURL, error: errorURL)
}

/// التطبيقات المفتوحة من Finder تحصل على PATH مختصر؛ نضيف المسارات المعتادة
/// حتى تجد الأداة ما تحتاجه (مثل node).
private func assistantEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
    environment["PATH"] = (extraPaths + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
    return environment
}

private func runProcess(
    executableURL: URL,
    arguments: [String],
    files: AssistantRunFiles,
    prompt: String,
    stdoutToOutput: Bool,
    timeout: TimeInterval
) throws -> Int32 {
    let process = Process()
    process.executableURL = executableURL
    process.currentDirectoryURL = files.workspace
    process.arguments = arguments
    process.environment = assistantEnvironment()

    let inputPipe = Pipe()
    process.standardInput = inputPipe
    let errorHandle = try FileHandle(forWritingTo: files.error)
    defer { try? errorHandle.close() }
    process.standardError = errorHandle
    let outputHandle: FileHandle? = try stdoutToOutput ? FileHandle(forWritingTo: files.output) : nil
    defer { try? outputHandle?.close() }
    process.standardOutput = outputHandle ?? FileHandle.nullDevice

    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    try process.run()
    // الصيغة الحديثة ترمي خطأً بدل الانهيار إن أُغلق الأنبوب مبكرًا.
    try? inputPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
    try? inputPipe.fileHandleForWriting.close()

    guard completion.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        throw PlannerAssistantError.execution("استغرق المساعد وقتًا طويلًا. يرجى المحاولة مرة أخرى.")
    }
    return process.terminationStatus
}

private func runCodex(executableURL: URL, model: String, prompt: String, date: Date) throws -> PlannerAIResult {
    let files = try prepareWorkspace()
    defer { try? FileManager.default.removeItem(at: files.workspace) }
    let arguments = [
        "exec",
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules",
        "--skip-git-repo-check",
        "--sandbox", "read-only",
        "--model", model,
        "--cd", files.workspace.path,
        "--output-schema", files.schema.path,
        "--output-last-message", files.output.path,
        "-"
    ]
    let status = try runProcess(
        executableURL: executableURL,
        arguments: arguments,
        files: files,
        prompt: prompt,
        stdoutToOutput: false,
        timeout: 150
    )
    guard status == 0 else {
        let errorText = (try? String(contentsOf: files.error, encoding: .utf8)) ?? ""
        throw PlannerAssistantError.execution(readableError(errorText, provider: .codex))
    }
    guard let data = try? Data(contentsOf: files.output), !data.isEmpty else {
        throw PlannerAssistantError.invalidResponse(.codex)
    }
    return try decodePlan(data, generatedAt: date, provider: .codex)
}

private func runClaude(executableURL: URL, model: String, prompt: String, date: Date) throws -> PlannerAIResult {
    let files = try prepareWorkspace()
    defer { try? FileManager.default.removeItem(at: files.workspace) }
    let schemaData = try JSONSerialization.data(withJSONObject: makePlanSchema())
    let schemaText = String(decoding: schemaData, as: UTF8.self)
    let arguments = [
        "-p",
        "--output-format", "json",
        "--json-schema", schemaText,
        "--model", model,
        "--system-prompt", "أنت مساعد تخطيط داخل تطبيق «خُطاي». لا تستخدم أي أدوات ولا تقرأ أي ملفات؛ أعد النتيجة المنظمة المطلوبة فقط.",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--permission-mode", "dontAsk",
        "--max-turns", "4"
    ]
    let status = try runProcess(
        executableURL: executableURL,
        arguments: arguments,
        files: files,
        prompt: prompt,
        stdoutToOutput: true,
        timeout: 180
    )
    let outputData = (try? Data(contentsOf: files.output)) ?? Data()
    let errorText = (try? String(contentsOf: files.error, encoding: .utf8)) ?? ""
    let envelope = (try? JSONSerialization.jsonObject(with: outputData)) as? [String: Any]

    // أخطاء التشغيل (مثل عدم تسجيل الدخول) تُطبع كنتيجة على stdout.
    let resultText = envelope?["result"] as? String ?? ""
    let isError = (envelope?["is_error"] as? Bool) ?? false
    guard status == 0, !isError else {
        throw PlannerAssistantError.execution(readableError(resultText + "\n" + errorText, provider: .claude))
    }

    if let structured = envelope?["structured_output"],
       JSONSerialization.isValidJSONObject(structured),
       let structuredData = try? JSONSerialization.data(withJSONObject: structured) {
        return try decodePlan(structuredData, generatedAt: date, provider: .claude)
    }
    // احتياط: بعض الإصدارات تعيد JSON داخل النص.
    let cleaned = resultText
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return try decodePlan(Data(cleaned.utf8), generatedAt: date, provider: .claude)
}

private func decodePlan(_ data: Data, generatedAt: Date, provider: AIProvider) throws -> PlannerAIResult {
    guard let payload = try? JSONDecoder().decode(PlanPayload.self, from: data) else {
        throw PlannerAssistantError.invalidResponse(provider)
    }
    return PlannerAIResult(
        date: payload.date,
        overview: payload.overview,
        encouragement: payload.encouragement,
        generatedAt: generatedAt,
        tasks: payload.tasks
    )
}

private func readableError(_ errorText: String, provider: AIProvider) -> String {
    let name = provider == .codex ? "Codex" : "Claude"
    let lowered = errorText.lowercased()
    if lowered.contains("login") || lowered.contains("log in") || lowered.contains("not logged") || lowered.contains("authenticat") {
        return provider == .codex
            ? "يحتاج Codex إلى تسجيل الدخول بحساب ChatGPT أولًا."
            : "يحتاج Claude إلى تسجيل الدخول أولًا (بتشغيل الأمر claude في الطرفية مرة واحدة)."
    }
    if lowered.contains("usage limit") || lowered.contains("rate limit") || lowered.contains("limit reached") {
        return "وصل اشتراكك في \(name) إلى حد الاستخدام الحالي. يرجى المحاولة لاحقًا أو التبديل إلى المزوّد الآخر من الإعدادات."
    }
    if lowered.contains("model") && (lowered.contains("not found") || lowered.contains("invalid") || lowered.contains("not supported")) {
        return "اسم النموذج غير متاح في \(name). يمكن تغييره من الإعدادات."
    }
    return "تعذر تشغيل \(name) الآن. يرجى المحاولة مرة أخرى."
}

// MARK: - النتائج

enum PlannerAIMode {
    /// فهم التفاصيل: الخطوات المذكورة صراحةً + طلبات التخطيط والتذكير.
    case interpretNotes
    /// اقتراح خطوات إضافية فقط بطلب من المستخدمة.
    case suggestSteps
}

struct PlannerAIResult {
    let date: String
    let overview: String
    let encouragement: String
    let generatedAt: Date
    let tasks: [TaskInterpretation]
}

struct TaskInterpretation: Decodable {
    let taskID: String
    let subtasks: [AIStep]
    let suggestions: [AIStep]
    let planning: AIPlanning
    let reminders: [AIReminder]
}

struct AIStep: Decodable {
    let title: String
    let note: String
    let scheduledDate: String?
    let estimatedMinutes: Int?
}

struct AIPlanning: Decodable {
    let effortMinutes: Int?
    let minSessionMinutes: Int?
    let spreadOverDays: Int?
    let earliestStart: String?
    let priority: String?
    let recurrence: String?
}

struct AIReminder: Decodable {
    let label: String
    let minutesBeforeDeadline: Int?
    let dateTime: String?
}

private struct PlanPayload: Decodable {
    let date: String
    let overview: String
    let encouragement: String
    let tasks: [TaskInterpretation]
}

// MARK: - التعليمات

/// ما يُرسل للنموذج عن كل مهمة.
private struct TaskInput: Encodable {
    let id: String
    let title: String
    let deadline: String
    let category: String
    let notes: String
    let existingSteps: [String]
}

private func planningPrompt(tasks: [PlannerTask], mode: PlannerAIMode, date: Date) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let inputs = tasks.map { task in
        TaskInput(
            id: task.id.uuidString,
            title: task.title,
            deadline: PlannerStorage.dateKey(for: task.deadline),
            category: task.category.rawValue,
            notes: task.trimmedNotes,
            existingSteps: (task.subtasks + task.suggestedSubtasks).map(\.title)
        )
    }

    let todayKey = PlannerStorage.dateKey(for: date)
    let tasksJSON = String(decoding: try encoder.encode(inputs), as: UTF8.self)

    let modeInstructions: String
    switch mode {
    case .interpretNotes:
        modeInstructions = """
        المهمة الرئيسية لها موعدها النهائي الخاص (deadline). وnotes تعليمات من صاحبة المهام تحدد ما تريده فقط؛ نفّذها حرفيًا دون اختراع أو جدولة من عندك:
        ١) subtasks: الخطوات التي ذُكرت صراحةً في notes فقط، بصياغتها مع تنقيح بسيط، وبالترتيب الذي ذُكرت به ما لم يُطلب ترتيب آخر. لا تضف أي خطوة لم تُذكر. إن لم تذكر notes خطوات صريحة فاجعل subtasks مصفوفة فارغة.
        ٢) scheduledDate لكل خطوة: null دائمًا، إلا إن حددت notes صراحةً يومًا أو تاريخًا لتلك الخطوة بعينها، فحوّله إلى yyyy-MM-dd. لا توزّع الخطوات على الأيام ولا تقترح أيامًا.
        ٣) estimatedMinutes: ضع المدة فقط إن ذكرتها notes صراحةً لتلك الخطوة، وإلا null.
        note لكل خطوة: اتركه نصًا فارغًا "" إلا إن ذكرت notes تفاصيل لتلك الخطوة بعينها؛ لا تكتب شرحًا من عندك.
        ٤) planning: استخرج فقط ما طُلب صراحةً: effortMinutes للجهد الكلي بالدقائق (مثلًا «ساعتان إلى ثلاث» = 150)، minSessionMinutes لأقل مدة جلسة عمل، spreadOverDays لعدد الأيام المطلوب التوزيع عليها («عدة أيام» = 3)، earliestStart لأول يوم بدء بصيغة yyyy-MM-dd، priority إحدى high أو normal أو low إن ذُكرت الأهمية، recurrence إحدى weekly أو monthly إن طُلب التكرار. ما لم يُذكر اجعله null.
        ٥) reminders: التذكيرات المطلوبة صراحةً فقط، وهي للمهمة الرئيسية ومحسوبة من موعدها النهائي. label وصف عربي قصير مثل «قبل الموعد بيومين». minutesBeforeDeadline للتذكير النسبي (يوم = 1440، يومان = 2880)، أو dateTime بصيغة yyyy-MM-dd HH:mm لوقت محدد، والآخر null. إن لم يُطلب تذكير فاجعلها فارغة.
        ٦) suggestions: مصفوفة فارغة دائمًا في هذا الطلب.
        """
    case .suggestSteps:
        modeInstructions = """
        المطلوب اقتراحات فقط: في suggestions اقترح من خطوتين إلى خمس خطوات عملية مفيدة لإنجاز كل مهمة، لا تكرر existingSteps، واجعل scheduledDate وestimatedMinutes لكل خطوة null. هذه اقتراحات تُعرض للموافقة ولن تُضاف تلقائيًا.
        اجعل subtasks وreminders مصفوفات فارغة، وكل حقول planning قيمتها null.
        """
    }

    return """
    أنت مساعد تخطيط عربي حنون وعملي في تطبيق «خُطاي». خاطب القارئ بصيغة محايدة لا تكشف عن جنسه: استخدم المصدر والجمل الاسمية، وتجنّب صيغ المذكر والمؤنث في الأفعال والضمائر. لا تستخدم الشرطة الطويلة (—) في أي نص، واستخدم الفاصلة أو النقطة بدلها. لا تستخدم أي أدوات ولا تقرأ أي ملفات؛ أعد النتيجة النهائية فقط.
    تاريخ اليوم \(todayKey). استخدم التقويم الميلادي فقط، وأي تاريخ تذكره يكون بصيغة yyyy-MM-dd ومحسوبًا من التعليمات كما وردت.
    أعد عنصرًا واحدًا في tasks لكل مهمة مُدخلة، واجعل taskID مساويًا تمامًا لقيمة id.
    \(modeInstructions)
    في overview اكتب ملخصًا قصيرًا ليوم \(todayKey). وفي encouragement تشجيعًا عربيًا قويًا وحنونًا وقصيرًا بصيغة محايدة.

    المهام بصيغة JSON:
    \(tasksJSON)
    """
}

// MARK: - مخطط النتيجة

private func makePlanSchema() -> [String: Any] {
    let nullableString: [String: Any] = ["type": ["string", "null"]]
    let nullableMinutes: [String: Any] = ["type": ["integer", "null"], "minimum": 1, "maximum": 6000]
    let step: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "note", "scheduledDate", "estimatedMinutes"],
        "properties": [
            "title": ["type": "string"],
            "note": ["type": "string"],
            "scheduledDate": nullableString,
            "estimatedMinutes": nullableMinutes
        ]
    ]
    return [
        "type": "object",
        "additionalProperties": false,
        "required": ["date", "overview", "tasks", "encouragement"],
        "properties": [
            "date": ["type": "string"],
            "overview": ["type": "string"],
            "encouragement": ["type": "string"],
            "tasks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["taskID", "subtasks", "suggestions", "planning", "reminders"],
                    "properties": [
                        "taskID": ["type": "string"],
                        "subtasks": ["type": "array", "items": step],
                        "suggestions": ["type": "array", "items": step],
                        "planning": [
                            "type": "object",
                            "additionalProperties": false,
                            "required": [
                                "effortMinutes", "minSessionMinutes", "spreadOverDays",
                                "earliestStart", "priority", "recurrence"
                            ],
                            "properties": [
                                "effortMinutes": nullableMinutes,
                                "minSessionMinutes": nullableMinutes,
                                "spreadOverDays": ["type": ["integer", "null"], "minimum": 1, "maximum": 365],
                                "earliestStart": nullableString,
                                "priority": nullableString,
                                "recurrence": nullableString
                            ]
                        ],
                        "reminders": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["label", "minutesBeforeDeadline", "dateTime"],
                                "properties": [
                                    "label": ["type": "string"],
                                    "minutesBeforeDeadline": ["type": ["integer", "null"], "minimum": 0, "maximum": 525600],
                                    "dateTime": nullableString
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]
}
